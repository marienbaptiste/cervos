/*
 * Cervos — Shared Audio Ring Buffer
 *
 * Audio: 48kHz, 16-bit PCM, stereo interleaved, 20ms frames
 * 960 samples/channel × 2 channels = 1920 samples = 3840 bytes per frame
 */

#ifndef AUDIO_BUFFER_H
#define AUDIO_BUFFER_H

#include <zephyr/kernel.h>
#include <stdint.h>
#include <stdbool.h>

#define AUDIO_SAMPLE_RATE       24000
#define AUDIO_SAMPLE_BITS       16
#define AUDIO_CHANNELS          1
#define AUDIO_FRAME_MS          20
#define AUDIO_FRAME_SAMPLES     (AUDIO_SAMPLE_RATE * AUDIO_FRAME_MS / 1000 * AUDIO_CHANNELS)  /* 960 */
#define AUDIO_FRAME_BYTES       (AUDIO_FRAME_SAMPLES * (AUDIO_SAMPLE_BITS / 8))  /* 1920 */
#define AUDIO_BUFFER_FRAMES     4

typedef struct {
    int16_t frames[AUDIO_BUFFER_FRAMES][AUDIO_FRAME_SAMPLES];
    volatile uint32_t write_head;
    volatile uint32_t read_head;
    struct k_sem frame_ready;
} audio_ring_buffer_t;

extern audio_ring_buffer_t audio_ring_buffer;

void audio_buffer_init(audio_ring_buffer_t *buf);
int  audio_buffer_write(audio_ring_buffer_t *buf, const int16_t *pcm, size_t samples);
int  audio_buffer_read(audio_ring_buffer_t *buf, int16_t *pcm_out, size_t samples);
bool audio_buffer_has_data(audio_ring_buffer_t *buf);
void audio_buffer_flush(audio_ring_buffer_t *buf);

#endif
