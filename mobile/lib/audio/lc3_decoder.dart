import 'dart:typed_data';

import 'package:flutter/services.dart';

/// LC3 decoder using Android NDK via platform channel.
/// Decodes LC3 compressed audio to 48kHz stereo interleaved PCM.
class Lc3AudioDecoder {
  static const _channel = MethodChannel('com.cervos.cervos/lc3_decoder');

  bool _initialized = false;

  static const int sampleRate = 48000;
  static const int channels = 2;
  static const int frameMs = 10;
  static const int frameSamplesPerChannel = sampleRate * frameMs ~/ 1000; // 480
  static const int frameSamples = frameSamplesPerChannel * channels; // 960

  /// Stereo LC3 frame size: 100 bytes/ch × 2 = 200 bytes
  static const int stereoFrameBytes = 200;

  /// Mono LC3 frame size: 100 bytes
  static const int monoFrameBytes = 100;

  Future<void> init() async {
    if (_initialized) return;
    final ret = await _channel.invokeMethod<int>('init');
    if (ret != 0) {
      throw Exception('LC3 decoder init failed: $ret');
    }
    _initialized = true;
  }

  /// Decode a stereo LC3 frame to interleaved PCM.
  /// Returns 960 interleaved int16 samples (480 L + 480 R), or null on failure.
  Future<Int16List?> decodeStereo(Uint8List lc3Data) async {
    if (!_initialized) return null;
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'decodeStereo',
        {'data': lc3Data},
      );
      if (bytes == null) return null;
      return bytes.buffer.asInt16List();
    } catch (_) {
      return null;
    }
  }

  /// Decode a mono LC3 frame to interleaved stereo PCM (duplicated).
  Future<Int16List?> decodeMono(Uint8List lc3Data) async {
    if (!_initialized) return null;
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'decodeMono',
        {'data': lc3Data},
      );
      if (bytes == null) return null;
      return bytes.buffer.asInt16List();
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    await _channel.invokeMethod<void>('release');
    _initialized = false;
  }
}
