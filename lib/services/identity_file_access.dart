import 'package:flutter/services.dart';

class IdentityFileAccess {
  static const _channel = MethodChannel('mdslens/identity_file_access');

  static Future<String> authorize(
    String path, {
    bool promptIfNeeded = true,
  }) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    try {
      final authorized = await _channel.invokeMethod<String>(
        'authorizeIdentityFile',
        {'path': trimmed, 'promptIfNeeded': promptIfNeeded},
      );
      return authorized?.trim().isNotEmpty == true
          ? authorized!.trim()
          : trimmed;
    } on MissingPluginException {
      return trimmed;
    } on PlatformException {
      rethrow;
    }
  }
}
