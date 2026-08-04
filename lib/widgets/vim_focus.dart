import 'dart:async';

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

class _VimFocusTarget {
  const _VimFocusTarget(this.node, this.rect, this.depth);

  final FocusNode node;
  final Rect rect;
  final int depth;
}

FocusScopeNode? _vimFocusScope(BuildContext context) {
  final current = FocusManager.instance.primaryFocus;
  final currentScope = current?.nearestScope;
  if (currentScope != null) return currentScope;
  return Focus.maybeOf(context, scopeOk: true)?.nearestScope;
}

Rect? _vimNodeRect(FocusNode node) {
  final renderObject = node.context?.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize ||
      renderObject.size.width <= 0 ||
      renderObject.size.height <= 0) {
    return null;
  }
  final topLeft = renderObject.localToGlobal(Offset.zero);
  final rect = topLeft & renderObject.size;
  if (!rect.left.isFinite ||
      !rect.top.isFinite ||
      !rect.right.isFinite ||
      !rect.bottom.isFinite) {
    return null;
  }
  return rect;
}

int _vimNodeDepth(FocusNode node) {
  var depth = 0;
  for (var parent = node.parent; parent != null; parent = parent.parent) {
    depth++;
  }
  return depth;
}

bool _sameVimRect(Rect a, Rect b) {
  const tolerance = 1.5;
  return (a.left - b.left).abs() <= tolerance &&
      (a.top - b.top).abs() <= tolerance &&
      (a.width - b.width).abs() <= tolerance &&
      (a.height - b.height).abs() <= tolerance;
}

List<_VimFocusTarget> _vimFocusTargets(FocusScopeNode scope) {
  final targets = <_VimFocusTarget>[];
  for (final node in scope.traversalDescendants) {
    if (!node.canRequestFocus || node.skipTraversal || node is FocusScopeNode) {
      continue;
    }
    final rect = _vimNodeRect(node);
    if (rect == null) continue;
    final target = _VimFocusTarget(node, rect, _vimNodeDepth(node));
    final duplicate =
        targets.indexWhere((existing) => _sameVimRect(existing.rect, rect));
    if (duplicate < 0) {
      targets.add(target);
    } else if (target.depth < targets[duplicate].depth) {
      // Custom controls often contain a second focus node created by InkWell
      // or ButtonStyleButton. Keep the outer node: it owns the control's
      // Vim-specific Enter/Space handler and gives navigation one stable
      // target instead of visiting the same rectangle twice.
      targets[duplicate] = target;
    }
  }
  return targets;
}

bool _vimInDirection(
    Rect candidate, Offset origin, TraversalDirection direction) {
  const epsilon = 0.5;
  final center = candidate.center;
  return switch (direction) {
    TraversalDirection.left => center.dx < origin.dx - epsilon,
    TraversalDirection.right => center.dx > origin.dx + epsilon,
    TraversalDirection.up => center.dy < origin.dy - epsilon,
    TraversalDirection.down => center.dy > origin.dy + epsilon,
  };
}

double _vimDirectionalScore(
  Rect candidate,
  Offset origin,
  TraversalDirection direction,
) {
  final center = candidate.center;
  final primary = switch (direction) {
    TraversalDirection.left ||
    TraversalDirection.right =>
      (center.dx - origin.dx).abs(),
    TraversalDirection.up ||
    TraversalDirection.down =>
      (center.dy - origin.dy).abs(),
  };
  final cross = switch (direction) {
    TraversalDirection.left ||
    TraversalDirection.right =>
      (center.dy - origin.dy).abs(),
    TraversalDirection.up ||
    TraversalDirection.down =>
      (center.dx - origin.dx).abs(),
  };
  final crossOverlaps = switch (direction) {
    TraversalDirection.left ||
    TraversalDirection.right =>
      candidate.top <= origin.dy && candidate.bottom >= origin.dy,
    TraversalDirection.up ||
    TraversalDirection.down =>
      candidate.left <= origin.dx && candidate.right >= origin.dx,
  };
  // A control in the same row/column wins over a nearer control in an
  // unrelated row/column. This prevents the old traversal policy from
  // skipping toolbar controls or jumping diagonally across the plot grid.
  return primary + (crossOverlaps ? cross * 0.12 : cross * 4.0);
}

_VimFocusTarget? _vimEdgeTarget(
  List<_VimFocusTarget> targets,
  TraversalDirection direction,
) {
  if (targets.isEmpty) return null;
  final sorted = [...targets]..sort((a, b) {
      final primary = switch (direction) {
        TraversalDirection.left ||
        TraversalDirection.right =>
          a.rect.center.dx.compareTo(b.rect.center.dx),
        TraversalDirection.up ||
        TraversalDirection.down =>
          a.rect.center.dy.compareTo(b.rect.center.dy),
      };
      if (primary != 0) return primary;
      return a.rect.center.dx.compareTo(b.rect.center.dx);
    });
  return switch (direction) {
    TraversalDirection.left || TraversalDirection.up => sorted.first,
    TraversalDirection.right || TraversalDirection.down => sorted.last,
  };
}

void _requestVimFocus(_VimFocusTarget target) {
  target.node.requestFocus();
  final targetContext = target.node.context;
  if (targetContext == null) return;
  // Focus can land on a control that is currently outside a compact toolbar,
  // dialog, or menu viewport. Reveal it after the focus change without
  // delaying the key event itself.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!targetContext.mounted) return;
    unawaited(
      Scrollable.ensureVisible(
        targetContext,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      ),
    );
  });
}

/// Move focus geometrically across the active route, including nested
/// FocusTraversalGroups. Flutter's directional policy is intentionally not
/// used here: it treats each nested group as a separate island and can skip
/// controls that are visually between the current and requested targets.
/// If there is no widget in the requested direction, wrap to the opposite
/// edge so H/J/K/L never strand the user at a dead end.
bool moveVimFocus(BuildContext context, TraversalDirection direction) {
  if (vimEditingText()) return false;
  final current = FocusManager.instance.primaryFocus;
  final scope = _vimFocusScope(context);
  if (scope == null) return false;
  final targets = _vimFocusTargets(scope);
  if (targets.isEmpty) return false;

  final currentRect = current == null ? null : _vimNodeRect(current);
  if (currentRect == null || current is FocusScopeNode) {
    final target = _vimEdgeTarget(targets, direction);
    if (target == null) return false;
    _requestVimFocus(target);
    return true;
  }

  final candidates = targets.where((target) {
    if (target.node == current || _sameVimRect(target.rect, currentRect)) {
      return false;
    }
    return _vimInDirection(target.rect, currentRect.center, direction);
  }).toList();
  candidates.sort((a, b) => _vimDirectionalScore(
        a.rect,
        currentRect.center,
        direction,
      ).compareTo(_vimDirectionalScore(
        b.rect,
        currentRect.center,
        direction,
      )));
  final target = candidates.isNotEmpty
      ? candidates.first
      : _vimEdgeTarget(targets, direction);
  if (target == null || target.node == current) return false;
  _requestVimFocus(target);
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
