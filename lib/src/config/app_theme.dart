import 'package:flutter/material.dart';

class AppTheme {
  const AppTheme._();

  static ThemeData light() {
    const seed = Color(0xFF2563EB);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.light,
      surface: const Color(0xFFF8FAFC),
    );

    return _baseTheme(scheme, Brightness.light);
  }

  static ThemeData dark() {
    const seed = Color(0xFF7DD3FC);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: Brightness.dark,
      surface: const Color(0xFF0F172A),
    );

    return _baseTheme(scheme, Brightness.dark);
  }

  static ThemeData _baseTheme(ColorScheme scheme, Brightness brightness) {
    final textTheme = ThemeData(useMaterial3: true, brightness: brightness)
        .textTheme
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      textTheme: textTheme,
      cardTheme: CardThemeData(
        color:
            brightness == Brightness.light
                ? Colors.white.withValues(alpha: 0.88)
                : const Color(0xFF111827),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color:
                brightness == Brightness.light
                    ? const Color(0xFFD9E2F2)
                    : const Color(0xFF1E293B),
          ),
        ),
      ),
      dividerColor:
          brightness == Brightness.light
              ? const Color(0xFFD7DFEC)
              : const Color(0xFF223047),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor:
            brightness == Brightness.light
                ? Colors.white
                : const Color(0xFF0F172A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color:
                brightness == Brightness.light
                    ? const Color(0xFFD7DFEC)
                    : const Color(0xFF334155),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(
            color:
                brightness == Brightness.light
                    ? const Color(0xFFD7DFEC)
                    : const Color(0xFF334155),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.2),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor:
            brightness == Brightness.light ? const Color(0xFF0F172A) : null,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: brightness == Brightness.light ? Colors.white : null,
        ),
      ),
    );
  }
}
