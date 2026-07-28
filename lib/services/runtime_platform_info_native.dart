import 'dart:ffi';
import 'dart:io';

String get runtimeOperatingSystem => Platform.operatingSystem;
String get runtimeOperatingSystemVersion => Platform.operatingSystemVersion;
String get runtimeArchitecture => Abi.current().toString();
bool get runtimeIsLinux => Platform.isLinux;

Future<String?> loadLinuxOsRelease() async {
  try {
    return await File('/etc/os-release').readAsString();
  } catch (_) {
    return null;
  }
}
