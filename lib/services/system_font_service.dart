import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _systemFontsChannel = MethodChannel('mdslens/system_fonts');

class SystemFontService {
  SystemFontService._();

  static const List<String> fallbackFamilies = [
    'Arial',
    'Helvetica',
    'Times New Roman',
    'Courier New',
    'Georgia',
    'Verdana',
    'Monaco',
  ];

  static Future<List<String>> loadFamilies() async {
    if (!(Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux)) {
      return fallbackFamilies;
    }
    try {
      final raw = await _systemFontsChannel.invokeListMethod<String>(
        'listFamilies',
      );
      final seen = <String>{};
      final families = <String>[];
      for (final value in raw ?? const <String>[]) {
        final family = value.trim();
        final key = family.toLowerCase();
        if (family.isEmpty ||
            family.startsWith('.') ||
            family.startsWith('@') ||
            !seen.add(key)) {
          continue;
        }
        families.add(family);
      }
      families.sort(
        (left, right) => left.toLowerCase().compareTo(right.toLowerCase()),
      );
      return families.isEmpty ? fallbackFamilies : families;
    } catch (_) {
      return fallbackFamilies;
    }
  }
}
