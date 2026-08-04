import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_state.dart';
import '../../services/keyboard_shortcuts.dart';
import 'keyboard_safe_dialog.dart';

/// A small Vim-style command line.  It gives every application action a
/// discoverable keyboard path without requiring users to memorize shortcuts.
class VimCommandPalette extends StatefulWidget {
  const VimCommandPalette({
    super.key,
    required this.app,
  });

  final AppState app;

  static Future<MdsShortcutCommand?> show(
    BuildContext context,
    AppState app,
  ) {
    return showDialog<MdsShortcutCommand>(
      context: context,
      builder: (_) => VimCommandPalette(app: app),
    );
  }

  @override
  State<VimCommandPalette> createState() => _VimCommandPaletteState();
}

class _VimCommandPaletteState extends State<VimCommandPalette> {
  final _queryController = TextEditingController();
  final _queryFocus = FocusNode(debugLabel: 'vim-command-query');
  int _selectedIndex = 0;

  List<MdsShortcutDefinition> get _commands {
    final query = _queryController.text.trim().toLowerCase();
    final commands = mdsShortcutDefinitions
        .where(
      (definition) =>
          definition.command != MdsShortcutCommand.menuLeft &&
          definition.command != MdsShortcutCommand.menuDown &&
          definition.command != MdsShortcutCommand.menuUp &&
          definition.command != MdsShortcutCommand.menuRight &&
          definition.command != MdsShortcutCommand.menuActivate,
    )
        .where((definition) {
      if (query.isEmpty) return true;
      final haystack =
          '${definition.label} ${definition.id} ${definition.category}'
              .toLowerCase();
      return haystack.contains(query);
    }).toList(growable: false);
    if (_selectedIndex >= commands.length) _selectedIndex = 0;
    return commands;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _queryController.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final commands = _commands;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && commands.isNotEmpty) {
      Navigator.pop(context, commands[_selectedIndex].command);
      return KeyEventResult.handled;
    }
    final backwards = event.logicalKey == LogicalKeyboardKey.arrowUp ||
        (event.logicalKey == LogicalKeyboardKey.keyK &&
            _queryController.text.isEmpty);
    final forwards = event.logicalKey == LogicalKeyboardKey.arrowDown ||
        (event.logicalKey == LogicalKeyboardKey.keyJ &&
            _queryController.text.isEmpty);
    if (backwards || forwards) {
      if (commands.isNotEmpty) {
        setState(() {
          _selectedIndex = forwards
              ? (_selectedIndex + 1) % commands.length
              : (_selectedIndex - 1 + commands.length) % commands.length;
        });
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _submit() {
    final commands = _commands;
    if (commands.isNotEmpty) {
      Navigator.pop(context, commands[_selectedIndex].command);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final commands = _commands;
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: KeyboardSafeDialog(
        key: const ValueKey('vim-command-palette'),
        maxWidth: 620,
        maxHeight: 700,
        title: const Row(
          children: [
            Icon(Icons.terminal_rounded),
            SizedBox(width: 10),
            Flexible(child: Text('Vim command')),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('vim-command-query'),
              controller: _queryController,
              focusNode: _queryFocus,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'Type a command, then press Enter',
                suffixIcon: IconButton(
                  tooltip: 'Clear command',
                  onPressed: () {
                    _queryController.clear();
                    setState(() => _selectedIndex = 0);
                  },
                  icon: const Icon(Icons.clear_rounded),
                ),
              ),
              onChanged: (_) => setState(() => _selectedIndex = 0),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            if (commands.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Text(
                  'No matching command',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                ),
              )
            else
              SizedBox(
                height: 390,
                child: ListView.builder(
                  key: const ValueKey('vim-command-list'),
                  itemCount: commands.length,
                  itemBuilder: (context, index) {
                    final definition = commands[index];
                    final selected = index == _selectedIndex;
                    return ListTile(
                      key: ValueKey('vim-command-${definition.id}'),
                      selected: selected,
                      selectedTileColor:
                          theme.colorScheme.primaryContainer.withValues(
                        alpha: 0.55,
                      ),
                      leading: Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(definition.label),
                      subtitle: Text(definition.category),
                      trailing: Text(
                        widget.app.shortcutText(definition.command),
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                      onTap: () => Navigator.pop(context, definition.command),
                    );
                  },
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            key: const ValueKey('vim-command-run'),
            onPressed: commands.isEmpty ? null : _submit,
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Run'),
          ),
        ],
      ),
    );
  }
}
