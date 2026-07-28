/// Browser credentials intentionally live only in the current page process.
///
/// Persistent browser storage is readable by page JavaScript and therefore
/// cannot provide Keychain-equivalent protection. The Web Gateway owns the
/// durable HttpOnly session; this map only bridges state during one page
/// lifetime.
class PlatformCredentialBackend {
  PlatformCredentialBackend();

  final Map<String, String> _sessionValues = <String, String>{};

  Future<String?> read(String key) async => _sessionValues[key];

  Future<void> write(String key, String value) async {
    _sessionValues[key] = value;
  }

  Future<void> delete(String key) async {
    _sessionValues.remove(key);
  }
}
