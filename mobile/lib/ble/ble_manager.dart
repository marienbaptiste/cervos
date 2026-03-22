import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import '../core/constants.dart';

/// Wraps FlutterReactiveBle for scanning, connecting, and GATT config.
/// Audio streaming uses L2CAP CoC via native platform channel.
class BleManager {
  BleManager() : _ble = FlutterReactiveBle();

  final FlutterReactiveBle _ble;

  static const _l2capMethod = MethodChannel('com.cervos.cervos/l2cap');
  static const _l2capEvent = EventChannel('com.cervos.cervos/l2cap_audio');

  /// BLE status stream.
  Stream<BleStatus> get statusStream => _ble.statusStream;

  /// Scan for devices advertising the Cervos audio service UUID.
  Stream<DiscoveredDevice> scanForDongle() {
    return _ble.scanForDevices(
      withServices: [BleUuids.audioService],
      scanMode: ScanMode.lowLatency,
    );
  }

  /// Connect to a discovered dongle (GATT for config characteristics).
  Stream<ConnectionStateUpdate> connectToDongle(String deviceId) {
    return _ble.connectToDevice(
      id: deviceId,
      connectionTimeout: const Duration(seconds: 10),
    );
  }

  /// Negotiate MTU.
  Future<int> negotiateMtu(String deviceId) async {
    return _ble.requestMtu(deviceId: deviceId, mtu: 512);
  }

  /// Discover services on the connected device.
  Future<List<DiscoveredService>> discoverServices(String deviceId) {
    return _ble.discoverServices(deviceId);
  }

  /// Write capture control: 0x01 = on, 0x00 = off.
  Future<void> writeCaptureControl(String deviceId, bool enabled) async {
    final characteristic = QualifiedCharacteristic(
      serviceId: BleUuids.audioService,
      characteristicId: BleUuids.captureControl,
      deviceId: deviceId,
    );
    await _ble.writeCharacteristicWithResponse(
      characteristic,
      value: [enabled ? 0x01 : 0x00],
    );
  }

  /// Write power mode (0 = battery saver, 1 = balanced, 2 = low latency).
  Future<void> writePowerMode(String deviceId, PowerMode mode) async {
    final characteristic = QualifiedCharacteristic(
      serviceId: BleUuids.audioService,
      characteristicId: BleUuids.powerMode,
      deviceId: deviceId,
    );
    await _ble.writeCharacteristicWithResponse(
      characteristic,
      value: [mode.value],
    );
  }

  /// Read current power mode from dongle.
  Future<PowerMode> readPowerMode(String deviceId) async {
    final characteristic = QualifiedCharacteristic(
      serviceId: BleUuids.audioService,
      characteristicId: BleUuids.powerMode,
      deviceId: deviceId,
    );
    final value = await _ble.readCharacteristic(characteristic);
    if (value.isNotEmpty && value[0] <= PowerMode.lowLatency.value) {
      return PowerMode.values[value[0]];
    }
    return PowerMode.balanced;
  }

  /// Write dongle name (max 32 chars). Triggers dongle soft-reset.
  Future<void> writeDongleName(String deviceId, String name) async {
    final characteristic = QualifiedCharacteristic(
      serviceId: BleUuids.audioService,
      characteristicId: BleUuids.dongleConfig,
      deviceId: deviceId,
    );
    final nameBytes = name.codeUnits.take(32).toList();
    await _ble.writeCharacteristicWithResponse(
      characteristic,
      value: nameBytes,
    );
  }

  /// Read dongle name.
  Future<String> readDongleName(String deviceId) async {
    final characteristic = QualifiedCharacteristic(
      serviceId: BleUuids.audioService,
      characteristicId: BleUuids.dongleConfig,
      deviceId: deviceId,
    );
    final value = await _ble.readCharacteristic(characteristic);
    return String.fromCharCodes(value);
  }

  /// Connect L2CAP CoC for audio streaming (native Android).
  Future<bool> connectL2cap(String deviceAddress) async {
    final result = await _l2capMethod.invokeMethod<bool>('connectL2cap', {
      'address': deviceAddress,
      'psm': BleUuids.audioL2capPsm,
    });
    return result ?? false;
  }

  /// Disconnect L2CAP audio channel.
  Future<void> disconnectL2cap() async {
    await _l2capMethod.invokeMethod<void>('disconnectL2cap');
  }

  /// L2CAP audio packet stream — raw bytes including header + LC3 frames.
  Stream<Uint8List> get l2capAudioStream {
    return _l2capEvent.receiveBroadcastStream().map((data) {
      if (data is List<int>) {
        return Uint8List.fromList(data);
      }
      return data as Uint8List;
    });
  }
}
