import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NetworkPermissionService {
  NetworkPermissionService._();

  static const MethodChannel _channel = MethodChannel('mdsscope/permissions');

  static bool get needsLocalNetworkPrivacyHandling =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  static bool get requestsLocalNetworkOnStartup =>
      defaultTargetPlatform == TargetPlatform.iOS;

  static Future<bool> requestInitialLocalNetworkAccess() async {
    try {
      return await _channel.invokeMethod<bool>('requestLocalNetworkAccess') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  static bool isLikelyPermissionFailure(Object error) {
    final message = error.toString().toLowerCase();
    return const [
      'local network denied',
      'localnetworkdenied',
      'local network permission',
      'policy denied',
      'kdnsserviceerr_policydenied',
      'permission denied',
      'operation not permitted',
      'network is down',
      'no route to host',
      'os error: 1',
      'os error: 13',
      'eacces',
      'eperm',
    ].any(message.contains);
  }

  static Future<bool> openAppSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
