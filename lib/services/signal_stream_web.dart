import 'web_gateway_client.dart';

typedef SignalStreamListener = void Function(Map<String, dynamic> signal);

Future<String> fetchSignalsStreamingInBackground(
  String configJson,
  String dataMode,
  String sshSettingsJson,
  SignalStreamListener onSignal,
) {
  return WebGatewayClient.instance.fetchSignalsBinary(
    configJson,
    dataMode,
    onSignal,
  );
}
