/*
 * Cervos — nRF52840 USB Audio Capture
 *
 * USB side: presents as a standard USB Audio Class output device (speaker).
 * The work PC sets this as the audio output in Zoom/Teams/Meet.
 * Meeting audio flows to the dongle digitally via USB.
 *
 * Zero install on work PC — it's just a USB speaker as far as the OS is concerned.
 *
 * Platform: Zephyr RTOS
 * Audio: 16kHz, 16-bit PCM, mono
 */

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/usb/usb_device.h>
#include <zephyr/usb/class/usb_audio.h>

#include "audio_buffer.h"

/* USB Audio Class configuration */
#define SAMPLE_RATE     16000
#define SAMPLE_SIZE     16      /* bits */
#define FRAME_SIZE_MS   20
#define SAMPLES_PER_FRAME (SAMPLE_RATE * FRAME_SIZE_MS / 1000)
#define FRAME_BYTES     (SAMPLES_PER_FRAME * (SAMPLE_SIZE / 8))

/* Circular buffer for captured audio frames */
static int16_t audio_buffer[SAMPLES_PER_FRAME * 8]; /* 8 frames deep */
static volatile uint32_t write_idx = 0;
static volatile uint32_t read_idx = 0;

/**
 * USB Audio data received callback.
 * Called when the work PC sends audio data to this "speaker" device.
 * Writes PCM frames into the circular buffer for BLE streaming.
 */
static void usb_audio_data_recv_cb(const struct device *dev,
                                    struct net_buf *buffer,
                                    size_t size)
{
    /* TODO: Write received PCM data into circular buffer */
    /* The BLE audio stream module reads from this buffer */
}

/**
 * Initialize USB Audio Class device.
 * After this, the dongle appears as "Meeting Audio" speaker on the work PC.
 */
int usb_audio_init(void)
{
    int ret;

    ret = usb_enable(NULL);
    if (ret != 0) {
        return ret;
    }

    /* TODO: Register audio data callback */
    /* TODO: Set device name (configurable: "Meeting Audio", etc.) */

    return 0;
}
