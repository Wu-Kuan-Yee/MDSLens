import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mdslens/services/toml_codec.dart';

const _catalogs = <_CatalogSpec>[
  _CatalogSpec('be', 'Belarusian', 'Беларуская'),
  _CatalogSpec('ca', 'Catalan', 'Català'),
  _CatalogSpec('cs', 'Czech', 'Čeština'),
  _CatalogSpec('da', 'Danish', 'Dansk'),
  _CatalogSpec('de', 'German', 'Deutsch'),
  _CatalogSpec('el', 'Greek', 'Ελληνικά'),
  _CatalogSpec('en', 'English', 'English'),
  _CatalogSpec('eo', 'Esperanto', 'Esperanto'),
  _CatalogSpec('es', 'Spanish', 'Español'),
  _CatalogSpec('fi', 'Finnish', 'Suomi'),
  _CatalogSpec('fr', 'French', 'Français'),
  _CatalogSpec('hu', 'Hungarian', 'Magyar'),
  _CatalogSpec('id', 'Indonesian', 'Bahasa Indonesia'),
  _CatalogSpec('it', 'Italian', 'Italiano'),
  _CatalogSpec('ja', 'Japanese', '日本語'),
  _CatalogSpec('ka', 'Georgian', 'ქართული'),
  _CatalogSpec('ko', 'Korean', '한국어'),
  _CatalogSpec('nl', 'Dutch', 'Nederlands'),
  _CatalogSpec('no', 'Norwegian', 'Norsk'),
  _CatalogSpec('pl', 'Polish', 'Polski'),
  _CatalogSpec('pt', 'Portuguese', 'Português'),
  _CatalogSpec('pt-BR', 'Portuguese (Brazil)', 'Português (Brasil)'),
  _CatalogSpec('ro', 'Romanian', 'Română'),
  _CatalogSpec('ru', 'Russian', 'Русский'),
  _CatalogSpec('sr', 'Serbian', 'Српски'),
  _CatalogSpec('sv', 'Swedish', 'Svenska'),
  _CatalogSpec('th', 'Thai', 'ไทย'),
  _CatalogSpec('tr', 'Turkish', 'Türkçe'),
  _CatalogSpec('uk', 'Ukrainian', 'Українська'),
  _CatalogSpec('vi', 'Vietnamese', 'Tiếng Việt'),
  _CatalogSpec('zh-Hans', 'Chinese (Simplified)', '简体中文'),
  _CatalogSpec('zh-Hant', 'Chinese (Traditional)', '繁體中文'),
];

