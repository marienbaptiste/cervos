/*
 * Cervos — nRF52840 Dongle Main
 *
 * "cervhole headset" (USB) / "cervhole dongle" (BLE)
 *
 * Entry point: initializes USB Audio Class and BLE GATT audio service,
 * then runs the frame pump loop that reads from the USB capture ring buffer
 * and sends frames over BLE notifications.
 *
 * Timing is driven by USB isochronous transfers from the work PC.
 * The main loop blocks on a semaphore until a complete 20ms frame
 * is assembled, then immediately sends it via BLE.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

/* Defined in usb_audio_capture.c */
extern int usb_audio_init(void);

/* Defined in ble_audio_stream.c */
extern int ble_audio_init(void);
extern int ble_audio_send_frame(const int16_t *pcm_data, size_t samples);

int main(void)
{
    int ret;

    LOG_INF("Cervos nRF52840 dongle starting...");

    /* Initialize the shared audio ring buffer */
    audio_buffer_init(&audio_ring_buffer);

    /* Initialize BLE first (takes longer, advertising starts) */
    ret = ble_audio_init();
    if (ret) {
        LOG_ERR("BLE audio init failed: %d", ret);
        return ret;
    }

    /* Initialize USB Audio — dongle appears as "cervhole headset" on work PC */
    ret = usb_audio_init();
    if (ret) {
        LOG_ERR("USB audio init failed: %d", ret);
        return ret;
    }

    LOG_INF("Dongle ready — USB: \"cervhole headset\", BLE: \"%s\"",
            CONFIG_BT_DEVICE_NAME);

    /* Frame pump loop: USB → ring buffer → BLE */
    int16_t frame[AUDIO_FRAME_SAMPLES];

    while (1) {
        /* Block until USB callback signals a complete 20ms frame */
        k_sem_take(&audio_ring_buffer.frame_ready, K_FOREVER);

        /* Read frame from ring buffer and send over BLE */
        if (audio_buffer_read(&audio_ring_buffer, frame, AUDIO_FRAME_SAMPLES) == 0) {
            ble_audio_send_frame(frame, AUDIO_FRAME_SAMPLES);
        }
    }

    return 0;
}
