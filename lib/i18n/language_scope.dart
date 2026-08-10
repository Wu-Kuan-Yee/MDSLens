import 'package:flutter/widgets.dart';

import 'language_service.dart';

class LanguageScope extends InheritedNotifier<LanguageService> {
  const LanguageScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static LanguageService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LanguageScope>()?.notifier;
}

extension TranslatedBuildContext on BuildContext {
  String tr(
    String key, [
    Map<String, Object?> parameters = const {},
  ]) =>
      LanguageScope.maybeOf(this)?.translate(key, parameters) ??
      _fallbackTranslation(key, parameters);
}

String _fallbackTranslation(
  String key,
  Map<String, Object?> parameters,
) {
  var value = key;
  if (parameters.isNotEmpty) {
    value = value.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (match) {
      final replacement = parameters[match.group(1)];
      return replacement?.toString() ?? match.group(0)!;
    });
  }
  return value;
}
