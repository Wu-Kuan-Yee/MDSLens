import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/app_state.dart';
import '../services/vim_page_model.dart';

/// Exposes the application's Vim-mode state above the Navigator so dialogs and
/// popup routes can use the same keyboard navigation rules as the main page.
class VimModeScope extends InheritedNotifier<AppState> {
  const VimModeScope(
      {super.key, required super.notifier, required super.child});

  static bool enabled(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<VimModeScope>();
    if (scope?.notifier?.vimMode == true) return true;
    // A few transient pages (most importantly Keyboard Mode itself) must be
    // keyboard-navigable while they are choosing whether Vim mode should be
    // enabled.  The page explicitly opts into the same dispatcher without
    // changing the persisted application preference until Apply is pressed.
    if (context
            .findAncestorWidgetOfExactType<VimPageScope>()
            ?.forceNavigation ==
        true) {
      return true;
    }
    if (scope != null) return false;
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
enum VimInputMode { normal, insert, visual, plot }

enum VimVisualMode { character, line, block }

/// The plot workspace is a two-level Vim document: columns are the outer
/// characters and panels are the lines inside the selected column.
enum VimPlotSelectionLevel { column, panel }

class VimInputState extends ChangeNotifier {
  final VimPageStack pages = VimPageStack();
  final Set<LogicalKeyboardKey> _plotMotionKeys = <LogicalKeyboardKey>{};
  Timer? _plotMotionTimer;
  VimInputMode _mode = VimInputMode.normal;
  VimVisualMode _visualMode = VimVisualMode.character;
  VimPlotSelectionLevel _plotSelectionLevel = VimPlotSelectionLevel.column;
  int? _visualAnchor;
  FocusNode? _editingNode;
  TextEditingValue? _editingSnapshot;
  bool _textEscapeReleased = false;
  bool _commitTextOnEscape = false;
  KeyEvent? _lastHierarchyEscapeEvent;
  KeyEvent? _lastActivationEvent;

  VimInputMode get mode => _mode;
  VimVisualMode get visualMode => _visualMode;
  VimPlotSelectionLevel get plotSelectionLevel => _plotSelectionLevel;
  int? get visualAnchor => _visualAnchor;

  bool consumeTextEscapeRelease() {
    final released = _textEscapeReleased;
    _textEscapeReleased = false;
    return released;
  }

  void markTextEscapeRelease() => _textEscapeReleased = true;

  /// A physical Escape press may be observed by a focused control, its page,
  /// and the application-level keyboard handler. It must still leave exactly
  /// one semantic page. Key-repeat events are consumed without climbing
  /// again, and the same KeyDownEvent cannot be applied by two dispatchers.
  bool claimHierarchyEscape(KeyEvent event) {
    if (event is KeyRepeatEvent ||
        identical(_lastHierarchyEscapeEvent, event)) {
      return false;
    }
    _lastHierarchyEscapeEvent = event;
    return true;
  }

  /// A key event can pass through the application hardware handler and the
  /// focused control's handler. Only the first observer may activate a Vim
  /// control; repeated observations of the same physical event are consumed.
  bool claimVimActivation(KeyEvent event) {
    if (event is KeyRepeatEvent || identical(_lastActivationEvent, event)) {
      return false;
    }
    _lastActivationEvent = event;
    return true;
  }

  bool wasVimActivationClaimed(KeyEvent event) =>
      identical(_lastActivationEvent, event);

  /// Some transient Vim editors (the command line in particular) use the
  /// normal Vim convention that Escape leaves Insert mode while retaining
  /// the text just entered.  Other application fields deliberately keep the
  /// existing cancel-on-Escape behavior, so this is an explicit per-editor
  /// opt-in rather than a global policy change.
  void setCommitTextOnEscape(bool enabled) => _commitTextOnEscape = enabled;

  bool consumeCommitTextOnEscape() {
    final enabled = _commitTextOnEscape;
    _commitTextOnEscape = false;
    return enabled;
  }

  String? get selectedPageId => pages.selectedId;

  /// Keep the semantic page cursor in sync with a widget-backed focus target.
  /// The focus node remains the Flutter accessibility anchor; this cursor is
  /// the stable Vim identity used by nested page navigation.
  void selectPageCell(String id) => pages.setSelection(id);

  bool enterPage(VimPage page, {bool selectFirst = true}) =>
      pages.push(page, selectFirst: selectFirst);

  bool leavePage() => pages.pop();

  /// Save the value that was present immediately before entering Insert mode.
  /// A single active editor is enough: Vim only has one primary focus at a
  /// time, and keeping the snapshot here means Escape works consistently in
  /// dialogs, popups, and the main page.
  void beginTextEdit(FocusNode node, TextEditingValue value) {
    if (identical(_editingNode, node) && _editingSnapshot != null) return;
    _editingNode = node;
    _editingSnapshot = value;
  }

  TextEditingValue? takeTextEditSnapshot(FocusNode node) {
    if (!identical(_editingNode, node)) return null;
    final snapshot = _editingSnapshot;
    _editingNode = null;
    _editingSnapshot = null;
    return snapshot;
  }

  void commitTextEdit([FocusNode? node]) {
    if (node != null && !identical(_editingNode, node)) return;
    _editingNode = null;
    _editingSnapshot = null;
  }

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
    if (mode != VimInputMode.plot) _stopPlotMotion();
    notifyListeners();
  }

  /// Feed a directional key into the plot interaction layer.  Keeping the
  /// pressed-key set here (rather than in a widget) means a plot remains
  /// responsive even when its Focus widget is rebuilt by streamed data.
  void updatePlotMotionKey(
    AppState app,
    LogicalKeyboardKey key, {
    required bool pressed,
  }) {
    if (_mode != VimInputMode.plot) return;
    if (pressed) {
      _plotMotionKeys.add(key);
      _plotMotionTimer ??= Timer.periodic(
        const Duration(milliseconds: 16),
        (_) => _applyPlotMotion(app),
      );
      _applyPlotMotion(app);
    } else {
      _plotMotionKeys.remove(key);
      if (_plotMotionKeys.isEmpty) _stopPlotMotion();
    }
  }

  void _stopPlotMotion() {
    _plotMotionKeys.clear();
    _plotMotionTimer?.cancel();
    _plotMotionTimer = null;
  }

  void _applyPlotMotion(AppState app) {
    if (_plotMotionKeys.isEmpty || _mode != VimInputMode.plot) return;
    final h = _plotMotionKeys.contains(LogicalKeyboardKey.keyH);
    final j = _plotMotionKeys.contains(LogicalKeyboardKey.keyJ);
    final k = _plotMotionKeys.contains(LogicalKeyboardKey.keyK);
    final l = _plotMotionKeys.contains(LogicalKeyboardKey.keyL);
    final horizontal = h || l;
    final vertical = j || k;
    if (!horizontal && !vertical) return;
    if (app.interactionMode == 1) {
      // Point mode deliberately keeps only H/L: vertical motions have no
      // crosshair meaning and must not move the page underneath the cursor.
      if (h && !l) {
        app.stepActivePoint(-1);
      } else if (l && !h) {
        app.stepActivePoint(1);
      }
      return;
    }

    final shrink = HardwareKeyboard.instance.isShiftPressed;
    if (h && l) {
      app.requestSelectedPanelShortcut(
        shrink ? 'zoom-x-out' : 'zoom-x-in',
      );
    } else if (h) {
      app.requestSelectedPanelShortcut('pan-left');
    } else if (l) {
      app.requestSelectedPanelShortcut('pan-right');
    }
    if (j && k) {
      app.requestSelectedPanelShortcut(
        shrink ? 'zoom-y-out' : 'zoom-y-in',
      );
    } else if (j) {
      app.requestSelectedPanelShortcut('pan-down');
    } else if (k) {
      app.requestSelectedPanelShortcut('pan-up');
    }
  }

  void updateVisualAnchor(int anchor) {
    if (_visualAnchor == anchor) return;
    _visualAnchor = anchor;
    notifyListeners();
  }

  void setPlotSelectionLevel(VimPlotSelectionLevel level) {
    if (_plotSelectionLevel == level) return;
    _plotSelectionLevel = level;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPlotMotion();
    pages.dispose();
    super.dispose();
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

  static VimPlotSelectionLevel plotSelectionLevel(BuildContext context) {
    return maybeOf(context)?.plotSelectionLevel ?? VimPlotSelectionLevel.column;
  }

  static void setPlotSelectionLevel(
    BuildContext context,
    VimPlotSelectionLevel level,
  ) {
    final element =
        context.getElementForInheritedWidgetOfExactType<VimInputModeScope>();
    final scope = element?.widget as VimInputModeScope?;
    scope?.notifier?.setPlotSelectionLevel(level);
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

bool _claimVimHierarchyEscape(BuildContext context, KeyEvent event) {
  final input = VimInputModeScope.maybeOf(context);
  return input?.claimHierarchyEscape(event) ?? event is! KeyRepeatEvent;
}

bool _claimVimActivation(BuildContext context, KeyEvent event) {
  final input = VimInputModeScope.maybeOf(context);
  return input?.claimVimActivation(event) ?? event is! KeyRepeatEvent;
}

bool _wasVimActivationClaimed(BuildContext context, KeyEvent event) {
  return VimInputModeScope.maybeOf(context)?.wasVimActivationClaimed(event) ??
      false;
}

/// Public bridge used by controls outside this library to consume one Vim
/// activation event exactly once.
bool claimVimActivation(BuildContext context, KeyEvent event) =>
    _claimVimActivation(context, event);

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

FocusNode? _findVimPageFocus(String pageId) {
  for (final node in FocusManager.instance.rootScope.traversalDescendants) {
    final nodeContext = node.context;
    if (!node.canRequestFocus ||
        node.skipTraversal ||
        nodeContext == null ||
        !nodeContext.mounted) {
      continue;
    }
    if (VimPageScope.maybeOf(nodeContext)?.pageId == pageId) return node;
  }
  return null;
}

/// Restore the unique semantic parent page after a child route closes. This
/// intentionally resolves the parent from the widget's page declaration on
/// every Escape; it never records or replays a focus history stack.
void scheduleVimPageParentFocus(String? parentPageId) {
  if (parentPageId == null) return;

  void request() {
    if (parentPageId == 'root') {
      requestVimWorkspaceFocus();
      return;
    }
    _findVimPageFocus(parentPageId)?.requestFocus();
  }

  WidgetsBinding.instance.addPostFrameCallback((_) {
    request();
    WidgetsBinding.instance.addPostFrameCallback((_) => request());
  });
}

/// Close the current transient page and select its declared parent page.
/// Plot and Layout pages have richer two-level handlers below; this helper is
/// for dialogs, popup menus, and other route-backed child pages.
bool leaveVimPageToParent(BuildContext context) {
  final parentPageId = VimPageScope.maybeOf(context)?.parentPageId;
  if (parentPageId == null) return false;
  Navigator.of(context).maybePop();
  scheduleVimPageParentFocus(parentPageId);
  return true;
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

class _VimFocusHostState extends State<VimFocusHost>
    with SingleTickerProviderStateMixin {
  final _vimInputState = VimInputState();
  late final AnimationController _focusRingController;
  Timer? _vimSequenceTimer;
  final List<ScrollPosition> _ringScrollPositions = <ScrollPosition>[];
  FocusNode? _ringTrackedFocus;
  bool _ringTrackingScheduled = false;
  bool _pendingVimG = false;

  @override
  void initState() {
    super.initState();
    _focusRingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 760),
      lowerBound: 0.24,
      upperBound: 1,
    )
      ..addListener(_focusRingTick)
      ..value = 1;
    _vimInputState.addListener(_inputModeChanged);
    FocusManager.instance.addListener(_focusChanged);
    HardwareKeyboard.instance.addHandler(_handleGlobalFocusKey);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_focusChanged);
    HardwareKeyboard.instance.removeHandler(_handleGlobalFocusKey);
    _vimSequenceTimer?.cancel();
    _vimInputState.removeListener(_inputModeChanged);
    _focusRingController.dispose();
    for (final position in _ringScrollPositions) {
      position.removeListener(_ringScrollChanged);
    }
    _ringScrollPositions.clear();
    _vimInputState.dispose();
    super.dispose();
  }

  void _clearVimSequence() {
    _pendingVimG = false;
    _vimSequenceTimer?.cancel();
    _vimSequenceTimer = null;
  }

  bool _handleVimPageSequence(BuildContext context, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // EditableText owns ordinary characters in Insert mode.  In particular,
    // `g` must be inserted into a command/search field instead of being
    // consumed as the first stroke of Vim's `gg`/`G` page navigation.
    if (vimEditingText()) {
      _clearVimSequence();
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      _clearVimSequence();
      return false;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyG) {
      if (_pendingVimG) _clearVimSequence();
      return false;
    }
    if (keyboard.isShiftPressed) {
      _clearVimSequence();
      return moveVimPageEdge(context, last: true);
    }
    if (_pendingVimG) {
      _clearVimSequence();
      return moveVimPageEdge(context, last: false);
    }
    _pendingVimG = true;
    _vimSequenceTimer?.cancel();
    _vimSequenceTimer = Timer(const Duration(milliseconds: 850), () {
      if (mounted) _clearVimSequence();
    });
    // A lone `g` is a pending Vim prefix, not text and not an application
    // shortcut.  Consume it until the second `g` or the timeout arrives.
    return true;
  }

  void _focusChanged() {
    if (_vimInputState.mode == VimInputMode.plot && !_focusedPlotContext()) {
      _vimInputState.setMode(VimInputMode.normal);
    }
    if (mounted) setState(() {});
  }

  void _inputModeChanged() {
    if (_vimInputState.mode == VimInputMode.normal) {
      _focusRingController.stop();
      _focusRingController.value = 1;
    } else if (!_focusRingController.isAnimating) {
      _focusRingController.repeat(reverse: true);
    }
    if (mounted) setState(() {});
  }

  void _focusRingTick() {
    if (mounted && _vimInputState.mode != VimInputMode.normal) setState(() {});
  }

  void _ringScrollChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleRingScrollTracking(FocusNode? focus) {
    _ringTrackedFocus = focus;
    if (_ringTrackingScheduled) return;
    _ringTrackingScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ringTrackingScheduled = false;
      if (!mounted) return;
      final target = _ringTrackedFocus?.context;
      final positions = <ScrollPosition>[];
      // A maximized plot can replace the focused route between scheduling and
      // this callback. Do not walk ancestors of a deactivated Element: doing
      // so throws and leaves the focus ring tracking stale scroll positions.
      if (target != null && target.mounted) {
        target.visitAncestorElements((element) {
          if (element is StatefulElement && element.state is ScrollableState) {
            final position = (element.state as ScrollableState).position;
            if (!positions.contains(position)) positions.add(position);
          }
          return true;
        });
      }
      final unchanged = positions.length == _ringScrollPositions.length &&
          positions.asMap().entries.every(
                (entry) => identical(
                  entry.value,
                  _ringScrollPositions[entry.key],
                ),
              );
      if (unchanged) return;
      for (final position in _ringScrollPositions) {
        position.removeListener(_ringScrollChanged);
      }
      _ringScrollPositions
        ..clear()
        ..addAll(positions);
      for (final position in _ringScrollPositions) {
        position.addListener(_ringScrollChanged);
      }
      if (mounted) setState(() {});
    });
  }

