import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _systemFontsChannel = MethodChannel('mdslens/system_fonts');

Future<List<String>> loadSystemFontFamilies() async {
  if (!(Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isWindows ||
      Platform.isLinux)) {
    return const [];
  }
  return await _systemFontsChannel.invokeListMethod<String>('listFamilies') ??
      const [];
}

Future<void> prepareSystemFontFamily(String family) async {}
