import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import 'rust_bridge.dart';

class RuntimeSystemInfo {
  const RuntimeSystemInfo({
    required this.name,
    required this.version,
    required this.architecture,
  });

  final String name;
  final String version;
  final String architecture;

  String get displayText {
    final versionPart = version.isEmpty ? '' : ' ($version)';
    final architecturePart = architecture.isEmpty ? '' : ' ($architecture)';
    return '$name$versionPart$architecturePart';
  }

  factory RuntimeSystemInfo.fallback() {
    return RuntimeSystemInfo(
      name: normalizedOperatingSystemName(Platform.operatingSystem),
      version: normalizedOperatingSystemVersion(
        Platform.operatingSystemVersion,
      ),
      architecture: normalizedArchitecture(Abi.current().toString()),
    );
  }
}

typedef RuntimeSystemInfoLoader = Future<RuntimeSystemInfo> Function();
typedef GitVersionLoader = Future<String> Function();

const _systemInfoChannel = MethodChannel('mdsscope/system_info');

Future<RuntimeSystemInfo> loadRuntimeSystemInfo() async {
  final fallback = RuntimeSystemInfo.fallback();
  try {
    final result =
        await _systemInfoChannel.invokeMapMethod<String, dynamic>('get');
    if (result == null) return fallback;
    final name = result['name']?.toString().trim() ?? '';
    final version = result['version']?.toString().trim() ?? '';
    final architecture =
        normalizedArchitecture(result['architecture']?.toString() ?? '');
    return RuntimeSystemInfo(
      name: name.isEmpty ? fallback.name : name,
      version: version.isEmpty ? fallback.version : version,
      architecture: architecture.isEmpty ? fallback.architecture : architecture,
    );
  } catch (_) {
    return fallback;
  }
}

Future<String> loadMdsScopeGitVersion() async {
  try {
    final version = RustBridge.instance.buildGitVersion().trim();
    if (version.isNotEmpty) return version;
  } catch (_) {}
  return 'unknown';
}

String normalizedOperatingSystemName(String value) {
  switch (value.toLowerCase()) {
    case 'android':
      return 'Android';
    case 'ios':
      return 'iOS';
    case 'macos':
      return 'macOS';
    case 'windows':
      return 'Windows';
    case 'linux':
      return 'Linux';
    case 'fuchsia':
      return 'Fuchsia';
    default:
      return value.isEmpty ? 'Unknown' : value;
  }
}

String normalizedOperatingSystemVersion(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return '';
  for (final pattern in [
    RegExp(r'\bVersion\s+([0-9]+(?:\.[0-9]+)*)', caseSensitive: false),
    RegExp(r'\b(?:Android|iOS|macOS|Windows)\s+([0-9]+(?:\.[0-9]+)*)',
        caseSensitive: false),
  ]) {
    final match = pattern.firstMatch(trimmed);
    if (match != null) return match.group(1) ?? '';
  }
  final leadingVersion = RegExp(r'^([0-9]+(?:\.[0-9]+)*)').firstMatch(trimmed);
  if (leadingVersion != null) return leadingVersion.group(1) ?? '';
  return trimmed;
}

String normalizedArchitecture(String value) {
  final architecture = value.toLowerCase().replaceAll('-', '_');
  if (architecture.contains('arm64') || architecture.contains('aarch64')) {
    return 'arm64';
  }
  if (architecture.contains('x64') ||
      architecture.contains('x86_64') ||
      architecture.contains('amd64')) {
    return 'x86_64';
  }
  if (architecture.contains('riscv64')) return 'riscv64';
  if (architecture.contains('armeabi') ||
      RegExp(r'(^|_)arm($|_)').hasMatch(architecture)) {
    return 'arm';
  }
  if (architecture.contains('ia32') || architecture.contains('x86')) {
    return 'x86';
  }
  return value.trim();
}
