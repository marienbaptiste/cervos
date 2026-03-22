/*
 * Cervos — nRF52840 Dongle Main
 *
 * Pipeline: USB 48kHz stereo → LC3 encode → BLE L2CAP CoC
 *
 * LC3 codec (google/liblc3): 48kHz stereo, 10ms frames, ~160kbps
 * With RSSI-driven adaptive bitrate fallback to mono.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"
#include "lc3_encoder.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

extern int usb_audio_init(void);
extern int ble_audio_init(void);
extern int ble_audio_send_lc3(const uint8_t *data, size_t len);
extern bool ble_audio_is_mono_fallback(void);

int main(void)
{
    int ret;

    LOG_INF("Cervos nRF52840 dongle starting...");

    audio_buffer_init(&audio_ring_buffer);

    /* BLE first — includes settings load, L2CAP server, GATT services */
    ret = ble_audio_init();
    if (ret) {
        LOG_ERR("BLE init failed: %d", ret);
        return ret;
    }

    /* USB audio */
    ret = usb_audio_init();
    if (ret) {
        LOG_WRN("USB init issue: %d", ret);
    }

    LOG_INF("Dongle ready — raw PCM 24kHz mono over GATT");

    static int16_t pcm_frame[AUDIO_FRAME_SAMPLES];

    while (1) {
        k_sem_take(&audio_ring_buffer.frame_ready, K_FOREVER);

        if (audio_buffer_read(&audio_ring_buffer, pcm_frame, AUDIO_FRAME_SAMPLES) == 0) {
            /* Send raw PCM in 240-byte chunks — 960 bytes / 240 = 4 notifications */
            const uint8_t *data = (const uint8_t *)pcm_frame;
            size_t total = AUDIO_FRAME_BYTES;
            size_t offset = 0;
            while (offset < total) {
                size_t len = total - offset;
                if (len > 240) len = 240;
                ble_audio_send_lc3(&data[offset], len);
                offset += len;
            }
        }
    }

    return 0;
}
