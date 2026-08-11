import '../services/user_data_store.dart';
import 'language_document.dart';
import 'language_storage_stub.dart'
    if (dart.library.io) 'language_storage_io.dart'
    if (dart.library.js_interop) 'language_storage_web.dart' as backend;

Future<List<StoredLanguageDocument>> loadStoredLanguageDocuments(
  UserDataStore userDataStore,
) =>
    backend.loadStoredLanguageDocuments(userDataStore);

Future<void> initializeStoredLanguageDocuments(
  UserDataStore userDataStore,
  List<StoredLanguageDocument> initialDocuments,
) =>
    backend.initializeStoredLanguageDocuments(
      userDataStore,
      initialDocuments,
    );

Stream<void> watchStoredLanguageDocuments(UserDataStore userDataStore) =>
    backend.watchStoredLanguageDocuments(userDataStore);

Future<void> installStoredLanguageDocument(
  UserDataStore userDataStore,
  String fileName,
  String content,
) =>
    backend.installStoredLanguageDocument(userDataStore, fileName, content);

Future<void> removeStoredLanguageDocument(
  UserDataStore userDataStore,
  String fileName,
) =>
    backend.removeStoredLanguageDocument(userDataStore, fileName);

Future<void> removeStoredLanguageDocuments(
  UserDataStore userDataStore,
  Iterable<String> fileNames,
) =>
    backend.removeStoredLanguageDocuments(userDataStore, fileNames);
