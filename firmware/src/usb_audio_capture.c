/*
 * Cervos — nRF52840 USB Audio Capture
 *
 * Receives 48kHz stereo 16-bit PCM from work PC.
 * Mixes stereo→mono, downsamples 2:1 to 24kHz mono.
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/usb/class/usb_audio.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(cervos_usb, LOG_LEVEL_INF);

#define USB_CHANNELS        2
#define DOWNSAMPLE_RATIO    2  /* 48kHz → 24kHz */

static int16_t accum_buf[AUDIO_FRAME_SAMPLES];
static uint32_t accum_pos = 0;
static uint32_t ds_counter = 0;

static void usb_audio_data_recv_cb(const struct device *dev,
                                    struct net_buf *buffer,
                                    size_t size)
{
    if (!buffer || size == 0) {
        return;
    }

    const int16_t *samples = (const int16_t *)buffer->data;
    size_t total_samples = size / sizeof(int16_t);

    for (size_t i = 0; i + 1 < total_samples; i += USB_CHANNELS) {
        int32_t left = samples[i];
        int32_t right = samples[i + 1];
        int16_t mono = (int16_t)((left + right) / 2);

        if (ds_counter % DOWNSAMPLE_RATIO == 0) {
            accum_buf[accum_pos++] = mono;

            if (accum_pos >= AUDIO_FRAME_SAMPLES) {
                audio_buffer_write(&audio_ring_buffer, accum_buf, AUDIO_FRAME_SAMPLES);
                accum_pos = 0;
            }
        }
        ds_counter++;
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
    ds_counter = 0;
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

    LOG_INF("USB Audio initialized — 48kHz stereo → 24kHz mono");
    return 0;
}
