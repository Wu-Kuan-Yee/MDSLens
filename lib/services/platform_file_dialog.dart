import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'browser_download.dart';

typedef PlatformSaveDialog = Future<String?> Function(Uint8List? bytes);

const MethodChannel _linuxFileDialogChannel = MethodChannel(
  'mdslens/file_dialog',
);

bool get _useNativeLinuxFileDialog => !kIsWeb && Platform.isLinux;

Future<List<String>?> pickFilePathsWithFallback({
  required String dialogTitle,
  List<String> allowedExtensions = const [],
  bool allowMultiple = false,
  String? initialDirectory,
}) async {
  if (_useNativeLinuxFileDialog) {
    try {
      final result = await _linuxFileDialogChannel.invokeMethod<List<dynamic>>(
        'pickFiles',
        <String, Object?>{
          'title': dialogTitle,
          'extensions': allowedExtensions,
          'allowMultiple': allowMultiple,
          if (initialDirectory != null) 'initialDirectory': initialDirectory,
        },
      );
      if (result != null) {
        return result
            .whereType<String>()
            .where((path) => path.trim().isNotEmpty)
            .toList(growable: false);
      }
      return null;
    } on MissingPluginException {
      // Keep tests and older Linux bundles usable while they are upgraded.
    } on PlatformException {
      // Fall through to file_picker if GTK cannot create a native dialog.
    }
  }

  final result = await FilePicker.platform.pickFiles(
    dialogTitle: dialogTitle,
    type: allowedExtensions.isEmpty ? FileType.any : FileType.custom,
    allowedExtensions: allowedExtensions.isEmpty ? null : allowedExtensions,
    allowMultiple: allowMultiple,
    withData: false,
    initialDirectory: initialDirectory,
    lockParentWindow: true,
  );
  if (result == null) return null;
  return result.files
      .map((file) => file.path)
      .whereType<String>()
      .where((path) => path.trim().isNotEmpty)
      .toList(growable: false);
}

Future<String?> saveFilePathWithFallback({
  required String dialogTitle,
  required String fileName,
  List<String> allowedExtensions = const [],
  String? initialDirectory,
}) async {
  if (_useNativeLinuxFileDialog) {
    try {
      return await _linuxFileDialogChannel.invokeMethod<String>(
        'saveFile',
        <String, Object?>{
          'title': dialogTitle,
          'fileName': fileName,
          'extensions': allowedExtensions,
          if (initialDirectory != null) 'initialDirectory': initialDirectory,
        },
      );
    } on MissingPluginException {
      // Keep tests and older Linux bundles usable while they are upgraded.
    } on PlatformException {
      // Fall through to file_picker if GTK cannot create a native dialog.
    }
  }

  return FilePicker.platform.saveFile(
    dialogTitle: dialogTitle,
    fileName: fileName,
    type: allowedExtensions.isEmpty ? FileType.any : FileType.custom,
    allowedExtensions: allowedExtensions.isEmpty ? null : allowedExtensions,
    initialDirectory: initialDirectory,
    lockParentWindow: true,
  );
}

Future<String?> pickDirectoryPathWithFallback({
  required String dialogTitle,
  String? initialDirectory,
}) async {
  if (_useNativeLinuxFileDialog) {
    try {
      return await _linuxFileDialogChannel.invokeMethod<String>(
        'pickDirectory',
        <String, Object?>{
          'title': dialogTitle,
          if (initialDirectory != null) 'initialDirectory': initialDirectory,
        },
      );
    } on MissingPluginException {
      // Keep tests and older Linux bundles usable while they are upgraded.
    } on PlatformException {
      // Fall through to file_picker if GTK cannot create a native dialog.
    }
  }

  return FilePicker.platform.getDirectoryPath(
    dialogTitle: dialogTitle,
    initialDirectory: initialDirectory,
    lockParentWindow: true,
  );
}

Future<String?> saveBytesWithFilePicker({
  required String dialogTitle,
  required String fileName,
  required List<String> allowedExtensions,
  required Uint8List bytes,
  String? initialDirectory,
  bool? mobileOverride,
  bool? webOverride,
  PlatformSaveDialog? saveDialog,
}) async {
  final web = webOverride ?? kIsWeb;
  final mobile =
      mobileOverride ?? (!web && (Platform.isAndroid || Platform.isIOS));
  if (web && saveDialog == null) {
    return downloadBytesInBrowser(fileName, bytes);
  }
  final dialog = saveDialog ??
      (Uint8List? payload) async {
        if (_useNativeLinuxFileDialog) {
          return saveFilePathWithFallback(
            dialogTitle: dialogTitle,
            fileName: fileName,
            allowedExtensions: allowedExtensions,
            initialDirectory: initialDirectory,
          );
        }
        return FilePicker.platform.saveFile(
          dialogTitle: dialogTitle,
          fileName: fileName,
          type: Platform.isAndroid ? FileType.any : FileType.custom,
          allowedExtensions: Platform.isAndroid ? null : allowedExtensions,
          bytes: payload,
          initialDirectory: initialDirectory,
          lockParentWindow: !mobile,
        );
      };
  var path = await dialog((mobile || web) ? bytes : null);
  if (path == null || path.trim().isEmpty) return null;

  if (!mobile && !web) {
    final hasAllowedExtension = allowedExtensions.any(
      (extension) =>
          path!.toLowerCase().endsWith('.${extension.toLowerCase()}'),
    );
    if (!hasAllowedExtension && allowedExtensions.isNotEmpty) {
      path = '$path.${allowedExtensions.first}';
    }
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return path;
}
