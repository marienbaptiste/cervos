import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

/// BLE service and characteristic UUIDs for the cervhole dongle.
class BleUuids {
  BleUuids._();

  /// Cervos Audio Service UUID
  static final audioService = Uuid.parse('CE570500-0001-4000-8000-00805F9B34FB');

  /// Audio Stream Characteristic UUID (notify only)
  static final audioStream = Uuid.parse('CE570500-0002-4000-8000-00805F9B34FB');
}

/// Audio constants matching firmware configuration.
class AudioConstants {
  AudioConstants._();

  static const int sampleRate = 16000;
  static const int sampleBits = 16;
  static const int channels = 1;
  static const int frameMs = 20;
  static const int frameSamples = sampleRate * frameMs ~/ 1000; // 320
  static const int frameBytes = frameSamples * (sampleBits ~/ 8); // 640

  /// FFT size — zero-pad 320 samples to 512 for power-of-2 FFT
  static const int fftSize = 512;

  /// Number of frequency bins (fftSize / 2)
  static const int frequencyBins = fftSize ~/ 2; // 256

  /// Nyquist frequency at 16kHz sample rate
  static const double nyquistHz = sampleRate / 2.0; // 8000.0

  /// Number of spectrogram columns visible (2 seconds at 20ms/frame)
  static const int spectrogramColumns = 100;
}

/// Design system spacing scale from tokens.yaml.
class Spacing {
  Spacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}
