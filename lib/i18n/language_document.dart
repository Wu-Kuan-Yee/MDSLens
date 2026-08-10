import 'dart:ui';

import '../services/toml_codec.dart';

class StoredLanguageDocument {
  const StoredLanguageDocument({
    required this.name,
    required this.content,
  });

  final String name;
  final String content;
}

class LanguageDefinition {
  const LanguageDefinition({
    required this.locale,
    required this.name,
    required this.nativeName,
    required this.messages,
    required this.source,
    this.baseLocale,
    this.coverageLevel,
    this.script,
    this.defaultRegion,
  });

  final String locale;
  final String name;
  final String nativeName;
  final Map<String, String> messages;
  final String source;

  /// Explicit parent locale used for sparse catalogs and regional variants.
  ///
  /// A missing parent does not disable normal BCP 47 fallback: the language
  /// service will still walk from a regional/script tag to its language tag.
  final String? baseLocale;
  final String? coverageLevel;
  final String? script;
  final String? defaultRegion;

  String get displayName => nativeName == name ? name : '$nativeName — $name';

  LanguageDefinition copyWith({
    String? baseLocale,
    String? coverageLevel,
    String? script,
    String? defaultRegion,
  }) {
    return LanguageDefinition(
      locale: locale,
      name: name,
      nativeName: nativeName,
      messages: messages,
      source: source,
      baseLocale: baseLocale ?? this.baseLocale,
      coverageLevel: coverageLevel ?? this.coverageLevel,
      script: script ?? this.script,
      defaultRegion: defaultRegion ?? this.defaultRegion,
    );
  }

  static LanguageDefinition parse(
    String content, {
    required String source,
  }) {
    final decoded = decodeTomlDocument(content);
    final version = decoded['version'];
    if (version != 1) {
      throw FormatException(
        'Unsupported language file version: ${version ?? 'missing'}.',
      );
    }
    final locale = normalizeLocaleTag(decoded['locale']?.toString() ?? '');
    if (locale.isEmpty) {
      throw const FormatException('The language file locale is missing.');
    }
    final name = decoded['name']?.toString().trim() ?? '';
    final nativeName = decoded['nativeName']?.toString().trim() ?? '';
    if (name.isEmpty || nativeName.isEmpty) {
      throw const FormatException(
        'The language file name and nativeName are required.',
      );
    }
    final rawMessages = decoded['messages'];
    if (rawMessages != null && rawMessages is! Map) {
      throw const FormatException(
          'The language file messages table is invalid.');
    }
    final messages = <String, String>{};
    for (final entry in (rawMessages as Map? ?? const {}).entries) {
      final key = entry.key.toString().trim();
      if (key.isEmpty || entry.value is! String) continue;
      messages[key] = entry.value as String;
    }
    final baseLocale = _optionalLocale(decoded['baseLocale']);
    final coverageLevel = _optionalString(decoded['coverageLevel']);
    final script = _optionalString(decoded['script']);
    final defaultRegion = _optionalString(decoded['defaultRegion']);
    return LanguageDefinition(
      locale: locale,
      name: name,
      nativeName: nativeName,
      messages: Map.unmodifiable(messages),
      source: source,
      baseLocale: baseLocale,
      coverageLevel: coverageLevel,
      script: script,
      defaultRegion: defaultRegion,
    );
  }
}

class LocaleRegistryDocument {
  const LocaleRegistryDocument({
    required this.version,
    required this.source,
    required this.coverage,
    required this.localeDefinitions,
  });

  final int version;
  final String source;
  final String coverage;
  final List<LanguageDefinition> localeDefinitions;

  static LocaleRegistryDocument parse(
    String content, {
    required String source,
  }) {
    final decoded = decodeTomlDocument(content);
    final version = decoded['version'];
    if (version != 1) {
      throw FormatException(
        'Unsupported locale registry version: ${version ?? 'missing'}.',
      );
    }
    final kind = decoded['kind']?.toString().trim();
    if (kind != 'locale-registry') {
      throw const FormatException('The locale registry kind is invalid.');
    }
    final coverage = decoded['coverage']?.toString().trim() ?? '';
    if (coverage.isEmpty) {
      throw const FormatException('The locale registry coverage is missing.');
    }
    final rawLocales = decoded['locales'];
    if (rawLocales is! Map) {
      throw const FormatException(
          'The locale registry locales table is missing.');
    }
    final definitions = <LanguageDefinition>[];
    for (final entry in rawLocales.entries) {
      if (entry.value is! Map) continue;
      final metadata = entry.value as Map;
      final locale = normalizeLocaleTag(entry.key.toString());
      final name = metadata['name']?.toString().trim() ?? '';
      final nativeName = metadata['nativeName']?.toString().trim() ?? '';
      if (locale.isEmpty || name.isEmpty || nativeName.isEmpty) continue;
      definitions.add(
        LanguageDefinition(
          locale: locale,
          name: name,
          nativeName: nativeName,
          messages: const {},
          source: source,
          baseLocale: _optionalLocale(metadata['baseLocale']),
          coverageLevel: _optionalString(metadata['coverageLevel']) ?? coverage,
          script: _optionalString(metadata['script']),
          defaultRegion: _optionalString(metadata['defaultRegion']),
        ),
      );
    }
    return LocaleRegistryDocument(
      version: version as int,
      source: source,
      coverage: coverage,
      localeDefinitions: List.unmodifiable(definitions),
    );
  }
}

String? _optionalString(Object? value) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

String? _optionalLocale(Object? value) {
  final normalized = normalizeLocaleTag(value?.toString() ?? '');
  return normalized.isEmpty ? null : normalized;
}

String normalizeLocaleTag(String value) {
  final parts = value
      .trim()
      .replaceAll('_', '-')
      .split('-')
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty || !RegExp(r'^[A-Za-z]{2,8}$').hasMatch(parts.first)) {
    return '';
  }
  final normalized = <String>[parts.first.toLowerCase()];
  for (var index = 1; index < parts.length; index++) {
    final part = parts[index];
    if (part.length == 4 && RegExp(r'^[A-Za-z]+$').hasMatch(part)) {
      normalized.add(
        '${part[0].toUpperCase()}${part.substring(1).toLowerCase()}',
      );
    } else if ((part.length == 2 && RegExp(r'^[A-Za-z]+$').hasMatch(part)) ||
        (part.length == 3 && RegExp(r'^\d+$').hasMatch(part))) {
      normalized.add(part.toUpperCase());
    } else if (RegExp(r'^[A-Za-z0-9]{1,8}$').hasMatch(part)) {
      normalized.add(part.toLowerCase());
    } else {
      return '';
    }
  }
  return normalized.join('-');
}

Locale localeFromTag(String value) {
  final normalized = normalizeLocaleTag(value);
  final parts = normalized.split('-');
  if (parts.isEmpty || parts.first.isEmpty) return const Locale('en');
  String? scriptCode;
  String? countryCode;
  for (final part in parts.skip(1)) {
    if (part.length == 4) {
      scriptCode = part;
    } else if (part.length == 2 || RegExp(r'^\d{3}$').hasMatch(part)) {
      countryCode = part;
    }
  }
  return Locale.fromSubtags(
    languageCode: parts.first,
    scriptCode: scriptCode,
    countryCode: countryCode,
  );
}
