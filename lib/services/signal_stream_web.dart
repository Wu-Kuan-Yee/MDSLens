import 'web_gateway_client.dart';

typedef SignalStreamListener = void Function(Map<String, dynamic> signal);

Future<String> fetchSignalsStreamingInBackground(
  String configJson,
  String dataMode,
  String sshSettingsJson,
  SignalStreamListener onSignal,
) {
  // HTTP gateways currently return one authoritative batch. The interface is
  // deliberately streaming-shaped so an NDJSON/SSE transport can be added
  // without changing AppState again.
  return WebGatewayClient.instance.fetchSignals(configJson, dataMode);
}
