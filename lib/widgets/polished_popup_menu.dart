import 'package:mdslens/i18n/localized_material.dart';
import 'package:flutter/services.dart';
import '../services/keyboard_shortcuts.dart';
import 'vim_focus.dart';

class PolishedPopupMenuOption<T> {
  const PolishedPopupMenuOption({
    required this.value,
    required this.label,
    required this.icon,
    required this.id,
    this.shortcutCommand,
  });

  final T value;
  final String label;
  final IconData icon;
  final String id;
  final MdsShortcutCommand? shortcutCommand;
}

class PolishedPopupMenuGroup<T> {
  const PolishedPopupMenuGroup({required this.label, required this.options});

  final String label;
  final List<PolishedPopupMenuOption<T>> options;
}

class _PopupVimFocusFrame extends StatelessWidget {
  const _PopupVimFocusFrame({
    required this.visible,
    required this.child,
  });

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
        fit: StackFit.passthrough,
        children: [
          child,
          if (visible)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  key: const ValueKey('vim-popup-focus-ring'),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: const Color(0xFFE040FB),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
        ],
      );
}

class _KeyboardPopupMenuItem<T> extends PopupMenuItem<T> {
  const _KeyboardPopupMenuItem({
    super.key,
    required super.value,
    required super.child,
    required this.keyboardShortcuts,
    required this.dispatcher,
    required this.autofocus,
    required this.vimMode,
    super.height,
    super.padding,
  });

  final Map<MdsShortcutCommand, MdsShortcutBinding> keyboardShortcuts;
  final MdsShortcutDispatcher dispatcher;
  final bool autofocus;
  final bool vimMode;

  @override
  PopupMenuItemState<T, _KeyboardPopupMenuItem<T>> createState() =>
      _KeyboardPopupMenuItemState<T>();
}

class _KeyboardPopupMenuItemState<T>
    extends PopupMenuItemState<T, _KeyboardPopupMenuItem<T>> {
  FocusNode? _menuFocusNode;
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    if (!widget.autofocus) return;
    _menuFocusNode = FocusNode(debugLabel: 'polished-popup-menu-item');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestInitialFocus();
    });
  }

  @override
  void dispose() {
    _menuFocusNode?.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.vimMode &&
        (event is KeyDownEvent || event is KeyRepeatEvent) &&
        !_hasModifier(event)) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.keyH:
        case LogicalKeyboardKey.arrowLeft:
          _moveMenuFocus(context, backward: true);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyK:
        case LogicalKeyboardKey.arrowUp:
          _moveMenuFocus(context, backward: true);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyJ:
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.keyL:
        case LogicalKeyboardKey.arrowRight:
          _moveMenuFocus(context, backward: false);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.enter:
          handleTap();
          return KeyEventResult.handled;
        default:
          break;
      }
    }
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

  bool _hasModifier(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    return keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed ||
        keyboard.isShiftPressed;
  }

  void _triggerMenuShortcut(
    BuildContext context,
    MdsShortcutCommand command,
  ) {
    switch (command) {
      case MdsShortcutCommand.menuLeft:
      case MdsShortcutCommand.menuUp:
        _moveMenuFocus(context, backward: true);
        break;
      case MdsShortcutCommand.menuDown:
      case MdsShortcutCommand.menuRight:
        _moveMenuFocus(context, backward: false);
        break;
      case MdsShortcutCommand.menuActivate:
        handleTap();
        break;
      default:
        break;
    }
  }

  void _moveMenuFocus(BuildContext context, {required bool backward}) {
    final current = FocusManager.instance.primaryFocus;
    final policy = FocusTraversalGroup.maybeOf(context);
    if (current != null && policy != null) {
      final moved = policy.inDirection(
        current,
        backward ? TraversalDirection.up : TraversalDirection.down,
      );
      if (moved) return;
    }
    final scope = FocusScope.of(context);
    final moved = backward ? scope.previousFocus() : scope.nextFocus();
    if (moved) return;

    // Keep menu navigation inside this popup and wrap at its edges. The
    // directional policy can otherwise jump between visually unrelated menu
    // groups, especially when a menu is opened near a screen edge.
    final descendants = scope.traversalDescendants
        .where((node) => node.canRequestFocus && !node.skipTraversal)
        .toList(growable: false);
    if (descendants.isEmpty) return;
    (backward ? descendants.last : descendants.first).requestFocus();
  }

  void _requestInitialFocus() {
    if (!widget.autofocus || !mounted) return;
    _menuFocusNode?.requestFocus();
    // PopupMenuRoute may perform its own focus request after the first frame;
    // repeat once so the first enabled option remains the actual Vim target.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _menuFocusNode?.requestFocus();
    });
  }

  void _handleFocusChange(bool focused) {
    if (_hasFocus == focused || !mounted) return;
    setState(() => _hasFocus = focused);
  }

  @override
  Widget build(BuildContext context) {
    final item = super.build(context);
    return VimPageScope(
      pageId: 'popup-menu',
      parentPageId: 'root',
      transient: true,
      child: Focus(
        focusNode: _menuFocusNode,
        autofocus: widget.autofocus,
        onFocusChange: _handleFocusChange,
        onKeyEvent: _handleKeyEvent,
        child: _PopupVimFocusFrame(
          visible: widget.vimMode && _hasFocus,
          child: item,
        ),
      ),
    );
  }
}

