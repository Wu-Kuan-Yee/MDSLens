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
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accountName: 'com.mdslens.app.credentials',
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
              label: 'MDSLens credentials',
            ),
            mOptions: MacOsOptions(
              accountName: 'com.mdslens.app.credentials',
              accessibility: KeychainAccessibility.first_unlock_this_device,
              synchronizable: false,
              label: 'MDSLens credentials',
              // Direct-distribution macOS builds are intentionally
              // unsandboxed so ~/.mdslens remains available. The Data
              // Protection Keychain requires an application-group
              // entitlement and rejects these builds with errSecMissingEntitlement.
              // The standard login Keychain remains encrypted and scoped to
              // this signed application without that entitlement.
              usesDataProtectionKeychain: false,
            ),
            aOptions: AndroidOptions(
              storageNamespace: 'com.mdslens.app.credentials',
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
