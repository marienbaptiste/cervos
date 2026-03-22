package com.cervos.cervos

/**
 * JNI wrapper for google/liblc3 decoder.
 * Decodes LC3 compressed audio frames to 48kHz stereo PCM.
 */
class Lc3Decoder {
    companion object {
        init {
            System.loadLibrary("lc3_decoder")
        }
    }

    external fun nativeInit(): Int
    external fun nativeDecodeStereo(lc3Data: ByteArray, dataLen: Int): ShortArray?
    external fun nativeDecodeMono(lc3Data: ByteArray, dataLen: Int): ShortArray?
    external fun nativeSelfTest(): ByteArray?
    external fun nativeRelease()
}
