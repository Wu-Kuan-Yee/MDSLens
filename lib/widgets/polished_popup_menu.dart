import 'package:flutter/material.dart';
import '../services/keyboard_shortcuts.dart';

class PolishedPopupMenuOption<T> {
  const PolishedPopupMenuOption({
    required this.value,
    required this.label,
    required this.icon,
    required this.id,
  });

  final T value;
  final String label;
  final IconData icon;
  final String id;
}

class PolishedPopupMenuGroup<T> {
  const PolishedPopupMenuGroup({required this.label, required this.options});

  final String label;
  final List<PolishedPopupMenuOption<T>> options;
}

class _KeyboardPopupMenuItem<T> extends PopupMenuItem<T> {
  const _KeyboardPopupMenuItem({
    super.key,
    required super.value,
    required super.child,
    required this.shortcuts,
    super.height,
    super.padding,
  });

  final Map<ShortcutActivator, Intent> shortcuts;

  @override
  PopupMenuItemState<T, _KeyboardPopupMenuItem<T>> createState() =>
      _KeyboardPopupMenuItemState<T>();
}

class _KeyboardPopupMenuItemState<T>
    extends PopupMenuItemState<T, _KeyboardPopupMenuItem<T>> {
  @override
  Widget build(BuildContext context) => Shortcuts(
        shortcuts: widget.shortcuts,
        child: super.build(context),
      );
}

Map<ShortcutActivator, Intent> _menuShortcutBindings(
  Map<MdsShortcutCommand, MdsShortcutBinding>? configured,
) {
  final bindings = configured ?? defaultMdsShortcutBindings();
  final result = <ShortcutActivator, Intent>{};

  void add(MdsShortcutCommand command, Intent intent) {
    final binding = bindings[command];
    if (binding == null) return;
    for (final sequence in binding.sequences) {
      if (sequence.isSingle) {
        result[sequence.strokes.single.activator] = intent;
      }
    }
  }

  add(MdsShortcutCommand.menuLeft, const PreviousFocusIntent());
  add(MdsShortcutCommand.menuDown, const NextFocusIntent());
  add(MdsShortcutCommand.menuUp, const PreviousFocusIntent());
  add(MdsShortcutCommand.menuRight, const NextFocusIntent());
  add(MdsShortcutCommand.menuActivate, const ActivateIntent());
  return result;
}

Future<T?> showPolishedPopupMenu<T>({
  required BuildContext context,
  required Offset globalPosition,
  required String id,
  required List<PolishedPopupMenuGroup<T>> groups,
  Map<MdsShortcutCommand, MdsShortcutBinding>? keyboardShortcuts,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final overlay =
      Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final anchor = overlay.globalToLocal(globalPosition);
  final position = RelativeRect.fromLTRB(
    anchor.dx,
    anchor.dy,
    (overlay.size.width - anchor.dx).clamp(0, overlay.size.width),
    (overlay.size.height - anchor.dy).clamp(0, overlay.size.height),
  );

  final entries = <PopupMenuEntry<T>>[];
  final menuShortcuts = _menuShortcutBindings(keyboardShortcuts);
  for (var groupIndex = 0; groupIndex < groups.length; groupIndex++) {
    final group = groups[groupIndex];
    if (groupIndex > 0) {
      entries.add(
        PopupMenuDivider(
          key: ValueKey('$id-group-divider-$groupIndex'),
          height: 10,
        ),
      );
    }
    entries.add(
      PopupMenuItem<T>(
        key: ValueKey('$id-group-$groupIndex'),
        enabled: false,
        height: 27,
        padding: const EdgeInsets.fromLTRB(14, 5, 14, 2),
        child: Text(
          group.label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: colors.primary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
    for (
      var optionIndex = 0;
      optionIndex < group.options.length;
      optionIndex++
    ) {
      if (optionIndex > 0) {
        entries.add(
          PopupMenuDivider(
            key: ValueKey('$id-option-divider-$groupIndex-$optionIndex'),
            height: 1,
          ),
        );
      }
      final option = group.options[optionIndex];
      entries.add(
        _KeyboardPopupMenuItem<T>(
          key: ValueKey('$id-${option.id}'),
          value: option.value,
          shortcuts: menuShortcuts,
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.11),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(option.icon, size: 19, color: colors.primary),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  option.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurface,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      );
    }
  }

  return showMenu<T>(
    context: context,
    position: position,
    color: colors.surfaceContainerHigh,
    surfaceTintColor: Colors.transparent,
    elevation: 18,
    shadowColor: colors.shadow.withValues(alpha: 0.32),
    menuPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
    constraints: const BoxConstraints(minWidth: 250, maxWidth: 300),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(15),
      side: BorderSide(color: colors.outlineVariant),
    ),
    popUpAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 160),
      reverseDuration: Duration(milliseconds: 110),
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    ),
    items: entries,
  );
}
