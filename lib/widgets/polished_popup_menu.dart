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
    required this.keyboardShortcuts,
    required this.dispatcher,
    required this.autofocus,
    super.height,
    super.padding,
  });

  final Map<MdsShortcutCommand, MdsShortcutBinding> keyboardShortcuts;
  final MdsShortcutDispatcher dispatcher;
  final bool autofocus;

  @override
  PopupMenuItemState<T, _KeyboardPopupMenuItem<T>> createState() =>
      _KeyboardPopupMenuItemState<T>();
}

class _KeyboardPopupMenuItemState<T>
    extends PopupMenuItemState<T, _KeyboardPopupMenuItem<T>> {
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final stroke = shortcutStrokeFromEvent(event);
    if (stroke == null) return KeyEventResult.ignored;
    final handled = widget.dispatcher.handle(
      stroke,
      bindings: widget.keyboardShortcuts,
      isEnabled: (_) => true,
      onTrigger: (command) => _triggerMenuShortcut(context, command),
    );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _triggerMenuShortcut(
    BuildContext context,
    MdsShortcutCommand command,
  ) {
    switch (command) {
      case MdsShortcutCommand.menuLeft:
      case MdsShortcutCommand.menuUp:
        FocusScope.of(context).previousFocus();
        break;
      case MdsShortcutCommand.menuDown:
      case MdsShortcutCommand.menuRight:
        FocusScope.of(context).nextFocus();
        break;
      case MdsShortcutCommand.menuActivate:
        handleTap();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
        autofocus: widget.autofocus,
        onKeyEvent: _handleKeyEvent,
        child: super.build(context),
      );
}

Map<MdsShortcutCommand, MdsShortcutBinding> _menuShortcutBindings(
  Map<MdsShortcutCommand, MdsShortcutBinding>? configured,
) {
  final bindings = configured ?? defaultMdsShortcutBindings();
  return {
    for (final command in const [
      MdsShortcutCommand.menuLeft,
      MdsShortcutCommand.menuDown,
      MdsShortcutCommand.menuUp,
      MdsShortcutCommand.menuRight,
      MdsShortcutCommand.menuActivate,
    ])
      if (bindings.containsKey(command)) command: bindings[command]!,
  };
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
  final menuDispatcher = MdsShortcutDispatcher();
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
    for (var optionIndex = 0;
        optionIndex < group.options.length;
        optionIndex++) {
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
          keyboardShortcuts: menuShortcuts,
          dispatcher: menuDispatcher,
          autofocus: groupIndex == 0 && optionIndex == 0,
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

  final menu = showMenu<T>(
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
  return menu.whenComplete(menuDispatcher.dispose);
}
