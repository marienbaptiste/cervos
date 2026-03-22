/*
 * Cervos — LC3 Encoder for nRF52840
 *
 * Encodes 24kHz mono PCM → LC3 compressed frames for BLE transmission.
 * 24kHz, mono, 10ms frames, ~48kbps → ~60 bytes per frame.
 */

#ifndef LC3_ENCODER_H
#define LC3_ENCODER_H

#include <stdint.h>
#include <stdbool.h>

#define LC3_SAMPLE_RATE     24000
#define LC3_CHANNELS        1
#define LC3_FRAME_US        10000   /* 10ms */
#define LC3_FRAME_SAMPLES   (LC3_SAMPLE_RATE / 100)  /* 240 per channel */
#define LC3_BITRATE         48000   /* 48kbps mono */
#define LC3_FRAME_BYTES     (LC3_BITRATE / 8 / 100)  /* 60 bytes per frame */
#define LC3_MAX_PACKET      128

int lc3_enc_init(void);
int lc3_enc_encode(const int16_t *pcm_input, uint8_t *output, int output_max);

#endif
