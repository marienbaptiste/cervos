/*
 * Cervos — Opus Encoder Wrapper for nRF52840
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "opus.h"
#include "opus_encoder_wrapper.h"

LOG_MODULE_REGISTER(opus_enc, LOG_LEVEL_INF);

/* Static encoder memory — avoids malloc on embedded */
static uint8_t encoder_mem[16384] __attribute__((aligned(4)));  /* 16KB — mono encoder */
static OpusEncoder *encoder = (OpusEncoder *)encoder_mem;

int opus_enc_init(void)
{
    int err;
    int size = opus_encoder_get_size(OPUS_CHANNELS);
    LOG_INF("Opus encoder needs %d bytes, allocated %d", size, sizeof(encoder_mem));

    if (size > (int)sizeof(encoder_mem)) {
        LOG_ERR("Opus encoder memory too small!");
        return -1;
    }

    err = opus_encoder_init(encoder, OPUS_SAMPLE_RATE, OPUS_CHANNELS,
                            OPUS_APPLICATION_RESTRICTED_LOWDELAY);
    if (err != OPUS_OK) {
        LOG_ERR("Opus encoder init failed: %d", err);
        return err;
    }

    opus_encoder_ctl(encoder, OPUS_SET_BITRATE(OPUS_BITRATE));
    opus_encoder_ctl(encoder, OPUS_SET_COMPLEXITY(1));  /* 1 = fastest encoding for embedded */
    opus_encoder_ctl(encoder, OPUS_SET_VBR(0));         /* CBR = predictable timing */
    opus_encoder_ctl(encoder, OPUS_SET_SIGNAL(OPUS_SIGNAL_MUSIC));

    LOG_INF("Opus encoder ready — %dHz %dch %dkbps %dms frames",
            OPUS_SAMPLE_RATE, OPUS_CHANNELS, OPUS_BITRATE / 1000, OPUS_FRAME_MS);
    return 0;
}

int opus_enc_encode(const int16_t *pcm_input, uint8_t *output, int output_max)
{
    return opus_encode(encoder, pcm_input, OPUS_FRAME_SAMPLES, output, output_max);
}
