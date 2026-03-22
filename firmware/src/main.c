/*
 * Cervos — nRF52840 Dongle Main
 *
 * Pipeline: USB 48kHz stereo → downsample 24kHz mono → LC3 encode → BLE GATT notify
 * Falls back to raw PCM if LC3 init fails.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"
#include "lc3_encoder.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

extern int usb_audio_init(void);
extern int ble_audio_init(void);
extern int ble_audio_send_lc3(const uint8_t *data, size_t len);

static bool lc3_ok = false;

int main(void)
{
    int ret;

    LOG_INF("Cervos nRF52840 dongle starting...");

    audio_buffer_init(&audio_ring_buffer);

    ret = ble_audio_init();
    if (ret) {
        LOG_ERR("BLE init failed: %d", ret);
        return ret;
    }

    ret = usb_audio_init();
    if (ret) {
        LOG_WRN("USB init issue: %d", ret);
    }

    /* LC3 encoder — non-fatal, fall back to raw PCM */
    ret = lc3_enc_init();
    if (ret == 0) {
        lc3_ok = true;
    } else {
        LOG_WRN("LC3 init failed: %d — raw PCM fallback", ret);
    }

    LOG_INF("Dongle ready — codec: %s",
            lc3_ok ? "LC3 24kHz mono 48kbps" : "raw PCM 24kHz mono");

    static int16_t pcm_frame[AUDIO_FRAME_SAMPLES];
    static uint8_t lc3_packet[LC3_MAX_PACKET];

    while (1) {
        k_sem_take(&audio_ring_buffer.frame_ready, K_FOREVER);

        if (audio_buffer_read(&audio_ring_buffer, pcm_frame, AUDIO_FRAME_SAMPLES) == 0) {
            if (lc3_ok) {
                int encoded = lc3_enc_encode(pcm_frame, lc3_packet,
                                             sizeof(lc3_packet));
                if (encoded > 0) {
                    ble_audio_send_lc3(lc3_packet, encoded);
                }
            } else {
                /* Raw PCM fallback in 240-byte chunks */
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
    }

    return 0;
}
