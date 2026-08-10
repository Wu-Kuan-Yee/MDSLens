import 'dart:async';

import 'package:flutter/foundation.dart';

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

typedef SystemFontFamilyLoader = Future<List<String>> Function();

/// A live view of the fonts currently exposed by the operating system.
///
/// There is no single cross-platform font-change notification in Flutter.
/// Polling only while the font picker is open gives every native runner and
/// the browser Local Font Access API the same predictable hot-refresh
/// behavior without keeping a permanent background task alive.
class SystemFontCatalog extends ChangeNotifier {
  SystemFontCatalog({
    SystemFontFamilyLoader? loader,
    this.refreshInterval = const Duration(seconds: 2),
  }) : _loader = loader ?? SystemFontService.loadFamilies;

  final SystemFontFamilyLoader _loader;
  final Duration refreshInterval;
  List<String> _families = SystemFontService.fallbackFamilies;
  Timer? _timer;
  Future<void>? _refreshing;
  bool _started = false;

  List<String> get families => List.unmodifiable(_families);

  Future<void> start() async {
    if (_started) return;
    _started = true;
    await refresh();
    if (refreshInterval > Duration.zero) {
      _timer = Timer.periodic(refreshInterval, (_) => unawaited(refresh()));
    }
  }

  Future<void> refresh() {
    final pending = _refreshing;
    if (pending != null) return pending;
    late final Future<void> refreshFuture;
    refreshFuture = _load().whenComplete(() {
      if (identical(_refreshing, refreshFuture)) _refreshing = null;
    });
    _refreshing = refreshFuture;
    return refreshFuture;
  }

  Future<void> _load() async {
    final next = await _loader();
    if (listEquals(next, _families)) return;
    _families = List.unmodifiable(next);
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
