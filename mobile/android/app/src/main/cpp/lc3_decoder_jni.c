/*
 * Cervos — LC3 Decoder JNI Bridge
 *
 * Wraps google/liblc3 decoder for use from Kotlin/Dart via platform channel.
 * Supports stereo (two independent decoders) and mono fallback.
 */

#include <jni.h>
#include <string.h>
#include <stdlib.h>
#include "liblc3/include/lc3.h"

#define LC3_SAMPLE_RATE     48000
#define LC3_FRAME_US        10000   /* 10ms */
#define LC3_FRAME_SAMPLES   480     /* per channel */

/*
 * lc3_decoder_size(10000, 48000) returns ~18KB per instance.
 * Allocate 24KB each for safety margin.
 */
#define LC3_DEC_MEM_SIZE    24576

static uint8_t dec_mem_l[LC3_DEC_MEM_SIZE] __attribute__((aligned(8)));
static uint8_t dec_mem_r[LC3_DEC_MEM_SIZE] __attribute__((aligned(8)));

static lc3_decoder_t dec_l = NULL;
static lc3_decoder_t dec_r = NULL;

static int16_t pcm_l[LC3_FRAME_SAMPLES];
static int16_t pcm_r[LC3_FRAME_SAMPLES];
static int16_t pcm_interleaved[LC3_FRAME_SAMPLES * 2];

JNIEXPORT jint JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeInit(JNIEnv *env, jobject thiz) {
    unsigned needed = lc3_decoder_size(LC3_FRAME_US, LC3_SAMPLE_RATE);
    if (needed > LC3_DEC_MEM_SIZE) {
        return -1;
    }

    dec_l = lc3_setup_decoder(LC3_FRAME_US, LC3_SAMPLE_RATE, 0, dec_mem_l);
    dec_r = lc3_setup_decoder(LC3_FRAME_US, LC3_SAMPLE_RATE, 0, dec_mem_r);
    if (!dec_l || !dec_r) {
        return -2;
    }
    return 0;
}

JNIEXPORT jshortArray JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeDecodeStereo(
        JNIEnv *env, jobject thiz,
        jbyteArray lc3Data, jint dataLen) {
    if (!dec_l || !dec_r) return NULL;

    jbyte *data = (*env)->GetByteArrayElements(env, lc3Data, NULL);
    if (!data) return NULL;

    int ch_bytes = dataLen / 2;

    /* Decode left channel (stride=1 for contiguous output) */
    int err_l = lc3_decode(dec_l, (const uint8_t *)data, ch_bytes,
                           LC3_PCM_FORMAT_S16, pcm_l, 1);

    /* Decode right channel */
    int err_r = lc3_decode(dec_r, (const uint8_t *)(data + ch_bytes), ch_bytes,
                           LC3_PCM_FORMAT_S16, pcm_r, 1);

    (*env)->ReleaseByteArrayElements(env, lc3Data, data, JNI_ABORT);

    /* On decode error, trigger PLC by passing NULL input */
    if (err_l < 0) lc3_decode(dec_l, NULL, 0, LC3_PCM_FORMAT_S16, pcm_l, 1);
    if (err_r < 0) lc3_decode(dec_r, NULL, 0, LC3_PCM_FORMAT_S16, pcm_r, 1);

    /* Interleave L+R for output */
    for (int i = 0; i < LC3_FRAME_SAMPLES; i++) {
        pcm_interleaved[i * 2] = pcm_l[i];
        pcm_interleaved[i * 2 + 1] = pcm_r[i];
    }

    jshortArray result = (*env)->NewShortArray(env, LC3_FRAME_SAMPLES * 2);
    (*env)->SetShortArrayRegion(env, result, 0, LC3_FRAME_SAMPLES * 2, pcm_interleaved);
    return result;
}

JNIEXPORT jshortArray JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeDecodeMono(
        JNIEnv *env, jobject thiz,
        jbyteArray lc3Data, jint dataLen) {
    if (!dec_l) return NULL;

    jbyte *data = (*env)->GetByteArrayElements(env, lc3Data, NULL);
    if (!data) return NULL;

    int err = lc3_decode(dec_l, (const uint8_t *)data, dataLen,
                         LC3_PCM_FORMAT_S16, pcm_l, 1);

    (*env)->ReleaseByteArrayElements(env, lc3Data, data, JNI_ABORT);

    if (err < 0) {
        lc3_decode(dec_l, NULL, 0, LC3_PCM_FORMAT_S16, pcm_l, 1);
    }

    /* Duplicate mono to stereo for consistent output format */
    for (int i = 0; i < LC3_FRAME_SAMPLES; i++) {
        pcm_interleaved[i * 2] = pcm_l[i];
        pcm_interleaved[i * 2 + 1] = pcm_l[i];
    }

    jshortArray result = (*env)->NewShortArray(env, LC3_FRAME_SAMPLES * 2);
    (*env)->SetShortArrayRegion(env, result, 0, LC3_FRAME_SAMPLES * 2, pcm_interleaved);
    return result;
}

JNIEXPORT void JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeRelease(JNIEnv *env, jobject thiz) {
    dec_l = NULL;
    dec_r = NULL;
}