// Small, reviewed corrections for source phrases that cause a known local
// model to repeat tokens instead of completing valid JSON.
const _reviewedTranslations = <String, Map<String, String>>{
  'da': {
    'Zoom and move mode': 'Zoom- og flyttetilstand',
  },
  'de': {
    'Layout drag cancelled': 'Layout-Verschiebung abgebrochen',
  },
  'hu': {
    'The downloaded disk image is open.':
        'A letöltött lemezkép meg van nyitva.',
  },
  'ka': {
    'Android rejected this package because its version is not newer than the installed copy.':
        'Android-მა უარყო ეს პაკეტი, რადგან მისი ვერსია დაინსტალირებულ ვერსიაზე ახალი არ არის.',
    'Android returned an unknown update status: {value1}':
        'Android-მა დააბრუნა განახლების უცნობი სტატუსი: {value1}',
    'Choose keyboard mode': 'აირჩიეთ კლავიატურის რეჟიმი',
    'Mode': 'რეჟიმი',
  },
  'ko': {
    'Remove {value1} selected bookmark{value2} ({value3})? This action cannot be undone.':
        '{value1}개의 선택한 북마크{value2}({value3})를 삭제하시겠습니까? 이 작업은 취소할 수 없습니다.',
  },
  'sv': {
    'Layout drag cancelled': 'Layoutdragningen avbröts',
    'Loaded: {value1} ({value2} cols, {value3} panels)':
        'Inläst: {value1} ({value2} kolumner, {value3} paneler)',
  },
  'tr': {
    '{value1} of {value2}': '{value2} öğeden {value1}',
  },
  'th': {
    'Legend': 'คำอธิบายเส้นกราฟ',
    'The mode is saved and restored when MDSLens starts again. Use J/K or the arrow keys to select a mode or configure its direct toggle shortcut, then move to Apply and press Enter. A hardware keyboard is required on mobile devices.':
        'โหมดนี้จะถูกบันทึกและเรียกคืนเมื่อ MDSLens เริ่มทำงานอีกครั้ง ใช้ J/K หรือปุ่มลูกศรเพื่อเลือกโหมด หรือกำหนดปุ่มลัดสำหรับสลับโหมดโดยตรง จากนั้นเลื่อนไปที่ Apply แล้วกด Enter อุปกรณ์เคลื่อนที่ต้องใช้แป้นพิมพ์ฮาร์ดแวร์',
  },
};

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  final sourceFile = File('assets/languages/en.toml');
  if (!sourceFile.existsSync()) {
    stderr.writeln('Run this tool from the MDSLens repository root.');
    exitCode = 2;
    return;
  }
  final sourceDocument = decodeTomlDocument(await sourceFile.readAsString());
  final rawMessages = sourceDocument['messages'];
  if (rawMessages is! Map) {
    throw const FormatException('The English messages table is missing.');
  }
  final sourceMessages = <String, String>{
    for (final entry in rawMessages.entries)
      entry.key.toString(): entry.value.toString(),
  };
  final selected = _catalogs
      .where((catalog) =>
          options.locales.isEmpty || options.locales.contains(catalog.locale))
      .toList(growable: false);
  if (selected.isEmpty) {
    throw ArgumentError('No requested locale is in the starter catalog set.');
  }

  if (options.checkOnly) {
    var failed = false;
    for (final catalog in selected) {
      final issue = await _validateCatalog(catalog, sourceMessages);
      if (issue == null) {
        stdout.writeln('${catalog.locale}: OK (${sourceMessages.length} keys)');
      } else {
        failed = true;
        stderr.writeln('${catalog.locale}: $issue');
      }
    }
    if (failed) exitCode = 1;
    return;
  }

  final pending = selected
      .where((catalog) => catalog.locale != 'en')
      .toList(growable: false);
  var next = 0;
  Future<void> worker() async {
    while (next < pending.length) {
      final catalog = pending[next++];
      final existingIssue = await _validateCatalog(catalog, sourceMessages);
      if (!options.force && existingIssue == null) {
        stdout.writeln('${catalog.locale}: existing catalog is complete');
        continue;
      }
      await _generateCatalog(catalog, sourceMessages, options);
    }
  }

  await Future.wait(List.generate(options.jobs, (_) => worker()));
}

Future<void> _generateCatalog(
  _CatalogSpec catalog,
  Map<String, String> sourceMessages,
  _Options options,
) async {
  final keys = sourceMessages.keys.toList(growable: false);
  final cacheDirectory = Directory(options.cacheDirectory);
  await cacheDirectory.create(recursive: true);
  final cacheFile = File('${cacheDirectory.path}/${catalog.locale}.json');
  final translated = <String, String>{};
  if (await cacheFile.exists()) {
    try {
      final cached = jsonDecode(await cacheFile.readAsString());
      if (cached is Map) {
        for (final entry in cached.entries) {
          if (entry.value is String && sourceMessages.containsKey(entry.key)) {
            translated[entry.key.toString()] = entry.value as String;
          }
        }
      }
    } catch (_) {}
  }
  if (options.seedExistingCatalog) {
    final existingFile = File('assets/languages/${catalog.locale}.toml');
    if (await existingFile.exists()) {
      try {
        final existingDocument =
            decodeTomlDocument(await existingFile.readAsString());
        final existingMessages = existingDocument['messages'];
        if (existingMessages is Map) {
          for (final entry in existingMessages.entries) {
            final key = entry.key.toString();
            if (entry.value is String && sourceMessages.containsKey(key)) {
              translated.putIfAbsent(key, () => entry.value as String);
            }
          }
        }
      } catch (_) {}
    }
  }
  translated.addAll(_reviewedTranslations[catalog.locale] ?? const {});
  if (options.refreshIdentical) {
    translated.removeWhere((key, target) {
      final source = sourceMessages[key];
      return source != null && _shouldRetranslateIdentical(source, target);
    });
  }
  if (options.repairScripts) {
    translated.removeWhere(
      (_, target) => _containsUnexpectedScript(catalog.locale, target),
    );
  }

  for (var start = 0; start < keys.length; start += options.batchSize) {
    final batchKeys = keys
        .skip(start)
        .take(options.batchSize)
        .where((key) => !translated.containsKey(key))
        .toList(growable: false);
    if (batchKeys.isEmpty) continue;
    final values = batchKeys.map((key) => sourceMessages[key]!).toList();
    final batch = await _translateBatch(catalog, values, options);
    for (var index = 0; index < batchKeys.length; index++) {
      final source = values[index];
      final target = batch[index].trim();
      final sourcePlaceholders = _placeholders(source);
      final targetPlaceholders = _placeholders(target);
      if (target.isEmpty ||
          !_sameStrings(sourcePlaceholders, targetPlaceholders)) {
        throw FormatException(
          '${catalog.locale}: invalid translation for "$source"; '
          'expected placeholders $sourcePlaceholders, got $targetPlaceholders.',
        );
      }
      translated[batchKeys[index]] = target;
    }
    await cacheFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(translated),
      flush: true,
    );
    stdout.writeln(
      '${catalog.locale}: ${translated.length}/${sourceMessages.length}',
    );
  }

  final output = encodeTomlDocument({
    'version': 1,
    'locale': catalog.locale,
    'name': catalog.name,
    'nativeName': catalog.nativeName,
    'baseLocale': catalog.locale == 'en' ? null : 'en',
    'messages': {
      for (final key in keys) key: translated[key]!,
    },
  });
  final outputFile = File('assets/languages/${catalog.locale}.toml');
  await outputFile.writeAsString(output, flush: true);
  final issue = await _validateCatalog(catalog, sourceMessages);
  if (issue != null) throw FormatException('${catalog.locale}: $issue');
  stdout.writeln('${catalog.locale}: wrote ${outputFile.path}');
}

