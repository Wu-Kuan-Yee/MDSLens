import 'credential_store_platform.dart';

/// Sensitive values that must never be placed in settings.json or exported
/// configuration files.
abstract interface class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformCredentialStore implements CredentialStore {
  PlatformCredentialStore() : _storage = PlatformCredentialBackend();

  final PlatformCredentialBackend _storage;

  @override
  Future<String?> read(String key) => _storage.read(key);

  @override
  Future<void> write(String key, String value) => _storage.write(key, value);

  @override
  Future<void> delete(String key) => _storage.delete(key);
}

class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore([Map<String, String>? initialValues])
    : values = {...?initialValues};

  final Map<String, String> values;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}
