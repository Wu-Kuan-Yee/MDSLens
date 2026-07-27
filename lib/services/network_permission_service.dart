import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum NetworkAccessPreparation {
  ready,
  deniedDuringRequest,
  deniedPreviously,
  unknown,
}

class NetworkPermissionService {
  NetworkPermissionService._();

  static const MethodChannel _channel = MethodChannel('mdslens/permissions');

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

  static Future<NetworkAccessPreparation> requestAllStartupPermissions(
    String apiUrl,
  ) async {
    var networkAccess = NetworkAccessPreparation.ready;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Trigger and await the system WLAN/cellular-data decision first. The
      // local-network prompt is deliberately last so system dialogs cannot
      // compete with each other during first launch.
      networkAccess = await prepareNetworkAccess(apiUrl);
    }
    if (needsLocalNetworkPrivacyHandling) {
      await requestInitialLocalNetworkAccess();
    }
    return networkAccess;
  }

  static Future<NetworkAccessPreparation> prepareNetworkAccess(
    String apiUrl,
  ) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return NetworkAccessPreparation.ready;
    }
    try {
      final result = await _channel.invokeMethod<String>(
        'prepareNetworkAccess',
        {'url': apiUrl},
      );
      return switch (result) {
        'ready' => NetworkAccessPreparation.ready,
        'deniedDuringRequest' => NetworkAccessPreparation.deniedDuringRequest,
        'deniedPreviously' => NetworkAccessPreparation.deniedPreviously,
        _ => NetworkAccessPreparation.unknown,
      };
    } on PlatformException {
      return NetworkAccessPreparation.unknown;
    } on MissingPluginException {
      return NetworkAccessPreparation.unknown;
    }
  }

  static bool isLikelyPermissionFailure(Object error) {
    final message = error.toString().toLowerCase();
    return const [
      'local network denied',
      'localnetworkdenied',
      'local network permission',
      'cellular data access was denied',
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

  static bool isConfirmedPermissionFailure(Object error) {
    final message = error.toString().toLowerCase();
    return const [
      'localnetworkdenied',
      'local network denied',
      'kdnsserviceerr_policydenied',
      'policy denied',
      'cellular data access was denied',
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
