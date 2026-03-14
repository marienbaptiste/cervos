import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../audio/audio_pipeline.dart';
import '../audio/audio_state.dart';
import '../ble/ble_state.dart';
import '../ble/dongle_connection.dart';
import '../core/constants.dart';
import '../core/theme.dart';
import 'cervos_scaffold.dart';
import 'widgets/connection_card.dart';
import 'widgets/dongle_scanner.dart';
import 'widgets/level_meter.dart';
import 'widgets/spectrogram_widget.dart';

/// Main screen: shows scanner when disconnected, audio view when connected.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _permissionsGranted = false;
  bool _pipelineInitialized = false;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();

    final allGranted = statuses.values.every(
        (s) => s == PermissionStatus.granted);

    setState(() {
      _permissionsGranted = allGranted;
    });
  }

  void _connectToDevice(DiscoveredDevice device) {
    final connection = ref.read(dongleConnectionProvider);
    connection.connect(device);
  }

  void _disconnect() {
    final connection = ref.read(dongleConnectionProvider);
    connection.disconnect();
  }

  Future<void> _ensurePipelineInitialized() async {
    if (!_pipelineInitialized) {
      final pipeline = ref.read(audioPipelineProvider);
      await pipeline.init();
      _pipelineInitialized = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_permissionsGranted) {
      return CervosScaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bluetooth_disabled,
                  size: 48, color: CervosTheme.textDisabled),
              const SizedBox(height: Spacing.lg),
              const Text(
                'Bluetooth permissions required',
                style: TextStyle(color: CervosTheme.textSecondary),
              ),
              const SizedBox(height: Spacing.lg),
              ElevatedButton(
                onPressed: _requestPermissions,
                child: const Text('Grant Permissions'),
              ),
            ],
          ),
        ),
      );
    }

    final dongleState = ref.watch(dongleStateProvider);
    final connection = ref.read(dongleConnectionProvider);

    final state = dongleState.when(
      data: (s) => s,
      loading: () => DongleState.disconnected,
      error: (_, __) => DongleState.disconnected,
    );

    // Wire BLE audio into pipeline when connected
    if (state == DongleState.connected) {
      _ensurePipelineInitialized();
      // Activate the audio bridge (BLE → pipeline)
      ref.watch(audioBridgeProvider);
    }

    return CervosScaffold(
      body: state == DongleState.disconnected
          ? _buildScannerView()
          : _buildAudioView(state, connection),
    );
  }

  Widget _buildScannerView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConnectionCard(
          state: DongleState.disconnected,
        ),
        const SizedBox(height: Spacing.lg),
        const Padding(
          padding: EdgeInsets.only(left: Spacing.xs),
          child: Text(
            'Available devices',
            style: TextStyle(
              color: CervosTheme.textSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: Spacing.sm),
        Expanded(
          child: DongleScanner(
            onDeviceSelected: _connectToDevice,
          ),
        ),
      ],
    );
  }

  Widget _buildAudioView(DongleState state, DongleConnection connection) {
    final spectrumUpdate = ref.watch(spectrumProvider);
    final level = ref.watch(audioLevelProvider);

    final spectrum = spectrumUpdate.when(
      data: (u) => u,
      loading: () => null,
      error: (_, __) => null,
    );

    final dbfs = level.when(
      data: (l) => l,
      loading: () => -100.0,
      error: (_, __) => -100.0,
    );

    return Column(
      children: [
        ConnectionCard(
          state: state,
          deviceName: connection.deviceName,
          mtu: connection.mtu,
          onDisconnect: _disconnect,
        ),
        const SizedBox(height: Spacing.lg),
        Expanded(
          child: SpectrogramWidget(update: spectrum),
        ),
        const SizedBox(height: Spacing.md),
        LevelMeter(dbfs: dbfs),
        const SizedBox(height: Spacing.lg),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _disconnect,
            style: ElevatedButton.styleFrom(
              backgroundColor: CervosTheme.level2,
              padding: const EdgeInsets.symmetric(vertical: Spacing.md),
            ),
            child: const Text('Disconnect'),
          ),
        ),
      ],
    );
  }
}
