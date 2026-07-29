import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mdslens/services/web_gateway_client.dart';

void main() {
  test('static-host HTTP responses look like ordinary connection failures', () {
    expect(
      () => decodeWebGatewayResponse(
        http.Response('<html>Method Not Allowed</html>', 405),
      ),
      throwsA(
        isA<WebGatewayUnavailableException>().having(
          (error) => error.toString(),
          'message',
          'Connection failed.',
        ),
      ),
    );
  });

  test('gateway authentication errors remain useful operation failures', () {
    expect(
      () => decodeWebGatewayResponse(
        http.Response('{"ok":false,"error":"Invalid credentials."}', 401),
      ),
      throwsA('Invalid credentials.'),
    );
  });

  test('successful gateway responses preserve their JSON payload', () {
    expect(
      decodeWebGatewayResponse(
        http.Response('{"ok":true,"authenticated":false}', 200),
      ),
      {'ok': true, 'authenticated': false},
    );
  });

  test('binary signal batches decode typed waveforms and metadata', () {
    final encoded = _binarySignalFixture();
    final signals = <Map<String, dynamic>>[];

    expect(decodeWebSignalBatch(encoded, signals.add), 1);
    expect(signals, hasLength(1));
    expect(signals.single['column'], 1);
    final series = signals.single['series'] as Map;
    expect(series['name'], 'IP');
    expect(series['uniform_y'], isA<Float32List>());
    expect(series['uniform_y'], <double>[1.25, 2.5]);
    expect(series['points'], <List<double>>[
      <double>[3, 4],
    ]);
  });

  test('binary signal batches reject truncated payloads', () {
    final encoded = _binarySignalFixture();
    expect(
      () => decodeWebSignalBatch(
        Uint8List.sublistView(encoded, 0, encoded.length - 1),
        (_) {},
      ),
      throwsFormatException,
    );
  });
}

Uint8List _binarySignalFixture() {
  final metadata = utf8.encode(jsonEncode({
    'column': 1,
    'row': 2,
    'signal': 3,
    'shot': '164309',
    'series': {
      'name': 'IP',
      'unit': 'kA',
      'x_name': 'time',
      'x_unit': 's',
      'error': '',
      'uniform_y': <double>[],
      'uniform_start': -0.1,
      'uniform_step': 0.05,
      'uniform_min_y': 1.25,
      'uniform_max_y': 2.5,
      'points': <List<double>>[],
    },
  }));
  final output = BytesBuilder(copy: false)
    ..add(<int>[77, 68, 83, 76, 66, 73, 78, 49])
    ..add(_uint32(1))
    ..add(_uint32(metadata.length))
    ..add(_uint32(2))
    ..add(_uint32(1))
    ..add(metadata);
  _padToEight(output);
  output
    ..add(_float32(1.25))
    ..add(_float32(2.5));
  _padToEight(output);
  output
    ..add(_float64(3))
    ..add(_float64(4));
  return output.takeBytes();
}

Uint8List _uint32(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _float32(double value) =>
    (ByteData(4)..setFloat32(0, value, Endian.little)).buffer.asUint8List();

Uint8List _float64(double value) =>
    (ByteData(8)..setFloat64(0, value, Endian.little)).buffer.asUint8List();

void _padToEight(BytesBuilder output) {
  final padding = (8 - output.length % 8) % 8;
  if (padding > 0) output.add(Uint8List(padding));
}
