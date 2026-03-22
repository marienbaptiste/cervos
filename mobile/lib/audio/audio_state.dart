import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/ble_state.dart';
import 'audio_pipeline.dart';

/// Singleton audio pipeline instance.
final audioPipelineProvider = Provider<AudioPipeline>((ref) {
  final pipeline = AudioPipeline();
  ref.onDispose(() => pipeline.dispose());
  return pipeline;
});

/// Spectrogram update stream.
final spectrumProvider = StreamProvider<SpectrogramUpdate>((ref) {
  final pipeline = ref.watch(audioPipelineProvider);
  return pipeline.spectrumStream;
});

/// Audio level (RMS dBFS) stream.
final audioLevelProvider = StreamProvider<double>((ref) {
  final pipeline = ref.watch(audioPipelineProvider);
  return pipeline.levelStream;
});

/// Wires LC3 frames from BLE into the audio pipeline.
final audioBridgeProvider = Provider<void>((ref) {
  final pipeline = ref.watch(audioPipelineProvider);
  final lc3Frame = ref.watch(lc3FrameProvider);

  lc3Frame.whenData((frame) {
    pipeline.onLc3Frame(frame);
  });
});
