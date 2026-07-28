import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum MdsShortcutCommand {
  pointMode,
  zoomMode,
  focusShot,
  toggleRefresh,
  maximizePanel,
  showAllPanels,
  resetCurrentScale,
  resetAllScales,
  previousShot,
  nextShot,
  latestShot,
  pointPrevious,
  pointNext,
  panelLeft,
  panelDown,
  panelUp,
  panelRight,
  exitPoint,
}

class MdsShortcutDefinition {
  const MdsShortcutDefinition(this.command, this.id, this.category, this.label);

  final MdsShortcutCommand command;
  final String id;
  final String category;
  final String label;
}

const mdsShortcutDefinitions = <MdsShortcutDefinition>[
  MdsShortcutDefinition(
    MdsShortcutCommand.pointMode,
    'point_mode',
    'General',
    'Point mode',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.zoomMode,
    'zoom_mode',
    'General',
    'Zoom / Move mode',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.focusShot,
    'focus_shot',
    'General',
    'Focus shot input',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.toggleRefresh,
    'toggle_refresh',
    'General',
    'Stop / refresh',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.maximizePanel,
    'maximize_panel',
    'Panel',
    'Maximize selected panel',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.showAllPanels,
    'show_all_panels',
    'Panel',
    'Show all panels',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.resetCurrentScale,
    'reset_current_scale',
    'Panel',
    'Reset selected panel scale',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.resetAllScales,
    'reset_all_scales',
    'Panel',
    'Reset all panel scales',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.previousShot,
    'previous_shot',
    'Shot',
    'Previous shot',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.nextShot,
    'next_shot',
    'Shot',
    'Next shot',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.latestShot,
    'latest_shot',
    'Shot',
    'Latest shot',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.pointPrevious,
    'point_previous',
    'Point tracking',
    'Move Point left',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.pointNext,
    'point_next',
    'Point tracking',
    'Move Point right',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.exitPoint,
    'exit_point',
    'Point tracking',
    'Lock or exit Point tracking',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.panelLeft,
    'panel_left',
    'Panel navigation',
    'Select panel left',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.panelDown,
    'panel_down',
    'Panel navigation',
    'Select panel down',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.panelUp,
    'panel_up',
    'Panel navigation',
    'Select panel up',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.panelRight,
    'panel_right',
    'Panel navigation',
    'Select panel right',
  ),
];

MdsShortcutDefinition shortcutDefinition(MdsShortcutCommand command) =>
    mdsShortcutDefinitions.firstWhere(
      (definition) => definition.command == command,
    );

