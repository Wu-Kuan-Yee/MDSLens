import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import 'browser_download.dart';

typedef PlatformSaveDialog = Future<String?> Function(Uint8List? bytes);

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
      (Uint8List? payload) => FilePicker.platform.saveFile(
            dialogTitle: dialogTitle,
            fileName: fileName,
            type: Platform.isAndroid ? FileType.any : FileType.custom,
            allowedExtensions: Platform.isAndroid ? null : allowedExtensions,
            bytes: payload,
            initialDirectory: initialDirectory,
            lockParentWindow: !mobile,
          );
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
