import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/user_data_store.dart';
import '../services/toml_codec.dart';
import 'language_document.dart';
import 'language_storage.dart';

const systemLanguagePreference = 'system';

class LanguageService extends ChangeNotifier {
  LanguageService({UserDataStore? userDataStore})
      : _userDataStore = userDataStore ?? UserDataStore();

  final UserDataStore _userDataStore;
  final Map<String, LanguageDefinition> _languages = {};
  List<Locale> _systemLocales = const [Locale('en')];
  String _preference = systemLanguagePreference;
  String _activeLocale = 'en';
  String _fingerprint = '';
  final Map<String, String> _translationCache = {};
  StreamSubscription<void>? _storageSubscription;
  Timer? _reloadDebounce;
  Future<void>? _refreshing;
  bool _refreshRequested = false;
  bool _initialized = false;

  // Asset bundles are immutable for the lifetime of a running application.
  // Share their parsed catalog so rebuilding AppState (including between
  // widget tests) never opens a second platform-asset request unnecessarily.
  static Future<List<LanguageDefinition>>? _bundledLanguageLoad;

  List<LanguageDefinition> get availableLanguages {
    final values = _languages.values.toList(growable: false)
      ..sort((left, right) => left.displayName.compareTo(right.displayName));
    return List.unmodifiable(values);
  }

  String get preference => _preference;
  String get activeLocale => _activeLocale;
  LanguageDefinition? get activeLanguage => _languages[_activeLocale];
  Locale get activeFlutterLocale => localeFromTag(_activeLocale);
  List<Locale> get supportedFlutterLocales {
    final locales = availableLanguages
        .map((language) => localeFromTag(language.locale))
        .toSet()
        .toList(growable: false);
    return locales.isEmpty ? const [Locale('en')] : List.unmodifiable(locales);
  }

  Future<void> initialize({
    String preference = systemLanguagePreference,
    List<Locale>? systemLocales,
  }) async {
    _preference = preference.trim().isEmpty
        ? systemLanguagePreference
        : preference.trim();
    if (systemLocales != null && systemLocales.isNotEmpty) {
      _systemLocales = List.unmodifiable(systemLocales);
    }
    await refresh();
    if (_initialized) return;
    _initialized = true;
    // Widget tests intentionally disable the file-backed user-data store.
    // Do not leave an asynchronously starting Directory.watch subscription
    // behind in that mode: a test can dispose AppState before the async*
    // stream reaches its first await, and the pending cancellation can then
    // leak into the next widget test in the same isolate.
    if (UserDataStore.disableFileStorageForTests) return;
    _storageSubscription = watchStoredLanguageDocuments(
      _userDataStore,
    ).listen((_) {
      _reloadDebounce?.cancel();
      _reloadDebounce = Timer(
        const Duration(milliseconds: 120),
        () => unawaited(refresh()),
      );
    });
  }

  Future<void> refresh() {
    _refreshRequested = true;
    final pending = _refreshing;
    if (pending != null) return pending;
    late final Future<void> refreshFuture;
    refreshFuture = _drainRefreshRequests().whenComplete(() {
      if (identical(_refreshing, refreshFuture)) _refreshing = null;
    });
    _refreshing = refreshFuture;
    return refreshFuture;
  }

  Future<void> _drainRefreshRequests() async {
    do {
      _refreshRequested = false;
      await _performRefresh();
    } while (_refreshRequested);
  }

  Future<void> _performRefresh() async {
    final next = <String, LanguageDefinition>{};
    final assets = await _loadBundledLanguages();
    for (final language in assets) {
      next[language.locale] = language;
    }
    for (final document in await loadStoredLanguageDocuments(_userDataStore)) {
      try {
        final language = LanguageDefinition.parse(
          document.content,
          source: document.name,
        );
        // A user language file intentionally overrides a bundled locale,
        // which also makes live translation editing possible.
        next[language.locale] = language;
      } catch (_) {
        // One malformed file must not make all valid languages disappear.
      }
    }
    next.putIfAbsent(
      'en',
      () => const LanguageDefinition(
        locale: 'en',
        name: 'English',
        nativeName: 'English',
        messages: {},
        source: 'built-in fallback',
      ),
    );
    final fingerprint = encodeTomlDocument({
      for (final entry in next.entries)
        entry.key: {
          'name': entry.value.name,
          'nativeName': entry.value.nativeName,
          'messages': entry.value.messages,
          'source': entry.value.source,
        },
    });
    final previousActive = _activeLocale;
    final changed = fingerprint != _fingerprint;
    _languages
      ..clear()
      ..addAll(next);
    _fingerprint = fingerprint;
    _activeLocale = _resolveActiveLocale();
    _translationCache.clear();
    if (changed || previousActive != _activeLocale) notifyListeners();
  }

