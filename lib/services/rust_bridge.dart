import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

class RustBridge {
  static const int _expectedAbiVersion = 1;
  static RustBridge? _i;
  // ignore: unused_field
  final DynamicLibrary _lib;
  final String Function(String) parseEnv;
  final String Function(String) encodeEnv;
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
        encodeEnv = _wrap1(_lib, 'mds_encode_environment'),
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
    if (Platform.isIOS) {
      try {
        final library = DynamicLibrary.process();
        _requireCompatibleAbi(library, 'iOS application process');
        return library;
      } catch (error) {
        throw Exception(
          'The bundled iOS Rust bridge is missing or incompatible: $error. '
          'Rebuild the application so Dart and Rust are packaged together.',
        );
      }
    }

    if (Platform.isAndroid) {
      try {
        final library = DynamicLibrary.open('libmds_bridge.so');
        _requireCompatibleAbi(library, 'libmds_bridge.so');
        return library;
      } catch (error) {
        throw Exception(
          'Failed to load a compatible bundled Android Rust library '
          '(libmds_bridge.so): $error. Rebuild the APK so its Dart and Rust '
          'components come from the same source revision.',
        );
      }
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final errors = <String>[];
    var debugBuild = false;
    assert(() {
      debugBuild = true;
      return true;
    }());
    final names = Platform.isMacOS
        ? [
            if (debugBuild) 'rust/target/debug/libmds_bridge.dylib',
            '$exeDir/../Frameworks/libmds_bridge.dylib',
            '$exeDir/libmds_bridge.dylib',
            'libmds_bridge.dylib',
            'rust/target/release/libmds_bridge.dylib',
          ]
        : Platform.isLinux
            ? [
                if (debugBuild) 'rust/target/debug/libmds_bridge.so',
                '$exeDir/lib/libmds_bridge.so',
                '$exeDir/libmds_bridge.so',
                'libmds_bridge.so',
                'rust/target/release/libmds_bridge.so',
              ]
            : [
                if (debugBuild) 'rust/target/debug/mds_bridge.dll',
                '$exeDir/mds_bridge.dll',
                'mds_bridge.dll',
                'rust/target/release/mds_bridge.dll',
              ];

    for (final name in names) {
      try {
        final library = DynamicLibrary.open(name);
        _requireCompatibleAbi(library, name);
        return library;
      } catch (e) {
        errors.add('$name -> $e');
      }
    }

    throw Exception(
      'Failed to load a compatible libmds_bridge library. Rebuild the '
      'application so Dart and Rust come from the same source revision:\n'
      '${errors.join("\n")}',
    );
  }

  static void _requireCompatibleAbi(
    DynamicLibrary library,
    String source,
  ) {
    final version = library.lookupFunction<Uint32 Function(), int Function()>(
        'mds_bridge_abi_version')();
    if (version != _expectedAbiVersion) {
      throw StateError(
        '$source has native ABI $version; expected $_expectedAbiVersion',
      );
    }
  }

  static String Function(String) _wrap1(DynamicLibrary lib, String name) {
    final f = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)>(name);
    final freeResult = _rustStringFree(lib);
    return (a) {
      final aPointer = a.toNativeUtf8();
      Pointer<Utf8> result = nullptr;
      try {
        result = f(aPointer);
        return _readResult(result, name);
      } finally {
        malloc.free(aPointer);
        if (result != nullptr) {
          freeResult(result);
        }
      }
    };
  }

  static String Function(String, String) _wrap2(
      DynamicLibrary lib, String name) {
    final f = lib.lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>)>(name);
    final freeResult = _rustStringFree(lib);
    return (a, b) {
      final aPointer = a.toNativeUtf8();
      final bPointer = b.toNativeUtf8();
      Pointer<Utf8> result = nullptr;
      try {
        result = f(aPointer, bPointer);
        return _readResult(result, name);
      } finally {
        malloc.free(aPointer);
        malloc.free(bPointer);
        if (result != nullptr) {
          freeResult(result);
        }
      }
    };
  }

  static String Function(String, String, String) _wrap3(
      DynamicLibrary lib, String name) {
    final f = lib.lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
        Pointer<Utf8> Function(
            Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>(name);
    final freeResult = _rustStringFree(lib);
    return (a, b, c) {
      final aPointer = a.toNativeUtf8();
      final bPointer = b.toNativeUtf8();
      final cPointer = c.toNativeUtf8();
      Pointer<Utf8> result = nullptr;
      try {
        result = f(aPointer, bPointer, cPointer);
        return _readResult(result, name);
      } finally {
        malloc.free(aPointer);
        malloc.free(bPointer);
        malloc.free(cPointer);
        if (result != nullptr) {
          freeResult(result);
        }
      }
    };
  }

  static void Function(Pointer<Utf8>) _rustStringFree(DynamicLibrary lib) {
    return lib.lookupFunction<Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)>('mds_free_string');
  }

  static String _readResult(Pointer<Utf8> result, String functionName) {
    if (result == nullptr) {
      throw StateError('$functionName returned a null string pointer');
    }
    return result.toDartString();
  }
}
