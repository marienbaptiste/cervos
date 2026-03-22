import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../core/constants.dart';
import 'ble_manager.dart';

/// Manages connection lifecycle to the Cervos dongle.
/// GATT for config (capture control, power mode, name).
/// L2CAP CoC for audio streaming (LC3 packets).
class DongleConnection {
  DongleConnection(this._bleManager);

  final BleManager _bleManager;

  String? _deviceId;
  String? _deviceName;
  StreamSubscription<ConnectionStateUpdate>? _connectionSub;
  StreamSubscription<List<int>>? _l2capSub;
  int _mtu = 23;
  int _rawPacketCount = 0;
  int _totalBytesReceived = 0;
  String _lastError = '';
  bool _captureEnabled = true;
  PowerMode _powerMode = PowerMode.balanced;

  /// PCM accumulator — BLE notifications come in 240-byte chunks,
  /// accumulate into full frames for the pipeline.
  final _pcmAccum = BytesBuilder(copy: false);
  int _lastSeqNum = -1;

  final _stateController = StreamController<DongleState>.broadcast();
  final _lc3Controller = StreamController<Lc3Packet>.broadcast();
  final _pcmController = StreamController<Int16List>.broadcast();

  /// Connection state stream.
  Stream<DongleState> get stateStream => _stateController.stream;

  /// Parsed LC3 packet stream (after deduplication).
  Stream<Lc3Packet> get lc3Stream => _lc3Controller.stream;

  /// Raw PCM frame stream (accumulated from BLE notification chunks).
  Stream<Int16List> get pcmStream => _pcmController.stream;

  int get mtu => _mtu;
  int get rawPacketCount => _rawPacketCount;
  int get totalBytesReceived => _totalBytesReceived;
  String get lastError => _lastError;
  bool get captureEnabled => _captureEnabled;
  PowerMode get powerMode => _powerMode;
  String? get deviceName => _deviceName;

  /// Toggle USB capture on/off.
  Future<void> setCaptureEnabled(bool enabled) async {
    if (_deviceId == null) return;
    try {
      await _bleManager.writeCaptureControl(_deviceId!, enabled);
      _captureEnabled = enabled;
    } catch (e) {
      _lastError = 'Capture toggle err: $e';
    }
  }

  /// Set power mode on the dongle.
  Future<void> setPowerMode(PowerMode mode) async {
    if (_deviceId == null) return;
    try {
      await _bleManager.writePowerMode(_deviceId!, mode);
      _powerMode = mode;
    } catch (e) {
      _lastError = 'Power mode err: $e';
    }
  }

  /// Rename the dongle (triggers soft-reset, will disconnect).
  Future<void> renameDongle(String name) async {
    if (_deviceId == null) return;
    await _bleManager.writeDongleName(_deviceId!, name);
  }

  /// Connect to the dongle by device ID.
  void connect(DiscoveredDevice device) {
    disconnect();
    _deviceId = device.id;
    _deviceName = device.name.isNotEmpty ? device.name : device.id;

    _stateController.add(DongleState.connecting);

    _connectionSub = _bleManager.connectToDongle(device.id).listen(
      (update) async {
        switch (update.connectionState) {
          case DeviceConnectionState.connected:
            await _onConnected();
          case DeviceConnectionState.disconnected:
            _stateController.add(DongleState.disconnected);
            _l2capSub?.cancel();
            _l2capSub = null;
          case DeviceConnectionState.connecting:
            _stateController.add(DongleState.connecting);
          case DeviceConnectionState.disconnecting:
            break;
        }
      },
      onError: (Object error) {
        _stateController.add(DongleState.disconnected);
      },
    );
  }

  Future<void> _onConnected() async {
    if (_deviceId == null) return;

    // Negotiate MTU
    try {
      _mtu = await _bleManager.negotiateMtu(_deviceId!);
      _lastError = 'MTU OK: $_mtu';
    } catch (e) {
      _mtu = 23;
      _lastError = 'MTU err: $e';
    }

    // Discover GATT services
    try {
      await _bleManager.discoverServices(_deviceId!);
      _lastError = '$_lastError | Svc OK';
    } catch (e) {
      _lastError = '$_lastError | Svc err: $e';
    }

    // Read current power mode from dongle
    try {
      _powerMode = await _bleManager.readPowerMode(_deviceId!);
    } catch (_) {
      _powerMode = PowerMode.balanced;
    }

    _rawPacketCount = 0;
    _totalBytesReceived = 0;
    _captureEnabled = true;
    _lastSeqNum = -1;

    _stateController.add(DongleState.connected);

    // Subscribe to GATT audio notifications — raw PCM chunks
    try {
      _l2capSub = _bleManager.subscribeToAudio(_deviceId!).listen(
        (List<int> data) => _processRawPcm(data),
        onError: (Object error) {
          _lastError = 'Audio stream err: $error';
        },
      );
      _lastError = '$_lastError | Audio sub OK';
    } catch (e) {
      _lastError = '$_lastError | Audio sub err: $e';
    }
  }

  /// Process raw PCM notification chunks — accumulate into full frames.
  void _processRawPcm(List<int> data) {
    _rawPacketCount++;
    _totalBytesReceived += data.length;

    _pcmAccum.add(Uint8List.fromList(data));

    // Emit complete frames (960 stereo samples = 1920 bytes)
    while (_pcmAccum.length >= AudioConstants.frameBytes) {
      final bytes = _pcmAccum.takeBytes();
      final frameBytes = Uint8List.sublistView(bytes, 0, AudioConstants.frameBytes);
      final pcmFrame = frameBytes.buffer.asInt16List(
          frameBytes.offsetInBytes, AudioConstants.frameSamples);
      _pcmController.add(pcmFrame);

      // Put remaining bytes back
      if (bytes.length > AudioConstants.frameBytes) {
        _pcmAccum.add(Uint8List.sublistView(bytes, AudioConstants.frameBytes));
      }
    }
  }

  // LC3 packet parser removed — using raw PCM over GATT

  void disconnect() {
    _l2capSub?.cancel();
    _l2capSub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _stateController.add(DongleState.disconnected);
  }

  void dispose() {
    disconnect();
    _stateController.close();
    _lc3Controller.close();
  }
}

enum DongleState {
  disconnected,
  connecting,
  connected,
}

/// A parsed LC3 packet from the dongle.
class Lc3Packet {
  const Lc3Packet({
    required this.seqNum,
    required this.timestamp,
    required this.lc3Data,
    required this.isMono,
  });

  final int seqNum;
  final int timestamp;
  final Uint8List lc3Data;
  final bool isMono;
}
