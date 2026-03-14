import 'dart:async';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../core/constants.dart';

/// Wraps FlutterReactiveBle for scanning, connecting, and MTU negotiation.
/// Designed to handle 4 simultaneous connections (G2, R1, earbuds, dongle)
/// but currently only implements dongle connection.
class BleManager {
  BleManager() : _ble = FlutterReactiveBle();

  final FlutterReactiveBle _ble;

  /// BLE status stream (e.g. powered on, unauthorized, etc.)
  Stream<BleStatus> get statusStream => _ble.statusStream;

  /// Scan for devices advertising the Cervos audio service UUID.
  Stream<DiscoveredDevice> scanForDongle() {
    return _ble.scanForDevices(
      withServices: [BleUuids.audioService],
      scanMode: ScanMode.lowLatency,
    );
  }

  /// Connect to a discovered dongle and negotiate MTU.
  /// Returns a stream of connection state updates.
  Stream<ConnectionStateUpdate> connectToDongle(String deviceId) {
    return _ble.connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 10),
    );
  }

  /// Negotiate MTU — request 247 to fit 640-byte audio frames.
  Future<int> negotiateMtu(String deviceId) async {
    return _ble.requestMtu(deviceId: deviceId, mtu: 247);
  }

  /// Subscribe to audio stream notifications from the dongle.
  /// Each notification contains 640 bytes of raw PCM (320 int16 samples).
  Stream<List<int>> subscribeToAudio(String deviceId) {
    final characteristic = QualifiedCharacteristic(
      serviceId: BleUuids.audioService,
      characteristicId: BleUuids.audioStream,
      deviceId: deviceId,
    );
    return _ble.subscribeToCharacteristic(characteristic);
  }
}
