import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

typedef PlatformSaveDialog = Future<String?> Function(Uint8List? bytes);

Future<String?> saveBytesWithFilePicker({
  required String dialogTitle,
  required String fileName,
  required List<String> allowedExtensions,
  required Uint8List bytes,
  bool? mobileOverride,
  PlatformSaveDialog? saveDialog,
}) async {
  final mobile = mobileOverride ?? (Platform.isAndroid || Platform.isIOS);
  final dialog = saveDialog ??
      (Uint8List? payload) => FilePicker.platform.saveFile(
            dialogTitle: dialogTitle,
            fileName: fileName,
            type: FileType.custom,
            allowedExtensions: allowedExtensions,
            bytes: payload,
            lockParentWindow: !mobile,
          );
  var path = await dialog(mobile ? bytes : null);
  if (path == null || path.trim().isEmpty) return null;

  if (!mobile) {
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
