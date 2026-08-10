import 'dart:async';
import 'dart:io';

import '../services/user_data_store.dart';
import 'language_document.dart';

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
  final directory = await userDataStore.languageDirectory();
  if (directory == null) return;
  final target = File(
    '${directory.path}${Platform.pathSeparator}${_safeFileName(fileName)}',
  );
  if (await target.exists()) await target.delete();
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
