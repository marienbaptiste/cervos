/*
 * Cervos — BLE Audio Transport
 *
 * GATT notification-based audio streaming with LC3 codec.
 * Each notification carries one packet:
 *   [seq_num:u16][timestamp:u32][frame_count:u8][LC3 frame]
 *
 * LC3 stereo frame = 200 bytes + 7 byte header = 207 bytes.
 * Fits in a single GATT notification with DLE (max 244 bytes payload).
 *
 * Also maintains GATT characteristics for config (capture control,
 * dongle name, power mode).
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "audio_buffer.h"
#include "lc3_encoder.h"

LOG_MODULE_REGISTER(ble_audio, LOG_LEVEL_INF);

/* ---- Packet header ---- */
#define PKT_HEADER_SIZE  7  /* u16 seq + u32 timestamp + u8 frame_count */

/* ---- GATT UUIDs ---- */
#define BT_UUID_CERVOS_AUDIO_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0001, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CERVOS_AUDIO BT_UUID_DECLARE_128(BT_UUID_CERVOS_AUDIO_VAL)

#define BT_UUID_AUDIO_STREAM_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0002, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_AUDIO_STREAM BT_UUID_DECLARE_128(BT_UUID_AUDIO_STREAM_VAL)

#define BT_UUID_CAPTURE_CTRL_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0003, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CAPTURE_CTRL BT_UUID_DECLARE_128(BT_UUID_CAPTURE_CTRL_VAL)

#define BT_UUID_DONGLE_CONFIG_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0xCF01, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_DONGLE_CONFIG BT_UUID_DECLARE_128(BT_UUID_DONGLE_CONFIG_VAL)

#define BT_UUID_POWER_MODE_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0xCF02, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_POWER_MODE BT_UUID_DECLARE_128(BT_UUID_POWER_MODE_VAL)

/* ---- State ---- */
static struct bt_conn *current_conn;
static bool notify_enabled;
static uint8_t capture_enabled = 1;
static uint8_t active_power_mode = 1;  /* Balanced */

/* Sequence counter and timestamp */
static uint16_t seq_num;
static uint32_t frame_timestamp;

/* ---- GATT: CCC changed ---- */

static void ccc_cfg_changed(const struct bt_gatt_attr *attr, uint16_t value)
{
    notify_enabled = (value == BT_GATT_CCC_NOTIFY);
    LOG_INF("Audio notifications %s", notify_enabled ? "enabled" : "disabled");
}

/* ---- GATT: capture control ---- */

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
    if (len != 1) return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    uint8_t val = *((const uint8_t *)buf);
    if (val > 1) return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    capture_enabled = val;
    if (capture_enabled) {
        usb_enable(NULL);
        LOG_INF("Capture ON");
    } else {
        usb_disable();
        LOG_INF("Capture OFF");
    }
    return len;
}

/* ---- GATT: dongle name config (0xCF01) ---- */

static char dongle_name[33] = CONFIG_BT_DEVICE_NAME;

static ssize_t read_dongle_name(struct bt_conn *conn,
                                 const struct bt_gatt_attr *attr,
                                 void *buf, uint16_t len, uint16_t offset)
{
    return bt_gatt_attr_read(conn, attr, buf, len, offset,
                             dongle_name, strlen(dongle_name));
}

static ssize_t write_dongle_name(struct bt_conn *conn,
                                  const struct bt_gatt_attr *attr,
                                  const void *buf, uint16_t len,
                                  uint16_t offset, uint8_t flags)
{
    if (len == 0 || len > 32) return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    memcpy(dongle_name, buf, len);
    dongle_name[len] = '\0';
    settings_save_one("cervos/name", dongle_name, len + 1);
    LOG_INF("Name set to \"%s\" — rebooting", dongle_name);
    k_sleep(K_MSEC(100));
    sys_reboot(SYS_REBOOT_WARM);
    return len;
}

/* ---- GATT: power mode (0xCF02) ---- */

