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

  // These are installation templates only. They are copied into the external
  // language store once and are never merged directly into the runtime list.
  static Future<List<StoredLanguageDocument>>? _initialLanguageLoad;

  List<LanguageDefinition> get availableLanguages {
    final values = _languages.values.toList(growable: false)
      ..sort((left, right) => left.displayName.compareTo(right.displayName));
    return List.unmodifiable(values);
  }

  String get preference => _preference;
  String get activeLocale => _activeLocale;
  LanguageDefinition? get activeLanguage => _languages[_activeLocale];
  String? get systemLocaleMatch => _resolveSystemLocale();
  String? get installedEnglishLocale => _bestAvailable('en');
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
    await initializeStoredLanguageDocuments(
      _userDataStore,
      await (_initialLanguageLoad ??= _readInitialLanguages()),
    );
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
    for (final document in await loadStoredLanguageDocuments(_userDataStore)) {
      try {
        final language = LanguageDefinition.parse(
          document.content,
          source: document.name,
        );
        // Metadata-only files are not usable translations and must not become
        // selectable placeholders in Language Settings.
        if (language.messages.isEmpty) continue;
        next[language.locale] = language;
      } catch (_) {
        // One malformed external file must not hide other valid catalogs.
      }
    }
    final fingerprint = encodeTomlDocument({
      for (final entry in next.entries)
        entry.key: {
          'name': entry.value.name,
          'nativeName': entry.value.nativeName,
          'baseLocale': entry.value.baseLocale,
          'coverageLevel': entry.value.coverageLevel,
          'script': entry.value.script,
          'defaultRegion': entry.value.defaultRegion,
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
    // AppState also needs this event when rendering remains English but the
    // automatic system-language selection has lost its installed match.
    if (previous != _activeLocale || !listEquals(nextTags, currentTags)) {
      notifyListeners();
    }
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
    for (final language in _fallbackChain(_activeLocale)) {
      if (!catalogs.contains(language.messages)) {
        catalogs.add(language.messages);
      }
    }
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
    await removeAll([fileName]);
  }

  Future<void> removeAll(Iterable<String> fileNames) async {
    final names = fileNames.toSet();
    if (names.isEmpty) return;
    await removeStoredLanguageDocuments(_userDataStore, names);
    await refresh();
  }

  String _resolveActiveLocale() {
    if (_preference != systemLanguagePreference) {
      return _bestAvailable(_preference) ?? 'en';
    }
    return _resolveSystemLocale() ?? installedEnglishLocale ?? 'en';
  }

  String? _resolveSystemLocale() {
    for (final locale in _systemLocales) {
      final match = _bestSystemAvailable(locale.toLanguageTag());
      if (match != null) return match;
    }
    return null;
  }

  String? _bestSystemAvailable(String locale) {
    final normalized = normalizeLocaleTag(locale);
    if (normalized.isEmpty) return null;
    if (_languages.containsKey(normalized)) return normalized;

    final parts = normalized.split('-');
    final language = parts.first;
    if (language == 'zh') {
      String? script;
      String? region;
      for (final part in parts.skip(1)) {
        if (part.length == 4) {
          script = '${part[0].toUpperCase()}'
              '${part.substring(1).toLowerCase()}';
        } else if (part.length == 2 && part == part.toUpperCase()) {
          region = part;
        }
      }
      final preferredScript = script ??
          (const {'TW', 'HK', 'MO'}.contains(region) ? 'Hant' : 'Hans');
      final scripted = 'zh-$preferredScript';
      if (_languages.containsKey(scripted)) return scripted;
      if (_languages.containsKey('zh')) return 'zh';
      // Simplified and Traditional Chinese are distinct choices. Never use
      // the opposite script only because it shares the `zh` language tag.
      return null;
    }

    for (final parent in _implicitParentLocales(normalized)) {
      if (_languages.containsKey(parent)) return parent;
    }
    if (_languages.containsKey(language)) return language;
    for (final available in _languages.keys) {
      if (available.split('-').first == language) return available;
    }
    return null;
  }

  String? _bestAvailable(String locale) {
    final normalized = normalizeLocaleTag(locale);
    if (normalized.isEmpty) return null;
    final exact = _languages[normalized];
    if (exact != null && exact.messages.isNotEmpty) return normalized;
    for (final parent in _implicitParentLocales(normalized)) {
      final candidate = _languages[parent];
      if (candidate != null && candidate.messages.isNotEmpty) return parent;
    }
    final language = normalized.split('-').first;
    // Prefer an installed base-language catalog over a regional sibling.
    if (language == 'en' && _languages.containsKey('en')) return 'en';
    final languageCatalog = _languages[language];
    if (languageCatalog != null && languageCatalog.messages.isNotEmpty) {
      return language;
    }
    for (final available in _languages.keys) {
      final candidate = _languages[available];
      if (available.split('-').first == language &&
          candidate != null &&
          candidate.messages.isNotEmpty) {
        return available;
      }
    }
    if (exact != null) return normalized;
    if (languageCatalog != null) return language;
    for (final available in _languages.keys) {
      if (available.split('-').first == language) return available;
    }
    return null;
  }

  static Future<List<StoredLanguageDocument>> _readInitialLanguages() async {
    const paths = <String>[
      'assets/languages/be.toml',
      'assets/languages/ca.toml',
      'assets/languages/cs.toml',
      'assets/languages/da.toml',
      'assets/languages/de.toml',
      'assets/languages/el.toml',
      'assets/languages/en.toml',
      'assets/languages/eo.toml',
      'assets/languages/es.toml',
      'assets/languages/fi.toml',
      'assets/languages/fr.toml',
      'assets/languages/hu.toml',
      'assets/languages/id.toml',
      'assets/languages/it.toml',
      'assets/languages/ja.toml',
      'assets/languages/ka.toml',
      'assets/languages/ko.toml',
      'assets/languages/nl.toml',
      'assets/languages/no.toml',
      'assets/languages/pl.toml',
      'assets/languages/pt.toml',
      'assets/languages/pt-BR.toml',
      'assets/languages/ro.toml',
      'assets/languages/ru.toml',
      'assets/languages/sr.toml',
      'assets/languages/sv.toml',
      'assets/languages/th.toml',
      'assets/languages/tr.toml',
      'assets/languages/uk.toml',
      'assets/languages/vi.toml',
      'assets/languages/zh-Hans.toml',
      'assets/languages/zh-Hant.toml',
    ];
    final documents = <StoredLanguageDocument>[];
    for (final path in paths) {
      try {
        final content = await rootBundle.loadString(path);
        LanguageDefinition.parse(content, source: path);
        documents.add(
          StoredLanguageDocument(
            name: path.split('/').last,
            content: content,
          ),
        );
      } catch (_) {
        // A missing installation template must not prevent startup. The
        // source-keyed English interface remains usable without any catalog.
      }
    }
    return List.unmodifiable(documents);
  }

  List<LanguageDefinition> _fallbackChain(String locale) {
    final chain = <LanguageDefinition>[];
    final visited = <String>{};
    String? current = normalizeLocaleTag(locale);
    while (current != null && current.isNotEmpty) {
      if (!visited.add(current)) break;
      final language = _languages[current];
      if (language != null) {
        chain.add(language);
        current = language.baseLocale;
        if (current == null || current.isEmpty) {
          final parents = _implicitParentLocales(language.locale);
          current = parents.isEmpty ? null : parents.first;
        }
      } else {
        final parents = _implicitParentLocales(current);
        current = parents.isEmpty ? null : parents.first;
      }
    }
    final english = _languages['en'];
    if (english != null && !visited.contains('en')) chain.add(english);
    return chain;
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _storageSubscription?.cancel();
    super.dispose();
  }
}

List<String> _implicitParentLocales(String locale) {
  final normalized = normalizeLocaleTag(locale);
  if (normalized.isEmpty) return const [];
  final parts = normalized.split('-');
  if (parts.length <= 1) return const [];
  final parent = parts.sublist(0, parts.length - 1).join('-');
  return [parent];
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
