import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

enum MdsShortcutCommand {
  openFile,
  openRecentFiles,
  openWebMenu,
  saveConfiguration,
  globalRate,
  globalLayout,
  globalExport,
  pointMode,
  zoomMode,
  focusShot,
  refreshData,
  toggleRefresh,
  maximizePanel,
  showAllPanels,
  resetCurrentScale,
  resetAllScales,
  sameXScale,
  sameYScale,
  previousShot,
  nextShot,
  latestShot,
  pointPrevious,
  pointNext,
  panelRate,
  panelSourceSetup,
  panelExport,
  panelSetup,
  panelLeft,
  panelDown,
  panelUp,
  panelRight,
  exitPoint,
  menuLeft,
  menuDown,
  menuUp,
  menuRight,
  menuActivate,
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
    MdsShortcutCommand.openFile,
    'open_file',
    'General',
    'Open configuration',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.openRecentFiles,
    'open_recent_files',
    'General',
    'Open recent configurations',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.openWebMenu,
    'open_web_menu',
    'General',
    'Open internal web pages',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.saveConfiguration,
    'save_configuration',
    'General',
    'Save configuration',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.globalRate,
    'global_rate',
    'Global',
    'Global rate',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.globalLayout,
    'global_layout',
    'Global',
    'Layout setup',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.globalExport,
    'global_export',
    'Global',
    'Export data',
  ),
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
    MdsShortcutCommand.refreshData,
    'refresh_data',
    'General',
    'Refresh data',
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
    MdsShortcutCommand.sameXScale,
    'same_x_scale',
    'Panel',
    'Use the same X scale',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.sameYScale,
    'same_y_scale',
    'Panel',
    'Use the same Y scale',
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
    MdsShortcutCommand.panelRate,
    'panel_rate',
    'Current panel',
    'Current panel rate',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.panelSourceSetup,
    'panel_source_setup',
    'Current panel',
    'Current panel data source',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.panelExport,
    'panel_export',
    'Current panel',
    'Export current panel',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.panelSetup,
    'panel_setup',
    'Current panel',
    'Current panel setup',
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
  MdsShortcutDefinition(
    MdsShortcutCommand.menuLeft,
    'menu_left',
    'Popup menu navigation',
    'Move left / close submenu',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.menuDown,
    'menu_down',
    'Popup menu navigation',
    'Move down',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.menuUp,
    'menu_up',
    'Popup menu navigation',
    'Move up',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.menuRight,
    'menu_right',
    'Popup menu navigation',
    'Move right / open submenu',
  ),
  MdsShortcutDefinition(
    MdsShortcutCommand.menuActivate,
    'menu_activate',
    'Popup menu navigation',
    'Activate selected item',
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

/// A shortcut may contain up to four key combinations, matching the
/// multi-stroke shortcuts supported by the desktop version.  A one-stroke
/// sequence is used for the existing shortcuts and is encoded in the legacy
/// stroke shape so older MDSLens settings remain readable.
class MdsShortcutSequence {
  MdsShortcutSequence(Iterable<MdsShortcutStroke> strokes)
      : strokes = _normalize(strokes);

  MdsShortcutSequence.single(MdsShortcutStroke stroke)
      : strokes = List.unmodifiable(<MdsShortcutStroke>[stroke]);

  final List<MdsShortcutStroke> strokes;

  static List<MdsShortcutStroke> _normalize(
    Iterable<MdsShortcutStroke> raw,
  ) {
    final result = raw.take(4).toList(growable: false);
    return List.unmodifiable(result);
  }

  bool get isEmpty => strokes.isEmpty;
  bool get isSingle => strokes.length == 1;

  String get portableText =>
      strokes.map((stroke) => stroke.portableText).join(', ');

  String get displayText =>
      strokes.map((stroke) => stroke.displayText).join(', ');

  Map<String, dynamic> toJson() {
    if (isSingle) return strokes.first.toJson();
    return {
      'strokes': [for (final stroke in strokes) stroke.toJson()],
    };
  }

  static MdsShortcutSequence? fromJson(dynamic value) {
    if (value is Map && value['strokes'] is List) {
      final strokes = <MdsShortcutStroke>[];
      for (final raw in value['strokes'] as List) {
        final stroke = MdsShortcutStroke.fromJson(raw);
        if (stroke == null) return null;
        strokes.add(stroke);
      }
      return strokes.isEmpty ? null : MdsShortcutSequence(strokes);
    }
    final stroke = MdsShortcutStroke.fromJson(value);
    return stroke == null ? null : MdsShortcutSequence.single(stroke);
  }

  @override
  bool operator ==(Object other) =>
      other is MdsShortcutSequence && listEquals(other.strokes, strokes);

  @override
  int get hashCode => Object.hashAll(strokes);
}

class MdsShortcutBinding {
  const MdsShortcutBinding({this.primary, this.alternative});

  final MdsShortcutSequence? primary;
  final MdsShortcutSequence? alternative;

  MdsShortcutBinding copyWith({
    MdsShortcutSequence? primary,
    MdsShortcutSequence? alternative,
    bool clearPrimary = false,
    bool clearAlternative = false,
  }) =>
      MdsShortcutBinding(
        primary: clearPrimary ? null : primary ?? this.primary,
        alternative: clearAlternative ? null : alternative ?? this.alternative,
      );

  Iterable<MdsShortcutStroke> get strokes sync* {
    if (primary != null) yield* primary!.strokes;
    if (alternative != null) yield* alternative!.strokes;
  }

  Iterable<MdsShortcutSequence> get sequences sync* {
    if (primary != null && !primary!.isEmpty) yield primary!;
    if (alternative != null && !alternative!.isEmpty) yield alternative!;
  }

  @override
  bool operator ==(Object other) =>
      other is MdsShortcutBinding &&
      other.primary == primary &&
      other.alternative == alternative;

  @override
  int get hashCode => Object.hash(primary, alternative);

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
  MdsShortcutSequence single(MdsShortcutStroke stroke) =>
      MdsShortcutSequence.single(stroke);
  MdsShortcutSequence modifiedSequence(
    LogicalKeyboardKey key, {
    bool shift = false,
  }) =>
      single(modified(key, shift: shift));
  MdsShortcutSequence chord(
    LogicalKeyboardKey first,
    LogicalKeyboardKey second, {
    bool shift = false,
  }) =>
      MdsShortcutSequence([
        modified(first, shift: shift),
        MdsShortcutStroke(second),
      ]);
  MdsShortcutSequence popupNavigation(LogicalKeyboardKey key) =>
      single(MdsShortcutStroke(key));

  return {
    MdsShortcutCommand.openFile: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyO),
    ),
    MdsShortcutCommand.openRecentFiles: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyO, shift: true),
    ),
    MdsShortcutCommand.openWebMenu: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyW),
    ),
    MdsShortcutCommand.saveConfiguration: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyS),
    ),
    MdsShortcutCommand.globalRate: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyG, LogicalKeyboardKey.keyR),
    ),
    MdsShortcutCommand.globalLayout: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyG, LogicalKeyboardKey.keyL),
    ),
    MdsShortcutCommand.globalExport: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyE),
    ),
    MdsShortcutCommand.pointMode: MdsShortcutBinding(
      primary: single(modified(LogicalKeyboardKey.keyP)),
    ),
    MdsShortcutCommand.zoomMode: MdsShortcutBinding(
      primary: single(modified(LogicalKeyboardKey.keyZ)),
    ),
    MdsShortcutCommand.focusShot: MdsShortcutBinding(
      primary: MdsShortcutSequence.single(
        MdsShortcutStroke(LogicalKeyboardKey.keyI),
      ),
    ),
    MdsShortcutCommand.refreshData: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyR, shift: true),
    ),
    MdsShortcutCommand.toggleRefresh: MdsShortcutBinding(
      primary: MdsShortcutSequence.single(
        MdsShortcutStroke(LogicalKeyboardKey.space),
      ),
    ),
    MdsShortcutCommand.maximizePanel: MdsShortcutBinding(
      primary: single(
        mac
            ? const MdsShortcutStroke(
                LogicalKeyboardKey.keyM,
                control: true,
              )
            : modified(LogicalKeyboardKey.keyM),
      ),
    ),
    MdsShortcutCommand.showAllPanels: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyA),
    ),
    MdsShortcutCommand.resetCurrentScale: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyR, LogicalKeyboardKey.keyC),
    ),
    MdsShortcutCommand.resetAllScales: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyR, LogicalKeyboardKey.keyA),
    ),
    MdsShortcutCommand.sameXScale: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyX),
    ),
    MdsShortcutCommand.sameYScale: MdsShortcutBinding(
      primary: modifiedSequence(LogicalKeyboardKey.keyY),
    ),
    MdsShortcutCommand.previousShot: MdsShortcutBinding(
      primary: single(
        modified(
          linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
        ),
      ),
    ),
    MdsShortcutCommand.nextShot: MdsShortcutBinding(
      primary: single(
        modified(
          linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
        ),
      ),
    ),
    MdsShortcutCommand.latestShot: MdsShortcutBinding(
      primary: single(
        modified(
          linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
          shift: true,
        ),
      ),
    ),
    MdsShortcutCommand.pointPrevious: MdsShortcutBinding(
      primary: single(
        MdsShortcutStroke(
          linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
        ),
      ),
    ),
    MdsShortcutCommand.pointNext: MdsShortcutBinding(
      primary: single(
        MdsShortcutStroke(
          linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
        ),
      ),
    ),
    MdsShortcutCommand.exitPoint: MdsShortcutBinding(
      primary: linux
          ? chord(LogicalKeyboardKey.keyJ, LogicalKeyboardKey.keyK)
          : MdsShortcutSequence.single(
              MdsShortcutStroke(LogicalKeyboardKey.escape),
            ),
      alternative: linux
          ? MdsShortcutSequence.single(
              MdsShortcutStroke(LogicalKeyboardKey.escape),
            )
          : null,
    ),
    MdsShortcutCommand.panelRate: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyT, LogicalKeyboardKey.keyR),
    ),
    MdsShortcutCommand.panelSourceSetup: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyT, LogicalKeyboardKey.keyS),
    ),
    MdsShortcutCommand.panelExport: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyT, LogicalKeyboardKey.keyE),
    ),
    MdsShortcutCommand.panelSetup: MdsShortcutBinding(
      primary: chord(LogicalKeyboardKey.keyT, LogicalKeyboardKey.keyP),
    ),
    MdsShortcutCommand.panelLeft: MdsShortcutBinding(
      primary: single(
        MdsShortcutStroke(
          linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
        ),
      ),
    ),
    MdsShortcutCommand.panelDown: MdsShortcutBinding(
      primary: single(
        MdsShortcutStroke(
          linux ? LogicalKeyboardKey.keyJ : LogicalKeyboardKey.arrowDown,
        ),
      ),
    ),
    MdsShortcutCommand.panelUp: MdsShortcutBinding(
      primary: single(
        MdsShortcutStroke(
          linux ? LogicalKeyboardKey.keyK : LogicalKeyboardKey.arrowUp,
        ),
      ),
    ),
    MdsShortcutCommand.panelRight: MdsShortcutBinding(
      primary: single(
        MdsShortcutStroke(
          linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
        ),
      ),
    ),
    MdsShortcutCommand.menuLeft: MdsShortcutBinding(
      primary: popupNavigation(
        linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
      ),
    ),
    MdsShortcutCommand.menuDown: MdsShortcutBinding(
      primary: popupNavigation(
        linux ? LogicalKeyboardKey.keyJ : LogicalKeyboardKey.arrowDown,
      ),
    ),
    MdsShortcutCommand.menuUp: MdsShortcutBinding(
      primary: popupNavigation(
        linux ? LogicalKeyboardKey.keyK : LogicalKeyboardKey.arrowUp,
      ),
    ),
    MdsShortcutCommand.menuRight: MdsShortcutBinding(
      primary: popupNavigation(
        linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
      ),
    ),
    MdsShortcutCommand.menuActivate: MdsShortcutBinding(
      primary: MdsShortcutSequence.single(
        MdsShortcutStroke(LogicalKeyboardKey.enter),
      ),
    ),
  };
}

