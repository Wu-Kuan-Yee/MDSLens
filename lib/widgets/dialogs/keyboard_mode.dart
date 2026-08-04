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
  final _focusNode = FocusNode(debugLabel: 'keyboard-mode-panel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.keyK:
      case LogicalKeyboardKey.keyH:
        setState(() => _selectedVim = false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.keyJ:
      case LogicalKeyboardKey.keyL:
        setState(() => _selectedVim = true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
        widget.onApply(_selectedVim);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        Navigator.pop(context, false);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Focus(
      key: const ValueKey('keyboard-mode-focus'),
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: KeyboardSafeDialog(
        key: const ValueKey('keyboard-mode-dialog'),
        maxWidth: 620,
        title: Row(
          children: [
            Icon(Icons.keyboard_alt_rounded, color: colors.primary),
            const SizedBox(width: 10),
            const Flexible(child: Text('Keyboard mode')),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ModeCard(
              key: const ValueKey('keyboard-mode-standard'),
              selected: !_selectedVim,
              icon: Icons.keyboard_rounded,
              title: 'Standard shortcuts',
              description:
                  'Use the configurable shortcuts and the normal pointer '
                  'interaction model.',
              onTap: () => setState(() => _selectedVim = false),
            ),
            const SizedBox(height: 10),
            _ModeCard(
              key: const ValueKey('keyboard-mode-vim'),
              selected: _selectedVim,
              icon: Icons.terminal_rounded,
              title: 'Vim keyboard-only',
              description:
                  'Use : to search every command, H/J/K/L to select panels, '
                  'C to open a selected panel menu, Shift + H/J/K/L to pan, '
                  'and [ / ] to zoom.',
              onTap: () => setState(() => _selectedVim = true),
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
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  const _ModeCard({
    super.key,
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
