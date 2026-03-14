import 'package:flutter/material.dart';

import '../../ble/dongle_connection.dart';
import '../../core/theme.dart';
import '../../core/constants.dart';

/// Displays dongle connection status: device name, state, MTU.
class ConnectionCard extends StatelessWidget {
  const ConnectionCard({
    super.key,
    required this.state,
    this.deviceName,
    this.mtu = 23,
    this.onDisconnect,
  });

  final DongleState state;
  final String? deviceName;
  final int mtu;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Row(
          children: [
            _statusIndicator(),
            const SizedBox(width: Spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    deviceName ?? 'No device',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: CervosTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: Spacing.xs),
                  Text(
                    _statusText(),
                    style: const TextStyle(
                      fontSize: 12,
                      color: CervosTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (state == DongleState.connected && onDisconnect != null)
              IconButton(
                icon: const Icon(Icons.link_off, color: CervosTheme.textSecondary),
                onPressed: onDisconnect,
                tooltip: 'Disconnect',
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusIndicator() {
    final color = switch (state) {
      DongleState.connected => CervosTheme.badgeOnDevice,
      DongleState.connecting => CervosTheme.warning,
      DongleState.disconnected => CervosTheme.textDisabled,
    };

    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }

  String _statusText() {
    return switch (state) {
      DongleState.connected => 'Connected  MTU $mtu',
      DongleState.connecting => 'Connecting...',
      DongleState.disconnected => 'Disconnected',
    };
  }
}
