import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PlatformCredentialBackend {
  PlatformCredentialBackend({FlutterSecureStorage? storage})
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
                usesDataProtectionKeychain: false,
              ),
              aOptions: AndroidOptions(
                storageNamespace: 'com.mdslens.app.credentials',
              ),
            );

  final FlutterSecureStorage _storage;

  Future<String?> read(String key) => _storage.read(key: key);
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  Future<void> delete(String key) => _storage.delete(key: key);
}
