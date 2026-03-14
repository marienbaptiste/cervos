import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../audio/audio_pipeline.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';

/// Real-time scrolling spectrogram display using CustomPainter.
///
/// X axis: time (scrolls left, newest on right)
/// Y axis: frequency (0 Hz at bottom, 8 kHz at top)
/// Color: magnitude (dark blue → cyan → green → yellow → red)
class SpectrogramWidget extends StatelessWidget {
  const SpectrogramWidget({
    super.key,
    required this.update,
  });

  final SpectrogramUpdate? update;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Spectrogram',
              style: TextStyle(
                color: CervosTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Spacing.sm),
            AspectRatio(
              aspectRatio: 2.5,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CustomPaint(
                  painter: _SpectrogramPainter(update),
                  size: Size.infinite,
                ),
              ),
            ),
            const SizedBox(height: Spacing.xs),
            const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('8 kHz',
                    style: TextStyle(
                        color: CervosTheme.textDisabled, fontSize: 10)),
                Text('0 Hz',
                    style: TextStyle(
                        color: CervosTheme.textDisabled, fontSize: 10)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SpectrogramPainter extends CustomPainter {
  _SpectrogramPainter(this.update);

  final SpectrogramUpdate? update;

  // Spectrogram color map: dark → blue → cyan → green → yellow → red
  static final List<Color> _colorMap = _buildColorMap();

  static List<Color> _buildColorMap() {
    const stops = [
      Color(0xFF000020), // Very dark blue (silence)
      Color(0xFF0000A0), // Blue
      Color(0xFF00A0A0), // Cyan
      Color(0xFF00C000), // Green
      Color(0xFFC0C000), // Yellow
      Color(0xFFC00000), // Red (loud)
    ];

    final colors = <Color>[];
    const segments = 5;
    const stepsPerSegment = 51;

    for (int s = 0; s < segments; s++) {
      for (int i = 0; i < stepsPerSegment; i++) {
        final t = i / stepsPerSegment;
        colors.add(Color.lerp(stops[s], stops[s + 1], t)!);
      }
    }
    colors.add(stops.last);
    return colors;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Fill background with Level 0
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = CervosTheme.level0,
    );

    if (update == null) return;

    final columns = update!.columns;
    final columnIndex = update!.columnIndex;
    final numColumns = AudioConstants.spectrogramColumns;
    final numBins = AudioConstants.frequencyBins;

    final colWidth = size.width / numColumns;
    final binHeight = size.height / numBins;

    // dB range for color mapping
    const dbMin = -80.0;
    const dbMax = 0.0;
    const dbRange = dbMax - dbMin;

    for (int col = 0; col < numColumns; col++) {
      // Map display column to buffer index (oldest on left, newest on right)
      final bufIdx = (columnIndex - numColumns + col) % numColumns;
      if (bufIdx < 0 || columnIndex < numColumns && col < numColumns - columnIndex) {
        continue; // Not yet filled
      }

      final spectrum = columns[bufIdx >= 0 ? bufIdx : bufIdx + numColumns];
      final x = col * colWidth;

      for (int bin = 0; bin < numBins; bin++) {
        final db = spectrum[bin].clamp(dbMin, dbMax);
        final normalized = (db - dbMin) / dbRange; // 0.0 to 1.0

        final colorIdx =
            (normalized * (_colorMap.length - 1)).round().clamp(0, _colorMap.length - 1);

        // Y axis: 0 Hz at bottom, Nyquist at top
        final y = size.height - (bin + 1) * binHeight;

        canvas.drawRect(
          Rect.fromLTWH(x, y, colWidth + 1, binHeight + 1),
          Paint()..color = _colorMap[colorIdx],
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrogramPainter oldDelegate) {
    return update != oldDelegate.update;
  }
}
