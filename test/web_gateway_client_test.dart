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
}
