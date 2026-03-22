/*
 * Cervos — LC3 Encoder for nRF52840
 *
 * Encodes 48kHz stereo PCM → LC3 compressed frames for BLE L2CAP transmission.
 * Uses google/liblc3 ported to Zephyr ARM Cortex-M4F with DSP intrinsics.
 *
 * Parameters:
 *   48kHz, 16-bit, stereo
 *   10ms frame duration
 *   ~160kbps (80kbps per channel)
 */

#ifndef LC3_ENCODER_H
#define LC3_ENCODER_H

#include <stdint.h>
#include <stdbool.h>

/* LC3 encoding parameters */
#define LC3_SAMPLE_RATE     48000
#define LC3_CHANNELS        2
#define LC3_FRAME_US        10000   /* 10ms in microseconds */
#define LC3_FRAME_SAMPLES   (LC3_SAMPLE_RATE / 100)  /* 480 per channel */
#define LC3_BITRATE         160000  /* ~160kbps stereo (80kbps/ch) */
#define LC3_BYTES_PER_CH    (LC3_BITRATE / LC3_CHANNELS / 8 / 100)  /* 100 bytes/ch/frame */
#define LC3_FRAME_BYTES     (LC3_BYTES_PER_CH * LC3_CHANNELS)  /* 200 bytes per stereo frame */
#define LC3_MAX_PACKET      256     /* Max encoded frame bytes with overhead */

/* Mono fallback for adaptive bitrate */
#define LC3_MONO_BITRATE    80000
#define LC3_MONO_BYTES      (LC3_MONO_BITRATE / 8 / 100)  /* 100 bytes/frame mono */

/**
 * Initialize LC3 encoder for stereo encoding.
 * Returns 0 on success, negative on error.
 */
int lc3_enc_init(void);

/**
 * Encode one 10ms frame of interleaved stereo PCM.
 *
 * @param pcm_input   960 interleaved stereo samples (480 L + 480 R)
 * @param output      Buffer for encoded LC3 data (both channels concatenated)
 * @param output_max  Size of output buffer
 * @param mono        If true, encode only left channel (adaptive bitrate fallback)
 * @return            Encoded size in bytes, or negative on error
 */
int lc3_enc_encode(const int16_t *pcm_input, uint8_t *output,
                   int output_max, bool mono);

/**
 * Get the encoded frame size for current mode.
 * @param mono  True for mono fallback mode
 * @return      Expected encoded frame size in bytes
 */
int lc3_enc_frame_bytes(bool mono);

#endif
