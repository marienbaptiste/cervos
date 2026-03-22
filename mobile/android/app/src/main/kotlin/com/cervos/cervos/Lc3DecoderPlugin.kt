package com.cervos.cervos

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter platform channel bridge for LC3 decoding.
 *
 * Methods:
 *   init() → int (0 = success)
 *   decodeStereo(Uint8List data) → Int16List (960 interleaved samples)
 *   decodeMono(Uint8List data) → Int16List (960 interleaved samples, mono duplicated)
 *   release() → void
 */
class Lc3DecoderPlugin {
    companion object {
        private const val CHANNEL = "com.cervos.cervos/lc3_decoder"

        fun register(flutterEngine: FlutterEngine) {
            val decoder = Lc3Decoder()

            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> {
                        val ret = decoder.nativeInit()
                        result.success(ret)
                    }
                    "decodeStereo" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data == null) {
                            result.error("INVALID_ARG", "Missing data", null)
                            return@setMethodCallHandler
                        }
                        val pcm = decoder.nativeDecodeStereo(data, data.size)
                        if (pcm != null) {
                            // Convert ShortArray to ByteArray for Dart Int16List
                            val bytes = ByteArray(pcm.size * 2)
                            for (i in pcm.indices) {
                                bytes[i * 2] = (pcm[i].toInt() and 0xFF).toByte()
                                bytes[i * 2 + 1] = (pcm[i].toInt() shr 8 and 0xFF).toByte()
                            }
                            result.success(bytes)
                        } else {
                            result.error("DECODE_FAIL", "LC3 stereo decode failed", null)
                        }
                    }
                    "decodeMono" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data == null) {
                            result.error("INVALID_ARG", "Missing data", null)
                            return@setMethodCallHandler
                        }
                        val pcm = decoder.nativeDecodeMono(data, data.size)
                        if (pcm != null) {
                            val bytes = ByteArray(pcm.size * 2)
                            for (i in pcm.indices) {
                                bytes[i * 2] = (pcm[i].toInt() and 0xFF).toByte()
                                bytes[i * 2 + 1] = (pcm[i].toInt() shr 8 and 0xFF).toByte()
                            }
                            result.success(bytes)
                        } else {
                            result.error("DECODE_FAIL", "LC3 mono decode failed", null)
                        }
                    }
                    "release" -> {
                        decoder.nativeRelease()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }
}
