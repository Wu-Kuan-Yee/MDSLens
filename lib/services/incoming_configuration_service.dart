import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

typedef IncomingConfigurationHandler = Future<void> Function(String path);

class IncomingConfigurationService {
  IncomingConfigurationService._();

  static const MethodChannel _channel = MethodChannel('mdsscope/open_requests');
  static IncomingConfigurationHandler? _handler;

  static Future<void> start(
    IncomingConfigurationHandler handler, {
    List<String> commandLineArguments = const [],
  }) async {
    _handler = handler;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openRequest' && call.arguments is String) {
        await _dispatch(call.arguments as String);
      }
    });

    for (final argument in commandLineArguments) {
      await _dispatch(argument);
    }
    try {
      final pending = await _channel.invokeListMethod<String>('takePending');
      for (final request in pending ?? const <String>[]) {
        await _dispatch(request);
      }
    } on MissingPluginException {
      // Desktop runners pass launch requests through main(List<String>) and
      // therefore do not need a native channel.
    }
  }

  static Future<void> _dispatch(String request) async {
    final handler = _handler;
    if (handler == null) return;
    final path = configurationPathFromOpenRequest(request);
    if (path != null) await handler(path);
  }
}

String? configurationPathFromOpenRequest(String request) {
  final value = request.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri != null && uri.scheme.toLowerCase() == 'mdsscope') {
    final path = uri.queryParameters['path'];
    if (path == null || path.trim().isEmpty) return null;
    return path;
  }
  final path = uri != null && uri.scheme.toLowerCase() == 'file'
      ? uri.toFilePath()
      : value;
  final extension = path.toLowerCase();
  if (!extension.endsWith('.toml') && !extension.endsWith('.webscp')) {
    return null;
  }
  return File(path).absolute.path;
}
