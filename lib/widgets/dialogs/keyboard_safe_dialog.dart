import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../vim_focus.dart';

void focusAndShowKeyboard(BuildContext context, FocusNode focusNode) {
  void ensureInputConnection() {
    if (!context.mounted || !focusNode.canRequestFocus) return;
    if (!focusNode.hasFocus) focusNode.requestFocus();
    unawaited(_showTextInputIfFocused(context, focusNode));
  }

  ensureInputConnection();
  WidgetsBinding.instance.addPostFrameCallback((_) => ensureInputConnection());
  unawaited(
    Future<void>.delayed(
      const Duration(milliseconds: 80),
      ensureInputConnection,
    ),
  );
}

Future<void> _showTextInputIfFocused(
  BuildContext context,
  FocusNode focusNode,
) async {
  if (!context.mounted || !focusNode.hasFocus) return;
  try {
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  } catch (_) {
    // Some desktop embedders do not expose an on-screen keyboard. The focus
    // transfer is still valid there, so a missing platform handler is harmless.
  }
}

class DialogResourceOwner extends StatefulWidget {
  const DialogResourceOwner({
    super.key,
    required this.child,
    required this.onDispose,
  });

  final Widget child;
  final VoidCallback onDispose;

  @override
  State<DialogResourceOwner> createState() => _DialogResourceOwnerState();
}

class _DialogResourceOwnerState extends State<DialogResourceOwner> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AdaptiveTwoAxisScrollView extends StatefulWidget {
  const AdaptiveTwoAxisScrollView({
    super.key,
    required this.child,
    required this.keyPrefix,
    this.enableHorizontal = false,
    this.enableVertical = true,
    this.showHorizontalScrollbar = false,
    this.showVerticalScrollbar = false,
    this.minContentWidth = 0,
  });

  final Widget child;
  final String keyPrefix;
  final bool enableHorizontal;
  final bool enableVertical;
  final bool showHorizontalScrollbar;
  final bool showVerticalScrollbar;
  final double minContentWidth;

  @override
  State<AdaptiveTwoAxisScrollView> createState() =>
      _AdaptiveTwoAxisScrollViewState();
}

class _AdaptiveTwoAxisScrollViewState extends State<AdaptiveTwoAxisScrollView> {
  final _horizontalController = ScrollController();
  final _verticalController = ScrollController();

  @override
  void dispose() {
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget result = widget.child;
    if (widget.enableHorizontal) {
      result = Scrollbar(
        key: ValueKey('${widget.keyPrefix}-horizontal-scrollbar'),
        controller: _horizontalController,
        thumbVisibility: widget.showHorizontalScrollbar,
        interactive: true,
        child: SingleChildScrollView(
          key: ValueKey('${widget.keyPrefix}-horizontal-scroll'),
          controller: _horizontalController,
          scrollDirection: Axis.horizontal,
          child: widget.minContentWidth > 0
              ? SizedBox(width: widget.minContentWidth, child: result)
              : result,
        ),
      );
    }
    if (widget.enableVertical) {
      result = Scrollbar(
        key: ValueKey('${widget.keyPrefix}-vertical-scrollbar'),
        controller: _verticalController,
        thumbVisibility: widget.showVerticalScrollbar,
        interactive: true,
        child: SingleChildScrollView(
          key: ValueKey('${widget.keyPrefix}-vertical-scroll'),
          controller: _verticalController,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: result,
        ),
      );
    }
    return result;
  }
}

class KeyboardSafeDialog extends StatefulWidget {
  const KeyboardSafeDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.pageId = 'dialog',
    this.parentPageId,
    this.forceVimNavigation = false,
    this.onEscape,
    this.escapeInterceptionListenable,
    this.shouldInterceptEscape,
    this.maxWidth = 440,
    this.maxHeight = 620,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final String pageId;

  /// Explicit semantic parent. When omitted, the dialog captures the current
  /// focused Vim page as it opens, which keeps ordinary nested dialogs from
  /// dropping focus back to the workspace on close.
  final String? parentPageId;
  final bool forceVimNavigation;

  /// Gives an owning transient interaction (such as a drag operation) a
  /// chance to consume Escape without closing this dialog.  It is deliberately
  /// only consulted outside Vim mode so Vim's page hierarchy keeps owning Esc.
  final bool Function()? onEscape;

  /// Rebuilds the route's pop guard while a transient operation is active.
  /// This is needed because desktop Flutter routes can turn Escape directly
  /// into a dismiss intent before a non-focusable dialog shell sees the key.
  final Listenable? escapeInterceptionListenable;

  /// When true, an attempted route pop is converted into [onEscape].
  final bool Function()? shouldInterceptEscape;
  final double maxWidth;
  final double maxHeight;

  @override
  State<KeyboardSafeDialog> createState() => _KeyboardSafeDialogState();
}

class _KeyboardSafeDialogState extends State<KeyboardSafeDialog> {
  late final String _resolvedParentPageId;
  late final FocusNode? _parentFocusNode;

