import 'package:flutter/foundation.dart';

String get runtimeOperatingSystem => 'web';
String get runtimeOperatingSystemVersion {
  final browser = defaultTargetPlatform.name;
  final engine = const bool.fromEnvironment('dart.tool.dart2wasm')
      ? 'WebAssembly'
      : 'JavaScript';
  return '$browser, $engine';
}

String get runtimeArchitecture => 'wasm';
bool get runtimeIsLinux => false;
Future<String?> loadLinuxOsRelease() async => null;
