import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_state.dart';
import '../../services/keyboard_shortcuts.dart';
import '../vim_focus.dart';
import 'keyboard_shortcuts.dart';
import 'keyboard_safe_dialog.dart';

/// Lets the user choose the navigation model without putting a check mark in
/// the main Settings popup.  Keeping the two choices in a dedicated panel
/// leaves the popup rows aligned and gives the keyboard-first mode enough room
/// to explain its complete keyboard workflow.
class KeyboardModeDialog {
  const KeyboardModeDialog._();

  static Future<void> show(BuildContext context) async {
    final app = context.read<AppState>();
    final selectedVim = app.vimMode;
    await showDialog<bool>(
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
  late final FocusNode _toggleShortcutNode = FocusNode(
    debugLabel: 'keyboard-mode-toggle-shortcut',
  );
  late final FocusNode _cancelNode = FocusNode(
    debugLabel: 'keyboard-mode-cancel',
  );
  late final FocusNode _applyNode = FocusNode(
    debugLabel: 'keyboard-mode-apply',
  );

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
    _toggleShortcutNode.dispose();
    _cancelNode.dispose();
    _applyNode.dispose();
    super.dispose();
  }

  KeyEventResult _handleNavigationKey(FocusNode node, KeyEvent event) {
    return handleVimKeyboardModeNavigationKey(node.context ?? context, event)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  void _selectMode(bool vim) {
    if (_selectedVim == vim) return;
    final previous = _selectedVim;
    setState(() => _selectedVim = vim);
    VimUndoScope.maybeOf(context)?.record(
      VimUndoRecord(
        pageId: 'keyboard-mode',
        undo: () {
          if (mounted) setState(() => _selectedVim = previous);
        },
        redo: () {
          if (mounted) setState(() => _selectedVim = vim);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final toggleShortcut = widget
            .app
            .keyboardShortcuts[MdsShortcutCommand.toggleVimMode]
            ?.primary
            ?.displayText ??
        'Not set';
    return KeyboardSafeDialog(
      key: const ValueKey('keyboard-mode-dialog'),
      pageId: 'keyboard-mode',
      forceVimNavigation: true,
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
          VimKeyboardModeControl(
            row: 0,
            column: 0,
            child: Focus(
              key: const ValueKey('keyboard-mode-standard'),
              focusNode: _standardNode,
              descendantsAreTraversable: false,
              onKeyEvent: _handleNavigationKey,
              child: VimActivatable(
                onActivate: () => _selectMode(false),
                child: _ModeCard(
                  selected: !_selectedVim,
                  icon: Icons.keyboard_rounded,
                  title: 'Standard Shortcuts',
                  description:
                      'Use the configurable shortcuts and the normal pointer '
                      'interaction model.',
                  onTap: () => _selectMode(false),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          VimKeyboardModeControl(
            row: 1,
            column: 0,
            child: Focus(
              key: const ValueKey('keyboard-mode-vim'),
              focusNode: _vimNode,
              descendantsAreTraversable: false,
              onKeyEvent: _handleNavigationKey,
              child: VimActivatable(
                onActivate: () => _selectMode(true),
                child: _ModeCard(
                  selected: _selectedVim,
                  icon: Icons.terminal_rounded,
                  title: 'Vim Keyboard-Only',
                  description:
                      'Use H/J/K/L to move the purple-pink selection between '
                      'controls, Enter to select, and Esc to cancel. Use : '
                      'to search every command; on a selected plot, Enter opens '
                      'its menu and Shift + H/J/K/L pans.',
                  onTap: () => _selectMode(true),
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          VimKeyboardModeControl(
            row: 2,
            column: 0,
            child: Focus(
              key: const ValueKey('keyboard-mode-toggle-shortcut'),
              focusNode: _toggleShortcutNode,
              descendantsAreTraversable: false,
              onKeyEvent: _handleNavigationKey,
              child: VimActivatable(
                onActivate: () async {
                  await KeyboardShortcutsDialog.show(context);
                  if (mounted) setState(() {});
                },
                child: OutlinedButton.icon(
                  onPressed: () async {
                    await KeyboardShortcutsDialog.show(context);
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.tune_rounded),
                  label: Text('Configure mode toggle ($toggleShortcut)'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'The mode is saved and restored when MDSLens starts again. '
            'Use J/K or the arrow keys to select a mode or configure its '
            'direct toggle shortcut, then move to Apply and press Enter. A '
            'hardware keyboard is required on mobile devices.',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        VimKeyboardModeControl(
          row: 3,
          column: 0,
          child: VimActivatable(
            onActivate: () => Navigator.pop(context, false),
            child: Focus(
              key: const ValueKey('keyboard-mode-cancel'),
              focusNode: _cancelNode,
              debugLabel: 'keyboard-mode-cancel',
              descendantsAreTraversable: false,
              onKeyEvent: _handleNavigationKey,
              child: TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
            ),
          ),
        ),
        VimKeyboardModeControl(
          row: 3,
          column: 1,
          child: VimActivatable(
            onActivate: () => widget.onApply(_selectedVim),
            child: Focus(
              key: const ValueKey('keyboard-mode-apply'),
              focusNode: _applyNode,
              debugLabel: 'keyboard-mode-apply',
              descendantsAreTraversable: false,
              onKeyEvent: _handleNavigationKey,
              child: FilledButton.icon(
                onPressed: () => widget.onApply(_selectedVim),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Apply'),
              ),
            ),
          ),
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
