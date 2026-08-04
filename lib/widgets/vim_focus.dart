import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/app_state.dart';

/// Exposes the application's Vim-mode state above the Navigator so dialogs and
/// popup routes can use the same keyboard navigation rules as the main page.
class VimModeScope extends InheritedNotifier<AppState> {
  const VimModeScope(
      {super.key, required super.notifier, required super.child});

  static bool enabled(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<VimModeScope>();
    if (scope != null) return scope.notifier?.vimMode ?? false;
    try {
      return context.read<AppState>().vimMode;
    } catch (_) {
      return false;
    }
  }
}

/// Draws a non-interactive focus ring around the currently focused control.
/// The ring is intentionally outside the widgets themselves so existing
/// button/dropdown styles remain unchanged and every native Flutter control
/// receives the same purple-pink Vim selection treatment.
class VimFocusHost extends StatefulWidget {
  const VimFocusHost({super.key, required this.child});

  final Widget child;

  @override
  State<VimFocusHost> createState() => _VimFocusHostState();
}

class _VimFocusHostState extends State<VimFocusHost> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_focusChanged);
    HardwareKeyboard.instance.addHandler(_handleGlobalFocusKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    HardwareKeyboard.instance.removeHandler(_handleGlobalFocusKey);
    super.dispose();
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  bool _handleGlobalFocusKey(KeyEvent event) {
    if (!VimModeScope.enabled(context) ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent) ||
        vimEditingText()) {
      return false;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    // The main page gives plot panels their own high-level behavior (panel
    // selection, pan/zoom, and context menu). Other routes and controls use
    // the generic geometric traversal here.
    if (focusContext?.findAncestorWidgetOfExactType<VimPlotFocus>() != null) {
      return false;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.keyH ||
      LogicalKeyboardKey.arrowLeft =>
        TraversalDirection.left,
      LogicalKeyboardKey.keyJ ||
      LogicalKeyboardKey.arrowDown =>
        TraversalDirection.down,
      LogicalKeyboardKey.keyK ||
      LogicalKeyboardKey.arrowUp =>
        TraversalDirection.up,
      LogicalKeyboardKey.keyL ||
      LogicalKeyboardKey.arrowRight =>
        TraversalDirection.right,
      _ => null,
    };
    if (direction == null ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
    return moveVimFocus(context, direction);
  }

  @override
  Widget build(BuildContext context) {
    // Depend on the inherited notifier so enabling/disabling Vim mode hides
    // or shows the ring immediately, without requiring a route rebuild.
    final enabled = VimModeScope.enabled(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        if (enabled) _buildFocusRing(context),
      ],
    );
  }

  Widget _buildFocusRing(BuildContext context) {
    final focus = FocusManager.instance.primaryFocus;
    final renderObject = focus?.context?.findRenderObject();
    final hostRenderObject = context.findRenderObject();
    if (renderObject is! RenderBox ||
        hostRenderObject is! RenderBox ||
        !renderObject.hasSize ||
        !hostRenderObject.hasSize) {
      return const SizedBox.shrink();
    }
    final topLeft = renderObject.localToGlobal(
      Offset.zero,
      ancestor: hostRenderObject,
    );
    final rect = (topLeft & renderObject.size).inflate(3);
    if (rect.width <= 0 || rect.height <= 0) return const SizedBox.shrink();
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: const Color(0xFFE040FB),
              width: 2,
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66E040FB),
                blurRadius: 10,
                spreadRadius: 1,
              ),
            ],
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// Marker used to keep plot-specific Vim behavior separate from ordinary
/// control traversal, including when a popup route is open above the plot.
class VimPlotFocus extends InheritedWidget {
  const VimPlotFocus({super.key, required super.child});

  @override
  bool updateShouldNotify(VimPlotFocus oldWidget) => false;
}