Future<List<String>> _translateBatch(
  _CatalogSpec catalog,
  List<String> values,
  _Options options,
) async {
  Object? lastError;
  final attempts = values.length <= 4 ? 4 : 2;
  for (var attempt = 1; attempt <= attempts; attempt++) {
    try {
      final requestBody = jsonEncode({
        'model': options.model,
        'stream': false,
        'think': false,
        'format': 'json',
        'keep_alive': '30m',
        'options': {
          'temperature': 0,
          'num_ctx': 16384,
          'num_predict': 4096,
          'repeat_last_n': 128,
          'repeat_penalty': 1.1,
        },
        'prompt': _translationPrompt(catalog, values),
      });
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final request = await client.postUrl(Uri.parse(options.endpoint));
        request.headers.contentType = ContentType.json;
        request.write(requestBody);
        final response =
            await request.close().timeout(const Duration(minutes: 5));
        final body = await utf8.decoder.bind(response).join();
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('HTTP ${response.statusCode}: $body');
        }
        final envelope = jsonDecode(body);
        if (envelope is! Map || envelope['response'] is! String) {
          throw const FormatException(
              'The model response envelope is invalid.');
        }
        final payload = jsonDecode(envelope['response'] as String);
        final rawTranslations = payload is Map ? payload['translations'] : null;
        if (rawTranslations is! Map) {
          throw const FormatException(
            'Expected a translation object, received invalid JSON.',
          );
        }
        final translations = List<String?>.filled(values.length, null);
        final missing = <int>[];
        for (var index = 0; index < values.length; index++) {
          final value = rawTranslations['$index'];
          final sourcePlaceholders = _placeholders(values[index]);
          final targetPlaceholders =
              value is String ? _placeholders(value) : const <String>[];
          if (value is String &&
              value.trim().isNotEmpty &&
              _sameStrings(sourcePlaceholders, targetPlaceholders)) {
            translations[index] = value;
          } else {
            missing.add(index);
          }
        }
        if (missing.length == values.length) {
          throw FormatException(
            'The model returned no valid items for this batch.',
          );
        }
        if (missing.isNotEmpty) {
          stderr.writeln(
            '${catalog.locale}: recovering ${missing.length} incomplete '
            'item(s) from a batch of ${values.length}',
          );
          final recovered = await _translateBatch(
            catalog,
            missing.map((index) => values[index]).toList(growable: false),
            options,
          );
          for (var index = 0; index < missing.length; index++) {
            translations[missing[index]] = recovered[index];
          }
        }
        return translations.cast<String>();
      } finally {
        client.close(force: true);
      }
    } catch (error) {
      lastError = error;
      stderr.writeln(
        '${catalog.locale}: batch attempt $attempt failed: $error',
      );
      if (attempt < attempts) {
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  }
  if (values.length > 1) {
    final middle = values.length ~/ 2;
    stderr.writeln(
      '${catalog.locale}: splitting incomplete batch of ${values.length}',
    );
    final left = await _translateBatch(
      catalog,
      values.sublist(0, middle),
      options,
    );
    final right = await _translateBatch(
      catalog,
      values.sublist(middle),
      options,
    );
    return [...left, ...right];
  }
  throw StateError(
    '${catalog.locale}: translation failed for ${jsonEncode(values.single)}: '
    '$lastError',
  );
}

