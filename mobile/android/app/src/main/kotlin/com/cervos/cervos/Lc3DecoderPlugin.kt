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
            var decodeCount = 0

            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
                when (call.method) {
                    "init" -> {
                        val ret = decoder.nativeInit()
                        if (ret == 0) {
                            // Run self-test: encode+decode sine wave locally
                            val test = decoder.nativeSelfTest()
                            if (test != null && test.isNotEmpty()) {
                                val err = test[0].toInt()
                                android.util.Log.i("LC3SelfTest", "encode+decode err=$err, data=${test.size} bytes")
                                // Compare input vs output energy
                                var inEnergy = 0L
                                var outEnergy = 0L
                                for (i in 0 until 240) {
                                    val inSample = (test[1 + i*2].toInt() and 0xFF) or (test[1 + i*2+1].toInt() shl 8)
                                    val outSample = (test[481 + i*2].toInt() and 0xFF) or (test[481 + i*2+1].toInt() shl 8)
                                    inEnergy += (inSample.toLong() * inSample)
                                    outEnergy += (outSample.toLong() * outSample)
                                }
                                android.util.Log.i("LC3SelfTest", "Input energy=$inEnergy, Output energy=$outEnergy, ratio=${if(inEnergy>0) outEnergy.toFloat()/inEnergy else 0f}")
                            } else {
                                android.util.Log.e("LC3SelfTest", "Self-test returned null")
                            }
                        }
                        result.success(ret)
                    }
                    "decodeMono" -> {
                        val data = call.argument<ByteArray>("data")
                        if (data == null) {
                            result.error("INVALID_ARG", "Missing data", null)
                            return@setMethodCallHandler
                        }
                        decodeCount++
                        val pcm = decoder.nativeDecodeMono(data, data.size)
                        if (pcm != null) {
                            if (decodeCount <= 3) {
                                var energy = 0L
                                for (s in pcm) energy += (s.toLong() * s)
                                android.util.Log.i("LC3Decode", "#$decodeCount: ${data.size}B → ${pcm.size} samples, energy=$energy, first5=[${pcm.take(5).joinToString()}]")
                            }
                            val bytes = ByteArray(pcm.size * 2)
                            for (i in pcm.indices) {
                                bytes[i * 2] = (pcm[i].toInt() and 0xFF).toByte()
                                bytes[i * 2 + 1] = (pcm[i].toInt() shr 8 and 0xFF).toByte()
                            }
                            result.success(bytes)
                        } else {
                            if (decodeCount <= 3) {
                                android.util.Log.e("LC3Decode", "#$decodeCount: FAILED, ${data.size}B input")
                            }
                            result.error("DECODE_FAIL", "LC3 decode failed", null)
                        }
                    }
                    "decodeBatch" -> {
                        // Batch decode: receives concatenated LC3 frames, each `frameSize` bytes
                        val data = call.argument<ByteArray>("data")
                        val frameSize = call.argument<Int>("frameSize")
                        if (data == null || frameSize == null || frameSize <= 0) {
                            result.error("INVALID_ARG", "Missing data or frameSize", null)
                            return@setMethodCallHandler
                        }
                        val frameCount = data.size / frameSize
                        val samplesPerFrame = 240  // 24kHz * 10ms
                        val allPcm = ByteArray(frameCount * samplesPerFrame * 2)
                        var outOffset = 0
                        for (f in 0 until frameCount) {
                            val frameData = data.copyOfRange(f * frameSize, (f + 1) * frameSize)
                            val pcm = decoder.nativeDecodeMono(frameData, frameData.size)
                            if (pcm != null) {
                                for (i in pcm.indices) {
                                    allPcm[outOffset++] = (pcm[i].toInt() and 0xFF).toByte()
                                    allPcm[outOffset++] = (pcm[i].toInt() shr 8 and 0xFF).toByte()
                                }
                            } else {
                                // PLC frame — fill with zeros
                                outOffset += samplesPerFrame * 2
                            }
                        }
                        result.success(allPcm.copyOf(outOffset))
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
