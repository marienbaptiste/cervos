import 'dart:math';
import 'dart:typed_data';

import 'package:fft/fft.dart';

import '../core/constants.dart';

/// Processes PCM audio frames into frequency-domain data for spectrogram display.
///
/// Takes 960-sample stereo frames (10ms at 48kHz), mixes to mono,
/// applies a Hanning window, zero-pads to 2048 samples, computes FFT,
/// and returns 1024 magnitude bins covering 0–24kHz.
class SpectrogramProcessor {
  SpectrogramProcessor()
      : _window = _createHanningWindow(AudioConstants.frameSamplesPerChannel),
        _rollingBuffer = List.generate(
          AudioConstants.spectrogramColumns,
          (_) => Float64List(AudioConstants.frequencyBins),
        ),
        _columnIndex = 0;

  final Float64List _window;
  final List<Float64List> _rollingBuffer;
  int _columnIndex;

  List<Float64List> get columns => _rollingBuffer;
  int get columnIndex => _columnIndex;

  /// Process one stereo PCM frame and return magnitude spectrum in dB.
  Float64List process(Int16List pcmFrame) {
    // Mix stereo to mono for FFT analysis
    final monoSamples = AudioConstants.frameSamplesPerChannel;
    final windowed = Float64List(AudioConstants.fftSize);

    for (int i = 0; i < monoSamples && i * 2 + 1 < pcmFrame.length; i++) {
      final mono = (pcmFrame[i * 2] + pcmFrame[i * 2 + 1]) / 2.0;
      windowed[i] = (mono / 32768.0) * _window[i];
    }
    // Remaining samples are zero (zero-padding)

    final input = List<double>.from(windowed);
    final spectrum = FFT.Transform(input);

    final magnitudes = Float64List(AudioConstants.frequencyBins);
    for (int i = 0; i < AudioConstants.frequencyBins; i++) {
      final real = spectrum[i].real;
      final imag = spectrum[i].imaginary;
      final mag = sqrt(real * real + imag * imag);
      magnitudes[i] = mag > 0 ? 20 * log(mag) / ln10 : -100.0;
    }

    final idx = _columnIndex % AudioConstants.spectrogramColumns;
    _rollingBuffer[idx] = magnitudes;
    _columnIndex++;

    return magnitudes;
  }

  /// Compute RMS level in dBFS from a stereo PCM frame.
  static double computeRmsDbfs(Int16List pcmFrame) {
    if (pcmFrame.isEmpty) return -100.0;

    double sumSquares = 0;
    for (int i = 0; i < pcmFrame.length; i++) {
      final normalized = pcmFrame[i] / 32768.0;
      sumSquares += normalized * normalized;
    }
    final rms = sqrt(sumSquares / pcmFrame.length);
    return rms > 0 ? 20 * log(rms) / ln10 : -100.0;
  }

  static Float64List _createHanningWindow(int length) {
    final window = Float64List(length);
    for (int i = 0; i < length; i++) {
      window[i] = 0.5 * (1.0 - cos(2.0 * pi * i / (length - 1)));
    }
    return window;
  }
}
