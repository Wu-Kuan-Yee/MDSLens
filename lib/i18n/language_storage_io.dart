import 'dart:async';
import 'dart:io';

import '../services/user_data_store.dart';
import 'language_document.dart';

const _initializationMarkerV1 = '.external-language-store-v1';
const _initializationMarkerV2 = '.external-language-store-v2';
const _v1StarterNames = {'en.toml', 'zh-hans.toml'};

Future<void> initializeStoredLanguageDocuments(
  UserDataStore userDataStore,
  List<StoredLanguageDocument> initialDocuments,
) async {
  final directory = await userDataStore.languageDirectory();
  if (directory == null) return;
  final markerV1 = File(
    '${directory.path}${Platform.pathSeparator}$_initializationMarkerV1',
  );
  final markerV2 = File(
    '${directory.path}${Platform.pathSeparator}$_initializationMarkerV2',
  );
  if (await markerV2.exists()) return;
  final migratedFromV1 = await markerV1.exists();

  final existingNames = <String>{};
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is File &&
        entity.path.toLowerCase().endsWith('.toml') &&
        !entity.path.split(Platform.pathSeparator).last.startsWith('.')) {
      existingNames.add(
        entity.path.split(Platform.pathSeparator).last.toLowerCase(),
      );
    }
  }
  for (final document in initialDocuments) {
    final safeName = _safeFileName(document.name);
    final normalizedName = safeName.toLowerCase();
    // V1 already handled English and Simplified Chinese. Skipping those two
    // during migration preserves a user's deliberate deletion; the 30 newly
    // introduced starter catalogs are still added once.
    if (migratedFromV1 && _v1StarterNames.contains(normalizedName)) continue;
    if (existingNames.contains(normalizedName)) continue;
    await installStoredLanguageDocument(
      userDataStore,
      safeName,
      document.content,
    );
  }

  await _writeMarker(markerV2, version: 2);
  if (!migratedFromV1) await _writeMarker(markerV1, version: 1);
}

Future<void> _writeMarker(File marker, {required int version}) async {
  final temporary = File('${marker.path}.tmp');
  await temporary.writeAsString('version = $version\n', flush: true);
  if (await marker.exists()) await marker.delete();
  await temporary.rename(marker.path);
}

Future<List<StoredLanguageDocument>> loadStoredLanguageDocuments(
  UserDataStore userDataStore,
) async {
  final directory = await userDataStore.languageDirectory();
  if (directory == null) return const [];
  final documents = <StoredLanguageDocument>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File ||
        !entity.path.toLowerCase().endsWith('.toml') ||
        entity.path.split(Platform.pathSeparator).last.startsWith('.')) {
      continue;
    }
    try {
      documents.add(
        StoredLanguageDocument(
          name: entity.uri.pathSegments.last,
          content: await entity.readAsString(),
        ),
      );
    } catch (_) {
      // A file can be observed between an editor's temporary rename steps.
      // The next filesystem event reloads the completed document.
    }
  }
  documents.sort((left, right) => left.name.compareTo(right.name));
  return documents;
}

Stream<void> watchStoredLanguageDocuments(
  UserDataStore userDataStore,
) async* {
  final directory = await userDataStore.languageDirectory();
  if (directory == null) return;
  try {
    await for (final _ in directory.watch()) {
      yield null;
    }
  } catch (_) {
    // Sandboxed or network filesystems can reject watches. Lifecycle refresh
    // remains available through LanguageService.refresh().
  }
}

Future<void> installStoredLanguageDocument(
  UserDataStore userDataStore,
  String fileName,
  String content,
) async {
  final directory = await userDataStore.languageDirectory();
  if (directory == null) return;
  final safeName = _safeFileName(fileName);
  final target = File('${directory.path}${Platform.pathSeparator}$safeName');
  final temporary = File('${target.path}.tmp');
  await temporary.writeAsString(content, flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);
}

Future<void> removeStoredLanguageDocument(
  UserDataStore userDataStore,
  String fileName,
) async {
  await removeStoredLanguageDocuments(userDataStore, [fileName]);
}

Future<void> removeStoredLanguageDocuments(
  UserDataStore userDataStore,
  Iterable<String> fileNames,
) async {
  final directory = await userDataStore.languageDirectory();
  if (directory == null) return;
  final names = fileNames.map(_safeFileName).toSet();
  for (final name in names) {
    final target = File(
      '${directory.path}${Platform.pathSeparator}$name',
    );
    if (await target.exists()) await target.delete();
  }
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
