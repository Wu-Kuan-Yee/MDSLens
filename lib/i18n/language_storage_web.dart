import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/user_data_store.dart';
import '../services/toml_codec.dart';
import 'language_document.dart';

const _storageKey = 'mdslens.runtimeLanguageFiles';
const _initializationKeyV1 = 'mdslens.runtimeLanguageFiles.initializedV1';
const _initializationKeyV2 = 'mdslens.runtimeLanguageFiles.initializedV2';
const _v1StarterNames = {'en.toml', 'zh-hans.toml'};
final _changes = StreamController<void>.broadcast();

Future<void> initializeStoredLanguageDocuments(
  UserDataStore _,
  List<StoredLanguageDocument> initialDocuments,
) async {
  final preferences = await SharedPreferences.getInstance();
  if (preferences.getBool(_initializationKeyV2) == true) return;
  final migratedFromV1 = preferences.getBool(_initializationKeyV1) == true;
  final current = <String, String>{
    for (final document in await loadStoredLanguageDocuments(UserDataStore()))
      _safeFileName(document.name): document.content,
  };
  final existingNames = current.keys.map((name) => name.toLowerCase()).toSet();
  var changed = false;
  for (final document in initialDocuments) {
    final safeName = _safeFileName(document.name);
    final normalizedName = safeName.toLowerCase();
    if (migratedFromV1 && _v1StarterNames.contains(normalizedName)) {
      continue;
    }
    if (existingNames.contains(normalizedName)) continue;
    current[safeName] = document.content;
    existingNames.add(normalizedName);
    changed = true;
  }
  if (changed) {
    await preferences.setString(
      _storageKey,
      encodeTomlDocument({'documents': current}),
    );
    _changes.add(null);
  }
  await preferences.setBool(_initializationKeyV2, true);
  if (!migratedFromV1) {
    await preferences.setBool(_initializationKeyV1, true);
  }
}

Future<List<StoredLanguageDocument>> loadStoredLanguageDocuments(
  UserDataStore _,
) async {
  final preferences = await SharedPreferences.getInstance();
  final raw = preferences.getString(_storageKey);
  if (raw == null || raw.isEmpty) return const [];
  try {
    final decoded = decodeTomlDocument(raw)['documents'];
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
  UserDataStore userDataStore,
  String fileName,
  String content,
) async {
  await installStoredLanguageDocuments(
    userDataStore,
    [StoredLanguageDocument(name: fileName, content: content)],
  );
}

Future<void> installStoredLanguageDocuments(
  UserDataStore _,
  Iterable<StoredLanguageDocument> documents,
) async {
  final preferences = await SharedPreferences.getInstance();
  final current = <String, String>{
    for (final document in await loadStoredLanguageDocuments(UserDataStore()))
      document.name: document.content,
  };
  for (final document in documents) {
    current[_safeFileName(document.name)] = document.content;
  }
  await preferences.setString(
    _storageKey,
    encodeTomlDocument({'documents': current}),
  );
  _changes.add(null);
}

Future<void> removeStoredLanguageDocument(
  UserDataStore userDataStore,
  String fileName,
) async {
  await removeStoredLanguageDocuments(userDataStore, [fileName]);
}

Future<void> removeStoredLanguageDocuments(
  UserDataStore _,
  Iterable<String> fileNames,
) async {
  final preferences = await SharedPreferences.getInstance();
  final current = <String, String>{
    for (final document in await loadStoredLanguageDocuments(UserDataStore()))
      document.name: document.content,
  };
  var changed = false;
  for (final fileName in fileNames) {
    changed = current.remove(_safeFileName(fileName)) != null || changed;
  }
  if (!changed) return;
  await preferences.setString(
    _storageKey,
    encodeTomlDocument({'documents': current}),
  );
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
  return name.toLowerCase().endsWith('.toml') ? name : '$name.toml';
}