  bool _focusedPlotContext() {
    return FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<VimPlotFocus>() !=
        null;
  }

  bool _handleGlobalFocusKey(KeyEvent event) {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (!VimModeScope.enabled(context)) return false;
    // Transient routes (dialogs and popup menus) have their own Focus
    // boundary and page-specific key handler.  The host only keeps the
    // application-wide `g` prefix alive there; routing navigation or Enter a
    // second time would move/activate a control twice.
    if (focusContext != null && ModalRoute.of(focusContext) is PopupRoute) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        final inputResult = handleVimInputModeKey(focusContext, event);
        if (inputResult == KeyEventResult.handled) return true;
      }
      // Do not let the page-sequence handler steal ordinary characters from
      // an EditableText that is already in Insert mode.
      if (vimEditingText()) return false;
      if (event.logicalKey == LogicalKeyboardKey.keyG) {
        return _handleVimPageSequence(focusContext, event);
      }
      return false;
    }
    if (handleVimPlotMotionKey(focusContext ?? context, event)) {
      return true;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // The host itself is above VimInputModeScope, so use the focused
    // descendant's context when routing editor keys. This is what makes i/a,
    // Escape, and visual-mode keys work in dialogs as well as on the page.
    final inputResult = handleVimInputModeKey(focusContext ?? context, event);
    if (inputResult == KeyEventResult.handled) return true;
    if (vimEditingText()) return false;
    if (handleVimPlotEditingKey(focusContext ?? context, event)) return true;
    if (enterVimPlotColumnPage(focusContext ?? context, event)) return true;
    if (enterVimLayoutColumnPage(focusContext ?? context, event)) return true;
    if (enterVimPlotEditing(focusContext ?? context, event)) return true;
    if (handleVimPageEntryKey(focusContext ?? context, event)) return true;
    final hasLineEdgeModifier = !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed;
    if (hasLineEdgeModifier &&
        (event.logicalKey == LogicalKeyboardKey.caret ||
            event.logicalKey == LogicalKeyboardKey.dollar ||
            (HardwareKeyboard.instance.isShiftPressed &&
                (event.logicalKey == LogicalKeyboardKey.digit6 ||
                    event.logicalKey == LogicalKeyboardKey.digit4)))) {
      final lineEnd = event.logicalKey == LogicalKeyboardKey.dollar ||
          (HardwareKeyboard.instance.isShiftPressed &&
              event.logicalKey == LogicalKeyboardKey.digit4);
      if (moveVimLineEdge(focusContext ?? context, last: lineEnd)) {
        return true;
      }
    }
    if (handleVimLayoutNavigationKey(focusContext ?? context, event)) {
      return true;
    }
    if (handleVimPlotNavigationKey(focusContext ?? context, event)) {
      return true;
    }
    if (_handleVimPageSequence(focusContext ?? context, event)) return true;
    if (event.logicalKey == LogicalKeyboardKey.escape && focusContext != null) {
      final route = ModalRoute.of(focusContext);
      if (route is PopupRoute) {
        if (vimFocusedEditable() && leaveVimTextEditing(focusContext)) {
          return true;
        }
        if (!leaveVimPageToParent(focusContext)) {
          Navigator.of(focusContext).maybePop();
        }
        return true;
      }
    }
    // The plot grid has a logical Column/Panel matrix, independent of the
    // responsive visual reflow. Use it before generic route geometry.
    if (_isVimPlotContext(focusContext)) {
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
      if (direction != null &&
          !HardwareKeyboard.instance.isShiftPressed &&
          moveVimPlotFocus(focusContext!, direction)) {
        return true;
      }
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
        clipBehavior: Clip.hardEdge,
        children: [
          widget.child,
          if (enabled) _buildFocusRing(context),
        ],
      ),
    );
  }

  Widget _buildFocusRing(BuildContext context) {
    final focus = FocusManager.instance.primaryFocus;
    _scheduleRingScrollTracking(focus);
    if (focus?.skipTraversal ?? false) return const SizedBox.shrink();
    var renderObject = focus?.context?.findRenderObject();
    final focusContext = focus?.context;
    if (focusContext != null &&
        VimPageScope.maybeOf(focusContext)?.pageId == 'popup-menu') {
      // Popup items draw their ring inside the animated route. A ring in this
      // host would live outside PopupMenuRoute's transform and lag behind
      // while the menu scales/translates into place.
      return const SizedBox.shrink();
    }
    if (focusContext != null &&
        VimInputModeScope.plotSelectionLevel(focusContext) ==
            VimPlotSelectionLevel.column &&
        focusContext.findAncestorWidgetOfExactType<VimPlotFocus>() != null) {
      renderObject = _ancestorRenderObject<VimPlotColumnFocus>(focusContext);
    }
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
    final rawRect = (topLeft & renderObject.size).inflate(3);
    final rect = _clipVimRectToAncestorViewports(
      focusContext,
      hostRenderObject,
      rawRect,
    );
    if (rect == null) return const SizedBox.shrink();
    if (rect.width <= 0 || rect.height <= 0) return const SizedBox.shrink();
    final editing = _vimInputState.mode != VimInputMode.normal;
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: Opacity(
          opacity: editing ? _focusRingController.value : 1,
          child: DecoratedBox(
            key: const ValueKey('vim-focus-ring'),
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
      ),
    );
  }
}

RenderObject? _ancestorRenderObject<T extends Widget>(BuildContext context) {
  RenderObject? result;
  context.visitAncestorElements((element) {
    if (element.widget is T) {
      result = element.findRenderObject();
      return false;
    }
    return true;
  });
  return result;
}

