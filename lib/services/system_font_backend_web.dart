import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/services.dart';

@JS('mdslensLocalFontFamilies')
external JSPromise<JSArray<JSString>> _localFontFamilies();

@JS('mdslensLocalFontBytes')
external JSPromise<JSArrayBuffer?> _localFontBytes(JSString family);

final Set<String> _loadedFamilies = {};

Future<List<String>> loadSystemFontFamilies() async {
  try {
    final values = await _localFontFamilies().toDart;
    final families = values.toDart.map((value) => value.toDart).toSet().toList()
      ..add('MDSLens Noto Sans SC')
      ..sort((left, right) => left.compareTo(right));
    return families;
  } catch (_) {
    // Safari, Firefox, permission denial, and managed browser policies may all
    // block Local Font Access. Offer only the font that is actually bundled
    // and therefore guaranteed to render, rather than listing fake choices.
    return const ['MDSLens Noto Sans SC'];
  }
}

Future<void> prepareSystemFontFamily(String family) async {
  if (family == 'MDSLens Noto Sans SC') return;
  if (!_loadedFamilies.add(family)) return;
  try {
    final buffer = await _localFontBytes(family.toJS).toDart;
    if (buffer == null) {
      _loadedFamilies.remove(family);
      return;
    }
    final bytes = buffer.toDart.asUint8List();
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
  } catch (_) {
    _loadedFamilies.remove(family);
    rethrow;
  }
}
