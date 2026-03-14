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
#include <zephyr/bluetooth/gatt.h>
#include <zephyr/bluetooth/uuid.h>

#include "audio_buffer.h"

/* Custom BLE Audio Service UUID */
#define BT_UUID_CERVOS_AUDIO_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0001, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_CERVOS_AUDIO BT_UUID_DECLARE_128(BT_UUID_CERVOS_AUDIO_VAL)

/* Audio Stream Characteristic UUID */
#define BT_UUID_AUDIO_STREAM_VAL \
    BT_UUID_128_ENCODE(0xCE570500, 0x0002, 0x4000, 0x8000, 0x00805F9B34FB)
#define BT_UUID_AUDIO_STREAM BT_UUID_DECLARE_128(BT_UUID_AUDIO_STREAM_VAL)

#define FRAME_SIZE_MS   20
#define SAMPLE_RATE     16000
#define SAMPLES_PER_FRAME (SAMPLE_RATE * FRAME_SIZE_MS / 1000)
#define FRAME_BYTES     (SAMPLES_PER_FRAME * 2) /* 16-bit samples */

static struct bt_conn *current_conn;
static bool notify_enabled;

/**
 * BLE connected callback.
 */
static void connected(struct bt_conn *conn, uint8_t err)
{
    if (err) {
        return;
    }
    current_conn = bt_conn_ref(conn);
}

/**
 * BLE disconnected callback.
 */
static void disconnected(struct bt_conn *conn, uint8_t reason)
{
    if (current_conn) {
        bt_conn_unref(current_conn);
        current_conn = NULL;
    }
}

/**
 * Stream audio frames from the USB capture buffer to the phone over BLE.
 * Called from the main loop at 20ms intervals.
 */
int ble_audio_send_frame(const int16_t *pcm_data, size_t samples)
{
    if (!current_conn || !notify_enabled) {
        return -ENOTCONN;
    }

    /* TODO: Send PCM frame as GATT notification */
    return 0;
}

/**
 * Initialize BLE and register the audio GATT service.
 */
int ble_audio_init(void)
{
    int ret;

    ret = bt_enable(NULL);
    if (ret) {
        return ret;
    }

    /* TODO: Register GATT service */
    /* TODO: Start advertising as "Meeting Audio" */

    return 0;
}
