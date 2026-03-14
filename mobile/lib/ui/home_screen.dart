import 'dart:async';
import 'dart:typed_data';

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

  // Direct stream subscriptions for reliable frame-by-frame processing
  StreamSubscription<Int16List>? _audioSub;
  StreamSubscription<SpectrogramUpdate>? _spectrumSub;
  StreamSubscription<double>? _levelSub;

  SpectrogramUpdate? _latestSpectrum;
  double _latestLevel = -100.0;
  int _frameCount = 0;

  // Periodic UI refresh for debug counters
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    // Refresh debug counters every 500ms
    _refreshTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _audioSub?.cancel();
    _spectrumSub?.cancel();
    _levelSub?.cancel();
    super.dispose();
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
    _audioSub?.cancel();
    _audioSub = null;
    _spectrumSub?.cancel();
    _spectrumSub = null;
    _levelSub?.cancel();
    _levelSub = null;
    _latestSpectrum = null;
    _latestLevel = -100.0;
    final connection = ref.read(dongleConnectionProvider);
    connection.disconnect();
  }

  Future<void> _startAudioPipeline() async {
    if (_audioSub != null) return; // Already listening

    final pipeline = ref.read(audioPipelineProvider);
    if (!_pipelineInitialized) {
      await pipeline.init();
      _pipelineInitialized = true;
    }

    final connection = ref.read(dongleConnectionProvider);

    // Listen to BLE audio frames and feed into pipeline
    _audioSub = connection.audioStream.listen((Int16List frame) {
      _frameCount++;
      pipeline.onPcmFrame(frame);
    });

    // Listen to pipeline outputs and update UI
    _spectrumSub = pipeline.spectrumStream.listen((update) {
      setState(() {
        _latestSpectrum = update;
      });
    });

    _levelSub = pipeline.levelStream.listen((level) {
      setState(() {
        _latestLevel = level;
      });
    });
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

    // Start the audio pipeline when connected
    if (state == DongleState.connected) {
      _startAudioPipeline();
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
        const ConnectionCard(
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
    return Column(
      children: [
        ConnectionCard(
          state: state,
          deviceName: '${connection.deviceName ?? ""}',
          mtu: connection.mtu,
          onDisconnect: _disconnect,
        ),
        const SizedBox(height: Spacing.sm),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Spacing.md),
            child: Text(
              'BLE: ${connection.rawNotificationCount} notifs, '
              '${connection.totalBytesReceived} bytes\n'
              'Pipeline: $_frameCount frames  |  MTU: ${connection.mtu}\n'
              '${connection.lastError}',
              style: const TextStyle(
                color: CervosTheme.textSecondary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        const SizedBox(height: Spacing.lg),
        Expanded(
          child: SpectrogramWidget(update: _latestSpectrum),
        ),
        const SizedBox(height: Spacing.md),
        LevelMeter(dbfs: _latestLevel),
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
