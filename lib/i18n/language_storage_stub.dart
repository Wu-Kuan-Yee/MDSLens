import '../services/user_data_store.dart';
import 'language_document.dart';

Future<void> initializeStoredLanguageDocuments(
  UserDataStore _,
  List<StoredLanguageDocument> __,
) async {}

Future<List<StoredLanguageDocument>> loadStoredLanguageDocuments(
  UserDataStore _,
) async =>
    const [];

Stream<void> watchStoredLanguageDocuments(UserDataStore _) =>
    const Stream<void>.empty();

Future<void> installStoredLanguageDocument(
  UserDataStore _,
  String __,
  String ___,
) async {}

Future<void> removeStoredLanguageDocument(
  UserDataStore _,
  String __,
) async {}
