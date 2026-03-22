import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

class BleUuids {
  BleUuids._();
  static final audioService = Uuid.parse('CE570500-0001-4000-8000-00805F9B34FB');
  static final captureControl = Uuid.parse('CE570500-0003-4000-8000-00805F9B34FB');
  static final dongleConfig = Uuid.parse('CE570500-CF01-4000-8000-00805F9B34FB');
  static final powerMode = Uuid.parse('CE570500-CF02-4000-8000-00805F9B34FB');

  /// L2CAP PSM for audio streaming (matches firmware CERVOS_L2CAP_PSM)
  static const int audioL2capPsm = 0x0080;
}

/// Power modes matching firmware enum
enum PowerMode {
  batterySaver(0, 'Battery Saver', '30ms CI, ~80ms latency'),
  balanced(1, 'Balanced', '15ms CI, ~55ms latency'),
  lowLatency(2, 'Low Latency', '7.5ms CI, ~35ms latency');

  const PowerMode(this.value, this.label, this.description);
  final int value;
  final String label;
  final String description;
}

class AudioConstants {
  AudioConstants._();

  // LC3 decoded output: 48kHz stereo
  static const int sampleRate = 48000;
  static const int sampleBits = 16;
  static const int channels = 2;
  static const int frameMs = 10;
  static const int frameSamplesPerChannel = sampleRate * frameMs ~/ 1000; // 480
  static const int frameSamples = frameSamplesPerChannel * channels; // 960
  static const int frameBytes = frameSamples * (sampleBits ~/ 8); // 1920

  // LC3 compressed frame sizes
  static const int lc3StereoFrameBytes = 200; // ~160kbps stereo
  static const int lc3MonoFrameBytes = 100;   // ~80kbps mono

  // BLE packet header: seq_num(2) + timestamp(4) + frame_count(1) = 7
  static const int packetHeaderSize = 7;

  // Spectrogram
  static const int fftSize = 2048;
  static const int frequencyBins = fftSize ~/ 2; // 1024
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