String _translationPrompt(_CatalogSpec catalog, List<String> values) => '''
You are a professional software localization translator for a scientific
MDSplus waveform viewer named MDSLens. Translate every English UI string in the
JSON array below into ${catalog.name} (${catalog.locale}). Return only one JSON
object whose "translations" value maps every input id to its translated text,
for example {"translations":{"0":"...","1":"..."}}. Return all
${values.length} ids exactly once, even when two source texts are identical.

Rules:
- Write concise, natural native user-interface language, not explanations.
- Preserve every placeholder such as {value1}, {count}, and {path} exactly.
- Never translate MDSLens, MDSplus, WebScope, GitHub, SSH, URL, API, JSON,
  TOML, CSV, TSV, AppImage, Flatpak, Snap, Windows, macOS, Linux, Android, iOS,
  iPadOS, keyboard shortcuts, file extensions, paths, signal names, or code.
- Protected names inside a sentence must stay unchanged, but translate all
  ordinary English words around them. Do not return an ordinary English phrase
  or sentence unchanged.
- In this application, "shot" means an experimental plasma discharge number,
  "panel" means a waveform plot panel, "tree" means an MDSplus data tree, and
  "signal" means a scientific data signal.
- Keep symbols and unit abbreviations unchanged when translation is not useful.
- Do not omit, combine, reorder, annotate, or invent any item id.

Input JSON:
${jsonEncode([
          for (var index = 0; index < values.length; index++)
            {'id': '$index', 'text': values[index]},
        ])}
''';

Future<String?> _validateCatalog(
  _CatalogSpec catalog,
  Map<String, String> sourceMessages,
) async {
  final file = File('assets/languages/${catalog.locale}.toml');
  if (!await file.exists()) return 'file is missing';
  try {
    final document = decodeTomlDocument(await file.readAsString());
    if (document['version'] != 1) return 'version must be 1';
    if (document['locale'] != catalog.locale) {
      return 'locale is ${document['locale']}, expected ${catalog.locale}';
    }
    if (document['name'] != catalog.name ||
        document['nativeName'] != catalog.nativeName) {
      return 'language names do not match the starter catalog specification';
    }
    final rawMessages = document['messages'];
    if (rawMessages is! Map) return 'messages table is missing';
    final messages = <String, String>{
      for (final entry in rawMessages.entries)
        entry.key.toString(): entry.value.toString(),
    };
    final missing =
        sourceMessages.keys.toSet().difference(messages.keys.toSet());
    final extra = messages.keys.toSet().difference(sourceMessages.keys.toSet());
    if (missing.isNotEmpty || extra.isNotEmpty) {
      return '${missing.length} missing and ${extra.length} extra message keys';
    }
    for (final entry in sourceMessages.entries) {
      final target = messages[entry.key]!.trim();
      if (target.isEmpty) return 'empty translation for "${entry.key}"';
      if (!_sameStrings(_placeholders(entry.value), _placeholders(target))) {
        return 'placeholder mismatch for "${entry.key}"';
      }
    }
    return null;
  } catch (error) {
    return 'cannot parse catalog: $error';
  }
}

