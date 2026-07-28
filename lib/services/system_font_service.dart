import 'system_font_backend.dart'
    if (dart.library.js_interop) 'system_font_backend_web.dart';

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
    try {
      final raw = await loadSystemFontFamilies();
      final seen = <String>{};
      final families = <String>[];
      for (final value in raw) {
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

  /// Makes a browser-selected local font available to Flutter's renderer.
  ///
  /// Native platforms already resolve installed families through the host.
  static Future<void> prepareFamily(String family) async {
    if (family == 'System') return;
    await prepareSystemFontFamily(family);
  }
}
