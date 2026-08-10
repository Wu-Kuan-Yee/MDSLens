import 'dart:async';
import 'dart:math' as math;

import 'package:mdslens/i18n/localized_material.dart';
import 'package:flutter/services.dart';
import 'vim_focus.dart';

class PolishedDropdownOption<T> {
  const PolishedDropdownOption({
    required this.value,
    required this.label,
    this.icon,
    this.fontFamily,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? fontFamily;
}

class PolishedDropdownAction {
  const PolishedDropdownAction({
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final bool destructive;
}

class PolishedDropdown<T> extends StatefulWidget {
  const PolishedDropdown({
    super.key,
    required this.id,
    required this.value,
    required this.options,
    required this.onChanged,
    this.leadingIcon,
    this.height = 44,
    this.fontSize,
    this.minimumMenuWidth = 172,
    this.menuMaxHeight = 280,
    this.showScrollbar = false,
    this.iconOnly = false,
    this.tooltip,
    this.menuAction,
  });

  final String id;
  final T value;
  final List<PolishedDropdownOption<T>> options;
  final ValueChanged<T> onChanged;
  final IconData? leadingIcon;
  final double height;
  final double? fontSize;
  final double minimumMenuWidth;
  final double menuMaxHeight;

  /// Shows an always-visible, draggable scrollbar inside long option lists.
  ///
  /// Most dropdowns are short enough for MenuAnchor's native clipping. Long
  /// catalogs (for example the CLDR locale registry) opt in so a user can
  /// discover and drag the viewport directly on desktop and touch devices.
  final bool showScrollbar;
  final bool iconOnly;
  final String? tooltip;
  final PolishedDropdownAction? menuAction;

  @override
  State<PolishedDropdown<T>> createState() => _PolishedDropdownState<T>();
}

class _PolishedDropdownState<T> extends State<PolishedDropdown<T>> {
  bool _open = false;
  MenuController? _menuController;
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'dropdown-${widget.id}',
  );
  FocusNode? _actionFocusNode;
  final List<FocusNode> _optionFocusNodes = <FocusNode>[];
  Timer? _menuSequenceTimer;
  bool _pendingMenuG = false;

  @override
  void initState() {
    super.initState();
    _syncMenuFocusNodes();
  }

  @override
  void didUpdateWidget(covariant PolishedDropdown<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncMenuFocusNodes();
  }

  void _syncMenuFocusNodes() {
    if (widget.menuAction != null && _actionFocusNode == null) {
      _actionFocusNode = FocusNode(
        debugLabel: 'dropdown-${widget.id}-menu-action',
      );
    } else if (widget.menuAction == null && _actionFocusNode != null) {
      _actionFocusNode!.dispose();
      _actionFocusNode = null;
    }
    while (_optionFocusNodes.length < widget.options.length) {
      final index = _optionFocusNodes.length;
      _optionFocusNodes.add(
        FocusNode(debugLabel: 'dropdown-${widget.id}-option-$index'),
      );
    }
    while (_optionFocusNodes.length > widget.options.length) {
      _optionFocusNodes.removeLast().dispose();
    }
  }

  void _focusFirstOption() {
    if (!_open || _optionFocusNodes.isEmpty) return;
    void request() {
      if (!_open || !mounted || _optionFocusNodes.isEmpty) return;
      (_actionFocusNode ?? _optionFocusNodes.first).requestFocus();
    }

    // MenuAnchor inserts its menu route after onOpen. The second frame is
    // intentional: it makes the first option deterministic even when the
    // menu has an entrance animation or is opened from a keyboard event.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      request();
      WidgetsBinding.instance.addPostFrameCallback((_) => request());
    });
  }

  List<FocusNode> get _menuFocusNodes => <FocusNode>[
        if (_actionFocusNode != null) _actionFocusNode!,
        ..._optionFocusNodes,
      ];

  void _clearMenuSequence() {
    _pendingMenuG = false;
    _menuSequenceTimer?.cancel();
    _menuSequenceTimer = null;
  }

  void _focusMenuNode(FocusNode node) {
    node.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = node.context;
      if (!_open ||
          !mounted ||
          targetContext == null ||
          !targetContext.mounted) {
        return;
      }
      // A tall MenuAnchor uses an internal viewport. Reveal the new focused
      // entry explicitly so Vim navigation never leaves its frame hidden
      // below the clipped edge of the menu.
      Scrollable.ensureVisible(
        targetContext,
        alignment: 0.35,
        duration: Duration.zero,
      );
    });
  }

  void _moveMenuFocus(int delta) {
    final nodes = _menuFocusNodes;
    if (nodes.isEmpty) return;
    var current = nodes.indexWhere((node) => node.hasFocus);
    if (current < 0) current = delta >= 0 ? -1 : 0;
    final next = (current + delta).clamp(0, nodes.length - 1).toInt();
    _focusMenuNode(nodes[next]);
  }

  void _moveMenuFocusToEdge({required bool last}) {
    final nodes = _menuFocusNodes;
    if (nodes.isEmpty) return;
    _focusMenuNode(last ? nodes.last : nodes.first);
  }

  int _menuPageStep() {
    final targetContext = FocusManager.instance.primaryFocus?.context;
    final scrollable =
        targetContext == null ? null : Scrollable.maybeOf(targetContext);
    final viewportHeight = scrollable?.position.hasContentDimensions == true
        ? scrollable!.position.viewportDimension
        : widget.menuMaxHeight;
    final visible =
        (viewportHeight / 48).floor().clamp(1, _menuFocusNodes.length);
    return visible > 1 ? visible - 1 : 1;
  }

  void _moveMenuFocusByPage({required bool forward}) {
    final nodes = _menuFocusNodes;
    if (nodes.isEmpty) return;
    var current = nodes.indexWhere((node) => node.hasFocus);
    if (current < 0) current = forward ? 0 : nodes.length - 1;
    final step = _menuPageStep();
    final next =
        (current + (forward ? step : -step)).clamp(0, nodes.length - 1).toInt();
    _focusMenuNode(nodes[next]);
  }

  KeyEventResult _handleMenuKey(KeyEvent event) {
    if (!_open || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        !keyboard.isShiftPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        _moveMenuFocusByPage(forward: true);
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyB) {
        _moveMenuFocusByPage(forward: false);
        return KeyEventResult.handled;
      }
    }
    if (!keyboard.isControlPressed &&
        !keyboard.isAltPressed &&
        !keyboard.isMetaPressed &&
        event.logicalKey == LogicalKeyboardKey.keyG) {
      if (keyboard.isShiftPressed) {
        _clearMenuSequence();
        _moveMenuFocusToEdge(last: true);
        return KeyEventResult.handled;
      }
      if (_pendingMenuG) {
        _clearMenuSequence();
        _moveMenuFocusToEdge(last: false);
        return KeyEventResult.handled;
      }
      _pendingMenuG = true;
      _menuSequenceTimer?.cancel();
      _menuSequenceTimer = Timer(const Duration(milliseconds: 850), () {
        if (mounted) _clearMenuSequence();
      });
      return KeyEventResult.handled;
    }
    if (_pendingMenuG) _clearMenuSequence();
    if (event.logicalKey == LogicalKeyboardKey.keyJ ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveMenuFocus(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyK ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveMenuFocus(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _menuController?.close();
      _focusNode.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _menuSequenceTimer?.cancel();
    _focusNode.dispose();
    _actionFocusNode?.dispose();
    for (final node in _optionFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final selected = widget.options.firstWhere(
      (option) => option.value == widget.value,
      orElse: () => widget.options.first,
    );
    // MenuAnchor positions the overlay near the trigger, but on narrow
    // screens its maximum width must still fit inside the viewport. Otherwise
    // the right edge (especially the scrollbar thumb) is clipped by the
    // overlay's hard viewport boundary.
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final maximumMenuWidth = math.max(
      96.0,
      math.min(360.0, viewportWidth - 24),
    );
    final menuWidth = math.min(
      math.max(120.0, widget.minimumMenuWidth),
      maximumMenuWidth,
    );
    final menuItems = <Widget>[
      if (widget.menuAction != null) ...[
        _withMenuVimNavigation(
          _menuAction(context, widget.menuAction!),
          onActivate: () => _activateMenuAction(widget.menuAction!),
        ),
        Divider(
          key: ValueKey('${widget.id}-action-divider'),
          height: 7,
          indent: 8,
          endIndent: 8,
          color: theme.dividerColor.withValues(alpha: 0.7),
        ),
      ],
      for (var index = 0; index < widget.options.length; index++) ...[
        if (index > 0)
          Divider(
            key: ValueKey('${widget.id}-divider-$index'),
            height: 1,
            indent: 10,
            endIndent: 10,
            color: theme.dividerColor.withValues(alpha: 0.55),
          ),
        _withMenuVimNavigation(
          _menuOption(context, widget.options[index], index),
          onActivate: () {
            _menuController?.close();
            widget.onChanged(widget.options[index].value);
          },
        ),
      ],
    ];
    final menuAnchor = MenuAnchor(
      // Flutter's cascading menu animation creates invalid Intervals for a
      // long history/options list. The anchor itself remains animated; keep
      // the overlay stable so every item can be focused and scrolled to.
      animated: false,
      consumeOutsideTap: false,
      onOpen: () {
        setState(() => _open = true);
        _focusFirstOption();
      },
      onClose: () => setState(() => _open = false),
      alignmentOffset: const Offset(0, 6),
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(colors.surfaceContainerHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shadowColor: WidgetStatePropertyAll(
          colors.shadow.withValues(alpha: 0.24),
        ),
        elevation: const WidgetStatePropertyAll(14),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        ),
        minimumSize: WidgetStatePropertyAll(Size(menuWidth, 0)),
        maximumSize: WidgetStatePropertyAll(
          Size(maximumMenuWidth, widget.menuMaxHeight),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colors.outlineVariant),
          ),
        ),
      ),
      menuChildren: menuItems,
      builder: (context, controller, _) {
        _menuController = controller;
        return VimActivatable(
          onActivate: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: VimPageScope(
            pageId: 'dropdown/${widget.id}',
            parentPageId: 'toolbar',
            transient: true,
            child: Focus(
              focusNode: _focusNode,
              canRequestFocus: true,
              skipTraversal: false,
              // The anchor is one Vim control. Menu items are rendered in the
              // overlay and have their own focus nodes, so nested anchor nodes must
              // not create a second, unreachable target in the main toolbar.
              descendantsAreTraversable: false,
              onKeyEvent: (node, event) {
                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                  return KeyEventResult.ignored;
                }
                if (event.logicalKey == LogicalKeyboardKey.escape &&
                    controller.isOpen) {
                  controller.close();
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.enter ||
                    event.logicalKey == LogicalKeyboardKey.space) {
                  if (VimModeScope.enabled(context) &&
                      !claimVimActivation(context, event)) {
                    return KeyEventResult.handled;
                  }
                  controller.isOpen ? controller.close() : controller.open();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Tooltip(
                message: widget.tooltip ?? widget.id,
                child: Semantics(
                  button: true,
                  expanded: _open,
                  label: widget.iconOnly
                      ? context.tr(widget.tooltip ?? widget.id)
                      : '${context.tr(widget.id)}: ${context.tr(selected.label)}',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => controller.isOpen
                          ? controller.close()
                          : controller.open(),
                      child: AnimatedContainer(
                        key: ValueKey('${widget.id}-anchor'),
                        duration: const Duration(milliseconds: 150),
                        width: widget.iconOnly ? widget.height : null,
                        height: widget.height,
                        padding: widget.iconOnly
                            ? EdgeInsets.zero
                            : const EdgeInsets.fromLTRB(10, 0, 7, 0),
                        decoration: BoxDecoration(
                          color: _open
                              ? Color.alphaBlend(
                                  colors.primary.withValues(alpha: 0.09),
                                  colors.surfaceContainerLow,
                                )
                              : colors.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color:
                                _open ? colors.primary : colors.outlineVariant,
                            width: _open ? 1.5 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: colors.shadow.withValues(alpha: 0.08),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: widget.iconOnly
                            ? _compactAnchor(colors)
                            : _regularAnchor(theme, colors, selected),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!widget.showScrollbar) return menuAnchor;
    // MenuAnchor supplies the actual scroll controller and viewport. Configure
    // its built-in Scrollbar instead of nesting another ListView/Scrollbar;
    // this keeps the thumb draggable on platforms where Scrollbar.interactive
    // would otherwise default to false.
    return ScrollbarTheme(
      data: theme.scrollbarTheme.copyWith(
        interactive: true,
        thumbVisibility: const WidgetStatePropertyAll(true),
        trackVisibility: const WidgetStatePropertyAll(true),
        thickness: const WidgetStatePropertyAll(7),
        crossAxisMargin: 4,
        mainAxisMargin: 4,
      ),
      child: menuAnchor,
    );
  }

  Widget _withMenuVimNavigation(
    Widget child, {
    required VoidCallback onActivate,
  }) {
    // MenuItemButton owns focus and activation.  This non-focusable ancestor
    // only receives bubbled H/J/K/L events, so keyboard and pointer behavior
    // remain identical while Vim gets deterministic list navigation.
    return VimPageScope(
      pageId: 'dropdown-menu/${widget.id}',
      parentPageId: 'dropdown/${widget.id}',
      transient: true,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) {
          final navigation = _handleMenuKey(event);
          if (navigation == KeyEventResult.handled) return navigation;
          if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
              (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            if (VimModeScope.enabled(context) &&
                !claimVimActivation(context, event)) {
              return KeyEventResult.handled;
            }
            onActivate();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: child,
      ),
    );
  }

  void _activateMenuAction(PolishedDropdownAction action) {
    _menuController?.close();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) action.onPressed();
    });
  }

  Widget _menuAction(BuildContext context, PolishedDropdownAction action) {
    final colors = Theme.of(context).colorScheme;
    final foreground =
        action.destructive ? colors.error : colors.onSurfaceVariant;
    final background = action.destructive
        ? colors.errorContainer.withValues(alpha: 0.46)
        : colors.surfaceContainerHighest;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 1, 2, 4),
      child: MenuItemButton(
        key: ValueKey('${widget.id}-menu-action'),
        focusNode: _actionFocusNode,
        onPressed: () => _activateMenuAction(action),
        leadingIcon: Icon(action.icon, size: 19, color: foreground),
        trailingIcon: Icon(
          Icons.chevron_right_rounded,
          size: 19,
          color: foreground,
        ),
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          backgroundColor: WidgetStatePropertyAll(background),
          foregroundColor: WidgetStatePropertyAll(foreground),
          textStyle: WidgetStatePropertyAll(
            Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: widget.fontSize,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ),
        child: Text(action.label, maxLines: 1),
      ),
    );
  }

  Widget _compactAnchor(ColorScheme colors) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Icon(
          widget.leadingIcon ?? Icons.more_horiz_rounded,
          size: 20,
          color: _open ? colors.primary : colors.onSurfaceVariant,
        ),
        Positioned(
          right: 3,
          bottom: 3,
          child: AnimatedRotation(
            turns: _open ? 0.5 : 0,
            duration: const Duration(milliseconds: 150),
            child: Icon(
              Icons.arrow_drop_down_rounded,
              size: 13,
              color: _open ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _regularAnchor(
    ThemeData theme,
    ColorScheme colors,
    PolishedDropdownOption<T> selected,
  ) {
    return Row(
      children: [
        if (widget.leadingIcon != null) ...[
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.leadingIcon, size: 16, color: colors.primary),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            selected.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontSize: widget.fontSize,
              fontFamily: selected.fontFamily,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
        ),
        const SizedBox(width: 6),
        AnimatedRotation(
          turns: _open ? 0.5 : 0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _open
                  ? colors.primary.withValues(alpha: 0.14)
                  : colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 19,
              color: _open ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _menuOption(
    BuildContext context,
    PolishedDropdownOption<T> option,
    int index,
  ) {
    final colors = Theme.of(context).colorScheme;
    final isSelected = option.value == widget.value;
    return _DropdownVimFocusFrame(
      focusNode: _optionFocusNodes[index],
      child: MenuItemButton(
        key: ValueKey('${widget.id}-option-$index'),
        focusNode: _optionFocusNodes[index],
        onPressed: () => widget.onChanged(option.value),
        leadingIcon: option.icon == null
            ? null
            : Icon(
                option.icon,
                size: 19,
                color: isSelected ? colors.primary : colors.onSurfaceVariant,
              ),
        trailingIcon: isSelected
            ? Icon(Icons.check_rounded, size: 19, color: colors.primary)
            : const SizedBox(width: 19),
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(Size(0, 46)),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          ),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          ),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return colors.primary.withValues(alpha: 0.11);
            }
            return isSelected
                ? colors.primary.withValues(alpha: 0.08)
                : Colors.transparent;
          }),
          foregroundColor: WidgetStatePropertyAll(colors.onSurface),
          textStyle: WidgetStatePropertyAll(
            Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontSize: widget.fontSize,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                ),
          ),
        ),
        child: Text(
          option.label,
          maxLines: 1,
          style: TextStyle(fontFamily: option.fontFamily),
        ),
      ),
    );
  }
}

class _DropdownVimFocusFrame extends StatelessWidget {
  const _DropdownVimFocusFrame({
    required this.focusNode,
    required this.child,
  });

  final FocusNode focusNode;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: focusNode,
      builder: (context, _) {
        final showRing = VimModeScope.enabled(context) && focusNode.hasFocus;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: showRing
                ? Border.all(color: const Color(0xFFD946EF), width: 2)
                : null,
          ),
          child: child,
        );
      },
    );
  }
}
