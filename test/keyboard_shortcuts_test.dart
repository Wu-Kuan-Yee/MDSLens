import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/services/keyboard_shortcuts.dart';

void main() {
  test('platform defaults expose scoped shortcut sequences', () {
    final bindings = defaultMdsShortcutBindings();

    expect(bindings, contains(MdsShortcutCommand.openFile));
    expect(bindings, contains(MdsShortcutCommand.refreshData));
    expect(bindings, contains(MdsShortcutCommand.panelSetup));
    expect(bindings, contains(MdsShortcutCommand.menuActivate));
    expect(
      bindings[MdsShortcutCommand.resetAllScales]!.primary!.strokes.length,
      2,
    );
    expect(
      bindings[MdsShortcutCommand.exitPoint]!.primary!.strokes.single.key,
      LogicalKeyboardKey.escape,
    );
  });

  test('shortcut settings survive JSON encoding and decoding', () {
    final defaults = defaultMdsShortcutBindings();
    final customized = Map<MdsShortcutCommand, MdsShortcutBinding>.of(defaults)
      ..[MdsShortcutCommand.pointMode] = MdsShortcutBinding(
        primary: MdsShortcutSequence.single(
          MdsShortcutStroke(
            LogicalKeyboardKey.keyG,
            control: true,
            shift: true,
          ),
        ),
        alternative: MdsShortcutSequence.single(
          MdsShortcutStroke(LogicalKeyboardKey.f8),
        ),
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

  test('Restore defaults repopulates every empty shortcut binding', () {
    final restored = restoredDefaultMdsShortcutBindings();

    expect(restored.keys, containsAll(MdsShortcutCommand.values));
    expect(restored.length, MdsShortcutCommand.values.length);
    expect(restored[MdsShortcutCommand.pointMode]!.primary, isNotNull);
    expect(restored[MdsShortcutCommand.latestShot]!.primary, isNotNull);
    expect(
      restored[MdsShortcutCommand.exitPoint]!.primary!.strokes.single.key,
      LogicalKeyboardKey.escape,
    );
  });

  test('legacy reset shortcut migrates to the new refresh command', () {
    final legacy = <String, dynamic>{
      'reset_all_scales': {
        'primary': MdsShortcutStroke(
          LogicalKeyboardKey.keyR,
          control: defaultTargetPlatform != TargetPlatform.macOS,
          meta: defaultTargetPlatform == TargetPlatform.macOS,
          shift: true,
        ).toJson(),
        'alternative': null,
      },
    };

    final decoded = decodeMdsShortcutBindings(legacy);
    expect(
      decoded[MdsShortcutCommand.refreshData]!.primary!.displayText,
      defaultMdsShortcutBindings()
          [MdsShortcutCommand.refreshData]!
          .primary!
          .displayText,
    );
    expect(
      decoded[MdsShortcutCommand.resetAllScales]!.primary!.strokes.length,
      2,
    );
  });

  test('sequence settings round-trip while accepting legacy single strokes', () {
    final sequence = MdsShortcutSequence([
      MdsShortcutStroke(LogicalKeyboardKey.keyG, control: true),
      MdsShortcutStroke(LogicalKeyboardKey.keyL),
    ]);
    final encoded = sequence.toJson();
    expect(MdsShortcutSequence.fromJson(encoded), sequence);
    final legacy = MdsShortcutSequence.fromJson(
      MdsShortcutStroke(LogicalKeyboardKey.keyP).toJson(),
    );
    expect(legacy?.strokes.single.key, LogicalKeyboardKey.keyP);
  });
}
