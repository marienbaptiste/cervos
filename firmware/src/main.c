/*
 * Cervos — nRF52840 Dongle Main
 *
 * USB audio in (48kHz stereo) → downsample to 16kHz mono → BLE out.
 * LED blinks when USB audio data arrives (diagnostic).
 * Test tone plays when no USB audio.
 */

#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(main, LOG_LEVEL_INF);

extern int usb_audio_init(void);
extern int ble_audio_init(void);
extern int ble_audio_send_frame(const int16_t *pcm_data, size_t samples);

/* LED for diagnostics */
static const struct gpio_dt_spec led = GPIO_DT_SPEC_GET(DT_ALIAS(led0), gpios);

/* Test tone */
#define TONE_FREQ 440
#define TONE_AMPLITUDE 4000
#define TONE_HALF_PERIOD (AUDIO_SAMPLE_RATE / (TONE_FREQ * 2))

static void generate_test_tone(int16_t *buf, size_t samples, uint32_t *phase)
{
    for (size_t i = 0; i < samples; i++) {
        uint32_t pos = (*phase) % (TONE_HALF_PERIOD * 2);
        buf[i] = (pos < TONE_HALF_PERIOD) ? TONE_AMPLITUDE : -TONE_AMPLITUDE;
        (*phase)++;
    }
}

int main(void)
{
    int ret;

    LOG_INF("Cervos nRF52840 dongle starting...");

    /* Setup LED */
    if (gpio_is_ready_dt(&led)) {
        gpio_pin_configure_dt(&led, GPIO_OUTPUT_ACTIVE);
        gpio_pin_set_dt(&led, 0);
    }

    audio_buffer_init(&audio_ring_buffer);

    /* Init USB FIRST — before BLE, to ensure USB audio is ready */
    ret = usb_audio_init();
    if (ret) {
        LOG_ERR("USB audio init failed: %d", ret);
        /* Blink LED rapidly on error */
        for (int i = 0; i < 10; i++) {
            gpio_pin_toggle_dt(&led);
            k_msleep(100);
        }
    } else {
        LOG_INF("USB audio OK");
    }

    /* Then init BLE */
    ret = ble_audio_init();
    if (ret) {
        LOG_ERR("BLE audio init failed: %d", ret);
        return ret;
    }

    LOG_INF("Dongle ready — USB: \"cervhole headset\", BLE: \"%s\"",
            CONFIG_BT_DEVICE_NAME);

    int16_t frame[AUDIO_FRAME_SAMPLES];
    uint32_t tone_phase = 0;
    bool usb_active = false;
    uint32_t led_counter = 0;

    while (1) {
        int got = k_sem_take(&audio_ring_buffer.frame_ready, K_MSEC(20));

        if (got == 0 &&
            audio_buffer_read(&audio_ring_buffer, frame, AUDIO_FRAME_SAMPLES) == 0) {
            /* USB audio frame — blink LED */
            ble_audio_send_frame(frame, AUDIO_FRAME_SAMPLES);
            led_counter++;
            if (led_counter % 25 == 0) {  /* Toggle every 500ms */
                gpio_pin_toggle_dt(&led);
            }
            if (!usb_active) {
                LOG_INF("USB audio active");
                usb_active = true;
            }
        } else {
            /* No USB audio — test tone, LED off */
            generate_test_tone(frame, AUDIO_FRAME_SAMPLES, &tone_phase);
            ble_audio_send_frame(frame, AUDIO_FRAME_SAMPLES);
            gpio_pin_set_dt(&led, 0);
            usb_active = false;
        }
    }

    return 0;
}
