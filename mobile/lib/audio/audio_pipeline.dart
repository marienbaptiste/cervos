import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'spectrogram_processor.dart';
import 'pcm_player.dart';

/// Central audio coordinator.
/// Receives BLE PCM frames and fans out to:
/// 1. Spectrogram processor (FFT → frequency bins)
/// 2. PCM player (phone speaker output)
/// 3. Level meter (RMS dBFS computation)
///
/// A 2-frame jitter buffer absorbs BLE timing hiccups before playback.
class AudioPipeline {
  AudioPipeline()
      : _spectrogram = SpectrogramProcessor(),
        _player = PcmPlayer();

  final SpectrogramProcessor _spectrogram;
  final PcmPlayer _player;

  bool spectroEnabled = true;

  static const int _jitterFrames = 2;
  final Queue<Int16List> _jitterBuffer = Queue<Int16List>();
  bool _primed = false;
  bool _smooth = false;

  bool get smooth => _smooth;

  void setSmooth(bool value) {
    _smooth = value;
    if (!value && _jitterBuffer.isNotEmpty) {
      while (_jitterBuffer.isNotEmpty) {
        _player.enqueue(_jitterBuffer.removeFirst());
      }
    }
  }

  final _spectrumController = StreamController<SpectrogramUpdate>.broadcast();
  final _levelController = StreamController<double>.broadcast();

  Stream<SpectrogramUpdate> get spectrumStream => _spectrumController.stream;
  Stream<double> get levelStream => _levelController.stream;
  SpectrogramProcessor get spectrogram => _spectrogram;

  Future<void> init() async {
    await _player.init();
  }

  /// Flush all buffers (call on reconnect).
  Future<void> flush() async {
    _jitterBuffer.clear();
    _primed = false;
    await _player.flush();
  }

  /// Process one PCM frame from BLE.
  void onPcmFrame(Int16List pcmFrame) {
    // 1. Spectrogram + level (skip if disabled to save CPU)
    if (spectroEnabled) {
      final spectrum = _spectrogram.process(pcmFrame);
      _spectrumController.add(SpectrogramUpdate(
        spectrum: spectrum,
        columns: _spectrogram.columns,
        columnIndex: _spectrogram.columnIndex,
      ));
      final level = SpectrogramProcessor.computeRmsDbfs(pcmFrame);
      _levelController.add(level);
    }

    // 2. Play on speaker
    if (!_smooth) {
      _player.enqueue(pcmFrame);
      return;
    }
    _jitterBuffer.addLast(pcmFrame);
    if (!_primed) {
      if (_jitterBuffer.length >= _jitterFrames) {
        _primed = true;
      } else {
        return;
      }
    }
    if (_jitterBuffer.isNotEmpty) {
      _player.enqueue(_jitterBuffer.removeFirst());
    }
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
