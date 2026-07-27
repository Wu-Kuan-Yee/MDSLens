import 'package:flutter/services.dart';

/// Receives platform-specific stylus tool changes that Flutter pointer events
/// do not expose, notably Apple Pencil double-tap.
class StylusModeChannel {
  static const MethodChannel _channel = MethodChannel('mdslens/stylus');
  static void Function(bool eraser)? _onModeChanged;
  static bool _initialized = false;

  static void init(void Function(bool eraser) onModeChanged) {
    _onModeChanged = onModeChanged;
    if (!_initialized) {
      _initialized = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'stylusModeChanged' && call.arguments is bool) {
          _onModeChanged?.call(call.arguments as bool);
        }
      });
    }
    _syncNativeMode();
  }

  static Future<void> _syncNativeMode() async {
    try {
      final eraser = await _channel.invokeMethod<bool>('getMode');
      if (eraser != null) _onModeChanged?.call(eraser);
    } on MissingPluginException {
      // Platforms without a hardware tool toggle stay in write/pan mode.
    } on PlatformException {
      // A transient native-channel failure must not disable stylus input.
    }
  }

  static void dispose() {
    _onModeChanged = null;
  }
}
