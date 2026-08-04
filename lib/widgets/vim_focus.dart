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

/// The transient editor state used by Vim mode. It intentionally is not part
/// of AppState preferences: reopening the application always starts in Normal
/// mode, just like a Vim buffer does after a fresh launch.
enum VimInputMode { normal, insert, visual }

enum VimVisualMode { character, line, block }

class VimInputState extends ChangeNotifier {
  VimInputMode _mode = VimInputMode.normal;
  VimVisualMode _visualMode = VimVisualMode.character;
  int? _visualAnchor;

  VimInputMode get mode => _mode;
  VimVisualMode get visualMode => _visualMode;
  int? get visualAnchor => _visualAnchor;

  void setMode(
    VimInputMode mode, {
    VimVisualMode visualMode = VimVisualMode.character,
    int? visualAnchor,
  }) {
    if (_mode == mode &&
        _visualMode == visualMode &&
        _visualAnchor == visualAnchor) {
      return;
    }
    _mode = mode;
    _visualMode = visualMode;
    _visualAnchor = mode == VimInputMode.visual ? visualAnchor : null;
    notifyListeners();
  }

  void updateVisualAnchor(int anchor) {
    if (_visualAnchor == anchor) return;
    _visualAnchor = anchor;
    notifyListeners();
  }
}

class VimInputModeScope extends InheritedNotifier<VimInputState> {
  const VimInputModeScope({
    super.key,
    required super.notifier,
    required super.child,
  });

  static VimInputState? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<VimInputModeScope>()
        ?.notifier;
  }

  static VimInputMode mode(BuildContext context) {
    return maybeOf(context)?.mode ?? VimInputMode.normal;
  }

  static bool isInsert(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<VimInputModeScope>();
    // A few small, isolated widget tests mount MainPage without the full
    // application builder. Preserve their historical editable behavior when
    // the transient Vim state provider is absent.
    return scope == null || scope.notifier?.mode == VimInputMode.insert;
  }

  static void setMode(
    BuildContext context,
    VimInputMode mode, {
    VimVisualMode visualMode = VimVisualMode.character,
    int? visualAnchor,
  }) {
    final element =
        context.getElementForInheritedWidgetOfExactType<VimInputModeScope>();
    final scope = element?.widget as VimInputModeScope?;
    scope?.notifier?.setMode(
      mode,
      visualMode: visualMode,
      visualAnchor: visualAnchor,
    );
  }
}

FocusNode? _vimWorkspaceFocus;

void registerVimWorkspaceFocus(FocusNode node) {
  _vimWorkspaceFocus = node;
}

void unregisterVimWorkspaceFocus(FocusNode node) {
  if (identical(_vimWorkspaceFocus, node)) _vimWorkspaceFocus = null;
}

void requestVimWorkspaceFocus() {
  _vimWorkspaceFocus?.requestFocus();
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
  final _vimInputState = VimInputState();

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
    _vimInputState.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  bool _handleGlobalFocusKey(KeyEvent event) {
    if (!VimModeScope.enabled(context) ||
        (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return false;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    // The host itself is above VimInputModeScope, so use the focused
    // descendant's context when routing editor keys. This is what makes i/a,
    // Escape, and visual-mode keys work in dialogs as well as on the page.
    final inputResult = handleVimInputModeKey(focusContext ?? context, event);
    if (inputResult == KeyEventResult.handled) return true;
    if (vimEditingText()) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape && focusContext != null) {
      final route = ModalRoute.of(focusContext);
      if (route is PopupRoute) {
        if (vimFocusedEditable() && leaveVimTextEditing(focusContext)) {
          return true;
        }
        Navigator.of(focusContext).maybePop();
        return true;
      }
    }
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
    return VimInputModeScope(
      notifier: _vimInputState,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          if (enabled) _buildFocusRing(context),
        ],
      ),
    );
  }

  Widget _buildFocusRing(BuildContext context) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.skipTraversal ?? false) return const SizedBox.shrink();
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

bool _isEditableContext(BuildContext? context) {
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool vimFocusedEditable() {
  return _isEditableContext(FocusManager.instance.primaryFocus?.context);
}

bool vimEditingText() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (!_isEditableContext(context)) return false;
  // In Normal mode a focused text field is a selectable control, not an
  // active editor. Its readOnly property is switched by vimTextFieldReadOnly.
  if (context != null && VimModeScope.enabled(context)) {
    return VimInputModeScope.mode(context) != VimInputMode.normal;
  }
  return true;
}

