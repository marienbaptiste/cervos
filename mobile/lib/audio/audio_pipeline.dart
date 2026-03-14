import 'dart:async';
import 'dart:typed_data';

import 'spectrogram_processor.dart';
import 'pcm_player.dart';

/// Central audio coordinator.
/// Receives BLE PCM frames and fans out to:
/// 1. Spectrogram processor (FFT → frequency bins)
/// 2. PCM player (phone speaker output)
/// 3. Level meter (RMS dBFS computation)
class AudioPipeline {
  AudioPipeline()
      : _spectrogram = SpectrogramProcessor(),
        _player = PcmPlayer();

  final SpectrogramProcessor _spectrogram;
  final PcmPlayer _player;

  final _spectrumController = StreamController<SpectrogramUpdate>.broadcast();
  final _levelController = StreamController<double>.broadcast();

  /// Spectrogram update stream — emits after each FFT computation.
  Stream<SpectrogramUpdate> get spectrumStream => _spectrumController.stream;

  /// Audio level stream — emits RMS dBFS after each frame.
  Stream<double> get levelStream => _levelController.stream;

  /// Access the spectrogram processor (for reading rolling buffer in painter).
  SpectrogramProcessor get spectrogram => _spectrogram;

  /// Initialize the audio output.
  Future<void> init() async {
    await _player.init();
  }

  /// Process one PCM frame from BLE.
  void onPcmFrame(Int16List pcmFrame) {
    // 1. Compute FFT spectrum
    final spectrum = _spectrogram.process(pcmFrame);
    _spectrumController.add(SpectrogramUpdate(
      spectrum: spectrum,
      columns: _spectrogram.columns,
      columnIndex: _spectrogram.columnIndex,
    ));

    // 2. Compute RMS level
    final level = SpectrogramProcessor.computeRmsDbfs(pcmFrame);
    _levelController.add(level);

    // 3. Play on speaker
    _player.enqueue(pcmFrame);
  }

  /// Clean up resources.
  Future<void> dispose() async {
    await _player.dispose();
    _spectrumController.close();
    _levelController.close();
  }
}

/// Snapshot of spectrogram state after processing one frame.
class SpectrogramUpdate {
  const SpectrogramUpdate({
    required this.spectrum,
    required this.columns,
    required this.columnIndex,
  });

  /// Current frame's magnitude spectrum in dB (256 bins, 0–8kHz).
  final Float64List spectrum;

  /// Rolling buffer of all columns (100 columns = 2 seconds).
  final List<Float64List> columns;

  /// Current write position in the rolling buffer.
  final int columnIndex;
}