static ssize_t read_power_mode(struct bt_conn *conn,
                                const struct bt_gatt_attr *attr,
                                void *buf, uint16_t len, uint16_t offset)
{
    return bt_gatt_attr_read(conn, attr, buf, len, offset,
                             &active_power_mode, sizeof(active_power_mode));
}

static ssize_t write_power_mode(struct bt_conn *conn,
                                 const struct bt_gatt_attr *attr,
                                 const void *buf, uint16_t len,
                                 uint16_t offset, uint8_t flags)
{
    if (len != 1) return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    uint8_t val = *((const uint8_t *)buf);
    if (val > 2) return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    active_power_mode = val;
    settings_save_one("cervos/power_mode", &active_power_mode, 1);
    LOG_INF("Power mode set to %d", active_power_mode);
    return len;
}

/* ---- NVS settings ---- */

static int settings_set(const char *name, size_t len,
                         settings_read_cb read_cb, void *cb_arg)
{
    if (!strcmp(name, "name")) {
        int rc = read_cb(cb_arg, dongle_name, sizeof(dongle_name) - 1);
        if (rc > 0) dongle_name[rc] = '\0';
        return 0;
    }
    if (!strcmp(name, "power_mode")) {
        int rc = read_cb(cb_arg, &active_power_mode, 1);
        if (rc == 1 && active_power_mode > 2) active_power_mode = 1;
        return 0;
    }
    return -ENOENT;
}

SETTINGS_STATIC_HANDLER_DEFINE(cervos, "cervos", NULL, settings_set, NULL, NULL);

/* ---- GATT service definition ---- */

BT_GATT_SERVICE_DEFINE(cervos_audio_svc,
    BT_GATT_PRIMARY_SERVICE(BT_UUID_CERVOS_AUDIO),

    /* Audio stream: notify */
    BT_GATT_CHARACTERISTIC(BT_UUID_AUDIO_STREAM,
        BT_GATT_CHRC_NOTIFY,
        BT_GATT_PERM_NONE,
        NULL, NULL, NULL),
    BT_GATT_CCC(ccc_cfg_changed,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE),

    /* Capture control: read/write */
    BT_GATT_CHARACTERISTIC(BT_UUID_CAPTURE_CTRL,
        BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
        read_capture_ctrl, write_capture_ctrl, &capture_enabled),

    /* Dongle name: read/write */
    BT_GATT_CHARACTERISTIC(BT_UUID_DONGLE_CONFIG,
        BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
        read_dongle_name, write_dongle_name, NULL),

    /* Power mode: read/write */
    BT_GATT_CHARACTERISTIC(BT_UUID_POWER_MODE,
        BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
        read_power_mode, write_power_mode, &active_power_mode),
);

/* ---- BLE connection callbacks ---- */

static void connected(struct bt_conn *conn, uint8_t err)
{
    if (err) {
        LOG_ERR("BLE connection failed (err %u)", err);
        return;
    }
    current_conn = bt_conn_ref(conn);
    LOG_INF("BLE connected");

    capture_enabled = 1;
    seq_num = 0;
    frame_timestamp = 0;

    audio_buffer_flush(&audio_ring_buffer);

    /* Request DLE for larger notifications */
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
        .timeout = 400,
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
    capture_enabled = 0;
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
    .connected = connected,
    .disconnected = disconnected,
};

/* ---- Audio send over GATT notify ---- */

/* Send raw data as GATT notification — no header wrapping */
int ble_audio_send_lc3(const uint8_t *data, size_t len)
{
    if (!current_conn || !notify_enabled || !capture_enabled) {
        return -ENOTCONN;
    }

    return bt_gatt_notify(current_conn,
                          &cervos_audio_svc.attrs[2],
                          data, len);
}

bool ble_audio_is_mono_fallback(void)
{
    return false;  /* No RSSI monitoring in GATT mode */
}

/* ---- BLE advertising ---- */

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

    /* Load saved settings — non-fatal */
    int settings_err = settings_subsys_init();
    if (settings_err) {
        LOG_WRN("Settings init failed: %d — using defaults", settings_err);
    } else {
        settings_load();
    }

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

    LOG_INF("BLE advertising as \"%s\" — GATT notify transport", dongle_name);
    return 0;
}
