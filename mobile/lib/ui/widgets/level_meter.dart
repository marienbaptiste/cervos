import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/constants.dart';

/// Horizontal audio level meter showing RMS dBFS.
/// Color gradient from primary blue (quiet) to amber (loud).
class LevelMeter extends StatelessWidget {
  const LevelMeter({
    super.key,
    required this.dbfs,
  });

  /// Audio level in dBFS (0 = full scale, -100 = silence).
  final double dbfs;

  @override
  Widget build(BuildContext context) {
    // Map dBFS to 0.0–1.0 range (-60 dB floor to 0 dB ceiling)
    const dbMin = -60.0;
    const dbMax = 0.0;
    final normalized = ((dbfs - dbMin) / (dbMax - dbMin)).clamp(0.0, 1.0);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Audio Level',
                  style: TextStyle(
                    color: CervosTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${dbfs.toStringAsFixed(1)} dBFS',
                  style: const TextStyle(
                    color: CervosTheme.textSecondary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 12,
                child: Stack(
                  children: [
                    // Background
                    Container(
                      decoration: const BoxDecoration(
                        color: CervosTheme.level0,
                      ),
                    ),
                    // Level bar
                    FractionallySizedBox(
                      widthFactor: normalized,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              CervosTheme.primary,
                              CervosTheme.badgeOnDevice,
                              CervosTheme.warning,
                              CervosTheme.error,
                            ],
                            stops: const [0.0, 0.5, 0.8, 1.0],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
