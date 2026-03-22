import 'dart:typed_data';

import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ble_manager.dart';
import 'dongle_connection.dart';

/// Singleton BLE manager instance.
final bleManagerProvider = Provider<BleManager>((ref) {
  return BleManager();
});

/// Singleton dongle connection instance.
final dongleConnectionProvider = Provider<DongleConnection>((ref) {
  final bleManager = ref.watch(bleManagerProvider);
  final connection = DongleConnection(bleManager);
  ref.onDispose(() => connection.dispose());
  return connection;
});

/// BLE adapter status stream.
final bleStatusProvider = StreamProvider<BleStatus>((ref) {
  final bleManager = ref.watch(bleManagerProvider);
  return bleManager.statusStream;
});

/// Scan results stream — emits discovered devices with the Cervos audio service.
final scanResultsProvider = StreamProvider.autoDispose<DiscoveredDevice>((ref) {
  final bleManager = ref.watch(bleManagerProvider);
  return bleManager.scanForDongle();
});

/// Dongle connection state stream.
final dongleStateProvider = StreamProvider<DongleState>((ref) {
  final connection = ref.watch(dongleConnectionProvider);
  return connection.stateStream;
});

/// LC3 frame stream from the dongle — each event is one compressed frame.
final lc3FrameProvider = StreamProvider<Uint8List>((ref) {
  final connection = ref.watch(dongleConnectionProvider);
  return connection.lc3Stream;
});
