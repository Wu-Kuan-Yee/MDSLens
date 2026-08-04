import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final bool iconOnly;
  final String? tooltip;
  final PolishedDropdownAction? menuAction;

  @override
  State<PolishedDropdown<T>> createState() => _PolishedDropdownState<T>();
}

class _PolishedDropdownState<T> extends State<PolishedDropdown<T>> {
  bool _open = false;
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'dropdown-${widget.id}',
  );
  FocusNode? _actionFocusNode;
  final List<FocusNode> _optionFocusNodes = <FocusNode>[];

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
      _optionFocusNodes.first.requestFocus();
    }

    // MenuAnchor inserts its menu route after onOpen. The second frame is
    // intentional: it makes the first option deterministic even when the
    // menu has an entrance animation or is opened from a keyboard event.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      request();
      WidgetsBinding.instance.addPostFrameCallback((_) => request());
    });
  }

  @override
  void dispose() {
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
    final menuWidth = widget.minimumMenuWidth.clamp(120, 360).toDouble();

    return MenuAnchor(
      animated: true,
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
        maximumSize: WidgetStatePropertyAll(Size(360, widget.menuMaxHeight)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: colors.outlineVariant),
          ),
        ),
      ),
      menuChildren: [
        if (widget.menuAction != null) ...[
          _menuAction(context, widget.menuAction!),
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
          _menuOption(context, widget.options[index], index),
        ],
      ],
      builder: (context, controller, _) => Focus(
        focusNode: _focusNode,
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
                ? (widget.tooltip ?? widget.id)
                : '${widget.id}: ${selected.label}',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () =>
                    controller.isOpen ? controller.close() : controller.open(),
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
                      color: _open ? colors.primary : colors.outlineVariant,
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
    );
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
        onPressed: () {
          MenuController.maybeOf(context)?.close();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            action.onPressed();
          });
        },
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
    return MenuItemButton(
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
    );
  }
}