Rect? _clipVimRectToAncestorViewports(
  BuildContext? targetContext,
  RenderBox host,
  Rect rect,
) {
  if (targetContext == null) return rect;
  var clipped = rect;
  targetContext.visitAncestorElements((element) {
    if (element is StatefulElement && element.state is ScrollableState) {
      final viewport =
          (element.state as ScrollableState).context.findRenderObject();
      if (viewport is RenderBox && viewport.attached && viewport.hasSize) {
        final topLeft = viewport.localToGlobal(Offset.zero, ancestor: host);
        clipped = clipped.intersect(topLeft & viewport.size);
        if (clipped.isEmpty) return false;
      }
    }
    return true;
  });
  return clipped.isEmpty ? null : clipped;
}

/// Marker used to keep plot-specific Vim behavior separate from ordinary
/// control traversal, including when a popup route is open above the plot.
class VimPlotFocus extends InheritedWidget {
  const VimPlotFocus({
    super.key,
    required super.child,
    this.column = -1,
    this.row = -1,
  });

  final int column;
  final int row;

  String get pageId => 'plot/panel/$column/$row';
  String get parentPageId => 'plot/column/$column';

  @override
  bool updateShouldNotify(VimPlotFocus oldWidget) => false;
}

/// Non-focusable marker for the outer Vim column surrounding a group of plot
/// panels. The focused panel remains the representative focus node, while the
/// marker gives the Vim focus ring the correct whole-column bounds.
class VimPlotColumnFocus extends InheritedWidget {
  const VimPlotColumnFocus({
    super.key,
    required super.child,
    required this.column,
  });

  final int column;

  String get pageId => 'plot/column/$column';
  String get parentPageId => 'plot/grid';

  @override
  bool updateShouldNotify(VimPlotColumnFocus oldWidget) => false;
}

/// Declares a non-plot cell of the Export Multiple Panels dialog.  The dialog
/// has a deliberately semantic top-level document: format/range, optional X
/// range fields, Select All, the row of source Columns, then its actions.
/// Keeping those row/column coordinates separate from render geometry avoids
/// uneven panel stacks being mistaken for a sequence of logical rows.
class VimPanelExportControl extends InheritedWidget {
  const VimPanelExportControl({
    super.key,
    required super.child,
    required this.row,
    required this.column,
  });

  final int row;
  final int column;

  @override
  bool updateShouldNotify(VimPanelExportControl oldWidget) =>
      row != oldWidget.row || column != oldWidget.column;
}

/// Marker used by Layout Setup. Columns and panels are real focusable cells,
/// but the marker keeps their source coordinates independent of the current
/// responsive/scrolling geometry.
class VimLayoutFocus extends InheritedWidget {
  const VimLayoutFocus({
    super.key,
    required super.child,
    required this.column,
    this.row = -1,
    required this.isColumn,
    this.onActivate,
  });

  final int column;
  final int row;
  final bool isColumn;
  final VoidCallback? onActivate;

  String get pageId =>
      isColumn ? 'layout/column/$column' : 'layout/panel/$column/$row';
  String get parentPageId => isColumn ? 'layout' : 'layout/column/$column';

  @override
  bool updateShouldNotify(VimLayoutFocus oldWidget) => false;
}

/// Declares a semantic page boundary in the widget tree.  Unlike a Flutter
/// FocusScope this does not trap focus; it only tells the Vim model which
/// parent page owns the current character.  That distinction lets a dialog or
/// dropdown be entered with `i` while preserving the normal Flutter route and
/// accessibility behavior.
class VimPageScope extends InheritedWidget {
  const VimPageScope({
    super.key,
    required super.child,
    required this.pageId,
    this.parentPageId,
    this.transient = false,
    this.forceNavigation = false,
  });

  final String pageId;
  final String? parentPageId;
  final bool transient;
  final bool forceNavigation;

  static VimPageScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VimPageScope>();

  @override
  bool updateShouldNotify(VimPageScope oldWidget) =>
      pageId != oldWidget.pageId ||
      parentPageId != oldWidget.parentPageId ||
      transient != oldWidget.transient ||
      forceNavigation != oldWidget.forceNavigation;
}

bool _isEditableContext(BuildContext? context) {
  if (context == null) return false;
  return context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null;
}

bool vimFocusedEditable() {
  final node = FocusManager.instance.primaryFocus;
  return node != null && _isEditableNode(node);
}

bool vimEditingText() {
  final node = FocusManager.instance.primaryFocus;
  if (node == null || !_isEditableNode(node)) return false;
  // In Normal mode a focused text field is a selectable control, not an
  // active editor. Its readOnly property is switched by vimTextFieldReadOnly.
  final context = node.context;
  if (context != null && VimModeScope.enabled(context)) {
    return VimInputModeScope.mode(context) != VimInputMode.normal;
  }
  return true;
}

bool vimTextFieldReadOnly(BuildContext context) {
  return VimModeScope.enabled(context) && !VimInputModeScope.isInsert(context);
}

