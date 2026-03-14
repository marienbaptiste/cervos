/*
 * Cervos — Shared Audio Ring Buffer Implementation
 */

#include "audio_buffer.h"
#include <string.h>
#include <errno.h>

/* Global instance */
audio_ring_buffer_t audio_ring_buffer;

void audio_buffer_init(audio_ring_buffer_t *buf)
{
    memset(buf->frames, 0, sizeof(buf->frames));
    buf->write_head = 0;
    buf->read_head = 0;
    k_sem_init(&buf->frame_ready, 0, AUDIO_BUFFER_FRAMES);
}

int audio_buffer_write(audio_ring_buffer_t *buf, const int16_t *pcm, size_t samples)
{
    if (samples != AUDIO_FRAME_SAMPLES) {
        return -EINVAL;
    }

    uint32_t idx = buf->write_head % AUDIO_BUFFER_FRAMES;
    int ret = 0;

    /* Check for overrun — if write catches up to read, we overwrite oldest */
    if (buf->write_head - buf->read_head >= AUDIO_BUFFER_FRAMES) {
        /* Buffer full — advance read head (drop oldest frame) */
        buf->read_head++;
        ret = -ENOSPC;
    }

    memcpy(buf->frames[idx], pcm, AUDIO_FRAME_BYTES);
    buf->write_head++;

    k_sem_give(&buf->frame_ready);

    return ret;
}

int audio_buffer_read(audio_ring_buffer_t *buf, int16_t *pcm_out, size_t samples)
{
    if (samples != AUDIO_FRAME_SAMPLES) {
        return -EINVAL;
    }

    if (buf->read_head >= buf->write_head) {
        return -ENODATA;
    }

    uint32_t idx = buf->read_head % AUDIO_BUFFER_FRAMES;
    memcpy(pcm_out, buf->frames[idx], AUDIO_FRAME_BYTES);
    buf->read_head++;

    return 0;
}

bool audio_buffer_has_data(audio_ring_buffer_t *buf)
{
    return buf->read_head < buf->write_head;
}
