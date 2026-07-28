import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/services/keyboard_shortcuts.dart';

void main() {
  test('platform defaults assign unique active shortcut strokes', () {
    final bindings = defaultMdsShortcutBindings();
    final strokes = [
      for (final binding in bindings.values) ...binding.strokes,
    ];

    expect(strokes, isNotEmpty);
    expect(strokes.toSet().length, strokes.length);
    expect(bindings[MdsShortcutCommand.exitPoint]!.primary!.key,
        LogicalKeyboardKey.escape);
  });

  test('shortcut settings survive JSON encoding and decoding', () {
    final defaults = defaultMdsShortcutBindings();
    final customized = Map<MdsShortcutCommand, MdsShortcutBinding>.of(defaults)
      ..[MdsShortcutCommand.pointMode] = const MdsShortcutBinding(
        primary: MdsShortcutStroke(
          LogicalKeyboardKey.keyG,
          control: true,
          shift: true,
        ),
        alternative: MdsShortcutStroke(LogicalKeyboardKey.f8),
      )
      ..[MdsShortcutCommand.latestShot] = const MdsShortcutBinding();

    final decoded = decodeMdsShortcutBindings(
      encodeMdsShortcutBindings(customized),
    );

    expect(
      decoded[MdsShortcutCommand.pointMode]!.primary,
      customized[MdsShortcutCommand.pointMode]!.primary,
    );
    expect(
      decoded[MdsShortcutCommand.pointMode]!.alternative,
      customized[MdsShortcutCommand.pointMode]!.alternative,
    );
    expect(decoded[MdsShortcutCommand.latestShot]!.primary, isNull);
  });
}