bool _isEditableNode(FocusNode node) {
  // A TextField's public FocusNode is attached to an ancestor Focus widget,
  // while the actual EditableTextState is its descendant.  Looking only at
  // ancestors made a field reachable by H/J/K/L but caused `i` to be ignored.
  // Focus scopes can contain many editable descendants, but the scope itself
  // is never an editor.  Excluding it prevents the second Escape from being
  // mistaken for another text-field transition after the field is unfocused.
  if (node is FocusScopeNode) return false;
  return _isEditableContext(node.context) || _editableState(node) != null;
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
    result = element.findAncestorStateOfType<EditableTextState>();
    if (result != null) return result;
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

bool _moveEditableCursor(
  BuildContext context,
  FocusNode node,
  int delta, {
  required bool extendSelection,
}) {
  final controller = _editableController(node);
  if (controller == null) return false;
  final current = _editableCursor(controller);
  final next = (current + delta).clamp(0, controller.text.length).toInt();
  if (next == current) return false;
  final selection = controller.selection;
  final base = extendSelection ? selection.baseOffset : next;
  _setEditableSelection(controller, base: base, extent: next);
  if (extendSelection) {
    VimInputModeScope.maybeOf(context)
        ?.updateVisualAnchor(selection.baseOffset);
  }
  return true;
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
  VimInputModeScope.maybeOf(context)?.commitTextEdit(node);
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
  VimInputModeScope.maybeOf(context)?.commitTextEdit(node);
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
  VimInputModeScope.maybeOf(context)?.beginTextEdit(node, controller.value);
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
  if (key == LogicalKeyboardKey.escape &&
      !_claimVimHierarchyEscape(context, event)) {
    return KeyEventResult.handled;
  }

  if (input.mode == VimInputMode.insert) {
    if (key == LogicalKeyboardKey.escape) {
      final controller = _editableController(node);
      if (input.consumeCommitTextOnEscape()) {
        input.commitTextEdit(node);
      } else {
        final snapshot = input.takeTextEditSnapshot(node);
        if (controller != null && snapshot != null) {
          controller.value = snapshot;
        }
      }
      input.setMode(VimInputMode.normal);
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      input.commitTextEdit(node);
      input.setMode(VimInputMode.normal);
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  if (key == LogicalKeyboardKey.escape) {
    input.markTextEscapeRelease();
    input.setMode(VimInputMode.normal);
    node.unfocus();
    // Keep the transient page focused after leaving a field. Otherwise the
    // next Escape has no Focus.onKeyEvent boundary to reach, so it cannot
    // close the dialog. Prefer the nearest non-editable control as the new
    // Vim cell while still making the field itself lose focus.
    final scope = node.nearestScope;
    final fallback = scope?.traversalDescendants
        .where(
          (candidate) =>
              candidate.canRequestFocus &&
              !candidate.skipTraversal &&
              !_isEditableNode(candidate),
        )
        .firstOrNull;
    fallback?.requestFocus();
    return KeyEventResult.handled;
  }

  if (input.mode == VimInputMode.visual) {
    if (key == LogicalKeyboardKey.enter) {
      input.commitTextEdit(node);
      input.setMode(VimInputMode.normal);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyV) {
      input.commitTextEdit(node);
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
      return _moveEditableCursorVertical(context, node, 1,
              extendSelection: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyK) {
      return _moveEditableCursorVertical(context, node, -1,
              extendSelection: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyH || key == LogicalKeyboardKey.arrowLeft) {
      return _moveEditableCursor(context, node, -1, extendSelection: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.keyL ||
        key == LogicalKeyboardKey.arrowRight) {
      return _moveEditableCursor(context, node, 1, extendSelection: true)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
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
  if (key == LogicalKeyboardKey.digit0) {
    final controller = _editableController(node);
    if (controller != null) {
      final cursor = _editableCursor(controller);
      final lineStart = controller.text.lastIndexOf('\n', cursor - 1) + 1;
      _setEditableSelection(controller, base: lineStart, extent: lineStart);
    }
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.dollar ||
      (shift && key == LogicalKeyboardKey.digit4)) {
    final controller = _editableController(node);
    if (controller != null) {
      final cursor = _editableCursor(controller);
      final lineEnd = controller.text.indexOf('\n', cursor);
      final end = lineEnd < 0 ? controller.text.length : lineEnd;
      _setEditableSelection(controller, base: end, extent: end);
    }
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.caret ||
      (shift && key == LogicalKeyboardKey.digit6)) {
    final controller = _editableController(node);
    if (controller != null) {
      final cursor = _editableCursor(controller);
      final lineStart = controller.text.lastIndexOf('\n', cursor - 1) + 1;
      _setEditableSelection(controller, base: lineStart, extent: lineStart);
    }
    return KeyEventResult.handled;
  }
  if (key == LogicalKeyboardKey.keyX) {
    _deleteEditableSelection(context, node, characterUnderCursor: true);
    return KeyEventResult.handled;
  }
  return KeyEventResult.ignored;
}

FocusNode? _firstDirectVimChild(FocusNode node) {
  final scope = node.nearestScope;
  if (scope == null) return null;
  for (final candidate in scope.traversalDescendants) {
    if (!candidate.canRequestFocus || candidate.skipTraversal) continue;
    if (candidate.ancestors.contains(node)) return candidate;
  }
  return null;
}

bool _activateVimControl(BuildContext context) {
  try {
    Actions.invoke(context, const ActivateIntent());
    return true;
  } on Object {
    return false;
  }
}

/// Public bridge for controls that provide their own ancestor
/// [Focus.onKeyEvent] boundary, such as toolbar icon buttons.
bool activateVimControl(BuildContext context) => _activateVimControl(context);

/// Enter a semantic child page without requiring a mouse.  For a composite
/// Focus widget we enter its first direct child; for a button/dropdown whose
/// child page is created by activation, `i` activates the control and the
/// opened route will deterministically focus its first cell.
bool handleVimPageEntryKey(BuildContext context, KeyEvent event) {
  if (!VimModeScope.enabled(context) ||
      (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
    return false;
  }
  if (vimEditingText() || _isVimPlotContext(context)) return false;
  final key = event.logicalKey;
  if (key != LogicalKeyboardKey.keyI &&
      key != LogicalKeyboardKey.enter &&
      key != LogicalKeyboardKey.numpadEnter &&
      key != LogicalKeyboardKey.space) {
    return false;
  }
  final current = FocusManager.instance.primaryFocus;
  if (current == null) return false;
  if (current is FocusScopeNode) return false;
  // Text fields own Enter for submission/commit.  In Insert mode the modal
  // handler already consumes it; in Normal mode letting the native field see
  // it avoids a second global handler invoking ActivateIntent and submitting
  // the shot twice.
  if (key != LogicalKeyboardKey.keyI && _isEditableNode(current)) {
    return false;
  }
  if (!_claimVimActivation(context, event)) return true;
  final layout =
      current.context?.findAncestorWidgetOfExactType<VimLayoutFocus>();
  if (key != LogicalKeyboardKey.keyI && layout?.onActivate != null) {
    layout!.onActivate!();
    return true;
  }
  if (key == LogicalKeyboardKey.keyI) {
    final child = _firstDirectVimChild(current);
    if (child != null) {
      child.requestFocus();
      return true;
    }
  }
  return _activateVimControl(current.context ?? context);
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
      final controller = _editableController(current);
      final snapshot = input.takeTextEditSnapshot(current);
      if (controller != null && snapshot != null) {
        controller.value = snapshot;
      }
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
  const _VimFocusTarget(
    this.node,
    this.rect,
    this.depth,
    this.plot,
    this.layout,
  );

  final FocusNode node;
  final Rect rect;
  final int depth;
  final VimPlotFocus? plot;
  final VimLayoutFocus? layout;
}

/// A virtual Vim page is the set of focusable controls on the active route.
///
/// Flutter exposes focus nodes as a tree, but that tree is not the mental
/// model a keyboard-only user sees.  A toolbar, a dialog, a popup, and the
/// plot grid are all pages made of rows; each row contains controls from left
/// to right, just like characters in a text line.  We derive those rows from
/// the rendered rectangles so the model follows responsive layout changes
/// without requiring every control to carry a hand-maintained row number.
class _VimFocusPage {
  _VimFocusPage(List<_VimFocusTarget> targets)
      : rows = _buildRows(targets),
        targets = List.unmodifiable(targets);

  final List<_VimFocusTarget> targets;
  final List<List<_VimFocusTarget>> rows;

  static List<List<_VimFocusTarget>> _buildRows(
    List<_VimFocusTarget> targets,
  ) {
    final ordered = [...targets]..sort((a, b) {
        final byY = a.rect.center.dy.compareTo(b.rect.center.dy);
        if (byY != 0) return byY;
        return a.rect.center.dx.compareTo(b.rect.center.dx);
      });
    final rows = <List<_VimFocusTarget>>[];
    for (final target in ordered) {
      var bestRow = -1;
      var bestDistance = double.infinity;
      for (var index = 0; index < rows.length; index++) {
        final row = rows[index];
        final minHeight =
            row.map((item) => item.rect.height).reduce((a, b) => a < b ? a : b);
        final center =
            row.map((item) => item.rect.center.dy).reduce((a, b) => a + b) /
                row.length;
        final centerDistance = (target.rect.center.dy - center).abs();
        // Use visual centers rather than rectangle overlap. A tall card can
        // overlap the action row below it even though those controls are two
        // distinct Vim lines; overlap-based grouping made G and J/K jump to
        // the wrong controls in compact dialogs such as Layout Setup.
        final tolerance = (minHeight * 0.35).clamp(12.0, 24.0).toDouble();
        final sameRow = centerDistance <= tolerance;
        if (!sameRow || centerDistance >= bestDistance) continue;
        bestRow = index;
        bestDistance = centerDistance;
      }
      if (bestRow < 0) {
        rows.add([target]);
      } else {
        rows[bestRow].add(target);
      }
    }
    for (final row in rows) {
      row.sort((a, b) => a.rect.center.dx.compareTo(b.rect.center.dx));
    }
    rows.sort((a, b) {
      final aTop =
          a.map((item) => item.rect.top).reduce((x, y) => x < y ? x : y);
      final bTop =
          b.map((item) => item.rect.top).reduce((x, y) => x < y ? x : y);
      return aTop.compareTo(bTop);
    });
    return rows;
  }

  /// The first line is geometric so `gg` starts at the visible top of a route.
  /// The last line uses traversal order: geometric sorting can put an
  /// off-screen child of a scroll view after a dialog's action bar merely
  /// because its global rectangle extends below the viewport.
  List<_VimFocusTarget> get readingOrder => [
        ...rows.firstOrNull ?? const <_VimFocusTarget>[],
        ...targets.skip(1),
      ];

  int rowOf(_VimFocusTarget target) {
    for (var index = 0; index < rows.length; index++) {
      if (rows[index].contains(target)) return index;
    }
    return -1;
  }
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
    final parentRoute =
        parent.context == null ? null : ModalRoute.of(parent.context!);
    // Some FocusScopeNodes (notably the scopes created by dialogs and
    // traversal groups) do not expose a BuildContext. They still belong to
    // the active route, so only stop when a non-null parent route explicitly
    // differs from the active route.
    if (route != null && parentRoute != null && parentRoute != route) break;
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
    final target = _VimFocusTarget(
      node,
      rect,
      _vimNodeDepth(node),
      node.context?.findAncestorWidgetOfExactType<VimPlotFocus>(),
      node.context?.findAncestorWidgetOfExactType<VimLayoutFocus>(),
    );
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

int _vimRevealGeneration = 0;

void _requestVimFocus(_VimFocusTarget target) {
  target.node.requestFocus();
  final targetContext = target.node.context;
  if (targetContext == null) return;
  _syncVimSemanticSelection(targetContext, target);
  final generation = ++_vimRevealGeneration;
  // Focus can land on a control that is currently outside a compact toolbar,
  // dialog, or menu viewport. Reveal it after the focus change without
  // delaying the key event itself.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!targetContext.mounted || generation != _vimRevealGeneration) return;
    void reveal() {
      if (!targetContext.mounted || generation != _vimRevealGeneration) return;
      _revealVimTargetInAncestorScrollables(targetContext);
    }

    reveal();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (generation == _vimRevealGeneration) reveal();
    });
  });
}

void _syncVimSemanticSelection(
  BuildContext context,
  _VimFocusTarget target,
) {
  final input = VimInputModeScope.maybeOf(context);
  if (input == null) return;
  final plot = target.plot;
  if (plot != null) {
    final level = input.plotSelectionLevel;
    final column = context.findAncestorWidgetOfExactType<VimPlotColumnFocus>();
    if (level == VimPlotSelectionLevel.column && column != null) {
      input.pages.setExternalSelection('plot/grid', column.pageId);
    } else {
      input.pages.setExternalSelection(plot.parentPageId, plot.pageId);
    }
    return;
  }
  final layout = target.layout;
  if (layout != null) {
    input.pages.setExternalSelection(
      layout.parentPageId,
      layout.pageId,
    );
    return;
  }
  final page = VimPageScope.maybeOf(context);
  final label = target.node.debugLabel;
  if (page != null && label != null && label.isNotEmpty) {
    input.pages.setExternalSelection(page.pageId, label);
  } else if (label != null && label.isNotEmpty) {
    input.pages.setExternalSelection('route', label);
  }
}

/// Reveal a focused control in every ancestor scroll view. Flutter's
/// `Scrollable.ensureVisible` normally handles this, but a Layout Setup column
/// is a horizontal scroll view containing independent vertical scroll views;
/// when a child is laid out outside the vertical viewport, the default helper
/// can decide that the nearest viewport already owns the reveal and leave the
/// column controller at zero. Rect-based correction is deterministic and also
/// works for custom/adaptive scroll containers on desktop and mobile.
void _revealVimTargetInAncestorScrollables(BuildContext targetContext) {
  final renderObject = targetContext.findRenderObject();
  if (renderObject is! RenderBox ||
      !renderObject.attached ||
      !renderObject.hasSize) {
    return;
  }
  final scrollables = <ScrollableState>[];
  targetContext.visitAncestorElements((element) {
    if (element is StatefulElement && element.state is ScrollableState) {
      scrollables.add(element.state as ScrollableState);
    }
    return true;
  });

  // Nearest first: after a per-column controller moves, the target's global
  // rectangle is recomputed before checking an outer horizontal viewport.
  for (final scrollable in scrollables) {
    if (!scrollable.mounted || !scrollable.position.hasContentDimensions) {
      continue;
    }
    final viewport = scrollable.context.findRenderObject();
    if (viewport is! RenderBox || !viewport.attached || !viewport.hasSize) {
      continue;
    }
    // Recompute after every inner scroll.  A vertical Layout Setup column can
    // move the target horizontally/vertically before its outer viewport is
    // checked; using one stale global rectangle was the source of the old
    // “selected but hidden behind the scrollbar” behavior.
    final targetTopLeft = renderObject.localToGlobal(Offset.zero);
    final targetRect = targetTopLeft & renderObject.size;
    final viewportTopLeft = viewport.localToGlobal(Offset.zero);
    final viewportRect = viewportTopLeft & viewport.size;
    var delta = 0.0;
    if (scrollable.position.axis == Axis.vertical) {
      if (targetRect.top < viewportRect.top) {
        delta = targetRect.top - viewportRect.top;
      } else if (targetRect.bottom > viewportRect.bottom) {
        delta = targetRect.bottom - viewportRect.bottom;
      }
    } else {
      if (targetRect.left < viewportRect.left) {
        delta = targetRect.left - viewportRect.left;
      } else if (targetRect.right > viewportRect.right) {
        delta = targetRect.right - viewportRect.right;
      }
    }
    if (delta.abs() < 0.5) continue;
    final desired = (scrollable.position.pixels + delta)
        .clamp(0.0, scrollable.position.maxScrollExtent)
        .toDouble();
    if ((desired - scrollable.position.pixels).abs() >= 0.5) {
      scrollable.position.jumpTo(desired);
    }
  }
}

bool _isVimPlotContext(BuildContext? context) {
  return context?.findAncestorWidgetOfExactType<VimPlotFocus>() != null;
}

bool vimPlotEditing(BuildContext context) {
  if (!VimModeScope.enabled(context)) return false;
  return VimInputModeScope.mode(context) == VimInputMode.plot;
}

LogicalKeyboardKey? _vimPlotMotionKey(LogicalKeyboardKey key) {
  return switch (key) {
    LogicalKeyboardKey.keyH ||
    LogicalKeyboardKey.arrowLeft =>
      LogicalKeyboardKey.keyH,
    LogicalKeyboardKey.keyJ ||
    LogicalKeyboardKey.arrowDown =>
      LogicalKeyboardKey.keyJ,
    LogicalKeyboardKey.keyK ||
    LogicalKeyboardKey.arrowUp =>
      LogicalKeyboardKey.keyK,
    LogicalKeyboardKey.keyL ||
    LogicalKeyboardKey.arrowRight =>
      LogicalKeyboardKey.keyL,
    _ => null,
  };
}

/// Route both key-down and key-up events to the shared plot motion controller.
/// This is intentionally separate from [handleVimPlotEditingKey]: the latter
/// handles modal entry/exit, while this function preserves simultaneous H/J/K/L
/// state for pan and axis-specific zoom.
bool handleVimPlotMotionKey(BuildContext context, KeyEvent event) {
  if (!vimPlotEditing(context)) return false;
  if (HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isAltPressed ||
      HardwareKeyboard.instance.isMetaPressed) {
    return false;
  }
  final key = _vimPlotMotionKey(event.logicalKey);
  if (key == null) return false;
  final input = VimInputModeScope.maybeOf(context);
  if (input == null) return false;
  final app = context.read<AppState>();
  if (event is KeyUpEvent) {
    input.updatePlotMotionKey(app, key, pressed: false);
    return true;
  }
  if (event is KeyDownEvent || event is KeyRepeatEvent) {
    input.updatePlotMotionKey(app, key, pressed: true);
    return true;
  }
  return false;
}

/// Enter a Layout Setup Column page at its first direct Panel character.
///
/// The outer Column focus node also owns drag handles and each Panel's Edit
/// button.  Flutter traversal therefore cannot express the nested-page model
/// on its own: its first descendant may be an Edit icon instead of the first
/// Panel.  Resolve the child page from the explicit [VimLayoutFocus] markers
/// so `i` never skips a hierarchy level.
bool enterVimLayoutColumnPage(BuildContext context, KeyEvent event) {
  if (!VimModeScope.enabled(context) ||
      (event is! KeyDownEvent && event is! KeyRepeatEvent) ||
      event.logicalKey != LogicalKeyboardKey.keyI ||
      !_isVimLayoutContext(context)) {
    return false;
  }
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed) {
    return false;
  }
  final page = _vimFocusPage(context);
  final current = _currentVimLayoutTarget(
    page ?? _VimFocusPage(const []),
    FocusManager.instance.primaryFocus,
  );
  if (current?.layout?.isColumn != true) {
    // The focused Column can observe the same physical key after its first
    // observer has already moved focus into a Panel. Consume that duplicate
    // instead of letting generic child traversal jump straight to Edit.
    return _wasVimActivationClaimed(context, event);
  }
  if (!_claimVimActivation(context, event)) return true;
  final column = current!.layout!.column;
  final firstPanel = _layoutTargets(page!, columns: false)
      .where((target) => target.layout!.column == column)
      .firstOrNull;
  if (firstPanel != null) _requestVimFocus(firstPanel);
  return true;
}

/// Enter the plot's Vim edit mode.  Point mode is deliberately explicit: in
/// Normal mode H/L/J/K always move between Panel cells, while in Plot mode
/// the horizontal keys operate the crosshair instead.
bool enterVimPlotColumnPage(BuildContext context, KeyEvent event) {
  if (!VimModeScope.enabled(context) ||
      (event is! KeyDownEvent && event is! KeyRepeatEvent) ||
      !_isVimPlotContext(context)) {
    return false;
  }
  final key = event.logicalKey;
  if (key != LogicalKeyboardKey.keyI &&
      key != LogicalKeyboardKey.enter &&
      key != LogicalKeyboardKey.numpadEnter) {
    return false;
  }
  final keyboard = HardwareKeyboard.instance;
  if (keyboard.isShiftPressed ||
      keyboard.isControlPressed ||
      keyboard.isAltPressed ||
      keyboard.isMetaPressed) {
    return false;
  }
  final input = VimInputModeScope.maybeOf(context);
  if (input == null) return false;
  if (input.plotSelectionLevel != VimPlotSelectionLevel.column) {
    // The same physical key can be observed by a focused PlotPanel and by the
    // application-wide handler. If the first observer entered the Column,
    // consume the duplicate instead of immediately activating its first
    // Panel with the very same Enter/i press.
    return _wasVimActivationClaimed(context, event);
  }
  if (!_claimVimActivation(context, event)) return true;
  final page = _vimFocusPage(context);
  final current = _currentVimPlotTarget(
    page ?? _VimFocusPage(const []),
    FocusManager.instance.primaryFocus,
  );
  final column = current?.plot?.column;
  if (page == null || column == null) return true;
  final first = _plotTargetsByColumn(page, column).firstOrNull;
  if (first == null) return true;
  input.setPlotSelectionLevel(VimPlotSelectionLevel.panel);
  _requestVimFocus(first);
  return true;
}

bool enterVimPlotEditing(BuildContext context, KeyEvent event) {
  if (!VimModeScope.enabled(context) ||
      (event is! KeyDownEvent && event is! KeyRepeatEvent) ||
      event.logicalKey != LogicalKeyboardKey.keyI ||
      HardwareKeyboard.instance.isShiftPressed ||
      !_isVimPlotContext(context)) {
    return false;
  }
  if (!_claimVimActivation(context, event)) return true;
  final app = context.read<AppState>();
  if (app.interactionMode == 1 && app.crosshairX == null) {
    app.activatePointForCurrentPanel();
  }
  VimInputModeScope.setMode(context, VimInputMode.plot);
  return true;
}

/// Handle the crosshair half of Plot edit mode.  The mode consumes all keys
/// while active so H/L cannot fall through to grid navigation accidentally.
bool handleVimPlotEditingKey(BuildContext context, KeyEvent event) {
  if (!vimPlotEditing(context) ||
      (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
    return false;
  }
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    if (!_claimVimHierarchyEscape(context, event)) return true;
    final input = VimInputModeScope.maybeOf(context);
    if (input?.plotSelectionLevel == VimPlotSelectionLevel.panel) {
      input?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
    }
    VimInputModeScope.setMode(context, VimInputMode.normal);
    return true;
  }
  final app = context.read<AppState>();
  if (app.interactionMode == 0) {
    // Move/Zoom uses the pressed-key controller so H+L/J+K can be combined.
    return false;
  }
  switch (event.logicalKey) {
    case LogicalKeyboardKey.keyH:
    case LogicalKeyboardKey.arrowLeft:
      app.stepActivePoint(-1);
      return true;
    case LogicalKeyboardKey.keyL:
    case LogicalKeyboardKey.arrowRight:
      app.stepActivePoint(1);
      return true;
    default:
      // Plot editing is modal.  A vertical motion has no crosshair meaning,
      // so consume it rather than unexpectedly moving to another control.
      return true;
  }
}

bool _isVimPlotNavigationKey(KeyEvent event) {
  if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
  final keyboard = HardwareKeyboard.instance;
  return !keyboard.isShiftPressed &&
      !keyboard.isControlPressed &&
      !keyboard.isAltPressed &&
      !keyboard.isMetaPressed;
}

TraversalDirection? _vimDirectionForKey(LogicalKeyboardKey key) {
  return switch (key) {
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
}

_VimFocusTarget? _currentVimPlotTarget(
  _VimFocusPage page,
  FocusNode? current,
) {
  if (current == null) return null;
  for (final target in page.targets) {
    if (target.plot == null) continue;
    if (target.node == current) return target;
  }
  final rect = _vimNodeRect(current);
  if (rect == null) return null;
  return page.targets
      .where((target) => target.plot != null && _sameVimRect(target.rect, rect))
      .firstOrNull;
}

List<_VimFocusTarget> _plotTargetsByColumn(
  _VimFocusPage page,
  int column,
) {
  final result = page.targets
      .where((target) => target.plot?.column == column)
      .toList()
    ..sort((a, b) => a.plot!.row.compareTo(b.plot!.row));
  return result;
}

List<int> _plotColumns(_VimFocusPage page) {
  return page.targets
      .where((target) => target.plot != null)
      .map((target) => target.plot!.column)
      .toSet()
      .toList()
    ..sort();
}

List<_VimFocusTarget> _plotColumnTargets(_VimFocusPage page) {
  return [
    for (final column in _plotColumns(page))
      if (_plotTargetsByColumn(page, column).firstOrNull case final target?)
        target,
  ];
}

VimPanelExportControl? _panelExportControlFor(_VimFocusTarget target) =>
    target.node.context?.findAncestorWidgetOfExactType<VimPanelExportControl>();

List<_VimFocusTarget> _panelExportControlTargets(_VimFocusPage page) {
  final unique = <String, _VimFocusTarget>{};
  for (final target in page.targets) {
    final marker = _panelExportControlFor(target);
    if (marker == null) continue;
    final key = '${marker.row}:${marker.column}';
    final previous = unique[key];
    if (previous == null || target.depth < previous.depth) {
      unique[key] = target;
    }
  }
  final result = unique.values.toList()
    ..sort((a, b) {
      final aMarker = _panelExportControlFor(a)!;
      final bMarker = _panelExportControlFor(b)!;
      final byRow = aMarker.row.compareTo(bMarker.row);
      return byRow != 0 ? byRow : aMarker.column.compareTo(bMarker.column);
    });
  return result;
}

bool _isPanelExportContext(BuildContext? context) {
  if (context == null || !context.mounted) return false;
  if (VimPageScope.maybeOf(context)?.pageId == 'panel-export') return true;
  var found = false;
  context.visitAncestorElements((element) {
    final scope = element.widget;
    if (scope is VimPageScope && scope.pageId == 'panel-export') {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Handle the outer-column/inner-panel state machine. A horizontal motion
/// always selects a whole source Column, even when the responsive layout has
/// reflowed it visually. A vertical motion enters or moves within that
/// column, so uneven column lengths never cause a jump into another column.
bool handleVimPlotNavigationKey(BuildContext context, KeyEvent event) {
  if (!VimModeScope.enabled(context) || !_isVimPlotNavigationKey(event)) {
    return false;
  }
  if (!_isVimPlotContext(context) || vimPlotEditing(context)) return false;
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    if (!_claimVimHierarchyEscape(context, event)) return true;
    final input = VimInputModeScope.maybeOf(context);
    if (input?.plotSelectionLevel == VimPlotSelectionLevel.panel) {
      input?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
      return true;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    return true;
  }
  final direction = _vimDirectionForKey(event.logicalKey);
  if (direction == null) return false;
  // A boundary is still a handled Vim motion.  Consuming it prevents the
  // generic geometric traversal fallback from jumping out of the waveform
  // document into an unrelated toolbar control.
  moveVimPlotFocus(context, direction);
  return true;
}

/// Move between PlotPanel cells using the source layout coordinates.  The
/// visual grid can reflow on phones, but a Column remains a Vim column and a
/// Panel remains its row within that Column.
bool moveVimPlotFocus(BuildContext context, TraversalDirection direction) {
  if (vimPlotEditing(context)) return false;
  final page = _vimFocusPage(context);
  final current = FocusManager.instance.primaryFocus;
  if (page == null || current == null) return false;
  final currentTarget = _currentVimPlotTarget(page, current);
  if (currentTarget?.plot == null) return false;
  final currentPlot = currentTarget!.plot!;
  final horizontal = direction == TraversalDirection.left ||
      direction == TraversalDirection.right;
  final columns = _plotColumns(page);
  final input = VimInputModeScope.maybeOf(context);
  final level = input?.plotSelectionLevel ?? VimPlotSelectionLevel.column;
  _VimFocusTarget? target;
  if (level == VimPlotSelectionLevel.column && !horizontal) {
    if (_isPanelExportContext(context)) {
      return _moveVimPanelExportRootFocus(page, direction);
    }
    return _moveVimPlotRootFocus(page, direction);
  }
  if (horizontal) {
    // Once Enter/i has entered a Column, it is an isolated one-column child
    // page. H/L cannot leak into a sibling Column; Escape returns to the
    // parent plot-grid page before horizontal Column selection resumes.
    if (level == VimPlotSelectionLevel.panel || columns.length <= 1) {
      return false;
    }
    final currentColumnIndex = columns.indexOf(currentPlot.column);
    if (currentColumnIndex < 0) return false;
    final step = direction == TraversalDirection.left ? -1 : 1;
    final targetIndex =
        (currentColumnIndex + step).clamp(0, columns.length - 1);
    final targetColumn = columns[targetIndex];
    final candidates = _plotTargetsByColumn(page, targetColumn);
    target = candidates.firstOrNull;
    input?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
  } else {
    final candidates = _plotTargetsByColumn(page, currentPlot.column);
    if (candidates.isEmpty) return false;
    final currentRow = candidates.indexWhere(
      (candidate) => candidate.plot!.row == currentPlot.row,
    );
    if (currentRow < 0) return false;
    final step = direction == TraversalDirection.up ? -1 : 1;
    final targetRow = (currentRow + step).clamp(0, candidates.length - 1);
    target = candidates[targetRow];
    input?.setPlotSelectionLevel(VimPlotSelectionLevel.panel);
  }
  if (target == null || target.node == current) return false;
  _requestVimFocus(target);
  return true;
}

/// Handle the parent page of Export Multiple Panels.  This runs for both
/// ordinary dialog controls and the outer Column characters, so J/K follow a
/// fixed semantic order instead of the changing pixel heights of its panels.
bool handleVimPanelExportNavigationKey(
  BuildContext context,
  KeyEvent event,
) {
  if (!VimModeScope.enabled(context) || !_isVimPlotNavigationKey(event)) {
    return false;
  }
  final current = FocusManager.instance.primaryFocus;
  final currentContext = current?.context;
  final isControl =
      currentContext?.findAncestorWidgetOfExactType<VimPanelExportControl>() !=
          null;
  final isPlot = _isPanelExportContext(currentContext) &&
      currentContext?.findAncestorWidgetOfExactType<VimPlotFocus>() != null;
  if (!isControl && !isPlot) return false;
  final direction = _vimDirectionForKey(event.logicalKey);
  if (direction == null) return false;
  final input = VimInputModeScope.maybeOf(context);
  if (isPlot && input?.plotSelectionLevel == VimPlotSelectionLevel.panel) {
    // The selected Panel belongs to its entered one-column child page. Its
    // own handler below owns J/K and consumes H/L at the child-page boundary.
    return false;
  }
  final page = _vimFocusPage(context);
  if (page != null) _moveVimPanelExportRootFocus(page, direction);
  // A boundary is still a handled motion: never fall back to pixel geometry.
  return true;
}

bool _moveVimPanelExportRootFocus(
  _VimFocusPage page,
  TraversalDirection direction,
) {
  final controls = _panelExportControlTargets(page);
  final columnTargets = _plotColumnTargets(page);
  if (controls.isEmpty || columnTargets.isEmpty) return false;
  final actionRow = controls
      .map((target) => _panelExportControlFor(target)!.row)
      .reduce((a, b) => a > b ? a : b);
  final gridRow = actionRow - 1;
  final rowsByNumber = <int, List<_VimFocusTarget>>{};
  for (final control in controls) {
    final marker = _panelExportControlFor(control)!;
    rowsByNumber.putIfAbsent(marker.row, () => []).add(control);
  }
  rowsByNumber[gridRow] = columnTargets;
  final rowNumbers = rowsByNumber.keys.toList()..sort();
  final rows = <List<_VimFocusTarget>>[
    for (final rowNumber in rowNumbers)
      rowsByNumber[rowNumber]!
        ..sort((a, b) {
          final aControl = _panelExportControlFor(a);
          final bControl = _panelExportControlFor(b);
          if (aControl != null && bControl != null) {
            return aControl.column.compareTo(bControl.column);
          }
          return a.plot!.column.compareTo(b.plot!.column);
        }),
  ];
  final currentNode = FocusManager.instance.primaryFocus;
  if (currentNode == null) return false;
  final currentPlot = _currentVimPlotTarget(page, currentNode)?.plot;
  final currentControl = currentNode.context
      ?.findAncestorWidgetOfExactType<VimPanelExportControl>();
  final currentTarget = currentPlot != null
      ? columnTargets
          .where((target) => target.plot!.column == currentPlot.column)
          .firstOrNull
      : currentControl == null
          ? null
          : controls.where((target) {
              final marker = _panelExportControlFor(target)!;
              return marker.row == currentControl.row &&
                  marker.column == currentControl.column;
            }).firstOrNull;
  if (currentTarget == null) return false;

  final semanticTargets = <String, _VimFocusTarget>{};
  final semanticRows = <List<VimPageCell>>[];
  for (final row in rows) {
    final semanticRow = <VimPageCell>[];
    for (final target in row) {
      final id = _vimFocusTargetId(target);
      semanticTargets[id] = target;
      semanticRow.add(VimPageCell(id: id, label: target.node.debugLabel ?? id));
    }
    semanticRows.add(semanticRow);
  }
  final navigator = VimPageStack(
    root: VimPage(
      id: 'panel-export-root',
      title: 'Export Multiple Panels',
      rows: semanticRows,
    ),
  )..setSelection(_vimFocusTargetId(currentTarget));
  if (!navigator.move(_vimPageMotionForDirection(direction))) return false;
  final target = semanticTargets[navigator.selectedId];
  if (target == null) return false;
  if (target.plot != null) {
    final targetContext = target.node.context ?? currentNode.context;
    if (targetContext != null) {
      VimInputModeScope.maybeOf(targetContext)
          ?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
    }
  }
  _requestVimFocus(target);
  return true;
}

bool _moveVimPlotRootFocus(
  _VimFocusPage page,
  TraversalDirection direction,
) {
  final columnTargets = _plotColumnTargets(page);
  final targets = <_VimFocusTarget>[
    ..._vimRootControls(page),
    ...columnTargets,
  ];
  if (targets.isEmpty) return false;
  final rootPage = _VimFocusPage(targets);
  final currentNode = FocusManager.instance.primaryFocus;
  if (currentNode == null) return false;
  final currentPlot = _currentVimPlotTarget(page, currentNode)?.plot;
  final currentRect = _vimNodeRect(currentNode);
  final currentTarget = currentPlot != null
      ? columnTargets
          .where((target) => target.plot!.column == currentPlot.column)
          .firstOrNull
      : rootPage.targets
          .where(
            (target) =>
                target.node == currentNode ||
                (currentRect != null && _sameVimRect(target.rect, currentRect)),
          )
          .firstOrNull;
  if (currentTarget == null) return false;

  final semanticTargets = <String, _VimFocusTarget>{};
  final rows = <List<VimPageCell>>[];
  for (final row in rootPage.rows) {
    final semanticRow = <VimPageCell>[];
    for (final target in row) {
      final id = _vimFocusTargetId(target);
      semanticTargets[id] = target;
      semanticRow.add(VimPageCell(id: id, label: target.node.debugLabel ?? id));
    }
    rows.add(semanticRow);
  }
  final navigator = VimPageStack(
    root: VimPage(id: 'plot-root', title: 'Application', rows: rows),
  )..setSelection(_vimFocusTargetId(currentTarget));
  if (!navigator.move(_vimPageMotionForDirection(direction))) return false;
  final target = semanticTargets[navigator.selectedId];
  if (target == null) return false;
  if (target.plot != null) {
    VimInputModeScope.maybeOf(target.node.context ?? currentNode.context!)
        ?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
  }
  _requestVimFocus(target);
  return true;
}

bool _isVimLayoutContext(BuildContext? context) {
  if (context == null) return false;
  if (context.findAncestorWidgetOfExactType<VimLayoutFocus>() != null) {
    return true;
  }
  if (context.findAncestorWidgetOfExactType<VimPageScope>()?.pageId ==
      'layout') {
    return true;
  }
  final focusedContext = FocusManager.instance.primaryFocus?.context;
  return focusedContext?.findAncestorWidgetOfExactType<VimLayoutFocus>() !=
          null ||
      focusedContext?.findAncestorWidgetOfExactType<VimPageScope>()?.pageId ==
          'layout';
}

_VimFocusTarget? _currentVimLayoutTarget(
  _VimFocusPage page,
  FocusNode? current,
) {
  if (current == null) return null;
  for (final target in page.targets) {
    if (target.layout == null) continue;
    if (target.node == current) return target;
  }
  final rect = _vimNodeRect(current);
  if (rect == null) return null;
  return page.targets
      .where(
          (target) => target.layout != null && _sameVimRect(target.rect, rect))
      .firstOrNull;
}

List<_VimFocusTarget> _layoutTargets(
  _VimFocusPage page, {
  required bool columns,
}) {
  final raw = page.targets
      .where((target) =>
          target.layout != null && target.layout!.isColumn == columns)
      .toList();
  // LongPressDraggable and its InkWell can expose a second focus node for the
  // same visual cell. Layout navigation is identity-based, so collapse those
  // duplicates before calculating rows and scroll destinations.
  final unique = <String, _VimFocusTarget>{};
  for (final target in raw) {
    final marker = target.layout!;
    final key = '${marker.column}:${marker.row}:${marker.isColumn}';
    final previous = unique[key];
    if (previous == null || target.depth < previous.depth) {
      unique[key] = target;
    }
  }
  final result = unique.values.toList();
  result.sort((a, b) {
    final byColumn = a.layout!.column.compareTo(b.layout!.column);
    if (byColumn != 0) return byColumn;
    return a.layout!.row.compareTo(b.layout!.row);
  });
  return result;
}

String _vimTargetLabel(_VimFocusTarget target) {
  final targetContext = target.node.context;
  if (targetContext != null) {
    final tooltip =
        targetContext.findAncestorWidgetOfExactType<Tooltip>()?.message;
    if (tooltip != null && tooltip.trim().isNotEmpty) return tooltip;
  }
  return target.node.debugLabel ?? '';
}

int _vimRootControlRank(_VimFocusTarget target) {
  final label = _vimTargetLabel(target).trim().toLowerCase();
  if (label.startsWith('open configuration')) return 0;
  if (label.startsWith('recent configurations')) return 1;
  if (label.startsWith('save configuration')) return 2;
  return 100;
}

/// Return the controls of the root application page in semantic order.
///
/// The toolbar is a child page of the root page and its visual rows reflow at
/// different widths.  Geometry alone therefore makes `gg` unstable: on a
/// compact window Settings or Recent configurations can appear above Open
/// configuration.  Keep the file actions' logical order ahead of the other
/// toolbar controls, then retain visual ordering for the rest.
List<_VimFocusTarget> _vimRootControls(_VimFocusPage page) {
  final allControls = page.targets
      .where((target) => target.plot == null && target.layout == null)
      .toList();
  final toolbarControls = allControls.where((target) {
    final targetContext = target.node.context;
    return targetContext != null &&
        VimPageScope.maybeOf(targetContext)?.pageId == 'toolbar';
  }).toList();
  final controls = toolbarControls.isEmpty ? allControls : toolbarControls;
  controls.sort((a, b) {
    final bySemanticRank = _vimRootControlRank(a).compareTo(
      _vimRootControlRank(b),
    );
    if (bySemanticRank != 0) return bySemanticRank;
    final byY = a.rect.top.compareTo(b.rect.top);
    return byY != 0 ? byY : a.rect.left.compareTo(b.rect.left);
  });
  return controls;
}

bool handleVimLayoutNavigationKey(BuildContext context, KeyEvent event) {
  if (!VimModeScope.enabled(context) || !_isVimPlotNavigationKey(event)) {
    return false;
  }
  final focusedContext = FocusManager.instance.primaryFocus?.context;
  final navigationContext =
      context.findAncestorWidgetOfExactType<VimLayoutFocus>() != null
          ? context
          : focusedContext ?? context;
  if (!_isVimLayoutContext(navigationContext)) return false;
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    if (!_claimVimHierarchyEscape(navigationContext, event)) return true;
    final current = _currentVimLayoutTarget(
      _vimFocusPage(navigationContext) ?? _VimFocusPage(const []),
      FocusManager.instance.primaryFocus,
    );
    if (current?.layout?.isColumn == false) {
      final page = _vimFocusPage(navigationContext);
      if (page == null) return false;
      final column = _layoutTargets(page, columns: true)
          .where((target) => target.layout!.column == current!.layout!.column)
          .firstOrNull;
      if (column != null) {
        _requestVimFocus(column);
        return true;
      }
    }
    FocusManager.instance.primaryFocus?.unfocus();
    return true;
  }
  final direction = _vimDirectionForKey(event.logicalKey);
  if (direction == null) return false;
  final current = _currentVimLayoutTarget(
    _vimFocusPage(navigationContext) ?? _VimFocusPage(const []),
    FocusManager.instance.primaryFocus,
  );
  // A panel belongs to the currently entered Column page.  Horizontal
  // motion must not leak into sibling Columns; leave the panel with Escape
  // first, which restores the Column character on the parent page.
  final horizontal = direction == TraversalDirection.left ||
      direction == TraversalDirection.right;
  final page = _vimFocusPage(navigationContext);
  if (page == null) return true;

  if (current?.layout == null || current!.layout!.isColumn) {
    // A Column is a character on the Layout Setup page.  Horizontal motion
    // therefore selects sibling Columns, while vertical motion remains on
    // the parent page and can reach the action row.  It must not implicitly
    // enter the Column's panel page; `i` is the explicit page-entry key.
    if (current?.layout?.isColumn == true && horizontal) {
      moveVimLayoutFocus(navigationContext, direction);
      return true;
    }
    _moveVimLayoutRootFocus(page, direction);
    return true;
  }

  // A Panel is a character inside its entered Column page.  Horizontal
  // motion is intentionally consumed here so it can never jump into a
  // sibling Column.  Vertical motion is confined to this Column's panels.
  if (horizontal) return true;
  moveVimLayoutFocus(navigationContext, direction);
  return true;
}

bool _moveVimLayoutRootFocus(
  _VimFocusPage page,
  TraversalDirection direction,
) {
  // The parent Layout Setup page contains both its action controls and the
  // Column characters. Panels are deliberately omitted: they belong to a
  // Column child page and become reachable only after `i` enters that page.
  final targets = <_VimFocusTarget>[
    ..._layoutRootControls(page),
    ..._layoutTargets(page, columns: true),
  ];
  if (targets.isEmpty) return false;
  final rootPage = _VimFocusPage(targets);
  final current = FocusManager.instance.primaryFocus;
  if (current == null) return false;
  final currentRect = _vimNodeRect(current);
  final currentTarget = rootPage.targets
      .where(
        (target) =>
            target.node == current ||
            (currentRect != null && _sameVimRect(target.rect, currentRect)),
      )
      .firstOrNull;
  if (currentTarget == null) return false;

  final semanticTargets = <String, _VimFocusTarget>{};
  final rows = <List<VimPageCell>>[];
  for (final row in rootPage.rows) {
    final semanticRow = <VimPageCell>[];
    for (final target in row) {
      final id = _vimFocusTargetId(target);
      semanticTargets[id] = target;
      semanticRow.add(VimPageCell(id: id, label: target.node.debugLabel ?? id));
    }
    rows.add(semanticRow);
  }
  final navigator = VimPageStack(
    root: VimPage(id: 'layout-root', title: 'Layout Setup', rows: rows),
  )..setSelection(_vimFocusTargetId(currentTarget));
  if (!navigator.move(_vimPageMotionForDirection(direction))) return false;
  final target = semanticTargets[navigator.selectedId];
  if (target == null) return false;
  _requestVimFocus(target);
  return true;
}

/// Layout Setup uses the same nested text-page model as the chart grid. A
/// horizontal move selects a sibling Column only while the Column character
/// itself is selected; once `i` enters that Column page, vertical motion stays
/// within its panels and horizontal motion is intentionally isolated. Every
/// request goes through the common reveal helper so both the outer horizontal
/// viewport and the column's vertical viewport are corrected.
bool moveVimLayoutFocus(
  BuildContext context,
  TraversalDirection direction,
) {
  final page = _vimFocusPage(context);
  final current = _currentVimLayoutTarget(
    page ?? _VimFocusPage(const []),
    FocusManager.instance.primaryFocus,
  );
  if (page == null || current?.layout == null) return false;
  final layout = current!.layout!;
  final columnTargets = _layoutTargets(page, columns: true);
  final panelTargets = _layoutTargets(page, columns: false);
  if (columnTargets.isEmpty) return false;
  _VimFocusTarget? target;
  final horizontal = direction == TraversalDirection.left ||
      direction == TraversalDirection.right;
  if (horizontal) {
    if (!layout.isColumn) return false;
    final index = columnTargets.indexWhere(
      (candidate) => candidate.layout!.column == layout.column,
    );
    if (index < 0) return false;
    final step = direction == TraversalDirection.left ? -1 : 1;
    target = columnTargets[(index + step).clamp(0, columnTargets.length - 1)];
  } else {
    if (layout.isColumn) return false;
    final candidates = panelTargets
        .where((candidate) => candidate.layout!.column == layout.column)
        .toList();
    if (candidates.isEmpty) return false;
    candidates.sort((a, b) => a.layout!.row.compareTo(b.layout!.row));
    final index = candidates.indexWhere(
      (candidate) => candidate.layout!.row == layout.row,
    );
    if (index < 0) return false;
    final step = direction == TraversalDirection.up ? -1 : 1;
    target = candidates[(index + step).clamp(0, candidates.length - 1)];
  }
  if (target.node == current.node) return false;
  _requestVimFocus(target);
  return true;
}

_VimFocusPage? _vimFocusPage(BuildContext context) {
  final scope = _vimFocusScope(context);
  if (scope == null) return null;
  final targets = _vimFocusTargets(scope);
  if (targets.isEmpty) return null;
  return _VimFocusPage(targets);
}

/// Put Vim on the first or last control of the active virtual page.  `gg`
/// and `G` use this reading order, so they remain meaningful when a route is
/// responsive and its controls reflow into a different number of rows.
bool moveVimPageEdge(BuildContext context, {required bool last}) {
  final page = _vimFocusPage(context);
  if (page == null) return false;
  final plotResult = _moveVimPlotPageEdge(context, page, last: last);
  if (plotResult) return true;
  final layoutResult = _moveVimLayoutPageEdge(context, page, last: last);
  if (layoutResult) return true;
  final rootControls = _vimRootControls(page);
  final target = last
      ? rootControls.lastOrNull ?? page.rows.lastOrNull?.lastOrNull
      : rootControls.firstOrNull ?? page.rows.firstOrNull?.firstOrNull;
  if (target == null) return false;
  _requestVimFocus(target);
  return true;
}

bool _moveVimPlotPageEdge(
  BuildContext context,
  _VimFocusPage page, {
  required bool last,
}) {
  final plotTargets = page.targets.where((target) => target.plot != null);
  if (plotTargets.isEmpty) return false;
  final current = _currentVimPlotTarget(
    page,
    FocusManager.instance.primaryFocus,
  );
  final input = VimInputModeScope.maybeOf(context);
  final focusContext = FocusManager.instance.primaryFocus?.context ?? context;
  final pageId = VimPageScope.maybeOf(focusContext)?.pageId;
  final rootWorkspace =
      pageId == 'root' || pageId == 'toolbar' || pageId == 'plot/grid';
  _VimFocusTarget? firstColumnTarget() {
    final firstColumn = _plotColumns(page).firstOrNull;
    if (firstColumn == null) return null;
    return _plotTargetsByColumn(page, firstColumn).firstOrNull;
  }

  bool selectRootLastColumn() {
    final target = firstColumnTarget();
    if (target == null) return false;
    input?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
    _requestVimFocus(target);
    return true;
  }

  if (current == null) {
    // The root toolbar is the first child page of the application page. Start
    // at its first semantic control instead of letting the responsive row
    // geometry choose Settings/Recent configurations ahead of Open.
    if (last && rootWorkspace && selectRootLastColumn()) return true;
    final rootControls = _vimRootControls(page);
    final rootTarget =
        last ? rootControls.lastOrNull : rootControls.firstOrNull;
    if (rootTarget != null) {
      _requestVimFocus(rootTarget);
      return true;
    }
    // With no toolbar controls, the waveform grid remains the deterministic
    // entry point; once inside that column, G/gg have their nested meaning.
    final firstColumn = _plotColumns(page).firstOrNull;
    if (firstColumn == null) return false;
    final candidates = _plotTargetsByColumn(page, firstColumn);
    final target = last ? candidates.lastOrNull : candidates.firstOrNull;
    if (target == null) return false;
    input?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
    _requestVimFocus(target);
    return true;
  }
  if (input?.plotSelectionLevel == VimPlotSelectionLevel.column) {
    // The selected Column is still a character of the root application page.
    // `gg`/`G` therefore operate on the root page; they must not implicitly
    // enter the Column and select its first/last Panel.
    if (last && rootWorkspace && selectRootLastColumn()) return true;
    final rootControls = _vimRootControls(page);
    final rootTarget =
        (last ? rootControls.lastOrNull : rootControls.firstOrNull);
    if (rootTarget != null) {
      _requestVimFocus(rootTarget);
      return true;
    }
  }
  final candidates = _plotTargetsByColumn(page, current.plot!.column);
  if (candidates.isEmpty) return false;
  final target = last ? candidates.last : candidates.first;
  input?.setPlotSelectionLevel(VimPlotSelectionLevel.panel);
  _requestVimFocus(target);
  return true;
}

bool _moveVimLayoutPageEdge(
  BuildContext context,
  _VimFocusPage page, {
  required bool last,
}) {
  final columns = _layoutTargets(page, columns: true);
  final panels = _layoutTargets(page, columns: false);
  if (columns.isEmpty) return false;
  final current = _currentVimLayoutTarget(
    page,
    FocusManager.instance.primaryFocus,
  );
  if (current == null || current.layout == null || current.layout!.isColumn) {
    // The root Layout Setup page starts with its one semantic row of Column
    // characters; Add panel/Add column and the action bar come after it.
    // Thus `gg` always selects Column 1, while `G` reaches the final root
    // action. A selected Column remains a root-page character, so an edge
    // command must never implicitly enter its Panel child page.
    final rootControls = _layoutRootControls(page);
    final target = last
        ? rootControls.lastOrNull ?? columns.last
        : columns.firstOrNull ?? rootControls.firstOrNull;
    if (target != null) _requestVimFocus(target);
    return target != null;
  }
  final column = current.layout!.column;
  final inColumn = panels
      .where((target) => target.layout!.column == column)
      .toList()
    ..sort((a, b) => a.layout!.row.compareTo(b.layout!.row));
  if (current.layout!.isColumn) {
    _requestVimFocus(columns.firstWhere(
      (target) => target.layout!.column == column,
      orElse: () => columns.first,
    ));
  } else if (inColumn.isNotEmpty) {
    _requestVimFocus(last ? inColumn.last : inColumn.first);
  }
  return true;
}

List<_VimFocusTarget> _layoutRootControls(_VimFocusPage page) {
  final controls = page.targets
      .where((target) => target.layout == null && target.plot == null)
      .toList()
    ..sort((a, b) {
      final byY = a.rect.top.compareTo(b.rect.top);
      return byY != 0 ? byY : a.rect.left.compareTo(b.rect.left);
    });
  return controls;
}

/// Move to the first or last focusable control in the current virtual Vim
/// line. `^` and `$` therefore behave like their text-editor counterparts on
/// every route, including dialogs whose action buttons are laid out in a
/// separate bottom row.
bool moveVimLineEdge(BuildContext context, {required bool last}) {
  if (vimEditingText()) return false;
  final page = _vimFocusPage(context);
  final current = FocusManager.instance.primaryFocus;
  if (page == null || current == null) return false;
  final currentRect = _vimNodeRect(current);
  if (currentRect == null) return false;
  _VimFocusTarget? currentTarget;
  for (final target in page.targets) {
    if (target.node == current || _sameVimRect(target.rect, currentRect)) {
      currentTarget = target;
      break;
    }
  }
  final rowIndex = currentTarget == null ? -1 : page.rowOf(currentTarget);
  if (rowIndex < 0 || rowIndex >= page.rows.length) return false;
  final row = page.rows[rowIndex];
  if (row.isEmpty) return false;
  final layout = currentTarget?.layout;
  if (layout != null && !layout.isColumn) {
    final columnTargets = page.targets
        .where(
          (target) =>
              target.layout != null &&
              !target.layout!.isColumn &&
              target.layout!.column == layout.column,
        )
        .toList()
      ..sort((a, b) => a.layout!.row.compareTo(b.layout!.row));
    final target = last ? columnTargets.lastOrNull : columnTargets.firstOrNull;
    if (target == null) return false;
    _requestVimFocus(target);
    return true;
  }
  _requestVimFocus(last ? row.last : row.first);
  return true;
}

/// Move focus geometrically across the active route, including nested
/// FocusTraversalGroups. Flutter's directional policy is intentionally not
/// used here: it treats each nested group as a separate island and can skip
/// controls that are visually between the current and requested targets.
/// If there is no widget in the requested direction, wrap to the opposite
/// edge so H/J/K/L never strand the user at a dead end.
bool moveVimFocus(BuildContext context, TraversalDirection direction) {
  if (vimEditingText()) return false;
  final page = _vimFocusPage(context);
  if (page == null) return false;
  if (page.rows.isEmpty) return false;

  final semanticTargets = <String, _VimFocusTarget>{};
  final rows = <List<VimPageCell>>[];
  for (final row in page.rows) {
    final semanticRow = <VimPageCell>[];
    for (final target in row) {
      final id = _vimFocusTargetId(target);
      semanticTargets[id] = target;
      semanticRow.add(VimPageCell(id: id, label: target.node.debugLabel ?? id));
    }
    rows.add(semanticRow);
  }
  final navigator = VimPageStack(
    root: VimPage(id: 'focus-route', title: 'Current page', rows: rows),
  );
  final current = FocusManager.instance.primaryFocus;
  final currentRect = current == null ? null : _vimNodeRect(current);
  final currentTarget = current == null || currentRect == null
      ? null
      : page.targets
          .where(
            (candidate) =>
                candidate.node == current ||
                _sameVimRect(candidate.rect, currentRect),
          )
          .firstOrNull;
  if (currentTarget != null) {
    navigator.setSelection(_vimFocusTargetId(currentTarget));
  }
  final changed = navigator.move(_vimPageMotionForDirection(direction));
  if (!changed) return false;
  final selected = navigator.selectedId;
  final target = selected == null ? null : semanticTargets[selected];
  if (target == null) return false;
  _requestVimFocus(target);
  return true;
}

String _vimFocusTargetId(_VimFocusTarget target) =>
    'focus-${identityHashCode(target.node)}';

VimPageMotion _vimPageMotionForDirection(TraversalDirection direction) {
  return switch (direction) {
    TraversalDirection.left => VimPageMotion.left,
    TraversalDirection.right => VimPageMotion.right,
    TraversalDirection.up => VimPageMotion.up,
    TraversalDirection.down => VimPageMotion.down,
  };
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
  final focusedContext = FocusManager.instance.primaryFocus?.context;
  final navigationContext = focusedContext ?? context;
  final input = VimInputModeScope.maybeOf(navigationContext);
  if (event.logicalKey == LogicalKeyboardKey.escape &&
      input?.consumeTextEscapeRelease() == true) {
    if (!_claimVimHierarchyEscape(navigationContext, event)) {
      return KeyEventResult.handled;
    }
    if (!leaveVimPageToParent(navigationContext)) {
      Navigator.maybePop(context);
    }
    return KeyEventResult.handled;
  }
  final inputResult = handleVimInputModeKey(navigationContext, event);
  if (inputResult == KeyEventResult.handled) return inputResult;
  if ((event.logicalKey == LogicalKeyboardKey.keyI ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
      enterVimPlotColumnPage(navigationContext, event)) {
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.keyI &&
      enterVimLayoutColumnPage(navigationContext, event)) {
    return KeyEventResult.handled;
  }
  if ((event.logicalKey == LogicalKeyboardKey.keyI ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) &&
      handleVimPageEntryKey(navigationContext, event)) {
    return KeyEventResult.handled;
  }
  if (handleVimPanelExportNavigationKey(navigationContext, event)) {
    return KeyEventResult.handled;
  }
  if (handleVimLayoutNavigationKey(navigationContext, event)) {
    return KeyEventResult.handled;
  }
  if (handleVimPlotNavigationKey(navigationContext, event)) {
    return KeyEventResult.handled;
  }
  if (event.logicalKey == LogicalKeyboardKey.escape) {
    if (!_claimVimHierarchyEscape(navigationContext, event)) {
      return KeyEventResult.handled;
    }
    if (vimFocusedEditable() && leaveVimTextEditing(navigationContext)) {
      return KeyEventResult.handled;
    }
    if (!leaveVimPageToParent(navigationContext)) {
      Navigator.maybePop(context);
    }
    return KeyEventResult.handled;
  }
  if (vimEditingText()) return KeyEventResult.ignored;
  final noModifier = !HardwareKeyboard.instance.isControlPressed &&
      !HardwareKeyboard.instance.isAltPressed &&
      !HardwareKeyboard.instance.isMetaPressed;
  if (noModifier &&
      (event.logicalKey == LogicalKeyboardKey.caret ||
          event.logicalKey == LogicalKeyboardKey.dollar ||
          (HardwareKeyboard.instance.isShiftPressed &&
              (event.logicalKey == LogicalKeyboardKey.digit6 ||
                  event.logicalKey == LogicalKeyboardKey.digit4)))) {
    final lineEnd = event.logicalKey == LogicalKeyboardKey.dollar ||
        (HardwareKeyboard.instance.isShiftPressed &&
            event.logicalKey == LogicalKeyboardKey.digit4);
    return moveVimLineEdge(navigationContext, last: lineEnd)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
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
    return KeyEventResult.ignored;
  }
  if (_isVimLayoutContext(navigationContext)) {
    if (moveVimLayoutFocus(navigationContext, direction)) {
      return KeyEventResult.handled;
    }
  }
  return moveVimFocus(navigationContext, direction)
      ? KeyEventResult.handled
      : KeyEventResult.ignored;
}
