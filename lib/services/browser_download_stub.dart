import 'dart:typed_data';

Future<String> downloadBytesInBrowser(
  String fileName,
  Uint8List bytes, {
  String mimeType = 'application/octet-stream',
}) {
  throw UnsupportedError('Browser downloads are only available on the web.');
}
