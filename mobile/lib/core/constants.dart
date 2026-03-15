import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class BleUuids {
  BleUuids._();
  static final audioService = Uuid.parse('CE570500-0001-4000-8000-00805F9B34FB');
  static final audioStream = Uuid.parse('CE570500-0002-4000-8000-00805F9B34FB');
  static final captureControl = Uuid.parse('CE570500-0003-4000-8000-00805F9B34FB');
}

class AudioConstants {
  AudioConstants._();

  // Opus decoded output: 24kHz mono
  static const int sampleRate = 24000;
  static const int sampleBits = 16;
  static const int channels = 1;
  static const int frameMs = 20;
  static const int frameSamplesPerChannel = sampleRate * frameMs ~/ 1000; // 480
  static const int frameSamples = frameSamplesPerChannel * channels; // 480
  static const int frameBytes = frameSamples * (sampleBits ~/ 8); // 960

  // BLE receives variable-length Opus packets (not fixed PCM frames)
  static const bool useOpus = true;

  static const int fftSize = 1024;
  static const int frequencyBins = fftSize ~/ 2; // 512
  static const double nyquistHz = sampleRate / 2.0; // 24000.0
  static const int spectrogramColumns = 100;
}

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