bool vimTextFieldReadOnly(BuildContext context) {
  return VimModeScope.enabled(context) && !VimInputModeScope.isInsert(context);
}

bool _isEditableNode(FocusNode node) {
  return _isEditableContext(node.context);
}

EditableTextState? _editableState(FocusNode node) {
  final context = node.context;
  if (context == null) return null;
  EditableTextState? result;

  void visit(Element element) {
    if (result != null) return;
    if (element is StatefulElement && element.state is EditableTextState) {
      result = element.state as EditableTextState;
      return;
    }
    element.visitChildElements(visit);
  }

  if (context is Element) {
    final element = context;
    if (element is StatefulElement && element.state is EditableTextState) {
      result = element.state as EditableTextState;
    } else {
      element.visitChildElements(visit);
    }
  }
  return result;
}

TextEditingController? _editableController(FocusNode node) {
  return _editableState(node)?.widget.controller;
}

int _editableCursor(TextEditingController controller) {
  final extent = controller.selection.extentOffset;
  if (extent >= 0) return extent.clamp(0, controller.text.length).toInt();
  return controller.text.length;
}

void _setEditableSelection(
  TextEditingController controller, {
  required int base,
  required int extent,
}) {
  final length = controller.text.length;
  final safeBase = base.clamp(0, length).toInt();
  final safeExtent = extent.clamp(0, length).toInt();
  controller.selection = TextSelection(
    baseOffset: safeBase,
    extentOffset: safeExtent,
  );
}

void _moveEditableCursor(
  BuildContext context,
  FocusNode node,
  int delta, {
  required bool extendSelection,
}) {
  final controller = _editableController(node);
  if (controller == null) return;
  final current = _editableCursor(controller);
  final next = (current + delta).clamp(0, controller.text.length).toInt();
  final selection = controller.selection;
  final base = extendSelection ? selection.baseOffset : next;
  _setEditableSelection(controller, base: base, extent: next);
  if (extendSelection) {
    VimInputModeScope.maybeOf(context)
        ?.updateVisualAnchor(selection.baseOffset);
  }
}

bool _moveEditableCursorVertical(
  BuildContext context,
  FocusNode node,
  int lineDelta, {
  required bool extendSelection,
}) {
  final controller = _editableController(node);
  if (controller == null) return false;
  final text = controller.text;
  final current = _editableCursor(controller);
  final currentLineStart = text.lastIndexOf('\n', current - 1) + 1;
  final currentLineEnd = text.indexOf('\n', current);
  final currentEnd = currentLineEnd < 0 ? text.length : currentLineEnd;
  final currentColumn = current - currentLineStart;
  final targetLineStart = lineDelta < 0
      ? text.lastIndexOf('\n', currentLineStart - 2) + 1
      : (currentEnd < text.length ? currentEnd + 1 : -1);
  if (targetLineStart < 0 || targetLineStart > text.length) return false;
  final targetLineEnd = text.indexOf('\n', targetLineStart);
  final targetEnd = targetLineEnd < 0 ? text.length : targetLineEnd;
  final next = (targetLineStart + currentColumn)
      .clamp(targetLineStart, targetEnd)
      .toInt();
  final selection = controller.selection;
  final base = extendSelection ? selection.baseOffset : next;
  _setEditableSelection(controller, base: base, extent: next);
  if (extendSelection) {
    VimInputModeScope.maybeOf(context)
        ?.updateVisualAnchor(selection.baseOffset);
  }
  return true;
}

void _enterVimVisualMode(
  BuildContext context,
  FocusNode node, {
  required VimVisualMode visualMode,
}) {
  final controller = _editableController(node);
  if (controller == null) return;
  final cursor = _editableCursor(controller);
  final text = controller.text;
  var start = cursor;
  var end = cursor;
  if (visualMode == VimVisualMode.line) {
    start = text.lastIndexOf('\n', cursor - 1) + 1;
    final lineEnd = text.indexOf('\n', cursor);
    end = lineEnd < 0 ? text.length : lineEnd + 1;
  } else if (cursor < text.length) {
    end = cursor + 1;
  } else if (cursor > 0) {
    start = cursor - 1;
  }
  _setEditableSelection(controller, base: start, extent: end);
  VimInputModeScope.setMode(
    context,
    VimInputMode.visual,
    visualMode: visualMode,
    visualAnchor: cursor,
  );
}

