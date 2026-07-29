import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'rust_bridge.dart';

typedef SignalStreamListener = void Function(Map<String, dynamic> signal);

SendPort? _nativeSignalPort;

void _forwardNativeBinarySignal(
  Pointer<Utf8> pointer,
  Pointer<Float> uniformPointer,
  int uniformLength,
) {
  try {
    final decoded = jsonDecode(pointer.toDartString());
    if (decoded is! Map) return;
    final signal = Map<String, dynamic>.from(decoded);
    if (uniformLength > 0 && signal['series'] is Map) {
      final series = Map<String, dynamic>.from(signal['series'] as Map);
      series['uniform_y'] = Float32List.fromList(
        uniformPointer.asTypedList(uniformLength),
      );
      signal['series'] = series;
    }
    _nativeSignalPort?.send(signal);
  } finally {
    RustBridge.instance.freeTransferredString(pointer);
  }
}

void _runNativeSignalFetch(List<Object> message) {
  final output = message[0] as SendPort;
  final configJson = message[1] as String;
  final dataMode = message[2] as String;
  final sshSettingsJson = message[3] as String;
  _nativeSignalPort = output;
  try {
    final callback = Pointer.fromFunction<NativeSignalBinaryStreamCallback>(
      _forwardNativeBinarySignal,
    );
    final result = RustBridge.instance.fetchSigSshStreamingBinary(
      configJson,
      dataMode,
      sshSettingsJson,
      callback.address,
    );
    output.send(<String, String>{'done': result});
  } catch (error, stackTrace) {
    output.send(<String, String>{
      'error': error.toString(),
      'stack': stackTrace.toString(),
    });
  } finally {
    _nativeSignalPort = null;
  }
}

Future<String> fetchSignalsStreamingInBackground(
  String configJson,
  String dataMode,
  String sshSettingsJson,
  SignalStreamListener onSignal,
) async {
  final receivePort = ReceivePort();
  final completion = Completer<String>();
  late final StreamSubscription<Object?> subscription;
  Isolate? worker;
  subscription = receivePort.listen((message) {
    if (message is Map &&
        message['series'] is Map &&
        !message.containsKey('done') &&
        !message.containsKey('error')) {
      onSignal(Map<String, dynamic>.from(message));
      return;
    }
    if (message is String) {
      try {
        final decoded = jsonDecode(message);
        if (decoded is Map) {
          onSignal(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // The authoritative final response still reports malformed payloads.
      }
      return;
    }
    if (message is Map && message['done'] is String) {
      if (!completion.isCompleted) {
        completion.complete(message['done'] as String);
      }
      return;
    }
    if (message is Map && message['error'] is String) {
      if (!completion.isCompleted) {
        completion.completeError(
          StateError(message['error'] as String),
          StackTrace.fromString(message['stack']?.toString() ?? ''),
        );
      }
    }
  });
  try {
    worker = await Isolate.spawn<List<Object>>(_runNativeSignalFetch, [
      receivePort.sendPort,
      configJson,
      dataMode,
      sshSettingsJson,
    ]);
    return await completion.future;
  } finally {
    worker?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    receivePort.close();
  }
}
