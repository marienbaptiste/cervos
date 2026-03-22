/*
 * Cervos — BLE L2CAP CoC Audio Transport
 *
 * Replaces GATT notification streaming with L2CAP Connection-Oriented Channels.
 * Higher throughput, flow control, and frame batching.
 *
 * Packet format:
 *   [seq_num: u16][timestamp: u32][frame_count: u8][LC3 frame 0][LC3 frame 1]...
 *
 * Resilience:
 *   - Duplicate-frame sending: each packet carries current + previous frame
 *   - RSSI monitoring for adaptive bitrate
 *
 * Also maintains a GATT service for:
 *   - Capture control (0xCE57:0003) — on/off
 *   - DongleConfigService name (0xCF01) — writable, NVS-persisted
 *   - Power mode (0xCF02) — writable, NVS-persisted
 */

#include <zephyr/kernel.h>
#include <zephyr/bluetooth/bluetooth.h>
#include <zephyr/bluetooth/conn.h>
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>
#include <zephyr/bluetooth/l2cap.h>
#include <zephyr/bluetooth/hci.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/settings/settings.h>
#include <zephyr/sys/reboot.h>
#include <zephyr/sys/byteorder.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "audio_buffer.h"
#include "lc3_encoder.h"

LOG_MODULE_REGISTER(ble_audio, LOG_LEVEL_INF);

/* ---- L2CAP CoC PSM ---- */
#define CERVOS_L2CAP_PSM        0x0080  /* Dynamic range PSM for audio */
#define L2CAP_MTU               512
#define L2CAP_BUF_COUNT         16  /* More buffers for async send pipeline */

/* ---- Packet header ---- */
#define PKT_HEADER_SIZE         7  /* u16 seq + u32 timestamp + u8 frame_count */

/* ---- GATT UUIDs ---- */
#define BT_UUID_CERVOS_AUDIO_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0001, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CERVOS_AUDIO BT_UUID_DECLARE_128(BT_UUID_CERVOS_AUDIO_VAL)

#define BT_UUID_CAPTURE_CTRL_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0003, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CAPTURE_CTRL BT_UUID_DECLARE_128(BT_UUID_CAPTURE_CTRL_VAL)

#define BT_UUID_DONGLE_CONFIG_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0xCF01, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_DONGLE_CONFIG BT_UUID_DECLARE_128(BT_UUID_DONGLE_CONFIG_VAL)

#define BT_UUID_POWER_MODE_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0xCF02, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_POWER_MODE BT_UUID_DECLARE_128(BT_UUID_POWER_MODE_VAL)

/* ---- Power modes ---- */
enum power_mode {
    POWER_BATTERY_SAVER = 0,  /* 30ms CI, 50ms buffer */
    POWER_BALANCED      = 1,  /* 15ms CI, 30ms buffer */
    POWER_LOW_LATENCY   = 2,  /* 7.5ms CI, 10ms buffer */
};

/* Connection intervals in 1.25ms units */
static const uint16_t ci_table[] = {
    [POWER_BATTERY_SAVER] = 24,  /* 30ms */
    [POWER_BALANCED]      = 12,  /* 15ms */
    [POWER_LOW_LATENCY]   = 6,   /* 7.5ms */
};

/* ---- State ---- */
static struct bt_conn *current_conn;
static struct bt_l2cap_le_chan l2cap_chan;
static bool l2cap_connected;
static uint8_t capture_enabled = 1;
static uint8_t active_power_mode = POWER_BALANCED;
static bool mono_fallback;  /* Set by RSSI monitor */

/* Sequence counter and timestamp */
static uint16_t seq_num;
static uint32_t frame_timestamp;

/* Previous frame for duplicate-frame resilience */
static uint8_t prev_frame[LC3_MAX_PACKET];
static int prev_frame_len;
static bool has_prev_frame;

/* RSSI monitoring */
#define RSSI_THRESHOLD_MONO     (-75)  /* dBm — switch to mono below this */
#define RSSI_THRESHOLD_STEREO   (-65)  /* dBm — switch back above this (hysteresis) */
#define RSSI_CHECK_INTERVAL_MS  1000