void _copyEditableSelection(
  BuildContext context,
  FocusNode node,
) {
  final controller = _editableController(node);
  if (controller == null) return;
  final selection = controller.selection;
  if (selection.isCollapsed) return;
  Clipboard.setData(
    ClipboardData(
        text: controller.text.substring(selection.start, selection.end)),
  );
  VimInputModeScope.setMode(context, VimInputMode.normal);
}

void _deleteEditableSelection(
  BuildContext context,
  FocusNode node, {
  bool characterUnderCursor = false,
}) {
  final controller = _editableController(node);
  if (controller == null) return;
  final selection = controller.selection;
  var start = selection.start;
  var end = selection.end;
  if (start == end && characterUnderCursor && start < controller.text.length) {
    end++;
  }
  if (start == end) return;
  controller.text = controller.text.replaceRange(start, end, '');
  _setEditableSelection(controller, base: start, extent: start);
  VimInputModeScope.setMode(context, VimInputMode.normal);
}

void _enterVimInsertMode(
  BuildContext context,
  FocusNode node, {
  int? cursor,
}) {
  final controller = _editableController(node);
  if (controller == null) return;
  final next = cursor ?? _editableCursor(controller);
  _setEditableSelection(controller, base: next, extent: next);
  VimInputModeScope.setMode(context, VimInputMode.insert);
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!node.hasFocus) return;
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  });
}

