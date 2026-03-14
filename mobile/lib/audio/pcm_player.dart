import 'dart:typed_data';

import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../core/constants.dart';

/// Plays raw PCM audio frames on the phone speaker.
class PcmPlayer {
  bool _initialized = false;

  /// Initialize the audio output at 16kHz mono 16-bit.
  Future<void> init() async {
    if (_initialized) return;

    await FlutterPcmSound.setLogLevel(LogLevel.error);

    await FlutterPcmSound.setup(
      sampleRate: AudioConstants.sampleRate,
      channelCount: AudioConstants.channels,
    );

    // Feed threshold in samples (request more when buffer drops below 2 frames)
    await FlutterPcmSound.setFeedThreshold(AudioConstants.frameSamples * 2);

    await FlutterPcmSound.play();

    _initialized = true;
  }

  /// Enqueue one 20ms PCM frame for playback.
  void enqueue(Int16List pcmFrame) {
    if (!_initialized) return;

    // Use the documented fromList constructor which handles byte conversion
    final pcmArray = PcmArrayInt16.fromList(pcmFrame.toList());
    FlutterPcmSound.feed(pcmArray);
  }

  /// Stop playback and release resources.
  Future<void> dispose() async {
    if (!_initialized) return;
    await FlutterPcmSound.release();
    _initialized = false;
  }
}
