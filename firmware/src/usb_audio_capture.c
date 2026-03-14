/*
 * Cervos — nRF52840 USB Audio Capture
 *
 * USB side: presents as a standard USB Audio Class output device (speaker).
 * The work PC sets this as the audio output in Zoom/Teams/Meet.
 * Meeting audio flows to the dongle digitally via USB.
 *
 * USB receives 48kHz stereo 16-bit PCM from the work PC.
 * We mix stereo→mono and downsample 3:1 to 16kHz mono,
 * then write 20ms frames (320 samples = 640 bytes) to the ring buffer
 * for BLE streaming.
 *
 * Zero install on work PC — it's just a USB speaker as far as the OS is concerned.
 *
 * Platform: Zephyr RTOS
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/usb/class/usb_audio.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(cervos_usb, LOG_LEVEL_INF);

/* USB input: 48kHz stereo 16-bit */
#define USB_SAMPLE_RATE     48000
#define USB_CHANNELS        2
#define DOWNSAMPLE_RATIO    3  /* 48kHz → 16kHz */

/* Output: 16kHz mono 16-bit (matches BLE stream) */
/* AUDIO_FRAME_SAMPLES = 320 (defined in audio_buffer.h) */

/* Accumulation buffer for assembling 20ms output frames.
 * 20ms at 16kHz mono = 320 samples.
 * 20ms at 48kHz stereo = 960 stereo pairs = 1920 samples. */
static int16_t accum_buf[AUDIO_FRAME_SAMPLES];
static uint32_t accum_pos = 0;

/* Downsample counter — tracks position within the 3:1 ratio */
static uint32_t ds_counter = 0;

/**
 * USB Audio data received callback.
 * Called by the USB stack when the work PC sends audio data.
 * Input: 48kHz stereo 16-bit PCM.
 * Processing: stereo→mono mix, 3:1 downsample → 16kHz mono.
 */
static void usb_audio_data_recv_cb(const struct device *dev,
                                    struct net_buf *buffer,
                                    size_t size)
{
    if (!buffer || size == 0) {
        return;
    }

    const int16_t *samples = (const int16_t *)buffer->data;
    size_t total_samples = size / sizeof(int16_t);

    /* Process stereo pairs: [L, R, L, R, ...] */
    for (size_t i = 0; i + 1 < total_samples; i += USB_CHANNELS) {
        /* Mix stereo to mono: average L and R */
        int32_t left = samples[i];
        int32_t right = samples[i + 1];
        int16_t mono = (int16_t)((left + right) / 2);

        /* Downsample 3:1: keep every 3rd sample */
        if (ds_counter % DOWNSAMPLE_RATIO == 0) {
            accum_buf[accum_pos++] = mono;

            /* Full 20ms frame assembled — write to ring buffer */
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

/**
 * Initialize USB Audio Class device.
 * After this, the dongle appears as "cervhole headset" speaker on the work PC.
 * Device name comes from CONFIG_USB_DEVICE_PRODUCT in prj.conf.
 */
int usb_audio_init(void)
{
    int ret;
    const struct device *usb_audio_dev;

    /* Reset accumulation state */
    accum_pos = 0;
    ds_counter = 0;
    memset(accum_buf, 0, sizeof(accum_buf));

    /* Get the USB audio device */
    usb_audio_dev = DEVICE_DT_GET_ONE(usb_audio_hp);
    if (!device_is_ready(usb_audio_dev)) {
        LOG_ERR("USB audio device not ready");
        return -ENODEV;
    }

    /* Register audio callbacks */
    usb_audio_register(usb_audio_dev, &audio_ops);

    /* Enable the USB subsystem */
    ret = usb_enable(NULL);
    if (ret != 0) {
        LOG_ERR("Failed to enable USB: %d", ret);
        return ret;
    }

    LOG_INF("USB Audio initialized — 48kHz stereo → 16kHz mono, appearing as \"cervhole headset\"");
    return 0;
}