static struct k_work_delayable rssi_work;

/* L2CAP TX buffer pool — must include SDU header reserve for bt_l2cap_chan_send */
NET_BUF_POOL_DEFINE(l2cap_pool, L2CAP_BUF_COUNT,
                    BT_L2CAP_SDU_BUF_SIZE(L2CAP_MTU), 0, NULL);

/* ---- L2CAP callbacks ---- */

static int l2cap_recv(struct bt_l2cap_chan *chan, struct net_buf *buf)
{
    /* Phone → dongle: not used for audio, but could carry control */
    net_buf_unref(buf);
    return 0;
}

static void l2cap_connected_cb(struct bt_l2cap_chan *chan)
{
    l2cap_connected = true;
    seq_num = 0;
    frame_timestamp = 0;
    has_prev_frame = false;
    mono_fallback = false;
    LOG_INF("L2CAP CoC connected — audio streaming ready");
}

static void l2cap_disconnected_cb(struct bt_l2cap_chan *chan)
{
    l2cap_connected = false;
    has_prev_frame = false;
    LOG_INF("L2CAP CoC disconnected");
}

static struct bt_l2cap_chan_ops l2cap_ops = {
    .recv = l2cap_recv,
    .connected = l2cap_connected_cb,
    .disconnected = l2cap_disconnected_cb,
};

static int l2cap_accept(struct bt_conn *conn, struct bt_l2cap_server *server,
                         struct bt_l2cap_chan **chan)
{
    memset(&l2cap_chan, 0, sizeof(l2cap_chan));
    l2cap_chan.chan.ops = &l2cap_ops;
    l2cap_chan.rx.mtu = L2CAP_MTU;

    *chan = &l2cap_chan.chan;
    LOG_INF("L2CAP CoC accept");
    return 0;
}

static struct bt_l2cap_server l2cap_server = {
    .psm = CERVOS_L2CAP_PSM,
    .accept = l2cap_accept,
};

/* ---- RSSI monitoring for adaptive bitrate ---- */

static void rssi_work_handler(struct k_work *work)
{
    if (!current_conn) {
        return;
    }

    /*
     * Read RSSI via HCI Read RSSI command.
     * Zephyr exposes connection handle via bt_conn_get_info().
     */
    struct bt_conn_info info;
    int err = bt_conn_get_info(current_conn, &info);
    if (err) {
        k_work_reschedule(&rssi_work, K_MSEC(RSSI_CHECK_INTERVAL_MS));
        return;
    }

    struct bt_hci_cp_read_rssi *cp;
    struct bt_hci_rp_read_rssi *rp;
    struct net_buf *buf, *rsp = NULL;

    buf = bt_hci_cmd_create(BT_HCI_OP_READ_RSSI, sizeof(*cp));
    if (!buf) {
        k_work_reschedule(&rssi_work, K_MSEC(RSSI_CHECK_INTERVAL_MS));
        return;
    }

    cp = net_buf_add(buf, sizeof(*cp));
    cp->handle = sys_cpu_to_le16(info.id);

    err = bt_hci_cmd_send_sync(BT_HCI_OP_READ_RSSI, buf, &rsp);
    if (err || !rsp) {
        k_work_reschedule(&rssi_work, K_MSEC(RSSI_CHECK_INTERVAL_MS));
        return;
    }

    rp = (void *)rsp->data;
    int8_t rssi = rp->rssi;
    net_buf_unref(rsp);

    /* Hysteresis to avoid rapid toggling */
    if (!mono_fallback && rssi < RSSI_THRESHOLD_MONO) {
        mono_fallback = true;
        LOG_WRN("RSSI %d dBm — falling back to mono", rssi);
    } else if (mono_fallback && rssi > RSSI_THRESHOLD_STEREO) {
        mono_fallback = false;
        LOG_INF("RSSI %d dBm — restored stereo", rssi);
    }

    k_work_reschedule(&rssi_work, K_MSEC(RSSI_CHECK_INTERVAL_MS));
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
    if (len == 0 || len > 32) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    memcpy(dongle_name, buf, len);
    dongle_name[len] = '\0';

    /* Persist to NVS */
    settings_save_one("cervos/name", dongle_name, len + 1);
    LOG_INF("Dongle name set to \"%s\" — reboot to apply", dongle_name);

    /* Trigger soft-reset so new name takes effect on BLE GAP + USB product string */
    k_sleep(K_MSEC(100));
    sys_reboot(SYS_REBOOT_WARM);

    return len;  /* Unreachable after reboot, but keeps compiler happy */
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
    if (len != 1) {
        return BT_GATT_ERR(BT_ATT_ERR_INVALID_ATTRIBUTE_LEN);
    }

    uint8_t val = *((const uint8_t *)buf);
    if (val > POWER_LOW_LATENCY) {
        return BT_GATT_ERR(BT_ATT_ERR_VALUE_NOT_ALLOWED);
    }

    active_power_mode = val;

    /* Persist to NVS */
    settings_save_one("cervos/power_mode", &active_power_mode, 1);

    /* Apply new connection interval if connected */
    if (current_conn) {
        uint16_t ci = ci_table[active_power_mode];
        struct bt_le_conn_param param = {
            .interval_min = ci,
            .interval_max = ci,
            .latency = 0,
            .timeout = 400,
        };
        bt_conn_le_param_update(current_conn, &param);
    }

    LOG_INF("Power mode set to %d — CI %d×1.25ms",
            active_power_mode, ci_table[active_power_mode]);
    return len;
}

