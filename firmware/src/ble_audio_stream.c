/*
 * Cervos — nRF52840 BLE Audio Stream
 *
 * BLE side: streams captured meeting audio to the phone via a custom
 * BLE GATT audio service. 20ms PCM frames at 16kHz.
 *
 * The phone receives this stream and does two things:
 * 1. Plays it through BLE earbuds (you hear the meeting)
 * 2. Forwards raw PCM to Mac Studio via Tailscale (for STT + diarization)
 *
 * Runs simultaneously with USB Audio Capture on the same nRF52840.
 *
 * Platform: Zephyr RTOS
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(ble_audio, LOG_LEVEL_INF);

/* Custom BLE Audio Service UUID: CE570500-0001-4000-8000-00805F9B34FB */
#define BT_UUID_CERVOS_AUDIO_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0001, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CERVOS_AUDIO BT_UUID_DECLARE_128(BT_UUID_CERVOS_AUDIO_VAL)

/* Audio Stream Characteristic UUID: CE570500-0002-4000-8000-00805F9B34FB */
#define BT_UUID_AUDIO_STREAM_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0002, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_AUDIO_STREAM BT_UUID_DECLARE_128(BT_UUID_AUDIO_STREAM_VAL)

static struct bt_conn *current_conn;
static bool notify_enabled;

/* Track in-flight notifications to avoid overrunning TX queue */
static volatile int notifications_in_flight;
#define MAX_NOTIFICATIONS_IN_FLIGHT 4

/**
 * CCC (Client Characteristic Configuration) changed callback.
 * Called when the phone subscribes/unsubscribes to audio notifications.
 */
static void ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Audio notifications %s", notify_enabled ? "enabled" : "disabled");
}

/* GATT service definition */
BT_GATT_SERVICE_DEFINE(cervos_audio_svc,
    BT_GATT_PRIMARY_SERVICE(BT_UUID_CERVOS_AUDIO),
    BT_GATT_CHARACTERISTIC(BT_UUID_AUDIO_STREAM,
        BT_GATT_CHRC_NOTIFY,
        BT_GATT_PERM_NONE,
        NULL, NULL, NULL),
    BT_GATT_CCC(ccc_cfg_changed,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
);

/**
 * BLE connected callback.
 */
static void connected(struct bt_conn *conn, uint8_t err)
{
    if (err) {
        LOG_ERR("BLE connection failed (err %u)", err);
        return;
    }

    current_conn = bt_conn_ref(conn);
    notifications_in_flight = 0;
    LOG_INF("BLE connected");

    /* Request Data Length Extension for larger packets */
    struct bt_conn_le_data_len_param dl_param = {
        .tx_max_len = 251,
        .tx_max_time = 2120,
    };
    bt_conn_le_data_len_update(conn, &dl_param);
}

/**
 * BLE disconnected callback.
 */
static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    LOG_INF("BLE disconnected (reason %u)", reason);

    if (current_conn) {
        bt_conn_unref(current_conn);
        current_conn = NULL;
    }
    notify_enabled = false;
    notifications_in_flight = 0;
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
    .connected = connected,
    .disconnected = disconnected,
};

/**
 * Notification sent callback — track in-flight count for backpressure.
 */
static void notify_sent_cb(struct bt_conn *conn, void *user_data)
{
    ARG_UNUSED(user_data);

    if (notifications_in_flight > 0) {
        notifications_in_flight--;
    }
}

/**
 * Stream one audio frame from the USB capture buffer to the phone over BLE.
 * Called from the main loop at 20ms intervals.
 *
 * Sends 640 bytes as a single GATT notification. The BLE controller
 * handles L2CAP fragmentation transparently with DLE enabled.
 */
int ble_audio_send_frame(const int16_t *pcm_data, size_t samples)
{
    if (!current_conn || !notify_enabled) {
        return -ENOTCONN;
    }

    /* Backpressure: don't queue too many notifications */
    if (notifications_in_flight >= MAX_NOTIFICATIONS_IN_FLIGHT) {
        LOG_WRN("BLE TX backpressure — dropping frame");
        return -ENOMEM;
    }

    struct bt_gatt_notify_params params = {
        .attr = &cervos_audio_svc.attrs[2], /* Audio stream characteristic value */
        .data = pcm_data,
        .len = samples * sizeof(int16_t),
        .func = notify_sent_cb,
    };

    int ret = bt_gatt_notify_cb(current_conn, &params);
    if (ret == 0) {
        notifications_in_flight++;
    } else if (ret == -ENOMEM) {
        LOG_WRN("BLE notify buffer full — dropping frame");
    } else {
        LOG_ERR("BLE notify failed: %d", ret);
    }

    return ret;
}

/* Advertising data */
static const struct bt_data ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA_BYTES(BT_DATA_UUID128_ALL, BT_UUID_CERVOS_AUDIO_VAL),
};

/* Scan response — includes device name */
static const struct bt_data sd[] = {
    BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME,
            sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

/**
 * Initialize BLE and start advertising as "cervhole dongle".
 */
int ble_audio_init(void)
{
    int ret;

    ret = bt_enable(NULL);
    if (ret) {
        LOG_ERR("Bluetooth init failed: %d", ret);
        return ret;
    }

    LOG_INF("Bluetooth initialized");

    /* Start advertising with service UUID so Flutter app can filter by it */
    ret = bt_le_adv_start(BT_LE_ADV_CONN, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
    if (ret) {
        LOG_ERR("Advertising start failed: %d", ret);
        return ret;
    }

    LOG_INF("BLE advertising as \"%s\"", CONFIG_BT_DEVICE_NAME);
    return 0;
}
