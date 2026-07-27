import 'dart:async';
import 'package:flutter/services.dart';

class ThemeChannel {
  static final _channel = MethodChannel('mdslens/theme');
  static final _controller = StreamController<bool>.broadcast();
  static Stream<bool> get onThemeChanged => _controller.stream;

  static Future<bool?> isDark() async {
    try {
      return await _channel.invokeMethod('isDark') == true;
    } catch (_) {
      return null;
    }
  }

  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'themeChanged') {
        _controller.add(call.arguments == true);
      }
    });
  }
}
