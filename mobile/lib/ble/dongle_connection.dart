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
  StreamSubscription<Uint8List>? _l2capSub;
  int _mtu = 23;
  int _rawPacketCount = 0;
  int _totalBytesReceived = 0;
  String _lastError = '';
  bool _captureEnabled = true;
  PowerMode _powerMode = PowerMode.balanced;

  /// Duplicate-frame tracking: last processed seq_num
  int _lastSeqNum = -1;

  final _stateController = StreamController<DongleState>.broadcast();
  final _lc3Controller = StreamController<Lc3Packet>.broadcast();

  /// Connection state stream.
  Stream<DongleState> get stateStream => _stateController.stream;

  /// Parsed LC3 packet stream (after deduplication).
  Stream<Lc3Packet> get lc3Stream => _lc3Controller.stream;

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

    // Subscribe to L2CAP audio stream BEFORE connecting
    // (EventChannel onListen must fire before the read thread starts)
    _l2capSub = _bleManager.l2capAudioStream.listen(
      (data) => _processL2capPacket(data),
      onError: (Object error) {
        _lastError = 'L2CAP stream err: $error';
      },
    );

    // Now connect L2CAP CoC for audio streaming
    try {
      await _bleManager.connectL2cap(_deviceId!);
      _lastError = '$_lastError | L2CAP OK';
    } catch (e) {
      _lastError = '$_lastError | L2CAP err: $e';
    }
  }

  /// Parse L2CAP packet: [seq_num:u16][timestamp:u32][frame_count:u8][frames...]
  void _processL2capPacket(Uint8List data) {
    _rawPacketCount++;
    _totalBytesReceived += data.length;

    if (data.length < AudioConstants.packetHeaderSize) return;

    final byteData = ByteData.sublistView(data);
    final seqNum = byteData.getUint16(0, Endian.little);
    final timestamp = byteData.getUint32(2, Endian.little);
    final frameCount = data[6];

    // Extract LC3 frames from payload
    int offset = AudioConstants.packetHeaderSize;
    final frames = <Uint8List>[];

    for (int i = 0; i < frameCount && offset < data.length; i++) {
      // Determine frame size: check if remaining data suggests stereo or mono
      int frameSize;
      final remaining = data.length - offset;

      if (frameCount == 2) {
        // Duplicate-frame mode: prev + current, split evenly
        frameSize = (data.length - AudioConstants.packetHeaderSize) ~/ 2;
      } else if (remaining >= AudioConstants.lc3StereoFrameBytes) {
        frameSize = AudioConstants.lc3StereoFrameBytes;
      } else {
        frameSize = remaining;
      }

      if (offset + frameSize > data.length) break;
      frames.add(Uint8List.sublistView(data, offset, offset + frameSize));
      offset += frameSize;
    }

    if (frames.isEmpty) return;

    // With duplicate-frame resilience: packet carries [prev_frame, current_frame]
    // Only emit the latest frame (last one), skip if we already processed this seq
    final latestFrame = frames.last;
    final isMono = latestFrame.length <= AudioConstants.lc3MonoFrameBytes;

    // Deduplication: skip if we've already seen this sequence number
    if (seqNum <= _lastSeqNum && _lastSeqNum - seqNum < 1000) {
      return;
    }
    _lastSeqNum = seqNum;

    _lc3Controller.add(Lc3Packet(
      seqNum: seqNum,
      timestamp: timestamp,
      lc3Data: latestFrame,
      isMono: isMono,
    ));
  }

  void disconnect() {
    _l2capSub?.cancel();
    _l2capSub = null;
    _connectionSub?.cancel();
    _connectionSub = null;
    _bleManager.disconnectL2cap();
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
