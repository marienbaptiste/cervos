import 'dart:async';
import 'dart:typed_data';

import 'lc3_decoder.dart';
import 'spectrogram_processor.dart';
import 'pcm_player.dart';

/// Minimal audio pipeline: LC3 decode (FFI) → player (direct push).
/// Spectrogram at 10fps to keep UI responsive.
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

  int _frameCount = 0;

  Future<void> init() async {
    await _lc3Decoder.init();
    await _player.init();
  }

  Future<void> flush() async {
    await _player.flush();
  }

  void onLc3Frame(Uint8List lc3Data) {
    final pcmFrame = _lc3Decoder.decode(lc3Data);
    if (pcmFrame == null) return;
    _frameCount++;

    // Always play
    _player.enqueue(pcmFrame);

    // Spectrogram at 10fps (every 10th frame)
    if (spectroEnabled && _frameCount % 10 == 0) {
      final spectrum = _spectrogram.process(pcmFrame);
      _spectrumController.add(SpectrogramUpdate(
        spectrum: spectrum,
        columns: _spectrogram.columns,
        columnIndex: _spectrogram.columnIndex,
      ));
      final level = SpectrogramProcessor.computeRmsDbfs(pcmFrame);
      _levelController.add(level);
    }
  }

  Future<void> dispose() async {
    await _lc3Decoder.dispose();
    await _player.dispose();
    _spectrumController.close();
    _levelController.close();
  }
}

class SpectrogramUpdate {
  const SpectrogramUpdate({
    required this.spectrum,
    required this.columns,
    required this.columnIndex,
  });

  final Float64List spectrum;
  final List<Float64List> columns;
  final int columnIndex;
}
