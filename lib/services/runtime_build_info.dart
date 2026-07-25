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
    return runtimeSystemInfoForValues(
      operatingSystem: Platform.operatingSystem,
      operatingSystemVersion: Platform.operatingSystemVersion,
      architecture: Abi.current().toString(),
    );
  }
}

typedef RuntimeSystemInfoLoader = Future<RuntimeSystemInfo> Function();
typedef GitVersionLoader = Future<String> Function();

const _systemInfoChannel = MethodChannel('mdsscope/system_info');

Future<RuntimeSystemInfo> loadRuntimeSystemInfo({
  bool? useLinuxReleaseInfo,
}) async {
  final fallback = RuntimeSystemInfo.fallback();
  if (useLinuxReleaseInfo ?? Platform.isLinux) {
    try {
      final osRelease = await File('/etc/os-release').readAsString();
      return linuxRuntimeSystemInfo(
        osRelease: osRelease,
        kernelVersion: Platform.operatingSystemVersion,
        architecture: Abi.current().toString(),
      );
    } catch (_) {
      return fallback;
    }
  }
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

RuntimeSystemInfo runtimeSystemInfoForValues({
  required String operatingSystem,
  required String operatingSystemVersion,
  required String architecture,
}) {
  final normalizedArchitectureValue = normalizedArchitecture(architecture);
  if (operatingSystem.toLowerCase() == 'windows') {
    return windowsRuntimeSystemInfo(
      operatingSystemVersion,
      normalizedArchitectureValue,
    );
  }
  return RuntimeSystemInfo(
    name: normalizedOperatingSystemName(operatingSystem),
    version: normalizedOperatingSystemVersion(operatingSystemVersion),
    architecture: normalizedArchitectureValue,
  );
}

RuntimeSystemInfo windowsRuntimeSystemInfo(
  String rawVersion,
  String architecture,
) {
  final buildMatch =
      RegExp(r'\b10\.0\.(\d+)(?:\.(\d+))?').firstMatch(rawVersion);
  final build = int.tryParse(buildMatch?.group(1) ?? '');
  if (build == null) {
    return RuntimeSystemInfo(
      name: 'Windows',
      version: normalizedOperatingSystemVersion(rawVersion),
      architecture: architecture,
    );
  }
  final revision = buildMatch?.group(2);
  final completeBuild =
      revision == null ? build.toString() : '$build.$revision';
  final isWindows11 = build >= 22000;
  final release = switch (build) {
    >= 28000 => '26H1',
    >= 26200 => '25H2',
    >= 26100 => '24H2',
    >= 22631 => '23H2',
    >= 22621 => '22H2',
    >= 22000 => '21H2',
    _ => '',
  };
  final version = [
    if (release.isNotEmpty) release,
    'build $completeBuild',
  ].join(', ');
  return RuntimeSystemInfo(
    name: isWindows11 ? 'Windows 11' : 'Windows 10',
    version: version,
    architecture: architecture,
  );
}

RuntimeSystemInfo linuxRuntimeSystemInfo({
  required String osRelease,
  required String kernelVersion,
  required String architecture,
}) {
  final values = <String, String>{};
  for (final line in osRelease.split('\n')) {
    final separator = line.indexOf('=');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    var value = line.substring(separator + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    values[key] = value
        .replaceAll(r'\"', '"')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\\', '\\');
  }
  final name = values['PRETTY_NAME']?.trim().isNotEmpty == true
      ? values['PRETTY_NAME']!.trim()
      : 'Linux';
  final kernelMatch =
      RegExp(r'(?:^|\bLinux\s+)([0-9][^\s]*)').firstMatch(kernelVersion);
  final kernel = kernelMatch?.group(1) ?? kernelVersion.trim();
  return RuntimeSystemInfo(
    name: name,
    version: kernel.isEmpty ? '' : 'kernel $kernel',
    architecture: normalizedArchitecture(architecture),
  );
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