class MdsShortcutStroke {
  const MdsShortcutStroke(
    this.key, {
    this.control = false,
    this.alt = false,
    this.shift = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool control;
  final bool alt;
  final bool shift;
  final bool meta;

  SingleActivator get activator => SingleActivator(
        key,
        control: control,
        alt: alt,
        shift: shift,
        meta: meta,
      );

  String get portableText {
    final parts = <String>[
      if (control) 'Ctrl',
      if (alt) 'Alt',
      if (shift) 'Shift',
      if (meta) 'Meta',
      key.keyLabel.isNotEmpty ? key.keyLabel : key.debugName ?? 'Key',
    ];
    return parts.join('+');
  }

  String get displayText {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      return [
        if (control) '⌃',
        if (alt) '⌥',
        if (shift) '⇧',
        if (meta) '⌘',
        _displayKey(key),
      ].join();
    }
    return portableText.replaceAll('Meta', 'Super');
  }

  Map<String, dynamic> toJson() => {
        'keyId': key.keyId,
        'control': control,
        'alt': alt,
        'shift': shift,
        'meta': meta,
      };

  static MdsShortcutStroke? fromJson(dynamic value) {
    if (value is! Map || value['keyId'] is! num) return null;
    final key = LogicalKeyboardKey.findKeyByKeyId(
      (value['keyId'] as num).toInt(),
    );
    if (key == null || _isModifierKey(key)) return null;
    return MdsShortcutStroke(
      key,
      control: value['control'] == true,
      alt: value['alt'] == true,
      shift: value['shift'] == true,
      meta: value['meta'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MdsShortcutStroke &&
      other.key == key &&
      other.control == control &&
      other.alt == alt &&
      other.shift == shift &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, control, alt, shift, meta);
}

class MdsShortcutBinding {
  const MdsShortcutBinding({this.primary, this.alternative});

  final MdsShortcutStroke? primary;
  final MdsShortcutStroke? alternative;

  MdsShortcutBinding copyWith({
    MdsShortcutStroke? primary,
    MdsShortcutStroke? alternative,
    bool clearPrimary = false,
    bool clearAlternative = false,
  }) =>
      MdsShortcutBinding(
        primary: clearPrimary ? null : primary ?? this.primary,
        alternative: clearAlternative ? null : alternative ?? this.alternative,
      );

  Iterable<MdsShortcutStroke> get strokes sync* {
    if (primary != null) yield primary!;
    if (alternative != null) yield alternative!;
  }

  Map<String, dynamic> toJson() => {
        'primary': primary?.toJson(),
        'alternative': alternative?.toJson(),
      };
}

Map<MdsShortcutCommand, MdsShortcutBinding> defaultMdsShortcutBindings() {
  final platform = defaultTargetPlatform;
  final mac = platform == TargetPlatform.macOS;
  final linux = platform == TargetPlatform.linux;
  MdsShortcutStroke modified(LogicalKeyboardKey key, {bool shift = false}) =>
      MdsShortcutStroke(key, control: !mac, meta: mac, shift: shift);

  return {
    MdsShortcutCommand.pointMode: MdsShortcutBinding(
      primary: modified(LogicalKeyboardKey.keyP),
    ),
    MdsShortcutCommand.zoomMode: MdsShortcutBinding(
      primary: modified(LogicalKeyboardKey.keyZ),
    ),
    MdsShortcutCommand.focusShot: const MdsShortcutBinding(
      primary: MdsShortcutStroke(LogicalKeyboardKey.keyI),
    ),
    MdsShortcutCommand.toggleRefresh: const MdsShortcutBinding(
      primary: MdsShortcutStroke(LogicalKeyboardKey.space),
    ),
    MdsShortcutCommand.maximizePanel: MdsShortcutBinding(
      primary: mac
          ? const MdsShortcutStroke(
              LogicalKeyboardKey.keyM,
              control: true,
            )
          : modified(LogicalKeyboardKey.keyM),
    ),
    MdsShortcutCommand.showAllPanels: MdsShortcutBinding(
      primary: modified(LogicalKeyboardKey.keyA),
    ),
    MdsShortcutCommand.resetCurrentScale: MdsShortcutBinding(
      primary: modified(LogicalKeyboardKey.keyR),
    ),
    MdsShortcutCommand.resetAllScales: MdsShortcutBinding(
      primary: modified(LogicalKeyboardKey.keyR, shift: true),
    ),
    MdsShortcutCommand.previousShot: MdsShortcutBinding(
      primary: modified(
        linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
      ),
    ),
    MdsShortcutCommand.nextShot: MdsShortcutBinding(
      primary: modified(
        linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
      ),
    ),
    MdsShortcutCommand.latestShot: MdsShortcutBinding(
      primary: modified(
        linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
        shift: true,
      ),
    ),
    MdsShortcutCommand.pointPrevious: MdsShortcutBinding(
      primary: MdsShortcutStroke(
        linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
      ),
    ),
    MdsShortcutCommand.pointNext: MdsShortcutBinding(
      primary: MdsShortcutStroke(
        linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
      ),
    ),
    MdsShortcutCommand.exitPoint: const MdsShortcutBinding(
      primary: MdsShortcutStroke(LogicalKeyboardKey.escape),
    ),
    MdsShortcutCommand.panelLeft: MdsShortcutBinding(
      primary: MdsShortcutStroke(
        linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
        alt: true,
      ),
    ),
    MdsShortcutCommand.panelDown: MdsShortcutBinding(
      primary: MdsShortcutStroke(
        linux ? LogicalKeyboardKey.keyJ : LogicalKeyboardKey.arrowDown,
        alt: true,
      ),
    ),
    MdsShortcutCommand.panelUp: MdsShortcutBinding(
      primary: MdsShortcutStroke(
        linux ? LogicalKeyboardKey.keyK : LogicalKeyboardKey.arrowUp,
        alt: true,
      ),
    ),
    MdsShortcutCommand.panelRight: MdsShortcutBinding(
      primary: MdsShortcutStroke(
        linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
        alt: true,
      ),
    ),
  };
}

Map<MdsShortcutCommand, MdsShortcutBinding> decodeMdsShortcutBindings(
  dynamic value,
) {
  final result = defaultMdsShortcutBindings();
  if (value is! Map) return result;
  for (final definition in mdsShortcutDefinitions) {
    final raw = value[definition.id];
    if (raw is! Map) continue;
    result[definition.command] = MdsShortcutBinding(
      primary: MdsShortcutStroke.fromJson(raw['primary']),
      alternative: MdsShortcutStroke.fromJson(raw['alternative']),
    );
  }
  return result;
}

Map<String, dynamic> encodeMdsShortcutBindings(
  Map<MdsShortcutCommand, MdsShortcutBinding> bindings,
) =>
    {
      for (final definition in mdsShortcutDefinitions)
        definition.id: bindings[definition.command]?.toJson() ??
            const MdsShortcutBinding().toJson(),
    };

MdsShortcutStroke? shortcutStrokeFromEvent(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return null;
  if (_isModifierKey(event.logicalKey)) return null;
  final keyboard = HardwareKeyboard.instance;
  return MdsShortcutStroke(
    event.logicalKey,
    control: keyboard.isControlPressed,
    alt: keyboard.isAltPressed,
    shift: keyboard.isShiftPressed,
    meta: keyboard.isMetaPressed,
  );
}

bool _isModifierKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.controlLeft ||
    key == LogicalKeyboardKey.controlRight ||
    key == LogicalKeyboardKey.altLeft ||
    key == LogicalKeyboardKey.altRight ||
    key == LogicalKeyboardKey.shiftLeft ||
    key == LogicalKeyboardKey.shiftRight ||
    key == LogicalKeyboardKey.metaLeft ||
    key == LogicalKeyboardKey.metaRight;

String _displayKey(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.arrowLeft) return '←';
  if (key == LogicalKeyboardKey.arrowRight) return '→';
  if (key == LogicalKeyboardKey.arrowUp) return '↑';
  if (key == LogicalKeyboardKey.arrowDown) return '↓';
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.space) return 'Space';
  return key.keyLabel.isNotEmpty ? key.keyLabel : key.debugName ?? 'Key';
}

String shortcutPlatformDescription() {
  if (defaultTargetPlatform == TargetPlatform.macOS) {
    return 'macOS defaults use Command shortcuts and native key symbols.';
  }
  if (defaultTargetPlatform == TargetPlatform.windows) {
    return 'Windows defaults use Ctrl shortcuts and arrow-key navigation.';
  }
  if (defaultTargetPlatform == TargetPlatform.linux) {
    return 'Linux defaults include H/J/K/L navigation alongside Ctrl shortcuts.';
  }
  return 'Shortcuts take effect when a hardware keyboard is connected.';
}
