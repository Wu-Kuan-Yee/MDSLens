import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

class RustBridge {
  static RustBridge? _i;
  // ignore: unused_field
  final DynamicLibrary _lib;
  final String Function(String) parseEnv;
  final String Function(String, String) writeEnv;
  final String Function(String, String, String) reqLogin;
  final String Function(String, String) fetchS;
  final String Function(String, String, String) fetchSInfo;
  final String Function(String, String) prepareUrl;
  final String Function(String) sshT;
  final String Function(String, String) fetchSig;
  final String Function(String, String, String) fetchSigSsh;

  RustBridge._(this._lib)
      : parseEnv = _wrap1(_lib, 'mds_parse_environment'),
        writeEnv = _wrap2(_lib, 'mds_write_environment'),
        reqLogin = _wrap3(_lib, 'mds_request_login'),
        fetchS = _wrap2(_lib, 'mds_fetch_shot'),
        fetchSInfo = _wrap3(_lib, 'mds_fetch_shot_info'),
        prepareUrl = _wrap2(_lib, 'mds_prepare_url'),
        sshT = _wrap1(_lib, 'mds_ssh_test'),
        fetchSig = _wrap2(_lib, 'mds_fetch_signals'),
        fetchSigSsh = _wrap3(_lib, 'mds_fetch_signals_ssh');

  static RustBridge get instance => _i ??= RustBridge._(_openLib());

  static DynamicLibrary _openLib() {
    // Try static linking first (symbols are in the process)
    try { return DynamicLibrary.process(); } catch (_) {}
    // Fallback to dynamic linking
    final exeDir = File(Platform.resolvedExecutable).parent;
    final names = Platform.isMacOS ? [
      '$exeDir/../Frameworks/libmds_bridge.dylib',
      '$exeDir/libmds_bridge.dylib',
      'rust/target/debug/libmds_bridge.dylib',
    ] : Platform.isLinux ? ['$exeDir/lib/libmds_bridge.so', 'rust/target/debug/libmds_bridge.so']
      : ['$exeDir/mds_bridge.dll'];
    for (final name in names) {
      try { return DynamicLibrary.open(name); } catch (_) {}
    }
    throw Exception('Cannot find libmds_bridge. Static link failed; dynamic dylib/so/dll not found.');
  }

  static String Function(String) _wrap1(DynamicLibrary lib, String name) {
    final f = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(name);
    return (a) { final p = f(a.toNativeUtf8()); final s = p.toDartString(); malloc.free(p); return s; };
  }
  static String Function(String, String) _wrap2(DynamicLibrary lib, String name) {
    final f = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(name);
    return (a, b) { final p = f(a.toNativeUtf8(), b.toNativeUtf8()); final s = p.toDartString(); malloc.free(p); return s; };
  }
  static String Function(String, String, String) _wrap3(DynamicLibrary lib, String name) {
    final f = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(name);
    return (a, b, c) { final p = f(a.toNativeUtf8(), b.toNativeUtf8(), c.toNativeUtf8()); final s = p.toDartString(); malloc.free(p); return s; };
  }
}