/* ---- NVS settings handler ---- */

static int settings_set(const char *name, size_t len,
                         settings_read_cb read_cb, void *cb_arg)
{
    if (!strcmp(name, "name")) {
        int rc = read_cb(cb_arg, dongle_name, sizeof(dongle_name) - 1);
        if (rc > 0) {
            dongle_name[rc] = '\0';
        }
        return 0;
    }
    if (!strcmp(name, "power_mode")) {
        int rc = read_cb(cb_arg, &active_power_mode, 1);
        if (rc == 1 && active_power_mode > POWER_LOW_LATENCY) {
            active_power_mode = POWER_BALANCED;
        }
        return 0;
    }
    return -ENOENT;
}

SETTINGS_STATIC_HANDLER_DEFINE(cervos, "cervos", NULL, settings_set, NULL, NULL);

/* ---- GATT service definition ---- */

BT_GATT_SERVICE_DEFINE(cervos_audio_svc,
    BT_GATT_PRIMARY_SERVICE(BT_UUID_CERVOS_AUDIO),

    /* Capture control: read/write */
    BT_GATT_CHARACTERISTIC(BT_UUID_CAPTURE_CTRL,
        BT_GATT_CHRC_READ | BT_GATT_CHRC_WRITE,
        BT_GATT_PERM_READ | BT_GATT_PERM_WRITE,
        read_capture_ctrl, write_capture_ctrl, &capture_enabled),

    /* Dongle name config: read/write */
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
    audio_buffer_flush(&audio_ring_buffer);

    /* Request Data Length Extension */
    struct bt_conn_le_data_len_param dl_param = {
        .tx_max_len = 251,
        .tx_max_time = 2120,
    };
    bt_conn_le_data_len_update(conn, &dl_param);

    /* Apply connection interval for active power mode */
    uint16_t ci = ci_table[active_power_mode];
    struct bt_le_conn_param conn_param = {
        .interval_min = ci,
        .interval_max = ci,
        .latency = 0,
        .timeout = 400,
    };
    bt_conn_le_param_update(conn, &conn_param);

    /* Start RSSI monitoring */
    k_work_reschedule(&rssi_work, K_MSEC(RSSI_CHECK_INTERVAL_MS));
}

static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    LOG_INF("BLE disconnected (reason %u)", reason);
    if (current_conn) {
        bt_conn_unref(current_conn);
        current_conn = NULL;
    }
    l2cap_connected = false;
    capture_enabled = 0;
    has_prev_frame = false;

    /* Stop RSSI monitoring */
    k_work_cancel_delayable(&rssi_work);
}

