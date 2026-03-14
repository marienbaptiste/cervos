import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Cervos dark theme built from design-system/tokens.yaml.
/// Dark-only. Elevation via surface color lightness, never shadows.
class CervosTheme {
  CervosTheme._();

  // ---- Elevation surfaces (dark UI, no pure black) ----
  static const Color level0 = Color(0xFF1E1F22); // Base background
  static const Color level1 = Color(0xFF252629); // Cards, nav bars
  static const Color level2 = Color(0xFF2C2D32); // Elevated cards
  static const Color level3 = Color(0xFF323438); // Modals, dialogs
  static const Color level4 = Color(0xFF393C41); // Hover/focus states

  // ---- Brand colors ----
  static const Color primary = Color(0xFF1A73E8);
  static const Color secondary = Color(0xFF5F6368);
  static const Color accent = Color(0xFFFBBC04);
  static const Color warning = Color(0xFFF9AB00);
  static const Color error = Color(0xFFEA4335);

  // ---- Text colors for dark surfaces ----
  static const Color textPrimary = Color(0xFFE8E8E8);
  static const Color textSecondary = Color(0xFFB0B0B0);
  static const Color textDisabled = Color(0xFF6B6B6B);

  // ---- Model badge colors ----
  static const Color badgeOnDevice = Color(0xFF34A853); // Green — Nano
  static const Color badgeLocal = Color(0xFFF9AB00); // Amber — local
  static const Color badgeCloud = Color(0xFF4285F4); // Blue — cloud

  // ---- Permission tier colors ----
  static const Color permAlways = Color(0xFF34A853);
  static const Color permConfirm = Color(0xFFF9AB00);
  static const Color permUnlock = Color(0xFFEA4335);

  /// Build the full ThemeData.
  static ThemeData get darkTheme {
    final textTheme = GoogleFonts.interTextTheme().apply(
      bodyColor: textPrimary,
      displayColor: textPrimary,
    );

    return ThemeData.dark().copyWith(
      scaffoldBackgroundColor: level0,
      colorScheme: const ColorScheme.dark(
        primary: primary,
        secondary: secondary,
        surface: level1,
        error: error,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: textPrimary,
        onError: Colors.white,
      ),
      cardColor: level1,
      dialogBackgroundColor: level3,
      appBarTheme: const AppBarTheme(
        backgroundColor: level1,
        foregroundColor: textPrimary,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        color: level1,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: level2,
          foregroundColor: textPrimary,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      textTheme: textTheme.copyWith(
        headlineLarge: textTheme.headlineLarge?.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w700,
          height: 36 / 28,
        ),
        headlineMedium: textTheme.headlineMedium?.copyWith(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          height: 28 / 22,
        ),
        headlineSmall: textTheme.headlineSmall?.copyWith(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          height: 24 / 18,
        ),
        bodyLarge: textTheme.bodyLarge?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          height: 24 / 16,
        ),
        bodySmall: textTheme.bodySmall?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          height: 16 / 12,
        ),
        labelSmall: textTheme.labelSmall?.copyWith(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          height: 14 / 10,
        ),
      ),
    );
  }
}
