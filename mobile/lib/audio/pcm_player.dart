import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../core/constants.dart';

/// Plays raw PCM audio frames on the phone speaker / BLE earbuds.
/// 48kHz stereo, 16-bit, 10ms frames.
class PcmPlayer {
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) {
      await FlutterPcmSound.release();
      _initialized = false;
    }

    await FlutterPcmSound.setLogLevel(LogLevel.none);

    await FlutterPcmSound.setup(
      sampleRate: AudioConstants.sampleRate,
      channelCount: AudioConstants.channels,
    );

    await FlutterPcmSound.setFeedThreshold(AudioConstants.frameSamples);
    await FlutterPcmSound.play();

    _initialized = true;
  }

  void enqueue(Int16List pcmFrame) {
    if (!_initialized) return;
    FlutterPcmSound.feed(PcmArrayInt16.fromList(pcmFrame.toList()));
  }

  /// Clear playback buffer (call on reconnect to avoid stale audio).
  Future<void> flush() async {
    if (!_initialized) return;
    await FlutterPcmSound.clear();
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    await FlutterPcmSound.release();
    _initialized = false;
  }
}