BT_CONN_CB_DEFINE(conn_callbacks) = {
    .connected = connected,
    .disconnected = disconnected,
};

/* ---- Audio send over L2CAP ---- */

int ble_audio_send_lc3(const uint8_t *lc3_data, size_t lc3_len)
{
    if (!current_conn || !l2cap_connected || !capture_enabled) {
        return -ENOTCONN;
    }

    /*
     * Build packet: [seq_num:u16][timestamp:u32][frame_count:u8][frames...]
     *
     * With duplicate-frame resilience:
     *   frame_count = 2 (current + previous), or 1 for the first frame
     */
    uint8_t frame_count = has_prev_frame ? 2 : 1;

    struct net_buf *buf = net_buf_alloc(&l2cap_pool, K_NO_WAIT);
    if (!buf) {
        /* BLE can't keep up — drop this frame silently */
        return 0;
    }

    /* Reserve headroom for L2CAP SDU header */
    net_buf_reserve(buf, BT_L2CAP_SDU_CHAN_SEND_RESERVE);

    /* Header */
    net_buf_add_le16(buf, seq_num);
    net_buf_add_le32(buf, frame_timestamp);
    net_buf_add_u8(buf, frame_count);

    /* Previous frame (duplicate for resilience) */
    if (has_prev_frame) {
        net_buf_add_mem(buf, prev_frame, prev_frame_len);
    }

    /* Current frame */
    net_buf_add_mem(buf, lc3_data, lc3_len);

    /* Send over L2CAP CoC */
    int ret = bt_l2cap_chan_send(&l2cap_chan.chan, buf);
    if (ret < 0) {
        net_buf_unref(buf);
        return ret;
    }

    /* Save current frame as previous for next packet */
    memcpy(prev_frame, lc3_data, lc3_len);
    prev_frame_len = lc3_len;
    has_prev_frame = true;

    seq_num++;
    frame_timestamp += AUDIO_FRAME_MS;  /* 10ms per frame */

    return 0;
}

/* ---- Getters for main loop ---- */

bool ble_audio_is_mono_fallback(void)
{
    return mono_fallback;
}

/* ---- BLE advertising data ---- */

static const struct bt_data ad[] = {
    BT_DATA_BYTES(BT_DATA_FLAGS, (BT_LE_AD_GENERAL | BT_LE_AD_NO_BREDR)),
    BT_DATA_BYTES(BT_DATA_UUID128_ALL, BT_UUID_CERVOS_AUDIO_VAL),
};

static const struct bt_data sd[] = {
    BT_DATA(BT_DATA_NAME_COMPLETE, CONFIG_BT_DEVICE_NAME,
            sizeof(CONFIG_BT_DEVICE_NAME) - 1),
};

/* ---- Init ---- */

int ble_audio_init(void)
{
    int ret;

    /* Load saved settings (name, power mode) — non-fatal */
    int settings_err = settings_subsys_init();
    if (settings_err) {
        LOG_WRN("Settings init failed: %d — using defaults", settings_err);
    } else {
        settings_load();
    }

    k_work_init_delayable(&rssi_work, rssi_work_handler);

    ret = bt_enable(NULL);
    if (ret) {
        LOG_ERR("Bluetooth init failed: %d", ret);
        return ret;
    }

    /* Register L2CAP server for audio streaming */
    ret = bt_l2cap_server_register(&l2cap_server);
    if (ret) {
        LOG_ERR("L2CAP server register failed: %d", ret);
        return ret;
    }

    /* Request 2M PHY for higher throughput */
    /* PHY update will be negotiated after connection */

    ret = bt_le_adv_start(BT_LE_ADV_CONN, ad, ARRAY_SIZE(ad), sd, ARRAY_SIZE(sd));
    if (ret) {
        LOG_ERR("Advertising start failed: %d", ret);
        return ret;
    }

    LOG_INF("BLE advertising as \"%s\" — L2CAP PSM 0x%04X",
            dongle_name, CERVOS_L2CAP_PSM);
    return 0;
}
