import 'dart:io';

import 'package:flutter/services.dart';

Future<String> loadLanguageAsset(
  String path, {
  bool preferFileSystem = false,
}) {
  // testWidgets runs in Flutter's fake-async zone, where an unpumped dart:io
  // Future can never complete. The files are small language catalogs, so the
  // test-only path intentionally reads them synchronously.
  if (preferFileSystem) {
    return Future<String>.value(File(path).readAsStringSync());
  }
  return rootBundle.loadString(path);
}
