import 'package:flutter/services.dart';

/// Receives platform-specific stylus tool changes that Flutter pointer events
/// do not expose, notably Apple Pencil double-tap.
class StylusModeChannel {
  static const MethodChannel _channel = MethodChannel('mdsscope/stylus');
  static void Function(bool eraser)? _onModeChanged;
  static bool _initialized = false;

  static void init(void Function(bool eraser) onModeChanged) {
    _onModeChanged = onModeChanged;
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stylusModeChanged' && call.arguments is bool) {
        _onModeChanged?.call(call.arguments as bool);
      }
    });
  }

  static void dispose() {
    _onModeChanged = null;
  }
}
