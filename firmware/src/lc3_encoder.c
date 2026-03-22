/*
 * Cervos — LC3 Encoder for nRF52840
 *
 * Wraps google/liblc3 for stereo encoding on ARM Cortex-M4F.
 * Two encoder instances (L + R) encode channels independently.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "lc3.h"
#include "lc3_encoder.h"

LOG_MODULE_REGISTER(lc3_enc, LOG_LEVEL_INF);

/*
 * lc3_encoder_size(10000, 48000) returns ~20KB per instance.
 * Allocate 24KB each for safety margin.
 */
#define LC3_ENC_MEM_SIZE  24576

static uint8_t enc_mem_l[LC3_ENC_MEM_SIZE] __attribute__((aligned(8)));
static uint8_t enc_mem_r[LC3_ENC_MEM_SIZE] __attribute__((aligned(8)));

static lc3_encoder_t enc_l;
static lc3_encoder_t enc_r;
static bool initialized;

/* Deinterleave buffers */
static int16_t ch_l[LC3_FRAME_SAMPLES];
static int16_t ch_r[LC3_FRAME_SAMPLES];

int lc3_enc_init(void)
{
    unsigned needed = lc3_encoder_size(LC3_FRAME_US, LC3_SAMPLE_RATE);
    LOG_INF("LC3 encoder needs %u bytes/instance, allocated %u", needed, LC3_ENC_MEM_SIZE);

    if (needed > LC3_ENC_MEM_SIZE) {
        LOG_ERR("LC3 encoder memory too small: need %u, have %u", needed, LC3_ENC_MEM_SIZE);
        return -1;
    }

    enc_l = lc3_setup_encoder(LC3_FRAME_US, LC3_SAMPLE_RATE, 0, enc_mem_l);
    if (!enc_l) {
        LOG_ERR("LC3 left encoder setup failed");
        return -1;
    }

    enc_r = lc3_setup_encoder(LC3_FRAME_US, LC3_SAMPLE_RATE, 0, enc_mem_r);
    if (!enc_r) {
        LOG_ERR("LC3 right encoder setup failed");
        return -1;
    }

    initialized = true;
    LOG_INF("LC3 encoder ready — %dHz %dch 10ms frames ~%dkbps",
            LC3_SAMPLE_RATE, LC3_CHANNELS, LC3_BITRATE / 1000);
    return 0;
}

int lc3_enc_encode(const int16_t *pcm_input, uint8_t *output,
                   int output_max, bool mono)
{
    if (!initialized) {
        return -1;
    }

    if (mono) {
        if (output_max < LC3_MONO_BYTES) {
            return -2;
        }

        /* Mix stereo to mono */
        for (int i = 0; i < LC3_FRAME_SAMPLES; i++) {
            ch_l[i] = (int16_t)(((int32_t)pcm_input[i * 2] +
                                  pcm_input[i * 2 + 1]) / 2);
        }

        /* stride=1 for contiguous mono samples */
        int err = lc3_encode(enc_l, LC3_PCM_FORMAT_S16, ch_l, 1,
                             LC3_MONO_BYTES, output);
        if (err) {
            LOG_WRN("LC3 mono encode error: %d", err);
            return -3;
        }
        return LC3_MONO_BYTES;
    }

    /* Stereo: encode L and R independently, concatenated in output */
    if (output_max < LC3_FRAME_BYTES) {
        return -2;
    }

    /* Deinterleave stereo to separate channels */
    for (int i = 0; i < LC3_FRAME_SAMPLES; i++) {
        ch_l[i] = pcm_input[i * 2];
        ch_r[i] = pcm_input[i * 2 + 1];
    }

    int err = lc3_encode(enc_l, LC3_PCM_FORMAT_S16, ch_l, 1,
                         LC3_BYTES_PER_CH, output);
    if (err) {
        LOG_WRN("LC3 left encode error: %d", err);
        return -3;
    }

    err = lc3_encode(enc_r, LC3_PCM_FORMAT_S16, ch_r, 1,
                     LC3_BYTES_PER_CH, output + LC3_BYTES_PER_CH);
    if (err) {
        LOG_WRN("LC3 right encode error: %d", err);
        return -3;
    }

    return LC3_FRAME_BYTES;
}

int lc3_enc_frame_bytes(bool mono)
{
    return mono ? LC3_MONO_BYTES : LC3_FRAME_BYTES;
}