  void setPreference(String value) {
    final normalized = value == systemLanguagePreference
        ? systemLanguagePreference
        : normalizeLocaleTag(value);
    if (normalized.isEmpty || normalized == _preference) return;
    _preference = normalized;
    final previous = _activeLocale;
    _activeLocale = _resolveActiveLocale();
    _translationCache.clear();
    if (previous != _activeLocale || normalized == systemLanguagePreference) {
      notifyListeners();
    }
  }

  void updateSystemLocales(List<Locale> locales) {
    if (locales.isEmpty) return;
    final nextTags = locales.map((locale) => locale.toLanguageTag()).toList();
    final currentTags =
        _systemLocales.map((locale) => locale.toLanguageTag()).toList();
    if (listEquals(nextTags, currentTags)) return;
    _systemLocales = List.unmodifiable(locales);
    if (_preference != systemLanguagePreference) return;
    final previous = _activeLocale;
    _activeLocale = _resolveActiveLocale();
    _translationCache.clear();
    if (previous != _activeLocale) notifyListeners();
  }

  String translate(
    String key, [
    Map<String, Object?> parameters = const {},
  ]) {
    var value = _translationCache[key] ??= _lookupMessage(key) ?? key;
    if (parameters.isNotEmpty) {
      value = value.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (match) {
        final replacement = parameters[match.group(1)];
        return replacement?.toString() ?? match.group(0)!;
      });
    }
    return value;
  }

  String? _lookupMessage(String source) {
    final catalogs = <Map<String, String>>[];
    void addCatalog(LanguageDefinition? language) {
      if (language != null && !catalogs.contains(language.messages)) {
        catalogs.add(language.messages);
      }
    }

    addCatalog(_languages[_activeLocale]);
    addCatalog(_languages[_activeLocale.split('-').first]);
    addCatalog(_languages['en']);
    for (final catalog in catalogs) {
      final exact = catalog[source];
      if (exact != null) return exact;
    }
    for (final catalog in catalogs) {
      final templated = _lookupTemplatedMessage(catalog, source);
      if (templated != null) return templated;
    }
    return null;
  }

  Future<void> install(String fileName, String content) async {
    LanguageDefinition.parse(content, source: fileName);
    await installStoredLanguageDocument(
      _userDataStore,
      fileName,
      content,
    );
    await refresh();
  }

  Future<void> remove(String fileName) async {
    await removeStoredLanguageDocument(_userDataStore, fileName);
    await refresh();
  }

  String _resolveActiveLocale() {
    if (_preference != systemLanguagePreference) {
      return _bestAvailable(_preference) ?? 'en';
    }
    for (final locale in _systemLocales) {
      final match = _bestAvailable(locale.toLanguageTag());
      if (match != null) return match;
    }
    return 'en';
  }

  String? _bestAvailable(String locale) {
    final normalized = normalizeLocaleTag(locale);
    if (normalized.isEmpty) return null;
    if (_languages.containsKey(normalized)) return normalized;
    final language = normalized.split('-').first;
    if (_languages.containsKey(language)) return language;
    for (final available in _languages.keys) {
      if (available.split('-').first == language) return available;
    }
    return null;
  }

  Future<List<LanguageDefinition>> _loadBundledLanguages() async {
    return _bundledLanguageLoad ??= _readBundledLanguages();
  }

  static Future<List<LanguageDefinition>> _readBundledLanguages() async {
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final paths = manifest
          .listAssets()
          .where(
            (path) =>
                path.startsWith('assets/languages/') &&
                path.toLowerCase().endsWith('.toml'),
          )
          .toList(growable: false)
        ..sort();
      final languages = <LanguageDefinition>[];
      for (final path in paths) {
        try {
          languages.add(
            LanguageDefinition.parse(
              await rootBundle.loadString(path),
              source: path,
            ),
          );
        } catch (_) {
          // Invalid optional bundles are ignored independently.
        }
      }
      return languages;
    } catch (_) {
      return const [];
    }
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _storageSubscription?.cancel();
    super.dispose();
  }
}

String? _lookupTemplatedMessage(
  Map<String, String> messages,
  String source,
) {
  for (final entry in messages.entries) {
    final placeholders = RegExp(r'\{([A-Za-z0-9_]+)\}')
        .allMatches(entry.key)
        .toList(growable: false);
    if (placeholders.isEmpty) continue;
    final pattern = StringBuffer('^');
    var offset = 0;
    for (final placeholder in placeholders) {
      pattern
        ..write(RegExp.escape(entry.key.substring(offset, placeholder.start)))
        ..write('(.*?)');
      offset = placeholder.end;
    }
    pattern
      ..write(RegExp.escape(entry.key.substring(offset)))
      ..write(r'$');
    final match = RegExp(pattern.toString(), dotAll: true).firstMatch(source);
    if (match == null) continue;
    var translated = entry.value;
    for (var index = 0; index < placeholders.length; index++) {
      translated = translated.replaceAll(
        '{${placeholders[index].group(1)}}',
        match.group(index + 1) ?? '',
      );
    }
    return translated;
  }
  return null;
}
