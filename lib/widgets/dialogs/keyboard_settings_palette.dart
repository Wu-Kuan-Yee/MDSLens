import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/app_state.dart';
import '../../services/keyboard_shortcuts.dart';
import 'keyboard_safe_dialog.dart';

/// A keyboard-addressable equivalent of the Settings popup.  It is opened by
/// the Vim command palette, so settings remain reachable even when no pointer
/// can be used to open the toolbar menu.
class KeyboardSettingsPalette extends StatefulWidget {
  const KeyboardSettingsPalette({
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
      builder: (_) => KeyboardSettingsPalette(app: app),
    );
  }

  @override
  State<KeyboardSettingsPalette> createState() =>
      _KeyboardSettingsPaletteState();
}

class _KeyboardSettingsPaletteState extends State<KeyboardSettingsPalette> {
  static const _options = <MdsShortcutCommand>[
    MdsShortcutCommand.openWebMenu,
    MdsShortcutCommand.globalLayout,
    MdsShortcutCommand.openFontSettings,
    MdsShortcutCommand.openKeyboardShortcuts,
    MdsShortcutCommand.openKeyboardMode,
    MdsShortcutCommand.openLogin,
    MdsShortcutCommand.openSshTunnel,
    MdsShortcutCommand.openAbout,
    MdsShortcutCommand.restoreAllSettings,
  ];

  final _queryController = TextEditingController();
  final _queryFocus = FocusNode(debugLabel: 'keyboard-settings-query');
  int _selectedIndex = 0;

  List<MdsShortcutCommand> get _filteredOptions {
    final query = _queryController.text.trim().toLowerCase();
    final result = _options.where((command) {
      if (query.isEmpty) return true;
      final definition = shortcutDefinition(command);
      return '${definition.label} ${definition.category} ${definition.id}'
          .toLowerCase()
          .contains(query);
    }).toList(growable: false);
    if (_selectedIndex >= result.length) _selectedIndex = 0;
    return result;
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
    final options = _filteredOptions;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && options.isNotEmpty) {
      Navigator.pop(context, options[_selectedIndex]);
      return KeyEventResult.handled;
    }
    final backwards = event.logicalKey == LogicalKeyboardKey.arrowUp ||
        (event.logicalKey == LogicalKeyboardKey.keyK &&
            _queryController.text.isEmpty);
    final forwards = event.logicalKey == LogicalKeyboardKey.arrowDown ||
        (event.logicalKey == LogicalKeyboardKey.keyJ &&
            _queryController.text.isEmpty);
    if (backwards || forwards) {
      if (options.isNotEmpty) {
        setState(() {
          _selectedIndex = forwards
              ? (_selectedIndex + 1) % options.length
              : (_selectedIndex - 1 + options.length) % options.length;
        });
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final options = _filteredOptions;
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: KeyboardSafeDialog(
        key: const ValueKey('keyboard-settings-palette'),
        maxWidth: 620,
        maxHeight: 720,
        title: Row(
          children: [
            Icon(Icons.settings_rounded, color: colors.primary),
            const SizedBox(width: 10),
            const Flexible(child: Text('Settings')),
          ],
        ),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('keyboard-settings-query'),
              controller: _queryController,
              focusNode: _queryFocus,
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: 'Search settings, then press Enter',
              ),
              onChanged: (_) => setState(() => _selectedIndex = 0),
            ),
            const SizedBox(height: 12),
            if (options.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No matching setting', textAlign: TextAlign.center),
              )
            else
              SizedBox(
                height: 420,
                child: ListView.builder(
                  key: const ValueKey('keyboard-settings-list'),
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final command = options[index];
                    final definition = shortcutDefinition(command);
                    final selected = index == _selectedIndex;
                    return ListTile(
                      key: ValueKey('keyboard-setting-${definition.id}'),
                      selected: selected,
                      selectedTileColor:
                          colors.primaryContainer.withValues(alpha: 0.55),
                      leading: Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color:
                            selected ? colors.primary : colors.onSurfaceVariant,
                      ),
                      title: Text(definition.label),
                      subtitle: Text(definition.category),
                      trailing: Text(
                        widget.app.shortcutText(command),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                      onTap: () => Navigator.pop(context, command),
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
            key: const ValueKey('keyboard-settings-run'),
            onPressed: options.isEmpty
                ? null
                : () => Navigator.pop(context, options[_selectedIndex]),
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Open'),
          ),
        ],
      ),
    );
  }
}
