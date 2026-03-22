/*
 * Cervos — LC3 Encoder for nRF52840
 *
 * Single encoder instance for 24kHz mono.
 */

#include <zephyr/kernel.h>
#include <zephyr/logging/log.h>
#include <string.h>

#include "lc3.h"
#include "lc3_encoder.h"

LOG_MODULE_REGISTER(lc3_enc, LOG_LEVEL_INF);

#define LC3_ENC_MEM_SIZE  24576

static uint8_t enc_mem[LC3_ENC_MEM_SIZE] __attribute__((aligned(8)));
static lc3_encoder_t enc;
static bool initialized;

int lc3_enc_init(void)
{
    unsigned needed = lc3_encoder_size(LC3_FRAME_US, LC3_SAMPLE_RATE);
    LOG_INF("LC3 encoder needs %u bytes, allocated %u", needed, LC3_ENC_MEM_SIZE);

    if (needed > LC3_ENC_MEM_SIZE) {
        LOG_ERR("LC3 encoder memory too small");
        return -1;
    }

    enc = lc3_setup_encoder(LC3_FRAME_US, LC3_SAMPLE_RATE, 0, enc_mem);
    if (!enc) {
        LOG_ERR("LC3 encoder setup failed");
        return -1;
    }

    initialized = true;
    LOG_INF("LC3 encoder ready — %dHz mono 10ms %dkbps (%d bytes/frame)",
            LC3_SAMPLE_RATE, LC3_BITRATE / 1000, LC3_FRAME_BYTES);
    return 0;
}

int lc3_enc_encode(const int16_t *pcm_input, uint8_t *output, int output_max)
{
    if (!initialized || output_max < LC3_FRAME_BYTES) {
        return -1;
    }

    int err = lc3_encode(enc, LC3_PCM_FORMAT_S16, pcm_input, 1,
                         LC3_FRAME_BYTES, output);
    if (err) {
        return -1;
    }
    return LC3_FRAME_BYTES;
}
