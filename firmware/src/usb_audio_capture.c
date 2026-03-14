/*
 * Cervos — nRF52840 USB Audio Capture
 *
 * USB side: presents as a standard USB Audio Class output device (speaker).
 * The work PC sets this as the audio output in Zoom/Teams/Meet.
 * Meeting audio flows to the dongle digitally via USB.
 *
 * Zero install on work PC — it's just a USB speaker as far as the OS is concerned.
 *
 * USB isochronous transfers arrive at 1ms intervals (~32 bytes each at 16kHz mono 16-bit).
 * We accumulate into 20ms frames (640 bytes) before writing to the shared ring buffer.
 *
 * Platform: Zephyr RTOS
 * Audio: 16kHz, 16-bit PCM, mono
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/usb/class/usb_audio.h>
#include <zephyr/logging/log.h>

#include "audio_buffer.h"

LOG_MODULE_REGISTER(usb_audio, LOG_LEVEL_INF);

/* Accumulation buffer for assembling 20ms frames from USB micro-frames.
 * USB delivers ~32 bytes (16 samples) per 1ms isochronous interval.
 * We need 20 intervals to fill one 640-byte frame. */
static int16_t accum_buf[AUDIO_FRAME_SAMPLES];
static uint32_t accum_pos = 0;

/* LED for audio activity indication */
static const struct device *audio_led;

/**
 * USB Audio data received callback.
 * Called by the USB stack when the work PC sends audio data to this "speaker" device.
 * Accumulates USB micro-frames into 20ms PCM frames, then writes to the ring buffer.
 */
static void usb_audio_data_recv_cb(const struct device *dev,
                                    struct net_buf *buffer,
                                    size_t size)
{
    if (!buffer || size == 0) {
        return;
    }

    const int16_t *samples = (const int16_t *)buffer->data;
    size_t num_samples = size / sizeof(int16_t);

    /* Accumulate samples into the 20ms frame buffer */
    while (num_samples > 0) {
        size_t space = AUDIO_FRAME_SAMPLES - accum_pos;
        size_t to_copy = (num_samples < space) ? num_samples : space;

        memcpy(&accum_buf[accum_pos], samples, to_copy * sizeof(int16_t));
        accum_pos += to_copy;
        samples += to_copy;
        num_samples -= to_copy;

        /* Full 20ms frame assembled — write to ring buffer */
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

    LOG_INF("USB Audio initialized — appearing as \"cervhole headset\"");
    return 0;
}
