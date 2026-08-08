import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/services/keyboard_shortcuts.dart';

void main() {
  test('platform defaults expose scoped shortcut sequences', () {
    final bindings = defaultMdsShortcutBindings();

    expect(bindings, contains(MdsShortcutCommand.openFile));
    expect(bindings, contains(MdsShortcutCommand.openRecentFiles));
    expect(bindings, contains(MdsShortcutCommand.refreshData));
    expect(bindings, contains(MdsShortcutCommand.toggleVimMode));
    expect(bindings, contains(MdsShortcutCommand.panelSetup));
    expect(bindings, contains(MdsShortcutCommand.menuActivate));
    expect(
      bindings[MdsShortcutCommand.resetAllScales]!.primary!.strokes.length,
      2,
    );
    expect(
      bindings[MdsShortcutCommand.resetCurrentScale]!.primary!.strokes,
      hasLength(2),
    );
    expect(
      bindings[MdsShortcutCommand.resetCurrentScale]!
          .primary!
          .strokes
          .first
          .key,
      LogicalKeyboardKey.keyR,
    );
    expect(
      bindings[MdsShortcutCommand.resetAllScales]!.primary!.strokes.first.key,
      LogicalKeyboardKey.keyR,
    );
    expect(
      bindings[MdsShortcutCommand.panelLeft]!.primary!.strokes.single.alt,
      isFalse,
    );
    final recent = bindings[MdsShortcutCommand.openRecentFiles]!.primary!;
    expect(recent.strokes.single.key, LogicalKeyboardKey.keyO);
    expect(recent.strokes.single.shift, isTrue);
    final toggleVim = bindings[MdsShortcutCommand.toggleVimMode]!.primary!;
    expect(toggleVim.strokes, hasLength(1));
    expect(toggleVim.strokes.single.key, LogicalKeyboardKey.keyV);
    expect(toggleVim.strokes.single.alt, isTrue);
    expect(
      toggleVim.strokes.single.meta,
      defaultTargetPlatform == TargetPlatform.macOS,
    );
    expect(
      toggleVim.strokes.single.control,
      defaultTargetPlatform != TargetPlatform.macOS,
    );
    expect(
      fixedPointSeriesOrdinal(
        const MdsShortcutStroke(LogicalKeyboardKey.digit3),
      ),
      2,
    );
    expect(
      fixedPointSeriesOrdinal(
        const MdsShortcutStroke(LogicalKeyboardKey.digit3, control: true),
      ),
      isNull,
    );
    final exitSequence = bindings[MdsShortcutCommand.exitPoint]!.primary!;
    expect(
      exitSequence.strokes.first.key,
      defaultTargetPlatform == TargetPlatform.linux
          ? LogicalKeyboardKey.keyJ
          : LogicalKeyboardKey.escape,
    );
    if (defaultTargetPlatform == TargetPlatform.linux) {
      expect(exitSequence.strokes, hasLength(2));
      expect(
        bindings[MdsShortcutCommand.exitPoint]!.alternative!.strokes.single.key,
        LogicalKeyboardKey.escape,
      );
    }
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
      defaultMdsShortcutBindings()[MdsShortcutCommand.refreshData]!
          .primary!
          .displayText,
    );
    expect(
      decoded[MdsShortcutCommand.resetAllScales]!.primary!.strokes.length,
      2,
    );
  });

  test('legacy temporary panel and scale mappings migrate to original defaults',
      () {
    final defaults = defaultMdsShortcutBindings();
    final legacy = encodeMdsShortcutBindings(defaults);
    final panel = MdsShortcutCommand.panelLeft;
    legacy[shortcutDefinition(panel).id] = MdsShortcutBinding(
      primary: MdsShortcutSequence.single(
        MdsShortcutStroke(
          defaultTargetPlatform == TargetPlatform.linux
              ? LogicalKeyboardKey.keyH
              : LogicalKeyboardKey.arrowLeft,
          alt: true,
        ),
      ),
    ).toJson();
    legacy[shortcutDefinition(MdsShortcutCommand.resetCurrentScale).id] =
        MdsShortcutBinding(
      primary: MdsShortcutSequence.single(
        MdsShortcutStroke(
          LogicalKeyboardKey.keyR,
          control: defaultTargetPlatform != TargetPlatform.macOS,
          meta: defaultTargetPlatform == TargetPlatform.macOS,
        ),
      ),
    ).toJson();

    final decoded = decodeMdsShortcutBindings(legacy);
    expect(
      decoded[panel]!.primary!.strokes.single.alt,
      isFalse,
    );
    expect(
      decoded[MdsShortcutCommand.resetCurrentScale]!.primary!.strokes,
      hasLength(2),
    );
  });

  test('sequence settings round-trip while accepting legacy single strokes',
      () {
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

  test('shortcut sequences are capped at four strokes when restored', () {
    final sequence = MdsShortcutSequence([
      MdsShortcutStroke(LogicalKeyboardKey.keyA),
      MdsShortcutStroke(LogicalKeyboardKey.keyB),
      MdsShortcutStroke(LogicalKeyboardKey.keyC),
      MdsShortcutStroke(LogicalKeyboardKey.keyD),
      MdsShortcutStroke(LogicalKeyboardKey.keyE),
    ]);
    expect(sequence.strokes, hasLength(4));
    expect(sequence.strokes.last.key, LogicalKeyboardKey.keyD);
  });

  test('dispatcher waits for a longer sequence before firing its prefix', () {
    final bindings = <MdsShortcutCommand, MdsShortcutBinding>{
      MdsShortcutCommand.showAllPanels: MdsShortcutBinding(
        primary: MdsShortcutSequence.single(
          MdsShortcutStroke(LogicalKeyboardKey.keyA, control: true),
        ),
      ),
      MdsShortcutCommand.resetAllScales: MdsShortcutBinding(
        primary: MdsShortcutSequence([
          MdsShortcutStroke(LogicalKeyboardKey.keyA, control: true),
          MdsShortcutStroke(LogicalKeyboardKey.keyR),
        ]),
      ),
    };
    final dispatcher = MdsShortcutDispatcher(
      sequenceTimeout: const Duration(milliseconds: 20),
    );
    final triggered = <MdsShortcutCommand>[];
    final first = dispatcher.handle(
      MdsShortcutStroke(LogicalKeyboardKey.keyA, control: true),
      bindings: bindings,
      isEnabled: (_) => true,
      onTrigger: triggered.add,
    );
    expect(first, isTrue);
    expect(triggered, isEmpty);
    dispatcher.handle(
      MdsShortcutStroke(LogicalKeyboardKey.keyR),
      bindings: bindings,
      isEnabled: (_) => true,
      onTrigger: triggered.add,
    );
    expect(triggered, [MdsShortcutCommand.resetAllScales]);
    dispatcher.dispose();
  });

  test('dispatcher fires a prefix command when the sequence times out',
      () async {
    final bindings = <MdsShortcutCommand, MdsShortcutBinding>{
      MdsShortcutCommand.showAllPanels: MdsShortcutBinding(
        primary: MdsShortcutSequence.single(
          MdsShortcutStroke(LogicalKeyboardKey.keyA, control: true),
        ),
      ),
      MdsShortcutCommand.resetAllScales: MdsShortcutBinding(
        primary: MdsShortcutSequence([
          MdsShortcutStroke(LogicalKeyboardKey.keyA, control: true),
          MdsShortcutStroke(LogicalKeyboardKey.keyR),
        ]),
      ),
    };
    final dispatcher = MdsShortcutDispatcher(
      sequenceTimeout: const Duration(milliseconds: 1),
    );
    final triggered = <MdsShortcutCommand>[];
    dispatcher.handle(
      MdsShortcutStroke(LogicalKeyboardKey.keyA, control: true),
      bindings: bindings,
      isEnabled: (_) => true,
      onTrigger: triggered.add,
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(triggered, [MdsShortcutCommand.showAllPanels]);
    dispatcher.dispose();
  });

  test('Linux Point lock chord wins over the H/J/K/L navigation prefix', () {
    final bindings = <MdsShortcutCommand, MdsShortcutBinding>{
      MdsShortcutCommand.panelDown: MdsShortcutBinding(
        primary: MdsShortcutSequence.single(
          MdsShortcutStroke(LogicalKeyboardKey.keyJ),
        ),
      ),
      MdsShortcutCommand.exitPoint: MdsShortcutBinding(
        primary: MdsShortcutSequence([
          MdsShortcutStroke(LogicalKeyboardKey.keyJ),
          MdsShortcutStroke(LogicalKeyboardKey.keyK),
        ]),
      ),
    };
    final dispatcher = MdsShortcutDispatcher();
    final triggered = <MdsShortcutCommand>[];

    expect(
      dispatcher.handle(
        const MdsShortcutStroke(LogicalKeyboardKey.keyJ),
        bindings: bindings,
        isEnabled: (_) => true,
        onTrigger: triggered.add,
      ),
      isTrue,
    );
    expect(triggered, isEmpty);

    expect(
      dispatcher.handle(
        const MdsShortcutStroke(LogicalKeyboardKey.keyK),
        bindings: bindings,
        isEnabled: (_) => true,
        onTrigger: triggered.add,
      ),
      isTrue,
    );
    expect(triggered, [MdsShortcutCommand.exitPoint]);
    dispatcher.dispose();
  });
}
