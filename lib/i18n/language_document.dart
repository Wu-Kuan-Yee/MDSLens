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
  });

  final String locale;
  final String name;
  final String nativeName;
  final Map<String, String> messages;
  final String source;

  String get displayName => nativeName == name ? name : '$nativeName — $name';

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
    if (rawMessages is! Map) {
      throw const FormatException(
          'The language file messages table is missing.');
    }
    final messages = <String, String>{};
    for (final entry in rawMessages.entries) {
      final key = entry.key.toString().trim();
      if (key.isEmpty || entry.value is! String) continue;
      messages[key] = entry.value as String;
    }
    return LanguageDefinition(
      locale: locale,
      name: name,
      nativeName: nativeName,
      messages: Map.unmodifiable(messages),
      source: source,
    );
  }
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
