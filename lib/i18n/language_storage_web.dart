import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/user_data_store.dart';
import 'language_document.dart';

const _storageKey = 'mdslens.runtimeLanguageFiles';
final _changes = StreamController<void>.broadcast();

Future<List<StoredLanguageDocument>> loadStoredLanguageDocuments(
  UserDataStore _,
) async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_storageKey);
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const [];
    final documents = <StoredLanguageDocument>[];
    for (final entry in decoded.entries) {
      if (entry.value is! String) continue;
      documents.add(
        StoredLanguageDocument(
          name: entry.key.toString(),
          content: entry.value as String,
        ),
      );
    }
    documents.sort((left, right) => left.name.compareTo(right.name));
    return documents;
  } catch (_) {
    return const [];
  }
}

Stream<void> watchStoredLanguageDocuments(UserDataStore _) => _changes.stream;

Future<void> installStoredLanguageDocument(
  UserDataStore _,
  String fileName,
  String content,
) async {
  final preferences = await SharedPreferences.getInstance();
  final current = <String, String>{
    for (final document in await loadStoredLanguageDocuments(UserDataStore()))
      document.name: document.content,
  };
  current[_safeFileName(fileName)] = content;
  await preferences.setString(_storageKey, jsonEncode(current));
  _changes.add(null);
}

Future<void> removeStoredLanguageDocument(
  UserDataStore _,
  String fileName,
) async {
  final preferences = await SharedPreferences.getInstance();
  final current = <String, String>{
    for (final document in await loadStoredLanguageDocuments(UserDataStore()))
      document.name: document.content,
  };
  if (current.remove(_safeFileName(fileName)) == null) return;
  await preferences.setString(_storageKey, jsonEncode(current));
  _changes.add(null);
}

String _safeFileName(String value) {
  final name = value
      .split(RegExp(r'[/\\]'))
      .last
      .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  if (name.isEmpty || name.startsWith('.')) {
    throw const FormatException('Invalid language file name.');
  }
  return name.toLowerCase().endsWith('.json') ? name : '$name.json';
}
