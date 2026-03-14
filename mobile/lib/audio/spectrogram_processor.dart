import 'dart:math';
import 'dart:typed_data';

import 'package:fft/fft.dart';

import '../core/constants.dart';

/// Processes PCM audio frames into frequency-domain data for spectrogram display.
///
/// Takes 320-sample PCM frames (20ms at 16kHz), applies a Hanning window,
/// zero-pads to 512 samples, computes FFT, and returns 256 magnitude bins
/// covering 0–8kHz.
class SpectrogramProcessor {
  SpectrogramProcessor()
      : _window = _createHanningWindow(AudioConstants.frameSamples),
        _rollingBuffer = List.generate(
          AudioConstants.spectrogramColumns,
          (_) => Float64List(AudioConstants.frequencyBins),
        ),
        _columnIndex = 0;

  final Float64List _window;
  final List<Float64List> _rollingBuffer;
  int _columnIndex;

  /// Rolling spectrogram data — list of columns, each column is frequency bins.
  /// Most recent column is at [columnIndex - 1].
  List<Float64List> get columns => _rollingBuffer;
  int get columnIndex => _columnIndex;

  /// Process one PCM frame and return magnitude spectrum in dB.
  Float64List process(Int16List pcmFrame) {
    // Apply Hanning window and normalize to [-1, 1]
    final windowed = Float64List(AudioConstants.fftSize);
    for (int i = 0; i < pcmFrame.length && i < AudioConstants.frameSamples; i++) {
      windowed[i] = (pcmFrame[i] / 32768.0) * _window[i];
    }
    // Remaining samples are zero (zero-padding from 320 to 512)

    // Compute FFT
    final fft = FFT(AudioConstants.fftSize);
    final spectrum = fft.realFft(windowed);

    // Compute magnitude in dB for each frequency bin
    final magnitudes = Float64List(AudioConstants.frequencyBins);
    for (int i = 0; i < AudioConstants.frequencyBins; i++) {
      final real = spectrum[i].x;
      final imag = spectrum[i].y;
      final mag = sqrt(real * real + imag * imag);
      // Convert to dB, floor at -100 dB
      magnitudes[i] = mag > 0 ? 20 * log(mag) / ln10 : -100.0;
    }

    // Store in rolling buffer
    final idx = _columnIndex % AudioConstants.spectrogramColumns;
    _rollingBuffer[idx] = magnitudes;
    _columnIndex++;

    return magnitudes;
  }

  /// Compute RMS level in dBFS from a PCM frame.
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