List<String> _placeholders(String value) {
  final result = RegExp(r'\{[A-Za-z0-9_]+\}')
      .allMatches(value)
      .map((match) => match.group(0)!)
      .toList();
  result.sort();
  return result;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _shouldRetranslateIdentical(String source, String target) {
  if (source != target || source.length < 14 || !source.contains(' ')) {
    return false;
  }
  const intentionallyStable = <String>{
    'Flutter & Rust FFI (libmds_bridge)',
    'Copyright (C) 2026',
  };
  if (intentionallyStable.contains(source)) return false;
  if (source.startsWith('~/') ||
      source.startsWith('dim_of(') ||
      source.startsWith('TextInput.')) {
    return false;
  }
  return true;
}

bool _containsUnexpectedScript(String locale, String value) {
  final language = locale.split('-').first;
  final allowed = switch (language) {
    'be' || 'ru' || 'sr' || 'uk' => _ScriptGroup.cyrillic,
    'el' => _ScriptGroup.greek,
    'ka' => _ScriptGroup.georgian,
    'th' => _ScriptGroup.thai,
    'ja' => _ScriptGroup.japanese,
    'ko' => _ScriptGroup.korean,
    'zh' => _ScriptGroup.chinese,
    _ => _ScriptGroup.latin,
  };
  for (final rune in value.runes) {
    final script = _scriptGroup(rune);
    if (script != null && script != allowed && script != _ScriptGroup.latin) {
      return true;
    }
  }
  return false;
}

_ScriptGroup? _scriptGroup(int rune) {
  if ((rune >= 0x0041 && rune <= 0x024f) ||
      (rune >= 0x1e00 && rune <= 0x1eff)) {
    return _ScriptGroup.latin;
  }
  if (rune >= 0x0370 && rune <= 0x03ff) return _ScriptGroup.greek;
  if (rune >= 0x0400 && rune <= 0x052f) return _ScriptGroup.cyrillic;
  if (rune >= 0x10a0 && rune <= 0x10ff) return _ScriptGroup.georgian;
  if (rune >= 0x0e00 && rune <= 0x0e7f) return _ScriptGroup.thai;
  if ((rune >= 0x3040 && rune <= 0x30ff)) return _ScriptGroup.japanese;
  if (rune >= 0xac00 && rune <= 0xd7af) return _ScriptGroup.korean;
  if ((rune >= 0x3400 && rune <= 0x9fff)) return _ScriptGroup.chinese;
  if ((rune >= 0x0530 && rune <= 0x058f) ||
      (rune >= 0x0590 && rune <= 0x05ff) ||
      (rune >= 0x0600 && rune <= 0x06ff) ||
      (rune >= 0x0900 && rune <= 0x0dff)) {
    return _ScriptGroup.other;
  }
  return null;
}

enum _ScriptGroup {
  latin,
  greek,
  cyrillic,
  georgian,
  thai,
  japanese,
  korean,
  chinese,
  other,
}

class _CatalogSpec {
  const _CatalogSpec(this.locale, this.name, this.nativeName);

  final String locale;
  final String name;
  final String nativeName;
}

class _Options {
  const _Options({
    required this.checkOnly,
    required this.force,
    required this.refreshIdentical,
    required this.seedExistingCatalog,
    required this.repairScripts,
    required this.locales,
    required this.endpoint,
    required this.model,
    required this.jobs,
    required this.batchSize,
    required this.cacheDirectory,
  });

  final bool checkOnly;
  final bool force;
  final bool refreshIdentical;
  final bool seedExistingCatalog;
  final bool repairScripts;
  final Set<String> locales;
  final String endpoint;
  final String model;
  final int jobs;
  final int batchSize;
  final String cacheDirectory;

  static _Options parse(List<String> arguments) {
    String value(String name, String fallback) {
      final prefix = '--$name=';
      for (final argument in arguments) {
        if (argument.startsWith(prefix)) {
          return argument.substring(prefix.length);
        }
      }
      return fallback;
    }

    final locales = value('locales', '')
        .split(',')
        .map((locale) => locale.trim())
        .where((locale) => locale.isNotEmpty)
        .toSet();
    return _Options(
      checkOnly: arguments.contains('--check'),
      force: arguments.contains('--force'),
      refreshIdentical: arguments.contains('--refresh-identical'),
      seedExistingCatalog: arguments.contains('--seed-existing'),
      repairScripts: arguments.contains('--repair-scripts'),
      locales: locales,
      endpoint: value(
        'endpoint',
        'http://127.0.0.1:11435/api/generate',
      ),
      model: value('model', 'qwen2.5-coder:7b'),
      jobs: int.parse(value('jobs', '2')).clamp(1, 8),
      batchSize: int.parse(value('batch-size', '48')).clamp(1, 96),
      cacheDirectory: value(
        'cache-dir',
        '.dart_tool/language_translation_cache',
      ),
    );
  }
}