Map<MdsShortcutCommand, MdsShortcutBinding>
    restoredDefaultMdsShortcutBindings() {
  final defaults = defaultMdsShortcutBindings();
  return {
    for (final definition in mdsShortcutDefinitions)
      definition.command:
          defaults[definition.command] ?? const MdsShortcutBinding(),
  };
}

Map<MdsShortcutCommand, MdsShortcutBinding> decodeMdsShortcutBindings(
  dynamic value,
) {
  final defaults = defaultMdsShortcutBindings();
  final result = Map<MdsShortcutCommand, MdsShortcutBinding>.of(defaults);
  if (value is! Map) return result;
  final hasRefreshBinding = value.containsKey('refresh_data');
  for (final definition in mdsShortcutDefinitions) {
    final raw = value[definition.id];
    if (raw is! Map) continue;
    result[definition.command] = MdsShortcutBinding(
      primary: MdsShortcutSequence.fromJson(raw['primary']),
      alternative: MdsShortcutSequence.fromJson(raw['alternative']),
    );
  }
  // Older MDSLens builds persisted a few temporary mappings while the
  // desktop shortcut set was being brought in.  Treat those exact old
  // defaults as defaults rather than preserving them forever, while leaving
  // every other user-customized binding untouched.
  final legacyDefaults = _legacyMdsShortcutBindings();
  for (final entry in legacyDefaults.entries) {
    if (result[entry.key] == entry.value) {
      result[entry.key] = defaults[entry.key]!;
    }
  }
  // MDSLens used Ctrl/Cmd+Shift+R for Reset All before Refresh had its own
  // command. Preserve that old setting as the new Refresh shortcut, while
  // moving Reset All to the original Ctrl/Cmd+R, A sequence. An
  // explicitly saved refresh binding (including an empty one) always wins.
  if (!hasRefreshBinding) {
    final legacyReset = result[MdsShortcutCommand.resetAllScales]?.primary;
    final legacyRefresh = _legacyRefreshSequence();
    if (legacyReset == legacyRefresh && legacyRefresh != null) {
      result[MdsShortcutCommand.refreshData] = MdsShortcutBinding(
        primary: legacyRefresh,
      );
      result[MdsShortcutCommand.resetAllScales] =
          defaults[MdsShortcutCommand.resetAllScales]!;
    }
  }
  return result;
}

