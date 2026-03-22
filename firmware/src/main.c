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

    /* LC3 encoder — non-fatal, fall back to raw PCM if it fails */
    static bool lc3_ok = false;
    ret = lc3_enc_init();
    if (ret) {
        LOG_WRN("LC3 encoder init failed: %d — raw PCM fallback", ret);
    } else {
        lc3_ok = true;
    }

    LOG_INF("Dongle ready — codec: %s", lc3_ok ? "LC3 48kHz stereo" : "raw PCM fallback");

    static int16_t pcm_frame[AUDIO_FRAME_SAMPLES];
    static uint8_t lc3_packet[LC3_MAX_PACKET];

    while (1) {
        k_sem_take(&audio_ring_buffer.frame_ready, K_FOREVER);

        if (audio_buffer_read(&audio_ring_buffer, pcm_frame, AUDIO_FRAME_SAMPLES) == 0) {
            if (lc3_ok) {
                bool mono = ble_audio_is_mono_fallback();
                int encoded = lc3_enc_encode(pcm_frame, lc3_packet,
                                             sizeof(lc3_packet), mono);
                if (encoded > 0) {
                    ble_audio_send_lc3(lc3_packet, encoded);
                }
            } else {
                /* Raw PCM fallback — send uncompressed */
                ble_audio_send_lc3((const uint8_t *)pcm_frame,
                                    AUDIO_FRAME_SAMPLES * sizeof(int16_t));
            }
        }
    }

    return 0;
}
