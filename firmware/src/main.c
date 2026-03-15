/*
 * Cervos — nRF52840 Dongle Main
 *
 * "cervhole headset" (USB) / "cervhole dongle" (BLE)
 *
 * Pipeline: USB 48kHz stereo → Opus encode → BLE compressed packets
 * Falls back to raw PCM if Opus init fails.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"
#include "opus_encoder_wrapper.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

extern int usb_audio_init(void);
extern int ble_audio_init(void);
extern int ble_audio_send_opus(const uint8_t *data, size_t len);

static bool opus_ok = false;

int main(void)
{
    int ret;

    LOG_INF("Cervos nRF52840 dongle starting...");

    audio_buffer_init(&audio_ring_buffer);

    /* BLE first */
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

    /* Opus encoder — non-fatal */
    ret = opus_enc_init();
    if (ret == 0) {
        opus_ok = true;
        LOG_INF("Opus encoder ready");
    } else {
        LOG_WRN("Opus init failed: %d — using raw PCM", ret);
    }

    LOG_INF("Dongle ready — BLE: \"%s\", codec: %s",
            CONFIG_BT_DEVICE_NAME, opus_ok ? "Opus 128kbps" : "raw PCM");

    static int16_t pcm_frame[AUDIO_FRAME_SAMPLES];
    static uint8_t opus_packet[OPUS_MAX_PACKET];

    while (1) {
        k_sem_take(&audio_ring_buffer.frame_ready, K_FOREVER);

        if (audio_buffer_read(&audio_ring_buffer, pcm_frame, AUDIO_FRAME_SAMPLES) == 0) {
            if (opus_ok) {
                int encoded = opus_enc_encode(pcm_frame, opus_packet, sizeof(opus_packet));
                if (encoded > 0) {
                    ble_audio_send_opus(opus_packet, encoded);
                }
            } else {
                ble_audio_send_opus((const uint8_t *)pcm_frame,
                                    AUDIO_FRAME_SAMPLES * sizeof(int16_t));
            }
        }
    }

    return 0;
}
