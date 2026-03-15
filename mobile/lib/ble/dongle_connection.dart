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

  /// Connection state stream.
  Stream<DongleState> get stateStream => _stateController.stream;

  /// PCM audio frame stream — each event is 320 int16 samples (20ms at 16kHz).
  Stream<Int16List> get audioStream => _audioController.stream;

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

    // Reset accumulator for fresh connection
    _accumulator.clear();
    _rawNotificationCount = 0;
    _totalBytesReceived = 0;

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

  /// Convert raw BLE bytes to Int16List PCM frames.
  /// Handles potential MTU fragmentation by accumulating bytes.
  final _accumulator = BytesBuilder(copy: false);

  void _processAudioNotification(List<int> data) {
    _rawNotificationCount++;
    _totalBytesReceived += data.length;
    _accumulator.add(Uint8List.fromList(data));

    // Process complete frames (1920 bytes = 960 samples at 48kHz mono)
    while (_accumulator.length >= AudioConstants.frameBytes) {
      final bytes = _accumulator.takeBytes();
      final frameBytes = Uint8List.fromList(
          bytes.sublist(0, AudioConstants.frameBytes));
      final pcmFrame = Int16List.view(frameBytes.buffer);
      _audioController.add(pcmFrame);

      // Put back any remaining bytes
      if (bytes.length > AudioConstants.frameBytes) {
        _accumulator.add(bytes.sublist(AudioConstants.frameBytes));
      }
    }
  }

  /// Disconnect from the dongle.
  void disconnect() {
    _audioSub?.cancel();
    _audioSub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _accumulator.clear();
    _stateController.add(DongleState.disconnected);
  }

  /// Clean up resources.
  void dispose() {
    disconnect();
    _stateController.close();
    _audioController.close();
  }
}

enum DongleState {
  disconnected,
  connecting,
  connected,
}
