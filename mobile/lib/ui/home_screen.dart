import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

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

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with WidgetsBindingObserver {
  bool _permissionsGranted = false;
  bool _pipelineInitialized = false;
  bool _spectroEnabled = true;

  StreamSubscription<Lc3Packet>? _audioSub;
  StreamSubscription<SpectrogramUpdate>? _spectrumSub;
  StreamSubscription<double>? _levelSub;

  SpectrogramUpdate? _latestSpectrum;
  double _latestLevel = -100.0;

  bool _spectroWasEnabled = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _requestPermissions();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final pipeline = ref.read(audioPipelineProvider);
    if (state == AppLifecycleState.inactive) {
      _spectroWasEnabled = pipeline.spectroEnabled;
      pipeline.spectroEnabled = false;
    } else if (state == AppLifecycleState.resumed) {
      pipeline.spectroEnabled = _spectroWasEnabled;
      if (_spectroWasEnabled) {
        setState(() {});
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    _stopForegroundService();
    final connection = ref.read(dongleConnectionProvider);
    connection.disconnect();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'cervos_audio',
        channelName: 'Cervos Audio',
        channelDescription: 'BLE audio streaming from dongle',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<void> _startForegroundService() async {
    _initForegroundTask();
    await FlutterForegroundTask.startService(
      notificationTitle: 'Cervos Audio',
      notificationText: 'Streaming LC3 from dongle',
    );
  }

  Future<void> _stopForegroundService() async {
    await FlutterForegroundTask.stopService();
  }

  Future<void> _startAudioPipeline() async {
    if (_audioSub != null) return;

    await _startForegroundService();

    final pipeline = ref.read(audioPipelineProvider);
    if (!_pipelineInitialized) {
      await pipeline.init();
      _pipelineInitialized = true;
    } else {
      await pipeline.flush();
    }

    final connection = ref.read(dongleConnectionProvider);

    _audioSub = connection.lc3Stream.listen((Lc3Packet packet) {
      pipeline.onLc3Packet(packet);
    });

    _spectrumSub = pipeline.spectrumStream.listen((update) {
      if (_spectroEnabled) {
        setState(() {
          _latestSpectrum = update;
        });
      }
    });

    _levelSub = pipeline.levelStream.listen((level) {
      if (_spectroEnabled) {
        setState(() {
          _latestLevel = level;
        });
      }
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
              const Icon(Icons.bluetooth_disabled_rounded,
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
        const ConnectionCard(state: DongleState.disconnected),
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
          child: DongleScanner(onDeviceSelected: _connectToDevice),
        ),
      ],
    );
  }

  Widget _buildAudioView(DongleState state, DongleConnection connection) {
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
          child: _spectroEnabled
              ? SpectrogramWidget(update: _latestSpectrum)
              : Center(
                  child: Text(
                    'Spectrogram OFF — audio only',
                    style: TextStyle(color: CervosTheme.textDisabled, fontSize: 14),
                  ),
                ),
        ),
        if (_spectroEnabled) ...[
          const SizedBox(height: Spacing.md),
          LevelMeter(dbfs: _latestLevel),
        ],
        const SizedBox(height: Spacing.sm),
        // Controls row: VIZ toggle + Power mode selector
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _spectroEnabled = !_spectroEnabled;
                  ref.read(audioPipelineProvider).spectroEnabled = _spectroEnabled;
                });
              },
              icon: Icon(
                Icons.equalizer_rounded,
                size: 16,
              ),
              label: Text(_spectroEnabled ? 'VIZ' : 'OFF', style: const TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                foregroundColor: _spectroEnabled
                    ? CervosTheme.badgeLocal
                    : CervosTheme.textDisabled,
                side: BorderSide(
                  color: _spectroEnabled
                      ? CervosTheme.badgeLocal
                      : CervosTheme.level3,
                ),
                padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            _buildPowerModeButton(connection),
          ],
        ),
        const SizedBox(height: Spacing.lg),
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: () async {
                  final newState = !connection.captureEnabled;
                  await connection.setCaptureEnabled(newState);
                  setState(() {});
                },
                icon: Icon(
                  connection.captureEnabled
                      ? Icons.graphic_eq_rounded
                      : Icons.volume_off_rounded,
                  size: 20,
                ),
                label: Text(
                    connection.captureEnabled ? 'Capture ON' : 'Capture OFF'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: connection.captureEnabled
                      ? CervosTheme.badgeOnDevice
                      : CervosTheme.level2,
                  foregroundColor: connection.captureEnabled
                      ? Colors.white
                      : CervosTheme.textSecondary,
                  padding: const EdgeInsets.symmetric(vertical: Spacing.md),
                ),
              ),
            ),
            const SizedBox(width: Spacing.sm),
            ElevatedButton(
              onPressed: _disconnect,
              style: ElevatedButton.styleFrom(
                backgroundColor: CervosTheme.level2,
                padding: const EdgeInsets.symmetric(
                    vertical: Spacing.md, horizontal: Spacing.xl),
              ),
              child: const Icon(Icons.link_off_rounded, size: 20),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPowerModeButton(DongleConnection connection) {
    final mode = connection.powerMode;
    return PopupMenuButton<PowerMode>(
      onSelected: (PowerMode selected) async {
        await connection.setPowerMode(selected);
        setState(() {});
      },
      itemBuilder: (context) => PowerMode.values.map((m) {
        return PopupMenuItem<PowerMode>(
          value: m,
          child: ListTile(
            dense: true,
            leading: Icon(
              m == mode ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18,
              color: m == mode ? CervosTheme.badgeLocal : CervosTheme.textSecondary,
            ),
            title: Text(m.label, style: const TextStyle(fontSize: 13)),
            subtitle: Text(m.description, style: const TextStyle(fontSize: 11)),
          ),
        );
      }).toList(),
      child: OutlinedButton.icon(
        onPressed: null, // Handled by PopupMenuButton
        icon: Icon(
          mode == PowerMode.lowLatency
              ? Icons.bolt_rounded
              : mode == PowerMode.batterySaver
                  ? Icons.battery_saver_rounded
                  : Icons.tune_rounded,
          size: 16,
        ),
        label: Text(mode.label, style: const TextStyle(fontSize: 11)),
        style: OutlinedButton.styleFrom(
          foregroundColor: CervosTheme.badgeLocal,
          side: const BorderSide(color: CervosTheme.level3),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.md),
        ),
      ),
    );
  }
}