Map<MdsShortcutCommand, MdsShortcutBinding> _legacyMdsShortcutBindings() {
  final platform = defaultTargetPlatform;
  final mac = platform == TargetPlatform.macOS;
  final linux = platform == TargetPlatform.linux;
  MdsShortcutStroke modified(LogicalKeyboardKey key, {bool shift = false}) =>
      MdsShortcutStroke(key, control: !mac, meta: mac, shift: shift);
  final panelKeys = <MdsShortcutCommand, LogicalKeyboardKey>{
    MdsShortcutCommand.panelLeft:
        linux ? LogicalKeyboardKey.keyH : LogicalKeyboardKey.arrowLeft,
    MdsShortcutCommand.panelDown:
        linux ? LogicalKeyboardKey.keyJ : LogicalKeyboardKey.arrowDown,
    MdsShortcutCommand.panelUp:
        linux ? LogicalKeyboardKey.keyK : LogicalKeyboardKey.arrowUp,
    MdsShortcutCommand.panelRight:
        linux ? LogicalKeyboardKey.keyL : LogicalKeyboardKey.arrowRight,
  };
  return {
    ...{
      MdsShortcutCommand.resetCurrentScale: MdsShortcutBinding(
        primary: MdsShortcutSequence.single(modified(LogicalKeyboardKey.keyR)),
      ),
      MdsShortcutCommand.resetAllScales: MdsShortcutBinding(
        primary: MdsShortcutSequence([
          modified(LogicalKeyboardKey.keyA),
          const MdsShortcutStroke(LogicalKeyboardKey.keyR),
        ]),
      ),
      if (linux)
        MdsShortcutCommand.exitPoint: MdsShortcutBinding(
          primary: MdsShortcutSequence.single(
            MdsShortcutStroke(LogicalKeyboardKey.escape),
          ),
        ),
    },
    for (final entry in panelKeys.entries)
      entry.key: MdsShortcutBinding(
        primary: MdsShortcutSequence.single(
          MdsShortcutStroke(entry.value, alt: true),
        ),
      ),
  };
}

