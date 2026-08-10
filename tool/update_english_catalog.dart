import 'dart:collection';
import 'dart:io';

import 'package:mdslens/services/toml_codec.dart';

/// Updates the source-keyed English runtime language catalog.
///
/// MDSLens deliberately uses the visible English source text as the stable
/// message key. This keeps runtime-added TOML language files possible on every
/// platform and avoids a generated Dart localization class for each locale.
void main(List<String> arguments) {
  final checkOnly = arguments.contains('--check');
  final catalogFile = File('assets/languages/en.toml');
  if (!catalogFile.existsSync()) {
    stderr.writeln('Run this tool from the MDSLens repository root.');
    exitCode = 2;
    return;
  }
  final messages = SplayTreeMap<String, String>();

  final files = Directory('lib')
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .where((file) => !file.path
          .contains('${Platform.pathSeparator}i18n${Platform.pathSeparator}'))
      .toList(growable: false)
    ..sort((left, right) => left.path.compareTo(right.path));
  for (final file in files) {
    final source = file.readAsStringSync();
    for (final literal in _scanLiterals(source)) {
      if (_isUserVisible(file.path, source, literal)) {
        messages.putIfAbsent(literal.value, () => literal.value);
      }
    }
  }

  final output = encodeTomlDocument({
    'version': 1,
    'locale': 'en',
    'name': 'English',
    'nativeName': 'English',
    'messages': messages,
  });
  if (checkOnly) {
    if (catalogFile.readAsStringSync() != output) {
      stderr.writeln(
        'assets/languages/en.toml is stale. '
        'Run: dart run tool/update_english_catalog.dart',
      );
      exitCode = 1;
    }
    return;
  }
  catalogFile.writeAsStringSync(output, flush: true);
  stdout.writeln('Updated ${catalogFile.path} (${messages.length} messages).');
}

class _Literal {
  const _Literal(this.value, this.start, this.end);

  final String value;
  final int start;
  final int end;
}

class _ParsedLiteral {
  const _ParsedLiteral(this.value, this.end, this.placeholderCount);

  final String value;
  final int end;
  final int placeholderCount;
}

List<_Literal> _scanLiterals(String source) {
  final result = <_Literal>[];
  var index = 0;
  while (index < source.length) {
    final skipped = _skipComment(source, index);
    if (skipped != index) {
      index = skipped;
      continue;
    }
    if (!_startsLiteral(source, index)) {
      index++;
      continue;
    }
    final start = index;
    var placeholders = 0;
    final value = StringBuffer();
    var parsed = _parseLiteral(source, index, placeholders);
    value.write(parsed.value);
    placeholders = parsed.placeholderCount;
    index = parsed.end;
    while (true) {
      final next = _skipTrivia(source, index);
      if (!_startsLiteral(source, next)) break;
      parsed = _parseLiteral(source, next, placeholders);
      value.write(parsed.value);
      placeholders = parsed.placeholderCount;
      index = parsed.end;
    }
    result.add(_Literal(value.toString(), start, index));
  }
  return result;
}

bool _startsLiteral(String source, int index) {
  if (index >= source.length) return false;
  final char = source[index];
  if (char == "'" || char == '"') return true;
  if ((char == 'r' || char == 'R') && index + 1 < source.length) {
    final next = source[index + 1];
    final previous = index == 0 ? '' : source[index - 1];
    return (next == "'" || next == '"') &&
        !RegExp(r'[A-Za-z0-9_]').hasMatch(previous);
  }
  return false;
}

_ParsedLiteral _parseLiteral(
  String source,
  int start,
  int initialPlaceholderCount,
) {
  var index = start;
  final raw = source[index] == 'r' || source[index] == 'R';
  if (raw) index++;
  final quote = source[index];
  final triple = index + 2 < source.length &&
      source[index + 1] == quote &&
      source[index + 2] == quote;
  index += triple ? 3 : 1;
  final value = StringBuffer();
  var placeholders = initialPlaceholderCount;
  while (index < source.length) {
    if (triple) {
      if (index + 2 < source.length &&
          source[index] == quote &&
          source[index + 1] == quote &&
          source[index + 2] == quote) {
        return _ParsedLiteral(value.toString(), index + 3, placeholders);
      }
    } else if (source[index] == quote) {
      return _ParsedLiteral(value.toString(), index + 1, placeholders);
    }
    final char = source[index];
    if (!raw && char == r'\' && index + 1 < source.length) {
      final escaped = source[index + 1];
      value.write(switch (escaped) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        _ => escaped,
      });
      index += 2;
      continue;
    }
    if (!raw && char == r'$' && index + 1 < source.length) {
      final next = source[index + 1];
      if (next == '{') {
        var depth = 1;
        index += 2;
        while (index < source.length && depth > 0) {
          if (source[index] == '{') depth++;
          if (source[index] == '}') depth--;
          index++;
        }
        value.write('{value${++placeholders}}');
        continue;
      }
      if (RegExp(r'[A-Za-z_]').hasMatch(next)) {
        index += 2;
        while (index < source.length &&
            RegExp(r'[A-Za-z0-9_]').hasMatch(source[index])) {
          index++;
        }
        value.write('{value${++placeholders}}');
        continue;
      }
    }
    value.write(char);
    index++;
  }
  return _ParsedLiteral(value.toString(), index, placeholders);
}

