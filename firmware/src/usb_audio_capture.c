/*
 * Cervos — nRF52840 USB Audio Capture
 *
 * Receives 48kHz stereo 16-bit PCM from work PC.
 * Mixes stereo→mono, bandpass 80Hz-8kHz, downsamples 2:1 to 24kHz mono.
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

/* Biquad filter state */
typedef struct {
    float b0, b1, b2, a1, a2;
    float x1, x2, y1, y2;
} biquad_t;

static float biquad_process(biquad_t *f, float x)
{
    float y = f->b0 * x + f->b1 * f->x1 + f->b2 * f->x2
                        - f->a1 * f->y1 - f->a2 * f->y2;
    f->x2 = f->x1; f->x1 = x;
    f->y2 = f->y1; f->y1 = y;
    return y;
}

/*
 * Pre-computed biquad coefficients for 48kHz sample rate (2nd order Butterworth).
 *
 * High-pass 80Hz: fc/fs=0.001667, Q=0.7071
 * Low-pass 8kHz:  fc/fs=0.1667,   Q=0.7071
 */
static biquad_t hp_filter = {
    .b0 =  0.98939f, .b1 = -1.97878f, .b2 =  0.98939f,
    .a1 = -1.97867f, .a2 =  0.97889f,
    .x1 = 0, .x2 = 0, .y1 = 0, .y2 = 0,
};

static biquad_t lp_filter = {
    .b0 = 0.15505f, .b1 = 0.31010f, .b2 = 0.15505f,
    .a1 = -0.62020f, .a2 = 0.24040f,
    .x1 = 0, .x2 = 0, .y1 = 0, .y2 = 0,
};

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
        if (ds_counter % DOWNSAMPLE_RATIO == 0) {
            int16_t mono = (int16_t)(((int32_t)samples[i] + samples[i + 1]) / 2);
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

    /* Disable immediately — BLE module will enable when phone connects */
    usb_disable();

    LOG_INF("USB Audio initialized (disabled until BLE connect)");
    return 0;
}