/// A plain Material popup item with a deterministic focus target. Flutter's
/// stock [PopupMenuItem] exposes a focusable InkWell, but it does not provide
/// an initial focus request or an activation handler for an ancestor Vim
/// focus node. This small variant keeps the stock visuals while making the
/// first item reliably selectable with Enter.
class VimPopupMenuItem<T> extends PopupMenuItem<T> {
  const VimPopupMenuItem({
    super.key,
    required super.value,
    required super.child,
    this.autofocus = false,
    this.debugLabel,
    super.height,
    super.padding,
    super.enabled,
    super.onTap,
    super.labelTextStyle,
    super.mouseCursor,
  });

  final bool autofocus;
  final String? debugLabel;

  @override
  PopupMenuItemState<T, VimPopupMenuItem<T>> createState() =>
      _VimPopupMenuItemState<T>();
}

class _VimPopupMenuItemState<T>
    extends PopupMenuItemState<T, VimPopupMenuItem<T>> {
  FocusNode? _focusNode;
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(
      debugLabel: widget.debugLabel ?? 'vim-popup-menu-item',
    );
    if (!widget.autofocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestInitialFocus();
    });
  }

  @override
  void dispose() {
    _focusNode?.dispose();
    super.dispose();
  }

  void _requestInitialFocus() {
    if (!mounted || !widget.enabled) return;
    _focusNode?.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled) _focusNode?.requestFocus();
    });
  }

  void _handleFocusChange(bool focused) {
    if (_hasFocus == focused || !mounted) return;
    setState(() => _hasFocus = focused);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (VimModeScope.enabled(context)) {
      switch (event.logicalKey) {
        case LogicalKeyboardKey.keyH:
        case LogicalKeyboardKey.keyK:
        case LogicalKeyboardKey.arrowLeft:
        case LogicalKeyboardKey.arrowUp:
          _moveMenuFocus(backward: true);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.keyJ:
        case LogicalKeyboardKey.keyL:
        case LogicalKeyboardKey.arrowDown:
        case LogicalKeyboardKey.arrowRight:
          _moveMenuFocus(backward: false);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.escape:
          if (!leaveVimPageToParent(context)) {
            Navigator.of(context).maybePop();
          }
          return KeyEventResult.handled;
        default:
          break;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.space) {
      handleTap();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveMenuFocus({required bool backward}) {
    final scope = FocusScope.of(context);
    final current = _focusNode;
    if (current == null) return;
    final descendants = scope.traversalDescendants
        .where(
          (candidate) =>
              candidate.canRequestFocus &&
              !candidate.skipTraversal &&
              candidate.context
                      ?.findAncestorWidgetOfExactType<VimPageScope>()
                      ?.pageId ==
                  'popup-menu',
        )
        .toList(growable: false);
    if (descendants.isEmpty) return;
    final index = descendants.indexOf(current);
    if (index < 0) {
      (backward ? descendants.last : descendants.first).requestFocus();
      return;
    }
    var nextIndex = index + (backward ? -1 : 1);
    if (nextIndex < 0) nextIndex = descendants.length - 1;
    if (nextIndex >= descendants.length) nextIndex = 0;
    final next = descendants[nextIndex];
    next.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final item = super.build(context);
    return VimPageScope(
      pageId: 'popup-menu',
      parentPageId: 'root',
      transient: true,
      child: Focus(
        focusNode: _focusNode,
        autofocus: widget.autofocus,
        descendantsAreTraversable: false,
        onFocusChange: _handleFocusChange,
        onKeyEvent: _handleKeyEvent,
        child: _PopupVimFocusFrame(
          visible: VimModeScope.enabled(context) && _hasFocus,
          child: item,
        ),
      ),
    );
  }
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
  bool vimMode = false,
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
      final shortcut = option.shortcutCommand == null
          ? ''
          : (keyboardShortcuts ?? const {})[option.shortcutCommand!]
                  ?.sequences
                  .map((sequence) => sequence.displayText)
                  .join(' / ') ??
              '';
      final translatedLabel = context.tr(option.label);
      final optionTooltip = shortcut.isEmpty
          ? translatedLabel
          : '$translatedLabel ($shortcut)';
      entries.add(
        _KeyboardPopupMenuItem<T>(
          key: ValueKey('$id-${option.id}'),
          value: option.value,
          keyboardShortcuts: menuShortcuts,
          dispatcher: menuDispatcher,
          autofocus: groupIndex == 0 && optionIndex == 0,
          vimMode: vimMode,
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Tooltip(
            message: optionTooltip,
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
                    translatedLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (shortcut.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    '($shortcut)',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(width: 6),
              ],
            ),
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
    requestFocus: true,
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
