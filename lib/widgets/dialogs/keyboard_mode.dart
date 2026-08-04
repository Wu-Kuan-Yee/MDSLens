import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/app_state.dart';
import 'keyboard_safe_dialog.dart';

/// Lets the user choose the navigation model without putting a check mark in
/// the main Settings popup.  Keeping the two choices in a dedicated panel
/// leaves the popup rows aligned and gives the keyboard-first mode enough room
/// to explain its complete keyboard workflow.
class KeyboardModeDialog {
  const KeyboardModeDialog._();

  static Future<void> show(
    BuildContext context, {
    bool previewToggle = false,
  }) async {
    final app = context.read<AppState>();
    final previousVim = app.vimMode;
    var selectedVim = previewToggle ? !previousVim : previousVim;
    if (previewToggle) app.setVimMode(selectedVim);
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => _KeyboardModePanel(
        initialVim: selectedVim,
        app: app,
        onApply: (value) {
          app.setVimMode(value);
          Navigator.pop(dialogContext, true);
        },
      ),
    );
    if (previewToggle && result != true) app.setVimMode(previousVim);
  }
}

class _KeyboardModePanel extends StatefulWidget {
  const _KeyboardModePanel({
    required this.initialVim,
    required this.app,
    required this.onApply,
  });

  final bool initialVim;
  final AppState app;
  final ValueChanged<bool> onApply;

  @override
  State<_KeyboardModePanel> createState() => _KeyboardModePanelState();
}

class _KeyboardModePanelState extends State<_KeyboardModePanel> {
  late bool _selectedVim = widget.initialVim;
  late final FocusNode _standardNode = FocusNode(
    debugLabel: 'keyboard-mode-standard',
  );
  late final FocusNode _vimNode = FocusNode(debugLabel: 'keyboard-mode-vim');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) (_selectedVim ? _vimNode : _standardNode).requestFocus();
    });
  }

  @override
  void dispose() {
    _standardNode.dispose();
    _vimNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleChoiceKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      setState(() => _selectedVim = identical(node, _vimNode));
      widget.onApply(_selectedVim);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.space) {
      setState(() => _selectedVim = identical(node, _vimNode));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return KeyboardSafeDialog(
      key: const ValueKey('keyboard-mode-dialog'),
      maxWidth: 620,
      title: Row(
        children: [
          Icon(Icons.keyboard_alt_rounded, color: colors.primary),
          const SizedBox(width: 10),
          const Flexible(child: Text('Keyboard Mode')),
        ],
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Focus(
            key: const ValueKey('keyboard-mode-standard'),
            focusNode: _standardNode,
            onKeyEvent: _handleChoiceKey,
            child: _ModeCard(
              selected: !_selectedVim,
              icon: Icons.keyboard_rounded,
              title: 'Standard Shortcuts',
              description:
                  'Use the configurable shortcuts and the normal pointer '
                  'interaction model.',
              onTap: () => setState(() => _selectedVim = false),
            ),
          ),
          const SizedBox(height: 10),
          Focus(
            key: const ValueKey('keyboard-mode-vim'),
            focusNode: _vimNode,
            onKeyEvent: _handleChoiceKey,
            child: _ModeCard(
              selected: _selectedVim,
              icon: Icons.terminal_rounded,
              title: 'Vim Keyboard-Only',
              description:
                  'Use H/J/K/L to move the purple-pink selection between '
                  'controls, Enter to activate, and Esc to cancel. Use : '
                  'to search every command; on a selected plot, Enter opens '
                  'its menu and Shift + H/J/K/L pans.',
              onTap: () => setState(() => _selectedVim = true),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'The mode is saved and restored when MDSLens starts again. '
            'Use Up/Left or K/H for Standard, Down/Right or J/L for Vim, '
            'then press Enter to apply. A hardware keyboard is required on '
            'mobile devices.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('keyboard-mode-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          key: const ValueKey('keyboard-mode-apply'),
          onPressed: () => widget.onApply(_selectedVim),
          icon: const Icon(Icons.check_rounded),
          label: const Text('Apply'),
        ),
      ],
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: selected
          ? colors.primaryContainer.withValues(alpha: 0.55)
          : colors.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 1.6 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: colors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
