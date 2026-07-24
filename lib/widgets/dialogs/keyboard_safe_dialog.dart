import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

class KeyboardSafeDialog extends StatelessWidget {
  const KeyboardSafeDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.maxWidth = 440,
    this.maxHeight = 620,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;
  final double maxWidth;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      key: const ValueKey('keyboard-safe-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: maxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: DefaultTextStyle(
                style: theme.textTheme.titleLarge!,
                child: title,
              ),
            ),
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
            Padding(
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
            ),
          ],
        ),
      ),
    );
  }
}
