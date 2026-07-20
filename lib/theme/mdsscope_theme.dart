import 'package:flutter/material.dart';

class MdsScopeTheme {
  static final light = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorSchemeSeed: const Color(0xFF2563eb),
    scaffoldBackgroundColor: const Color(0xFFf6f6f6),
    cardColor: const Color(0xFFffffff),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFf6f6f6)),
    textTheme: const TextTheme(),
  );

  static final dark = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorSchemeSeed: const Color(0xFF60a5fa),
    scaffoldBackgroundColor: const Color(0xFF111827),
    cardColor: const Color(0xFF0f172a),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF111827)),
    textTheme: const TextTheme(),
  );
}
