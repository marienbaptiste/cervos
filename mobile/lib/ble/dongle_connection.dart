import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../core/constants.dart';
import 'ble_manager.dart';

/// Manages connection lifecycle to the cervhole dongle.
/// Handles connect → MTU negotiate → subscribe to audio → emit PCM frames.
class DongleConnection {
  DongleConnection(this._bleManager);

  final BleManager _bleManager;

  String? _deviceId;
  String? _deviceName;
  StreamSubscription<ConnectionStateUpdate>? _connectionSub;
  StreamSubscription<List<int>>? _audioSub;
  int _mtu = 23;
  int _rawNotificationCount = 0;
  int _totalBytesReceived = 0;
  String _lastError = '';
  bool _captureEnabled = true;

  final _stateController = StreamController<DongleState>.broadcast();
  final _audioController = StreamController<Int16List>.broadcast();
  final _opusController = StreamController<Uint8List>.broadcast();

  /// Connection state stream.
  Stream<DongleState> get stateStream => _stateController.stream;

  /// PCM audio frame stream (after Opus decode).
  Stream<Int16List> get audioStream => _audioController.stream;

  /// Raw Opus packet stream (each BLE notification = one packet).
  Stream<Uint8List> get opusStream => _opusController.stream;

  /// Current negotiated MTU.
  int get mtu => _mtu;

  /// Raw BLE notification count (for debugging).
  int get rawNotificationCount => _rawNotificationCount;

  /// Total bytes received over BLE (for debugging).
  int get totalBytesReceived => _totalBytesReceived;

  /// Last BLE error message (for debugging).
  String get lastError => _lastError;

  /// Whether USB capture is enabled on the dongle.
  bool get captureEnabled => _captureEnabled;

  /// Toggle USB capture on/off. When off, Windows switches to default audio.
  Future<void> setCaptureEnabled(bool enabled) async {
    if (_deviceId == null) return;
    try {
      await _bleManager.writeCaptureControl(_deviceId!, enabled);
      _captureEnabled = enabled;
    } catch (e) {
      _lastError = 'Capture toggle err: $e';
    }
  }

  /// Connected device name.
  String? get deviceName => _deviceName;

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
            _audioSub?.cancel();
            _audioSub = null;
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

    // Negotiate MTU for large audio frames
    try {
      _mtu = await _bleManager.negotiateMtu(_deviceId!);
      _lastError = 'MTU OK: $_mtu';
    } catch (e) {
      _mtu = 23;
      _lastError = 'MTU err: $e';
    }

    // Discover services first — some BLE stacks require this
    try {
      await _bleManager.discoverServices(_deviceId!);
      _lastError = '$_lastError | Svc OK';
    } catch (e) {
      _lastError = '$_lastError | Svc err: $e';
    }

    // Reset counters for fresh connection
    _rawNotificationCount = 0;
    _totalBytesReceived = 0;
    _captureEnabled = true;  // Firmware defaults to ON on connect

    _stateController.add(DongleState.connected);

    // Subscribe to audio notifications
    try {
      _audioSub = _bleManager.subscribeToAudio(_deviceId!).listen(
        (data) {
          _processAudioNotification(data);
        },
        onError: (Object error) {
          _lastError = 'Sub stream err: $error';
        },
      );
      _lastError = '$_lastError | Sub OK';
    } catch (e) {
      _lastError = '$_lastError | Sub err: $e';
    }
  }

  void _processAudioNotification(List<int> data) {
    _rawNotificationCount++;
    _totalBytesReceived += data.length;

    // Each BLE notification is one complete Opus packet
    _opusController.add(Uint8List.fromList(data));
  }

  /// Disconnect from the dongle.
  void disconnect() {
    _audioSub?.cancel();
    _audioSub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _stateController.add(DongleState.disconnected);
  }

  /// Clean up resources.
  void dispose() {
    disconnect();
    _stateController.close();
    _audioController.close();
    _opusController.close();
  }
}

enum DongleState {
  disconnected,
  connecting,
  connected,
}
