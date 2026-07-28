import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Same-origin client for the server-side capabilities that browsers cannot
/// provide directly (MDSip, SSH and protected API sessions).
///
/// The gateway owns the real authentication token in an HttpOnly cookie-backed
/// session. No token or password is returned to JavaScript.
class WebGatewayClient {
  WebGatewayClient._();

  static final WebGatewayClient instance = WebGatewayClient._();

  static const _basePath = '/gateway/v1';
  static const _sessionMarker = 'gateway-session';

  Future<Map<String, dynamic>> session() => _get('/session');

  Future<({String token, bool usedSsh})> login(
    String apiUrl,
    String user,
    String password,
    String sshSettingsJson,
  ) async {
    final ssh = _decodeOptionalMap(sshSettingsJson);
    final response = await _post('/login', {
      'api_url': apiUrl,
      'user': user,
      'password': password,
      if (ssh != null) 'ssh': ssh,
    });
    return (
      token: _sessionMarker,
      usedSsh: response['used_ssh'] == true,
    );
  }

  Future<void> logout() async {
    await _post('/logout', const {});
  }

  Future<Map<String, dynamic>> latestShot() => _post('/shot/latest', const {});

  Future<String> shotInfo(String shot) async {
    final response = await _post('/shot/info', {'shot': shot});
    return jsonEncode(response);
  }

  Future<String> fetchSignals(String configJson, String dataMode) async {
    final response = await _postValue('/signals/fetch', {
      'config_json': configJson,
      'data_mode': int.tryParse(dataMode) ?? 0,
    });
    return jsonEncode(response);
  }

  Future<void> prewarmSignals(String configJson) async {
    await _post('/signals/prewarm', {'config_json': configJson});
  }

  Future<void> cancelFetch(int requestId) async {
    await _post('/signals/cancel', {'request_id': requestId});
  }

  Future<String> testSsh(String settingsJson) async {
    final settings = _decodeOptionalMap(settingsJson);
    if (settings == null) {
      throw const FormatException('SSH settings are required.');
    }
    final response = await _post('/ssh/test', settings);
    return jsonEncode(response);
  }

  Future<void> disconnectSsh() async {
    await _post('/ssh/disconnect', const {});
  }

  Future<String> parseConfiguration(String dataUri) async {
    final uri = Uri.parse(dataUri);
    if (!uri.isScheme('data')) {
      throw const FormatException(
        'Browser configuration parsing requires file bytes.',
      );
    }
    final name = uri.data?.parameters['name'] ?? 'configuration.toml';
    final bytes = uri.data?.contentAsBytes() ?? Uint8List(0);
    final response = await _post('/configuration/parse', {
      'name': name,
      'bytes_base64': base64Encode(bytes),
    });
    return jsonEncode(response);
  }

  Future<Uint8List> encodeConfiguration(
    String configJson,
    String format,
  ) async {
    final response = await _post('/configuration/encode', {
      'config_json': configJson,
      'format': format,
    });
    final content = response['content'];
    if (content is! String) {
      throw const FormatException(
        'The Web Gateway returned no configuration content.',
      );
    }
    return Uint8List.fromList(utf8.encode(content));
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await http
        .get(Uri.parse('$_basePath$path'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    return _decodeMap(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body,
  ) async {
    final value = await _postValue(path, body);
    if (value is! Map) {
      throw const FormatException(
        'The Web Gateway returned an unexpected response.',
      );
    }
    return Map<String, dynamic>.from(value);
  }

  Future<dynamic> _postValue(
    String path,
    Map<String, dynamic> body,
  ) async {
    final response = await http
        .post(
          Uri.parse('$_basePath$path'),
          headers: _headers,
          body: jsonEncode(body),
        )
        .timeout(const Duration(minutes: 5));
    return _decode(response);
  }

  Map<String, String> get _headers => const {
        'Accept': 'application/json',
        'Content-Type': 'application/json; charset=utf-8',
      };

  Map<String, dynamic> _decodeMap(http.Response response) {
    final value = _decode(response);
    if (value is! Map) {
      throw const FormatException(
        'The Web Gateway returned an unexpected response.',
      );
    }
    return Map<String, dynamic>.from(value);
  }

  dynamic _decode(http.Response response) {
    dynamic value;
    try {
      value = jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw 'Web Gateway returned invalid JSON (HTTP ${response.statusCode}).';
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = value is Map ? value['error']?.toString() : null;
      throw message ??
          'Web Gateway request failed (HTTP ${response.statusCode}).';
    }
    return value;
  }

  Map<String, dynamic>? _decodeOptionalMap(String source) {
    if (source.trim().isEmpty) return null;
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return Map<String, dynamic>.from(value);
  }
}
