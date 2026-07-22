import 'package:flutter/material.dart';

class MdsScopeTheme {
  static ThemeData light({String? fontFamily, double uiFontSize = 12}) {
    return _build(
      brightness: Brightness.light,
      seed: const Color(0xFF2563eb),
      scaffold: const Color(0xFFf6f6f6),
      card: const Color(0xFFffffff),
      fontFamily: fontFamily,
      uiFontSize: uiFontSize,
    );
  }

  static ThemeData dark({String? fontFamily, double uiFontSize = 12}) {
    return _build(
      brightness: Brightness.dark,
      seed: const Color(0xFF60a5fa),
      scaffold: const Color(0xFF111827),
      card: const Color(0xFF0f172a),
      fontFamily: fontFamily,
      uiFontSize: uiFontSize,
    );
  }

  static ThemeData _build({
    required Brightness brightness,
    required Color seed,
    required Color scaffold,
    required Color card,
    required String? fontFamily,
    required double uiFontSize,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorSchemeSeed: seed,
      scaffoldBackgroundColor: scaffold,
      cardColor: card,
      appBarTheme: AppBarTheme(backgroundColor: scaffold),
    );
    TextStyle? style(TextStyle? source, double size) => source?.copyWith(
          fontFamily: fontFamily,
          fontSize: size.clamp(6, 48),
        );
    final source = base.textTheme;
    final textTheme = source.copyWith(
      displayLarge: style(source.displayLarge, uiFontSize + 32),
      displayMedium: style(source.displayMedium, uiFontSize + 24),
      displaySmall: style(source.displaySmall, uiFontSize + 18),
      headlineLarge: style(source.headlineLarge, uiFontSize + 14),
      headlineMedium: style(source.headlineMedium, uiFontSize + 12),
      headlineSmall: style(source.headlineSmall, uiFontSize + 10),
      titleLarge: style(source.titleLarge, uiFontSize + 8),
      titleMedium: style(source.titleMedium, uiFontSize + 4),
      titleSmall: style(source.titleSmall, uiFontSize + 2),
      bodyLarge: style(source.bodyLarge, uiFontSize + 2),
      bodyMedium: style(source.bodyMedium, uiFontSize),
      bodySmall: style(source.bodySmall, uiFontSize - 1),
      labelLarge: style(source.labelLarge, uiFontSize),
      labelMedium: style(source.labelMedium, uiFontSize - 1),
      labelSmall: style(source.labelSmall, uiFontSize - 2),
    );
    return base.copyWith(
      textTheme: textTheme,
      primaryTextTheme: textTheme,
    );
  }
}
