/*
 * Cervos — nRF52840 Dongle Main
 *
 * "cervhole headset" (USB) / "cervhole dongle" (BLE)
 *
 * BLE starts first (advertising). USB is only enabled when phone connects.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

extern int usb_audio_init(void);
extern int ble_audio_init(void);
extern int ble_audio_send_frame(const int16_t *pcm_data, size_t samples);

int main(void)
{
    int ret;

    LOG_INF("Cervos nRF52840 dongle starting...");

    audio_buffer_init(&audio_ring_buffer);

    /* BLE first — must be advertising before anything else */
    ret = ble_audio_init();
    if (ret) {
        LOG_ERR("BLE audio init failed: %d", ret);
        return ret;
    }

    /* Register USB audio callbacks (does NOT enable USB — BLE module does that) */
    ret = usb_audio_init();
    if (ret) {
        LOG_WRN("USB audio init issue: %d (will retry on BLE connect)", ret);
        /* Don't fail — BLE still works */
    }

    LOG_INF("Dongle ready — BLE: \"%s\", USB: on phone connect",
            CONFIG_BT_DEVICE_NAME);

    int16_t frame[AUDIO_FRAME_SAMPLES];

    while (1) {
        k_sem_take(&audio_ring_buffer.frame_ready, K_FOREVER);

        if (audio_buffer_read(&audio_ring_buffer, frame, AUDIO_FRAME_SAMPLES) == 0) {
            ble_audio_send_frame(frame, AUDIO_FRAME_SAMPLES);
        }
    }

    return 0;
}
