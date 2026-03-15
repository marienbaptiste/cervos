/*
 * Cervos — nRF52840 BLE Audio Stream
 *
 * BLE GATT service with:
 * - Audio stream characteristic (notify) — 24kHz mono PCM frames
 * - Capture control characteristic (write) — 0x00=off, 0x01=on
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(ble_audio, LOG_LEVEL_INF);

#define BT_UUID_CERVOS_AUDIO_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0001, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CERVOS_AUDIO BT_UUID_DECLARE_128(BT_UUID_CERVOS_AUDIO_VAL)

#define BT_UUID_AUDIO_STREAM_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0002, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_AUDIO_STREAM BT_UUID_DECLARE_128(BT_UUID_AUDIO_STREAM_VAL)

#define BT_UUID_CAPTURE_CTRL_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0003, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CAPTURE_CTRL BT_UUID_DECLARE_128(BT_UUID_CAPTURE_CTRL_VAL)

static struct bt_conn *current_conn;
static bool notify_enabled;
static uint8_t capture_enabled = 1;

static void ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Audio notifications %s", notify_enabled ? "enabled" : "disabled");
}

static ssize_t read_capture_ctrl(struct bt_conn *conn,
                                  const struct bt_gatt_attr *attr,
                                  void *buf, uint16_t len, uint16_t offset)
{
    return bt_gatt_attr_read(conn, attr, buf, len, offset,
                             &capture_enabled, sizeof(capture_enabled));
}

static ssize_t write_capture_ctrl(struct bt_conn *conn,
                                   const struct bt_gatt_attr *attr,
                                   const void *buf, uint16_t len,
                                   uint16_t offset, uint8_t flags)
{
    if (len != 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t val = *((const uint8_t *)buf);
    if (val > 1) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }

    capture_enabled = val;

    if (capture_enabled) {
        usb_enable(NULL);
        LOG_INF("Capture ON — USB audio enabled");
    } else {
        usb_disable();
        LOG_INF("Capture OFF — USB audio released");
    }

    return len;
}

BT_GATT_SERVICE_DEFINE(cervos_audio_svc,
    BT_GATT_PRIMARY_SERVICE(BT_UUID_CERVOS_AUDIO),
    BT_GATT_CHARACTERISTIC(BT_UUID_AUDIO_STREAM,
        BT_GATT_CHRC_NOTIFY,
        BT_GATT_PERM_NONE,
        NULL, NULL, NULL),
    BT_GATT_CCC(ccc_cfg_changed,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),
    BT_GATT_CHARACTERISTIC(BT_UUID_CAPTURE_CTRL,
        BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
        read_capture_ctrl, write_capture_ctrl, &capture_enabled),
);

static void connected(struct bt_conn *conn, uint8_t err)
{
    if (err) {
        LOG_ERR("BLE connection failed (err %u)", err);
        return;
    }
    current_conn = bt_conn_ref(conn);
    LOG_INF("BLE connected");

    /* Flush stale audio from ring buffer */
    audio_buffer_flush(&audio_ring_buffer);

    struct bt_conn_le_data_len_param dl_param = {
        .tx_max_len = 251,
        .tx_max_time = 2120,
    };
    bt_conn_le_data_len_update(conn, &dl_param);

    /* Request fastest connection interval: 7.5ms */
    struct bt_le_conn_param conn_param = {
        .interval_min = 6,   /* 6 × 1.25ms = 7.5ms */
        .interval_max = 6,
        .latency = 0,
        .timeout = 400,      /* 4 seconds */
    };
    bt_conn_le_param_update(conn, &conn_param);
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    LOG_INF("BLE disconnected (reason %u)", reason);
    if (current_conn) {
        bt_conn_unref(current_conn);
        current_conn = NULL;
    }
    notify_enabled = false;
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
    .connected = connected,
    .disconnected = disconnected,
};

int ble_audio_send_frame(const int16_t *pcm_data, size_t samples)
{
    if (!current_conn || !capture_enabled) {
        return -ENOTCONN;
    }

    const uint8_t *data = (const uint8_t *)pcm_data;
    size_t total_len = samples * sizeof(int16_t);
    const size_t chunk_size = 240;
    size_t offset = 0;
    int ret = 0;

    while (offset < total_len) {
        size_t len = total_len - offset;
        if (len > chunk_size) {
            len = chunk_size;
        }

        ret = bt_gatt_notify(current_conn,
                             &cervos_audio_svc.attrs[2],
                             &data[offset],
                             len);
        if (ret != 0) {
            break;
        }
        offset += len;
    }

    return ret;
}

static const struct bt_data ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA_BYTES(BT_DATA_UUID128_ALL, BT_UUID_CERVOS_AUDIO_VAL),
};

static const struct bt_data sd[] = {
    BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME,
            sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

int ble_audio_init(void)
{
    int ret;

    ret = bt_enable(NULL);
    if (ret) {
        LOG_ERR("Bluetooth init failed: %d", ret);
        return ret;
    }

    ret = bt_le_adv_start(BT_LE_ADV_CONN, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
    if (ret) {
        LOG_ERR("Advertising start failed: %d", ret);
        return ret;
    }

    LOG_INF("BLE advertising as \"%s\"", CONFIG_BT_DEVICE_NAME);
    return 0;
}
