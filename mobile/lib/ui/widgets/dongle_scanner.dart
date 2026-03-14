import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/ble_state.dart';
import '../../core/theme.dart';
import '../../core/constants.dart';

/// Scan results list filtered by the Cervos audio service UUID.
/// Tap a device to connect.
class DongleScanner extends ConsumerStatefulWidget {
  const DongleScanner({
    super.key,
    required this.onDeviceSelected,
  });

  final void Function(DiscoveredDevice device) onDeviceSelected;

  @override
  ConsumerState<DongleScanner> createState() => _DongleScannerState();
}

class _DongleScannerState extends ConsumerState<DongleScanner> {
  final Map<String, DiscoveredDevice> _devices = {};

  @override
  Widget build(BuildContext context) {
    ref.listen(scanResultsProvider, (_, next) {
      next.whenData((device) {
        setState(() {
          _devices[device.id] = device;
        });
      });
    });

    if (_devices.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: CervosTheme.primary),
            SizedBox(height: Spacing.lg),
            Text(
              'Scanning for cervhole dongle...',
              style: TextStyle(
                color: CervosTheme.textSecondary,
                fontSize: 14,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: _devices.length,
      itemBuilder: (context, index) {
        final device = _devices.values.elementAt(index);
        final name = device.name.isNotEmpty ? device.name : 'Unknown';
        final rssi = device.rssi;

        return Card(
          child: ListTile(
            leading: const Icon(
              Icons.bluetooth_audio,
              color: CervosTheme.primary,
            ),
            title: Text(
              name,
              style: const TextStyle(
                color: CervosTheme.textPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
            subtitle: Text(
              '${device.id}  •  $rssi dBm',
              style: const TextStyle(
                color: CervosTheme.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: CervosTheme.textSecondary,
            ),
            onTap: () => widget.onDeviceSelected(device),
          ),
        );
      },
    );
  }
}