  @override
  void initState() {
    super.initState();
    final focused = FocusManager.instance.primaryFocus;
    final focusedContext = focused?.context;
    _resolvedParentPageId = widget.parentPageId ??
        focusedContext?.findAncestorWidgetOfExactType<VimPageScope>()?.pageId ??
        context.findAncestorWidgetOfExactType<VimPageScope>()?.pageId ??
        'root';
    _parentFocusNode = focused != null &&
            focused.canRequestFocus &&
            !focused.skipTraversal &&
            focusedContext != null &&
            focusedContext.mounted
        ? focused
        : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _requestInitialVimFocus();
      });
    });
  }

  void _requestInitialVimFocus() {
    if (!mounted ||
        !VimModeScope.enabled(context) ||
        widget.forceVimNavigation) {
      return;
    }
    final current = FocusManager.instance.primaryFocus;
    final route = ModalRoute.of(context);
    final currentRoute =
        current?.context == null ? null : ModalRoute.of(current!.context!);
    final currentPage =
        current?.context?.findAncestorWidgetOfExactType<VimPageScope>()?.pageId;
    if (current != null &&
        current.canRequestFocus &&
        route != null &&
        identical(route, currentRoute) &&
        currentPage == widget.pageId) {
      return;
    }
    final candidates = FocusManager.instance.rootScope.descendants
        .where(
          (node) {
            final nodeContext = node.context;
            if (nodeContext == null) return false;
            final nodeRoute = ModalRoute.of(nodeContext);
            return (route == null || nodeRoute == null || nodeRoute == route) &&
                nodeContext
                        .findAncestorWidgetOfExactType<VimPageScope>()
                        ?.pageId ==
                    widget.pageId;
          },
        )
        .where((node) => node.canRequestFocus && !node.skipTraversal)
        .toList(growable: false);
    final first = widget.pageId == 'layout'
        ? candidates
                .where(
                  (node) =>
                      node.context
                          ?.findAncestorWidgetOfExactType<VimLayoutFocus>()
                          ?.isColumn ==
                      true,
                )
                .firstOrNull ??
            candidates.firstOrNull
        : candidates.firstOrNull;
    first?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final tinyWidth = screenSize.width < 360;
    final tinyHeight = screenSize.height < 480;
    final tinyScreen = tinyWidth || tinyHeight;

    Widget observedContent() =>
        SizeChangedLayoutNotifier(child: widget.content);

    Widget focusShell(Widget dialog) {
      final geometryAwareDialog =
          NotificationListener<SizeChangedLayoutNotification>(
        onNotification: (_) {
          scheduleVimFocusVisualRefresh();
          return false;
        },
        child: SizeChangedLayoutNotifier(child: dialog),
      );
      Widget popScope() => PopScope(
            canPop: widget.shouldInterceptEscape?.call() != true,
            onPopInvokedWithResult: (didPop, __) {
              if (!didPop &&
                  !VimModeScope.enabled(context) &&
                  widget.shouldInterceptEscape?.call() == true &&
                  widget.onEscape?.call() == true) {
                return;
              }
              VimInputModeScope.setMode(context, VimInputMode.normal);
              if (didPop && VimModeScope.enabled(context)) {
                scheduleVimPageParentFocus(
                  _resolvedParentPageId,
                  preferredFocus: _parentFocusNode,
                );
              }
            },
            child: FocusTraversalGroup(
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (node, event) {
                  final isEscape = event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape;
                  if (isEscape &&
                      !VimModeScope.enabled(context) &&
                      widget.onEscape?.call() == true) {
                    return KeyEventResult.handled;
                  }
                  return handleVimDialogKey(node.context ?? context, event);
                },
                child: geometryAwareDialog,
              ),
            ),
          );
      return VimPageScope(
        pageId: widget.pageId,
        parentPageId: _resolvedParentPageId,
        transient: true,
        forceNavigation: widget.forceVimNavigation,
        child: widget.escapeInterceptionListenable == null
            ? popScope()
            : ListenableBuilder(
                listenable: widget.escapeInterceptionListenable!,
                builder: (context, _) => popScope(),
              ),
      );
    }

    Widget header() => Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: DefaultTextStyle(
              style: theme.textTheme.titleLarge!, child: widget.title),
        );

    Widget actionBar() => Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: widget.actions,
            ),
          ),
        );

    if (tinyScreen) {
      final viewportWidth =
          (screenSize.width - 24).clamp(80.0, widget.maxWidth).toDouble();
      final viewportHeight =
          (screenSize.height - 24).clamp(80.0, widget.maxHeight).toDouble();
      final contentWidth = tinyWidth ? 320.0 : viewportWidth;
      return focusShell(
        Dialog(
          key: const ValueKey('keyboard-safe-dialog'),
          insetPadding: const EdgeInsets.all(12),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: viewportWidth,
            height: viewportHeight,
            child: AdaptiveTwoAxisScrollView(
              keyPrefix: 'adaptive-dialog',
              enableHorizontal: tinyWidth,
              enableVertical: true,
              showHorizontalScrollbar: tinyWidth,
              showVerticalScrollbar: true,
              minContentWidth: contentWidth,
              child: SizedBox(
                width: contentWidth,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    header(),
                    Divider(height: 1, color: theme.dividerColor),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                      child: observedContent(),
                    ),
                    Divider(height: 1, color: theme.dividerColor),
                    actionBar(),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return focusShell(
      Dialog(
        key: const ValueKey('keyboard-safe-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: widget.maxWidth,
            maxHeight: widget.maxHeight,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header(),
              Divider(height: 1, color: theme.dividerColor),
              Flexible(
                child: Scrollbar(
                  child: SingleChildScrollView(
                    key: const ValueKey('keyboard-safe-dialog-scroll'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: observedContent(),
                  ),
                ),
              ),
              Divider(height: 1, color: theme.dividerColor),
              actionBar(),
            ],
          ),
        ),
      ),
    );
  }
}
