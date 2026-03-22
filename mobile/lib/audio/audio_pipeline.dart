import 'dart:async';
import 'dart:typed_data';

import '../ble/dongle_connection.dart';
import 'lc3_decoder.dart';
import 'spectrogram_processor.dart';
import 'pcm_player.dart';

/// Central audio coordinator.
/// Receives LC3 packets from BLE L2CAP CoC and fans out to:
/// 1. LC3 decoder (NDK) → 48kHz stereo PCM
/// 2. Spectrogram processor (FFT → frequency bins)
/// 3. PCM player (Oboe/AAudio → BLE earbuds)
/// 4. Level meter (RMS dBFS computation)
class AudioPipeline {
  AudioPipeline()
      : _spectrogram = SpectrogramProcessor(),
        _player = PcmPlayer(),
        _lc3Decoder = Lc3AudioDecoder();

  final SpectrogramProcessor _spectrogram;
  final PcmPlayer _player;
  final Lc3AudioDecoder _lc3Decoder;

  bool spectroEnabled = true;

  final _spectrumController = StreamController<SpectrogramUpdate>.broadcast();
  final _levelController = StreamController<double>.broadcast();

  Stream<SpectrogramUpdate> get spectrumStream => _spectrumController.stream;
  Stream<double> get levelStream => _levelController.stream;
  SpectrogramProcessor get spectrogram => _spectrogram;

  Future<void> init() async {
    await _lc3Decoder.init();
    await _player.init();
  }

  /// Flush all buffers (call on reconnect).
  Future<void> flush() async {
    await _player.flush();
  }

  /// Process one LC3 frame — synchronous decode via dart:ffi.
  void onLc3Frame(Uint8List lc3Data) {
    final pcmFrame = _lc3Decoder.decode(lc3Data);
    if (pcmFrame == null) return;
    _processDecodedFrame(pcmFrame);
  }

  void _processDecodedFrame(Int16List pcmFrame) {
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

    // 2. Play on earbuds via Oboe/AAudio
    _player.enqueue(pcmFrame);
  }

  Future<void> dispose() async {
    await _lc3Decoder.dispose();
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

  /// Current frame's magnitude spectrum in dB.
  final Float64List spectrum;

  /// Rolling buffer of all columns.
  final List<Float64List> columns;

  /// Current write position in the rolling buffer.
  final int columnIndex;
}
