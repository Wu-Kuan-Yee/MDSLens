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

class KeyboardSafeDialog extends StatelessWidget {
  const KeyboardSafeDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.pageId = 'dialog',
    this.forceVimNavigation = false,
    this.maxWidth = 440,
    this.maxHeight = 620,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final String pageId;
  final bool forceVimNavigation;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final tinyWidth = screenSize.width < 360;
    final tinyHeight = screenSize.height < 480;
    final tinyScreen = tinyWidth || tinyHeight;

    Widget focusShell(Widget dialog) {
      return VimPageScope(
        pageId: pageId,
        parentPageId: 'root',
        transient: true,
        forceNavigation: forceVimNavigation,
        child: PopScope(
          onPopInvokedWithResult: (_, __) {
            VimInputModeScope.setMode(context, VimInputMode.normal);
          },
          child: FocusTraversalGroup(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (node, event) =>
                  handleVimDialogKey(node.context ?? context, event),
              child: dialog,
            ),
          ),
        ),
      );
    }

    Widget header() => Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: DefaultTextStyle(
              style: theme.textTheme.titleLarge!, child: title),
        );

    Widget actionBar() => Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ),
        );

    if (tinyScreen) {
      final viewportWidth =
          (screenSize.width - 24).clamp(80.0, maxWidth).toDouble();
      final viewportHeight =
          (screenSize.height - 24).clamp(80.0, maxHeight).toDouble();
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
                      child: content,
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
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
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
                    child: content,
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