/// Handle the editor half of Vim's modal model. Normal mode makes every
/// ordinary TextField read-only; i/a/A/I/O enter Insert mode, v/V/Ctrl-V enter
/// a visual selection, and Escape returns to Normal mode. This is deliberately
/// limited to the currently focused editor so the rest of the application's
/// controls keep the same keyboard semantics.
KeyEventResult handleVimInputModeKey(
  BuildContext context,
  KeyEvent event,
) {
  if (!VimModeScope.enabled(context) ||
      (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
    return KeyEventResult.ignored;
  }
  final node = FocusManager.instance.primaryFocus;
  if (node == null || !_isEditableNode(node)) {
    return KeyEventResult.ignored;
  }
  final input = VimInputModeScope.maybeOf(context);
  if (input == null) return KeyEventResult.ignored;
  final key = event.logicalKey;
  final keyboard = HardwareKeyboard.instance;
  final shift = keyboard.isShiftPressed;

  if (input.mode == VimInputMode.insert) {
    if (key == LogicalKeyboardKey.escape) {
      input.setMode(VimInputMode.normal);
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  if (key == LogicalKeyboardKey.escape) {
    input.setMode(VimInputMode.normal);
    node.unfocus();
    return KeyEventResult.handled;
  }

  if (input.mode == VimInputMode.visual) {
    if (key == LogicalKeyboardKey.keyV) {
      input.setMode(VimInputMode.normal);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyX || key == LogicalKeyboardKey.keyD) {
      _deleteEditableSelection(context, node);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyY) {
      _copyEditableSelection(context, node);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyJ) {
      _moveEditableCursorVertical(context, node, 1, extendSelection: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyK) {
      _moveEditableCursorVertical(context, node, -1, extendSelection: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyH || key == LogicalKeyboardKey.arrowLeft) {
      _moveEditableCursor(context, node, -1, extendSelection: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.arrowRight) {
      _moveEditableCursor(context, node, 1, extendSelection: true);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  if (key == LogicalKeyboardKey.keyV) {
    _enterVimVisualMode(
      context,
      node,
      visualMode: keyboard.isControlPressed
          ? VimVisualMode.block
          : (shift ? VimVisualMode.line : VimVisualMode.character),
    );
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyI && shift) {
    _enterVimInsertMode(context, node, cursor: 0);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyI) {
    _enterVimInsertMode(context, node);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyA && shift) {
    final controller = _editableController(node);
    _enterVimInsertMode(context, node, cursor: controller?.text.length);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyA) {
    final controller = _editableController(node);
    if (controller == null) return KeyEventResult.handled;
    _enterVimInsertMode(
      context,
      node,
      cursor: (_editableCursor(controller) + 1)
          .clamp(0, controller.text.length)
          .toInt(),
    );
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyO) {
    final controller = _editableController(node);
    _enterVimInsertMode(
      context,
      node,
      cursor: shift ? 0 : controller?.text.length,
    );
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyJ) {
    _moveEditableCursorVertical(context, node, 1, extendSelection: false);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyK) {
    _moveEditableCursorVertical(context, node, -1, extendSelection: false);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.digit0) {
    final controller = _editableController(node);
    if (controller != null) {
      final cursor = _editableCursor(controller);
      final lineStart = controller.text.lastIndexOf('\n', cursor - 1) + 1;
      _setEditableSelection(controller, base: lineStart, extent: lineStart);
    }
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.dollar) {
    final controller = _editableController(node);
    if (controller != null) {
      final cursor = _editableCursor(controller);
      final lineEnd = controller.text.indexOf('\n', cursor);
      final end = lineEnd < 0 ? controller.text.length : lineEnd;
      _setEditableSelection(controller, base: end, extent: end);
    }
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyX) {
    _deleteEditableSelection(context, node, characterUnderCursor: true);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyH || key == LogicalKeyboardKey.arrowLeft) {
    _moveEditableCursor(context, node, -1, extendSelection: false);
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyL || key == LogicalKeyboardKey.arrowRight) {
    _moveEditableCursor(context, node, 1, extendSelection: false);
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

/// Leave a text field's insert state and put the Vim selection on the nearest
/// actionable non-text control. This preserves direct H/J/K/L navigation while
/// keeping H/J/K/L available for normal text entry until Escape is pressed.
bool leaveVimTextEditing(BuildContext context) {
  final current = FocusManager.instance.primaryFocus;
  if (current == null || !_isEditableNode(current)) return false;
  if (VimModeScope.enabled(context) &&
      VimInputModeScope.maybeOf(context) != null) {
    final input = VimInputModeScope.maybeOf(context)!;
    if (input.mode != VimInputMode.normal) {
      input.setMode(VimInputMode.normal);
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      return true;
    }
    // A second Escape leaves the text field selected in Normal mode and lets
    // the surrounding dialog/workspace receive the next Escape.
    current.unfocus();
    return true;
  }
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
  var scope = current?.nearestScope ??
      Focus.maybeOf(context, scopeOk: true)?.nearestScope;
  if (scope == null) return null;

  // FocusTraversalGroup creates nested scopes. Walk back up through scopes
  // belonging to the same route so H/J/K/L can reach toolbar controls,
  // dropdown anchors, and plots instead of becoming trapped in one group.
  final route = current?.context == null
      ? ModalRoute.of(context)
      : ModalRoute.of(current!.context!);
  while (scope?.parent is FocusScopeNode) {
    final parent = scope!.parent! as FocusScopeNode;
    final parentRoute = parent.context == null
        ? null
        : ModalRoute.of(parent.context!);
    if (route != null && parentRoute != route) break;
    if (route == null && parent.context != null && parentRoute != null) break;
    scope = parent;
  }
  return scope;
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

bool _vimSharesNavigationLane(
  Rect candidate,
  Rect origin,
  TraversalDirection direction,
) {
  return switch (direction) {
    TraversalDirection.left ||
    TraversalDirection.right =>
      candidate.top <= origin.bottom && candidate.bottom >= origin.top,
    TraversalDirection.up ||
    TraversalDirection.down =>
      candidate.left <= origin.right && candidate.right >= origin.left,
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
  if (currentRect == null ||
      current is FocusScopeNode ||
      (current?.skipTraversal ?? false)) {
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
  // Prefer controls in the same visual row/column before considering a
  // diagonal fallback. This makes H/L behave like Vim's horizontal motion:
  // adjacent controls are visited in order instead of jumping to a nearer
  // control on the row above or below.
  final laneCandidates = candidates
      .where((target) =>
          _vimSharesNavigationLane(target.rect, currentRect, direction))
      .toList();
  final orderedCandidates =
      (laneCandidates.isNotEmpty ? laneCandidates : candidates)
        ..sort((a, b) => _vimDirectionalScore(
              a.rect,
              currentRect.center,
              direction,
            ).compareTo(_vimDirectionalScore(
              b.rect,
              currentRect.center,
              direction,
            )));
  final target = orderedCandidates.isNotEmpty
      ? orderedCandidates.first
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
  final inputResult = handleVimInputModeKey(context, event);
  if (inputResult == KeyEventResult.handled) return inputResult;
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    if (vimFocusedEditable() && leaveVimTextEditing(context)) {
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
