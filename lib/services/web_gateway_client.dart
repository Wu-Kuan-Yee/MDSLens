import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class WebGatewayUnavailableException implements Exception {
  const WebGatewayUnavailableException();

  @override
  String toString() => 'Connection failed.';
}

dynamic decodeWebGatewayResponse(http.Response response) {
  dynamic value;
  try {
    value = jsonDecode(utf8.decode(response.bodyBytes));
  } on FormatException {
    throw const WebGatewayUnavailableException();
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    final message = value is Map ? value['error']?.toString().trim() : null;
    if (message == null || message.isEmpty) {
      throw const WebGatewayUnavailableException();
    }
    throw message;
  }
  return value;
}

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

  Future<Map<String, dynamic>> session() =>
      _get('/session', timeout: const Duration(seconds: 5));

  Future<({String token, bool usedSsh})> login(
    String apiUrl,
    String user,
    String password,
    String sshSettingsJson,
  ) async {
    final ssh = _decodeOptionalMap(sshSettingsJson);
    final response = await _post(
      '/login',
      {
        'api_url': apiUrl,
        'user': user,
        'password': password,
        if (ssh != null) 'ssh': ssh,
      },
      timeout: const Duration(seconds: 45),
    );
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
    final response = await _postValue(
      '/signals/fetch',
      {
        'config_json': configJson,
        'data_mode': int.tryParse(dataMode) ?? 0,
      },
      timeout: const Duration(minutes: 5),
    );
    return jsonEncode(response);
  }

  Future<String> fetchSignalsBinary(
    String configJson,
    String dataMode,
    void Function(Map<String, dynamic>) onSignal,
  ) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_basePath/signals/fetch-binary'),
            headers: const {
              'Accept': 'application/vnd.mdslens.signals-v1',
              'Content-Type': 'application/json; charset=utf-8',
            },
            body: jsonEncode({
              'config_json': configJson,
              'data_mode': int.tryParse(dataMode) ?? 0,
            }),
          )
          .timeout(const Duration(minutes: 5));
      if (response.statusCode == 404 || response.statusCode == 405) {
        return fetchSignals(configJson, dataMode);
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        decodeWebGatewayResponse(response);
      }
      decodeWebSignalBatch(response.bodyBytes, onSignal);
      return '[]';
    } on WebGatewayUnavailableException {
      rethrow;
    } on TimeoutException {
      throw const WebGatewayUnavailableException();
    } on http.ClientException {
      throw const WebGatewayUnavailableException();
    }
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
    final response = await _post(
      '/ssh/test',
      settings,
      timeout: const Duration(seconds: 45),
    );
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

  Future<Map<String, dynamic>> _get(
    String path, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final response = await http
          .get(Uri.parse('$_basePath$path'), headers: _headers)
          .timeout(timeout);
      return _decodeMap(response);
    } on WebGatewayUnavailableException {
      rethrow;
    } on TimeoutException {
      throw const WebGatewayUnavailableException();
    } on http.ClientException {
      throw const WebGatewayUnavailableException();
    }
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final value = await _postValue(path, body, timeout: timeout);
    if (value is! Map) {
      throw const FormatException(
        'The Web Gateway returned an unexpected response.',
      );
    }
    return Map<String, dynamic>.from(value);
  }

  Future<dynamic> _postValue(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    try {
      final response = await http
          .post(
            Uri.parse('$_basePath$path'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(timeout);
      return _decode(response);
    } on WebGatewayUnavailableException {
      rethrow;
    } on TimeoutException {
      throw const WebGatewayUnavailableException();
    } on http.ClientException {
      throw const WebGatewayUnavailableException();
    }
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

  dynamic _decode(http.Response response) => decodeWebGatewayResponse(response);

  Map<String, dynamic>? _decodeOptionalMap(String source) {
    if (source.trim().isEmpty) return null;
    final value = jsonDecode(source);
    if (value is! Map) {
      throw const FormatException('Expected a JSON object.');
    }
    return Map<String, dynamic>.from(value);
  }
}

int decodeWebSignalBatch(
  Uint8List bytes,
  void Function(Map<String, dynamic>) onSignal,
) {
  const magic = <int>[77, 68, 83, 76, 66, 73, 78, 49];
  if (bytes.length < 12) {
    throw const FormatException(
        'The Web Gateway returned invalid signal data.');
  }
  for (var index = 0; index < magic.length; index++) {
    if (bytes[index] != magic[index]) {
      throw const FormatException(
        'The Web Gateway returned invalid signal data.',
      );
    }
  }
  final data = ByteData.sublistView(bytes);
  final signalCount = data.getUint32(8, Endian.little);
  var offset = 12;
  for (var signalIndex = 0; signalIndex < signalCount; signalIndex++) {
    if (offset + 12 > bytes.length) {
      throw const FormatException(
        'The Web Gateway returned truncated signal metadata.',
      );
    }
    final metadataLength = data.getUint32(offset, Endian.little);
    final uniformLength = data.getUint32(offset + 4, Endian.little);
    final pointLength = data.getUint32(offset + 8, Endian.little);
    offset += 12;
    final metadataEnd = offset + metadataLength;
    if (metadataEnd > bytes.length) {
      throw const FormatException(
        'The Web Gateway returned truncated signal metadata.',
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes.sublist(offset, metadataEnd)));
    if (decoded is! Map || decoded['series'] is! Map) {
      throw const FormatException(
        'The Web Gateway returned invalid signal metadata.',
      );
    }
    final signal = Map<String, dynamic>.from(decoded);
    final series = Map<String, dynamic>.from(signal['series'] as Map);
    offset = _alignSignalOffset(metadataEnd);

    final uniformBytes = uniformLength * Float32List.bytesPerElement;
    if (offset + uniformBytes > bytes.length) {
      throw const FormatException(
        'The Web Gateway returned truncated uniform signal data.',
      );
    }
    if (uniformLength > 0) {
      series['uniform_y'] = _readFloat32Values(bytes, offset, uniformLength);
    }
    offset = _alignSignalOffset(offset + uniformBytes);

    final pointBytes = pointLength * 2 * Float64List.bytesPerElement;
    if (offset + pointBytes > bytes.length) {
      throw const FormatException(
        'The Web Gateway returned truncated irregular signal data.',
      );
    }
    if (pointLength > 0) {
      final values = _readFloat64Values(bytes, offset, pointLength * 2);
      series['points'] = <List<double>>[
        for (var index = 0; index < values.length; index += 2)
          <double>[values[index], values[index + 1]],
      ];
    }
    offset += pointBytes;
    signal['series'] = series;
    onSignal(signal);
  }
  if (offset != bytes.length) {
    throw const FormatException(
      'The Web Gateway returned trailing signal data.',
    );
  }
  return signalCount;
}

int _alignSignalOffset(int offset) => (offset + 7) & ~7;

Float32List _readFloat32Values(Uint8List bytes, int offset, int length) {
  final absoluteOffset = bytes.offsetInBytes + offset;
  if (Endian.host == Endian.little &&
      absoluteOffset % Float32List.bytesPerElement == 0) {
    return Float32List.view(bytes.buffer, absoluteOffset, length);
  }
  final data = ByteData.sublistView(bytes, offset, offset + length * 4);
  return Float32List.fromList(<double>[
    for (var index = 0; index < length; index++)
      data.getFloat32(index * 4, Endian.little),
  ]);
}

Float64List _readFloat64Values(Uint8List bytes, int offset, int length) {
  final absoluteOffset = bytes.offsetInBytes + offset;
  if (Endian.host == Endian.little &&
      absoluteOffset % Float64List.bytesPerElement == 0) {
    return Float64List.view(bytes.buffer, absoluteOffset, length);
  }
  final data = ByteData.sublistView(bytes, offset, offset + length * 8);
  return Float64List.fromList(<double>[
    for (var index = 0; index < length; index++)
      data.getFloat64(index * 8, Endian.little),
  ]);
}
