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

/// Wires LC3 packets from BLE into the audio pipeline.
/// This provider should be watched from the home screen to activate the pipeline.
final audioBridgeProvider = Provider<void>((ref) {
  final pipeline = ref.watch(audioPipelineProvider);
  final lc3Packet = ref.watch(lc3PacketProvider);

  lc3Packet.whenData((packet) {
    pipeline.onLc3Packet(packet);
  });
});
