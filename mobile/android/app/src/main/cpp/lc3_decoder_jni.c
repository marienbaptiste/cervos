/*
 * Cervos — LC3 Decoder JNI Bridge
 * 24kHz mono, 10ms frames.
 */

#include <jni.h>
#include <string.h>
#include <math.h>
#include "liblc3/include/lc3.h"

#define LC3_SAMPLE_RATE     24000
#define LC3_FRAME_US        10000
#define LC3_FRAME_SAMPLES   240     /* 24kHz * 10ms */
#define LC3_DEC_MEM_SIZE    24576

static uint8_t dec_mem[LC3_DEC_MEM_SIZE] __attribute__((aligned(8)));
static lc3_decoder_t dec = NULL;
static int16_t pcm_out[LC3_FRAME_SAMPLES];

JNIEXPORT jint JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeInit(JNIEnv *env, jobject thiz) {
    unsigned needed = lc3_decoder_size(LC3_FRAME_US, LC3_SAMPLE_RATE);
    if (needed > LC3_DEC_MEM_SIZE) return -1;

    dec = lc3_setup_decoder(LC3_FRAME_US, LC3_SAMPLE_RATE, 0, dec_mem);
    return dec ? 0 : -2;
}

JNIEXPORT jshortArray JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeDecodeMono(
        JNIEnv *env, jobject thiz,
        jbyteArray lc3Data, jint dataLen) {
    if (!dec) return NULL;

    jbyte *data = (*env)->GetByteArrayElements(env, lc3Data, NULL);
    if (!data) return NULL;

    int err = lc3_decode(dec, (const uint8_t *)data, dataLen,
                         LC3_PCM_FORMAT_S16, pcm_out, 1);

    (*env)->ReleaseByteArrayElements(env, lc3Data, data, JNI_ABORT);

    /* On error, trigger PLC */
    if (err < 0) {
        lc3_decode(dec, NULL, 0, LC3_PCM_FORMAT_S16, pcm_out, 1);
    }

    jshortArray result = (*env)->NewShortArray(env, LC3_FRAME_SAMPLES);
    (*env)->SetShortArrayRegion(env, result, 0, LC3_FRAME_SAMPLES, pcm_out);
    return result;
}

/* Keep stereo stub for API compatibility */
JNIEXPORT jshortArray JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeDecodeStereo(
        JNIEnv *env, jobject thiz,
        jbyteArray lc3Data, jint dataLen) {
    return Java_com_cervos_cervos_Lc3Decoder_nativeDecodeMono(env, thiz, lc3Data, dataLen);
}

/* Self-test: encode a sine wave, decode it, return both for comparison */
JNIEXPORT jbyteArray JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeSelfTest(JNIEnv *env, jobject thiz) {
    /* Setup encoder */
    static uint8_t test_enc_mem[LC3_DEC_MEM_SIZE] __attribute__((aligned(8)));
    lc3_encoder_t test_enc = lc3_setup_encoder(LC3_FRAME_US, LC3_SAMPLE_RATE, 0, test_enc_mem);
    if (!test_enc) return NULL;

    /* Generate sine wave input */
    int16_t sine_in[LC3_FRAME_SAMPLES];
    for (int i = 0; i < LC3_FRAME_SAMPLES; i++) {
        sine_in[i] = (int16_t)(16000.0 * sin(2.0 * 3.14159265 * 440.0 * i / LC3_SAMPLE_RATE));
    }

    /* Encode */
    uint8_t lc3_frame[60];
    int err = lc3_encode(test_enc, LC3_PCM_FORMAT_S16, sine_in, 1, 60, lc3_frame);
    if (err) return NULL;

    /* Decode with the existing decoder */
    if (!dec) return NULL;
    int16_t sine_out[LC3_FRAME_SAMPLES];
    err = lc3_decode(dec, lc3_frame, 60, LC3_PCM_FORMAT_S16, sine_out, 1);

    /* Return: [err(1 byte)][input PCM (480 bytes)][output PCM (480 bytes)] */
    int total = 1 + LC3_FRAME_SAMPLES * 2 + LC3_FRAME_SAMPLES * 2;
    jbyteArray result = (*env)->NewByteArray(env, total);
    jbyte header = (jbyte)err;
    (*env)->SetByteArrayRegion(env, result, 0, 1, &header);
    (*env)->SetByteArrayRegion(env, result, 1, LC3_FRAME_SAMPLES * 2, (const jbyte *)sine_in);
    (*env)->SetByteArrayRegion(env, result, 1 + LC3_FRAME_SAMPLES * 2, LC3_FRAME_SAMPLES * 2, (const jbyte *)sine_out);
    return result;
}

JNIEXPORT void JNICALL
Java_com_cervos_cervos_Lc3Decoder_nativeRelease(JNIEnv *env, jobject thiz) {
    dec = NULL;
}