int _skipTrivia(String source, int start) {
  var index = start;
  while (index < source.length) {
    if (RegExp(r'\s').hasMatch(source[index])) {
      index++;
      continue;
    }
    final skipped = _skipComment(source, index);
    if (skipped == index) break;
    index = skipped;
  }
  return index;
}

int _skipComment(String source, int start) {
  if (start + 1 >= source.length || source[start] != '/') return start;
  if (source[start + 1] == '/') {
    final end = source.indexOf('\n', start + 2);
    return end < 0 ? source.length : end + 1;
  }
  if (source[start + 1] == '*') {
    final end = source.indexOf('*/', start + 2);
    return end < 0 ? source.length : end + 2;
  }
  return start;
}

bool _isUserVisible(String path, String source, _Literal literal) {
  final value = literal.value.trim();
  if (!_looksHuman(value)) return false;
  final lineStart = source.lastIndexOf('\n', literal.start - 1) + 1;
  final linePrefix = source.substring(lineStart, literal.start).trimLeft();
  if (linePrefix.startsWith('import ') ||
      linePrefix.startsWith('export ') ||
      linePrefix.startsWith('part ')) {
    return false;
  }
  final contextStart = (literal.start - 220).clamp(0, source.length);
  final context = source.substring(contextStart, literal.start);
  if (RegExp(
    r'(?:ValueKey|ObjectKey|MethodChannel|EventChannel|RegExp|AssetImage|debugLabel)\s*\(?\s*$',
  ).hasMatch(context)) {
    return false;
  }
  if (RegExp(r'(?:id|key|path|source)\s*:\s*$').hasMatch(context)) {
    return false;
  }
  final explicit = RegExp(
    r'(?:Text(?:\.rich)?\s*\(|(?:\w+\.)?tr\s*\(|tooltip\s*:|message\s*:|dialogTitle\s*:|semanticsLabel\s*:|labelText\s*:|hintText\s*:|helperText\s*:|errorText\s*:|setStatus\s*\(|_status\s*=|MdsShortcutDefinition\s*\()',
    multiLine: true,
  ).hasMatch(context);
  if (explicit) return true;
  final uiPath = path.contains(
          '${Platform.pathSeparator}widgets${Platform.pathSeparator}') ||
      path.contains(
          '${Platform.pathSeparator}pages${Platform.pathSeparator}') ||
      path.endsWith('${Platform.pathSeparator}app.dart');
  return uiPath &&
      (RegExp(r'[\s.!?():—]').hasMatch(value) ||
          RegExp(r'^[A-Z]').hasMatch(value));
}

bool _looksHuman(String value) {
  if (value.isEmpty || !RegExp(r'[A-Za-z]').hasMatch(value)) return false;
  final withoutPlaceholders =
      value.replaceAll(RegExp(r'\{value\d+\}'), '').trim();
  if (!RegExp(r'[A-Za-z]').hasMatch(withoutPlaceholders)) return false;
  if (value.startsWith('http://') || value.startsWith('https://')) return false;
  if (value.startsWith('assets/') || value.startsWith('package:')) return false;
  if (value.startsWith('-') || value.startsWith('.')) return false;
  if (RegExp(r'^#[0-9A-Fa-f]{3,8}$').hasMatch(value)) return false;
  if (RegExp(r'^[a-z][a-z0-9_.:/@-]*$').hasMatch(withoutPlaceholders)) {
    const allowed = {
      'auto',
      'dark',
      'light',
      'none',
      'visible',
    };
    if (allowed.contains(withoutPlaceholders)) return true;
    return value.contains('{value') &&
        !RegExp(r'[._:/@-]').hasMatch(withoutPlaceholders);
  }
  if (value.contains(r'\d') || value.contains('(?<') || value.startsWith('^')) {
    return false;
  }
  return true;
}
