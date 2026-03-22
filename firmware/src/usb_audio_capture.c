/*
 * Cervos — nRF52840 USB Audio Capture
 *
 * Receives 48kHz stereo 16-bit PCM from work PC via USB Audio Class.
 * Accumulates samples into 10ms frames (960 stereo samples = 1920 bytes)
 * and writes them to the shared ring buffer for LC3 encoding.
 *
 * No downsampling or mixing — stereo passes through at full quality.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/usb/class/usb_audio.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(cervos_usb, LOG_LEVEL_INF);

/* Accumulate USB callbacks into complete 10ms frames */
static int16_t accum_buf[AUDIO_FRAME_SAMPLES];
static uint32_t accum_pos = 0;

static void usb_audio_data_recv_cb(const struct device *dev,
                                    struct net_buf *buffer,
                                    size_t size)
{
    if (!buffer || size == 0) {
        return;
    }

    const int16_t *samples = (const int16_t *)buffer->data;
    size_t total_samples = size / sizeof(int16_t);

    /* Copy interleaved stereo samples directly — no downsampling */
    for (size_t i = 0; i < total_samples; i++) {
        accum_buf[accum_pos++] = samples[i];

        if (accum_pos >= AUDIO_FRAME_SAMPLES) {
            audio_buffer_write(&audio_ring_buffer, accum_buf, AUDIO_FRAME_SAMPLES);
            accum_pos = 0;
        }
    }

    net_buf_unref(buffer);
}

static const struct usb_audio_ops audio_ops = {
    .data_received_cb = usb_audio_data_recv_cb,
};

int usb_audio_init(void)
{
    int ret;
    const struct device *usb_audio_dev;

    accum_pos = 0;
    memset(accum_buf, 0, sizeof(accum_buf));

    usb_audio_dev = DEVICE_DT_GET_ONE(usb_audio_hp);
    if (!device_is_ready(usb_audio_dev)) {
        LOG_ERR("USB audio device not ready");
        return -ENODEV;
    }

    usb_audio_register(usb_audio_dev, &audio_ops);

    ret = usb_enable(NULL);
    if (ret != 0) {
        LOG_ERR("Failed to enable USB: %d", ret);
        return ret;
    }

    LOG_INF("USB Audio initialized — 48kHz stereo → LC3");
    return 0;
}