bool vimEditingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool _isEditableNode(FocusNode node) {
  final context = node.context;
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// Leave a text field's insert state and put the Vim selection on the nearest
/// actionable non-text control. This preserves direct H/J/K/L navigation while
/// keeping H/J/K/L available for normal text entry until Escape is pressed.
bool leaveVimTextEditing(BuildContext context) {
  final current = FocusManager.instance.primaryFocus;
  if (current == null || !_isEditableNode(current)) return false;
  final scope = current.nearestScope ?? Focus.maybeOf(context, scopeOk: true);
  if (scope == null) {
    current.unfocus();
    return true;
  }
  final descendants = scope.traversalDescendants
      .where((node) =>
          node.canRequestFocus && !node.skipTraversal && !_isEditableNode(node))
      .toList(growable: false);
  if (descendants.isEmpty) {
    current.unfocus();
    return true;
  }
  final currentRect = current.rect;
  FocusNode? best;
  var bestDistance = double.infinity;
  for (final candidate in descendants) {
    final delta = candidate.rect.center - currentRect.center;
    final distance = delta.distanceSquared;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = candidate;
    }
  }
  best?.requestFocus();
  return best != null;
}

/// Move focus geometrically inside the nearest traversal scope. If there is no
/// widget in the requested direction, wrap to the opposite edge so H/J/K/L
/// never strand the user at a dead end.
bool moveVimFocus(BuildContext context, TraversalDirection direction) {
  if (vimEditingText()) return false;
  final current = FocusManager.instance.primaryFocus;
  if (current == null ||
      current is FocusScopeNode ||
      !current.canRequestFocus ||
      current.context == null) {
    return _requestEdgeFocus(context, direction);
  }
  final currentContext = current.context!;
  final policy = FocusTraversalGroup.maybeOf(currentContext) ??
      FocusTraversalGroup.maybeOf(context);
  if (policy != null && policy.inDirection(current, direction)) return true;

  final scope = current.nearestScope;
  if (scope == null) return _requestEdgeFocus(context, direction);
  final descendants = scope.traversalDescendants
      .where((node) => node.canRequestFocus && !node.skipTraversal)
      .toList(growable: false);
  if (descendants.isEmpty) return false;
  final target =
      direction == TraversalDirection.left || direction == TraversalDirection.up
          ? descendants.last
          : descendants.first;
  if (target == current) return false;
  target.requestFocus();
  return true;
}

bool _requestEdgeFocus(BuildContext context, TraversalDirection direction) {
  final scope = Focus.maybeOf(context, scopeOk: true)?.nearestScope;
  if (scope == null) return false;
  final descendants = scope.traversalDescendants
      .where((node) => node.canRequestFocus && !node.skipTraversal)
      .toList(growable: false);
  if (descendants.isEmpty) return false;
  final target =
      direction == TraversalDirection.left || direction == TraversalDirection.up
          ? descendants.last
          : descendants.first;
  target.requestFocus();
  return true;
}

/// Keyboard behavior shared by every KeyboardSafeDialog. Dialog controls keep
/// their native Enter/Space activation; this wrapper adds Vim navigation and a
/// consistent Escape-to-cancel path.
KeyEventResult handleVimDialogKey(
  BuildContext context,
  KeyEvent event,
) {
  if (!VimModeScope.enabled(context) ||
      (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
    return KeyEventResult.ignored;
  }
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    if (vimEditingText()) {
      leaveVimTextEditing(context);
      return KeyEventResult.handled;
    }
    Navigator.maybePop(context);
    return KeyEventResult.handled;
  }
  if (vimEditingText()) return KeyEventResult.ignored;
  final direction = switch (event.logicalKey) {
    LogicalKeyboardKey.keyH ||
    LogicalKeyboardKey.arrowLeft =>
      TraversalDirection.left,
    LogicalKeyboardKey.keyJ ||
    LogicalKeyboardKey.arrowDown =>
      TraversalDirection.down,
    LogicalKeyboardKey.keyK ||
    LogicalKeyboardKey.arrowUp =>
      TraversalDirection.up,
    LogicalKeyboardKey.keyL ||
    LogicalKeyboardKey.arrowRight =>
      TraversalDirection.right,
    _ => null,
  };
  if (direction == null ||
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isAltPressed ||
      HardwareKeyboard.instance.isMetaPressed ||
      HardwareKeyboard.instance.isShiftPressed) {
    return KeyEventResult.ignored;
  }
  return moveVimFocus(context, direction)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;
}
