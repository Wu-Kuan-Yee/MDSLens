import 'package:flutter/services.dart';

Future<String> loadLanguageAsset(
  String path, {
  bool preferFileSystem = false,
}) =>
    rootBundle.loadString(path);