MdsShortcutSequence? _legacyRefreshSequence() {
  final platform = defaultTargetPlatform;
  final mac = platform == TargetPlatform.macOS;
  return MdsShortcutSequence.single(
    MdsShortcutStroke(
      LogicalKeyboardKey.keyR,
      control: !mac,
      meta: mac,
      shift: true,
    ),
  );
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

typedef MdsShortcutCommandEnabled = bool Function(MdsShortcutCommand command);
typedef MdsShortcutCommandCallback = void Function(
  MdsShortcutCommand command,
);

/// Matches configurable single- and multi-stroke shortcuts without stealing
/// a key that belongs to a longer sequence. For example, Ctrl+A can remain a
/// usable command while Ctrl+A, R is also assigned to another command.
class MdsShortcutDispatcher {
  MdsShortcutDispatcher(
      {this.sequenceTimeout = const Duration(milliseconds: 850)});

  final Duration sequenceTimeout;
  final _pending = <MdsShortcutStroke>[];
  Timer? _timer;
  MdsShortcutCommand? _pendingExact;

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _pendingExact = null;
  }

  void reset() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _pendingExact = null;
  }

  bool handle(
    MdsShortcutStroke stroke, {
    required Map<MdsShortcutCommand, MdsShortcutBinding> bindings,
    required MdsShortcutCommandEnabled isEnabled,
    required MdsShortcutCommandCallback onTrigger,
  }) {
    final candidate = [..._pending, stroke];
    final result = _match(
      candidate,
      bindings: bindings,
      isEnabled: isEnabled,
    );
    if (result.exact != null && result.partial) {
      _pending
        ..clear()
        ..addAll(candidate);
      _pendingExact = result.exact;
      _schedule(bindings: bindings, isEnabled: isEnabled, onTrigger: onTrigger);
      return true;
    }
    if (result.exact != null) {
      reset();
      onTrigger(result.exact!);
      return true;
    }
    if (result.partial) {
      _pending
        ..clear()
        ..addAll(candidate);
      _pendingExact = null;
      _schedule(bindings: bindings, isEnabled: isEnabled, onTrigger: onTrigger);
      return true;
    }

    if (_pending.isNotEmpty) {
      final delayed = _pendingExact;
      reset();
      if (delayed != null && isEnabled(delayed)) {
        onTrigger(delayed);
      }
      final fresh = _match(
        [stroke],
        bindings: bindings,
        isEnabled: isEnabled,
      );
      if (fresh.exact != null) {
        onTrigger(fresh.exact!);
        return true;
      }
      if (fresh.partial) {
        _pending.add(stroke);
        _schedule(
          bindings: bindings,
          isEnabled: isEnabled,
          onTrigger: onTrigger,
        );
        return true;
      }
      return delayed != null;
    }
    return false;
  }

  _ShortcutMatch _match(
    List<MdsShortcutStroke> candidate, {
    required Map<MdsShortcutCommand, MdsShortcutBinding> bindings,
    required MdsShortcutCommandEnabled isEnabled,
  }) {
    MdsShortcutCommand? exact;
    var partial = false;
    for (final entry in bindings.entries) {
      if (!isEnabled(entry.key)) continue;
      for (final sequence in entry.value.sequences) {
        if (_sameStrokes(sequence.strokes, candidate)) {
          exact ??= entry.key;
        } else if (_startsWith(sequence.strokes, candidate)) {
          partial = true;
        }
      }
    }
    return _ShortcutMatch(exact: exact, partial: partial);
  }

  void _schedule({
    required Map<MdsShortcutCommand, MdsShortcutBinding> bindings,
    required MdsShortcutCommandEnabled isEnabled,
    required MdsShortcutCommandCallback onTrigger,
  }) {
    _timer?.cancel();
    _timer = Timer(sequenceTimeout, () {
      final command = _pendingExact;
      reset();
      if (command != null && isEnabled(command)) onTrigger(command);
    });
  }

  static bool _sameStrokes(
    List<MdsShortcutStroke> first,
    List<MdsShortcutStroke> second,
  ) =>
      first.length == second.length &&
      first.asMap().entries.every((entry) => entry.value == second[entry.key]);

  static bool _startsWith(
    List<MdsShortcutStroke> sequence,
    List<MdsShortcutStroke> prefix,
  ) =>
      prefix.isNotEmpty &&
      prefix.length < sequence.length &&
      prefix
          .asMap()
          .entries
          .every((entry) => sequence[entry.key] == entry.value);
}

class _ShortcutMatch {
  const _ShortcutMatch({required this.exact, required this.partial});

  final MdsShortcutCommand? exact;
  final bool partial;
}
