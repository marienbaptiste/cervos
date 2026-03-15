/*
 * Cervos — Opus Encoder Wrapper for nRF52840
 *
 * Encodes 48kHz stereo PCM → Opus compressed frames for BLE transmission.
 */

#ifndef OPUS_ENCODER_WRAPPER_H
#define OPUS_ENCODER_WRAPPER_H

#include <stdint.h>

/* Opus encoding parameters */
#define OPUS_SAMPLE_RATE    24000
#define OPUS_CHANNELS       1       /* Mono — halves encoding CPU */
#define OPUS_FRAME_MS       10      /* 10ms frames — low latency, sustainable */
#define OPUS_FRAME_SAMPLES  (OPUS_SAMPLE_RATE * OPUS_FRAME_MS / 1000)  /* 960 per channel */
#define OPUS_BITRATE        96000   /* 96kbps — fits in single BLE notification */
#define OPUS_MAX_PACKET     512     /* Max encoded frame bytes */

/* Initialize Opus encoder. Returns 0 on success. */
int opus_enc_init(void);

/* Encode one frame of interleaved stereo PCM.
 * pcm_input: 960 interleaved stereo samples (1920 int16_t values)
 * output: compressed Opus packet
 * output_max: max bytes in output buffer
 * Returns: encoded packet size in bytes, or negative on error. */
int opus_enc_encode(const int16_t *pcm_input, uint8_t *output, int output_max);

#endif
