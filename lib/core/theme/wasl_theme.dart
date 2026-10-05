import 'package:flutter/material.dart';

/// WASL visual identity — colors and motion durations matching the approved
/// web reference design (secure-chat-hub).
class WaslColors {
  static const Color background = Color(0xFFF5F8F7);
  static const Color foreground = Color(0xFF18342E);
  static const Color card = Colors.white;
  static const Color primary = Color(0xFF087E66);
  static const Color primaryForeground = Colors.white;
  static const Color secondary = Color(0xFFEAF3F0);
  static const Color muted = Color(0xFFEFF4F2);
  static const Color mutedForeground = Color(0xFF5E7A72);
  static const Color accent = Color(0xFFE3F0EC);
  static const Color destructive = Color(0xFFD64545);
  static const Color border = Color(0xFFDEE9E5);

  // Dark mode
  static const Color darkBackground = Color(0xFF122019);
  static const Color darkCard = Color(0xFF1B2C25);
  static const Color darkForeground = Color(0xFFF0F6F3);
  static const Color darkPrimary = Color(0xFF2FBF9B);
  static const Color darkMuted = Color(0xFF23362E);
  static const Color darkMutedForeground = Color(0xFFA9C0B8);
  static const Color darkBorder = Color(0xFF2A4038);

  /// Deterministic avatar colors cycled per contact (like the reference UI)
  static const List<Color> avatarPalette = [
    Color(0xFF087E66),
    Color(0xFF7A5C2E),
    Color(0xFF4A6FA5),
    Color(0xFF8A4B6E),
    Color(0xFF18342E),
    Color(0xFF2F7D5B),
  ];

  /// Theme-aware muted text color — readable in BOTH light and dark mode.
  /// Use this instead of hardcoding [mutedForeground]/[darkMutedForeground].
  static Color mutedFg(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? darkMutedForeground
          : mutedForeground;

  /// Theme-aware primary text color.
  static Color fg(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? darkForeground
          : foreground;

  static Color avatarColorFor(String seed) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return avatarPalette[hash % avatarPalette.length];
  }
}

class WaslTheme {
  static ThemeData light() {
    final base = ThemeData.light(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: WaslColors.background,
      colorScheme: const ColorScheme.light(
        primary: WaslColors.primary,
        onPrimary: WaslColors.primaryForeground,
        secondary: WaslColors.secondary,
        surface: WaslColors.card,
        onSurface: WaslColors.foreground,
        error: WaslColors.destructive,
        outline: WaslColors.border,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: WaslColors.card,
        foregroundColor: WaslColors.foreground,
        elevation: 0,
        centerTitle: false,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: WaslColors.foreground,
        displayColor: WaslColors.foreground,
      ),
      dividerTheme: const DividerThemeData(
        color: WaslColors.border,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  static ThemeData dark() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: WaslColors.darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: WaslColors.darkPrimary,
        onPrimary: WaslColors.darkBackground,
        secondary: WaslColors.darkMuted,
        surface: WaslColors.darkCard,
        onSurface: WaslColors.darkForeground,
        error: WaslColors.destructive,
        outline: WaslColors.darkBorder,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: WaslColors.darkCard,
        foregroundColor: WaslColors.darkForeground,
        elevation: 0,
        centerTitle: false,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: WaslColors.darkForeground,
        displayColor: WaslColors.darkForeground,
      ),
      dividerTheme: const DividerThemeData(
        color: WaslColors.darkBorder,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

/// Unified motion durations (matching the web reference)
class WaslMotion {
  static const Duration screenIn = Duration(milliseconds: 240);
  static const Duration sheetIn = Duration(milliseconds: 260);
  static const Duration messageIn = Duration(milliseconds: 220);
  static const Curve ease = Cubic(0.22, 0.61, 0.36, 1.0);
}
