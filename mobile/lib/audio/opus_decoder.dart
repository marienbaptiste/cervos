import 'dart:typed_data';

import 'package:opus_dart/opus_dart.dart';
import 'package:opus_flutter/opus_flutter.dart' as opus_flutter;

/// Opus decoder for BLE audio — decodes Opus packets to 48kHz stereo PCM.
class OpusAudioDecoder {
  SimpleOpusDecoder? _decoder;
  bool _initialized = false;

  static const int sampleRate = 24000;
  static const int channels = 1;
  static const int frameMs = 20;
  static const int frameSamplesPerChannel = sampleRate * frameMs ~/ 1000; // 960

  Future<void> init() async {
    if (_initialized) return;

    // Load native opus library
    initOpus(await opus_flutter.load());

    _decoder = SimpleOpusDecoder(
      sampleRate: sampleRate,
      channels: channels,
    );

    _initialized = true;
  }

  /// Decode an Opus packet to interleaved stereo PCM.
  /// Returns null if decoding fails.
  Int16List? decode(Uint8List opusPacket) {
    if (!_initialized || _decoder == null) return null;

    try {
      return _decoder!.decode(input: opusPacket);
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _decoder?.destroy();
    _decoder = null;
    _initialized = false;
  }
}
