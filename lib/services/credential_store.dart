import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Sensitive values that must never be placed in settings.json or exported
/// configuration files.
abstract interface class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformCredentialStore implements CredentialStore {
  PlatformCredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accountName: 'com.mdsscope.app.credentials',
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
                label: 'MdsScope credentials',
              ),
              mOptions: MacOsOptions(
                accountName: 'com.mdsscope.app.credentials',
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
                label: 'MdsScope credentials',
                usesDataProtectionKeychain: true,
              ),
              aOptions: AndroidOptions(
                storageNamespace: 'com.mdsscope.app.credentials',
              ),
            );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
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
