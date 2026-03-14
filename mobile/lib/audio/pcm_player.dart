import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../core/constants.dart';

/// Plays raw PCM audio frames on the phone speaker.
///
/// Uses flutter_pcm_sound for direct PCM buffer playback.
/// Maintains a small buffer (3-4 frames = 60-80ms) to smooth BLE jitter.
class PcmPlayer {
  bool _initialized = false;

  /// Initialize the audio output at 16kHz mono 16-bit.
  Future<void> init() async {
    if (_initialized) return;

    await FlutterPcmSound.setup(
      sampleRate: AudioConstants.sampleRate,
      channelCount: AudioConstants.channels,
      // Feed threshold — request more data when buffer drops below this
    );

    // Set a reasonable feed threshold (2 frames worth)
    await FlutterPcmSound.setFeedThreshold(
        AudioConstants.frameBytes * 2,
    );

    _initialized = true;
  }

  /// Enqueue one 20ms PCM frame for playback.
  void enqueue(Int16List pcmFrame) {
    if (!_initialized) return;

    // Convert Int16List to Uint8List (raw bytes) for the plugin
    final bytes = Uint8List.view(pcmFrame.buffer,
        pcmFrame.offsetInBytes, pcmFrame.lengthInBytes);
    FlutterPcmSound.feed(PcmArrayInt16(bytes: bytes));
  }

  /// Stop playback and release resources.
  Future<void> dispose() async {
    if (!_initialized) return;
    await FlutterPcmSound.release();
    _initialized = false;
  }
}
