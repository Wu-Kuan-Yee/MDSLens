import 'dart:async';

import 'package:mdslens/i18n/localized_material.dart';
import 'package:flutter/services.dart';

import '../../models/app_state.dart';
import '../../services/keyboard_shortcuts.dart';
import 'keyboard_safe_dialog.dart';
import '../vim_focus.dart';

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
  static const _commandItemExtent = 72.0;
  final _queryController = TextEditingController();
  final _queryFocus = FocusNode(debugLabel: 'vim-command-query');
  final _listController = ScrollController();
  int _selectedIndex = 0;
  bool _suppressQueryChanged = false;
  bool _closing = false;
  VimInputState? _vimInputState;
  VimInputMode? _previousVimMode;
  bool _suppressNextGlobalAction = false;

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
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        VimInputModeScope.setMode(context, VimInputMode.insert);
        _queryFocus.requestFocus();
        _ensureSelectedVisible();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = VimInputModeScope.maybeOf(context);
    if (identical(next, _vimInputState)) return;
    _vimInputState?.removeListener(_onVimInputModeChanged);
    _vimInputState = next;
    _previousVimMode = next?.mode;
    next?.setCommitTextOnEscape(true);
    next?.addListener(_onVimInputModeChanged);
  }

  void _onVimInputModeChanged() {
    final next = _vimInputState?.mode;
    final previous = _previousVimMode;
    if (previous != null &&
        previous != VimInputMode.normal &&
        next == VimInputMode.normal) {
      // HardwareKeyboard dispatches global handlers independently. If the
      // host handler exits Insert mode first, remember that the same physical
      // key must not subsequently close or activate the palette here.
      _suppressNextGlobalAction = true;
    }
    _previousVimMode = next;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _vimInputState?.setCommitTextOnEscape(false);
    _vimInputState?.removeListener(_onVimInputModeChanged);
    _queryController.dispose();
    _queryFocus.dispose();
    _listController.dispose();
    super.dispose();
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    if (_suppressNextGlobalAction) {
      _suppressNextGlobalAction = false;
      return true;
    }
    // The command line is a real Vim editor.  Let the shared modal handler
    // consume Insert/Visual-mode keys (especially the first Escape) before
    // the palette's own Escape-to-close behavior runs.  Returning false for
    // ordinary Insert-mode characters leaves them to EditableText.
    if (vimEditingText()) {
      final inputResult = handleVimInputModeKey(context, event);
      if (inputResult == KeyEventResult.handled) {
        // This handler itself performed the modal transition; do not suppress
        // the next unrelated key as well.
        _suppressNextGlobalAction = false;
        return true;
      }
      return false;
    }
    return _handleKeyEvent(_queryFocus, event) == KeyEventResult.handled;
  }

  void _ensureSelectedVisible() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final commands = _commands;
      if (commands.isEmpty || _selectedIndex >= commands.length) return;
      if (!_listController.hasClients) return;
      final position = _listController.position;
      final centeredOffset = _selectedIndex * _commandItemExtent -
          (position.viewportDimension - _commandItemExtent) / 2;
      final target = centeredOffset.clamp(0.0, position.maxScrollExtent);
      if ((position.pixels - target).abs() < 0.5) return;
      unawaited(
        _listController.animateTo(
          target,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _selectIndex(int index) {
    setState(() => _selectedIndex = index);
    _ensureSelectedVisible();
  }

  void _handleQueryChanged(String value) {
    if (_suppressQueryChanged || value.isEmpty) {
      _selectIndex(0);
      return;
    }
    // A blank Vim command line uses j/k for list navigation. Handling the
    // character at the controller boundary also covers platforms where the
    // editable text node consumes the physical key before its parent Focus.
    final appVim = VimModeScope.enabled(context);
    if (appVim && (value == 'j' || value == 'k')) {
      _suppressQueryChanged = true;
      _queryController.clear();
      _suppressQueryChanged = false;
      final commands = _commands;
      if (commands.isNotEmpty) {
        final next = value == 'j'
            ? (_selectedIndex + 1) % commands.length
            : (_selectedIndex - 1 + commands.length) % commands.length;
        _selectIndex(next);
      }
      return;
    }
    _selectIndex(0);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final commands = _commands;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && commands.isNotEmpty) {
      _pop(commands[_selectedIndex].command);
      return KeyEventResult.handled;
    }
    final backwards = event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.keyK;
    final forwards = event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.keyJ;
    if (backwards || forwards) {
      if (commands.isNotEmpty) {
        final nextIndex = forwards
            ? (_selectedIndex + 1) % commands.length
            : (_selectedIndex - 1 + commands.length) % commands.length;
        _selectIndex(nextIndex);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _submit() {
    final commands = _commands;
    if (commands.isNotEmpty) {
      _pop(commands[_selectedIndex].command);
    }
  }

  void _pop([MdsShortcutCommand? command]) {
    if (_closing) return;
    _closing = true;
    _queryFocus.unfocus();
    VimInputModeScope.setMode(context, VimInputMode.normal);
    Navigator.pop(context, command);
    requestVimWorkspaceFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      requestVimWorkspaceFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        requestVimWorkspaceFocus();
      });
    });
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
            Flexible(child: Text('Vim Command')),
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
              readOnly: vimTextFieldReadOnly(context),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: context.tr('Type a command, then press Enter'),
                suffixIcon: IconButton(
                  tooltip: context.tr('Clear command'),
                  onPressed: () {
                    _queryController.clear();
                    _selectIndex(0);
                  },
                  icon: const Icon(Icons.clear_rounded),
                ),
              ),
              onChanged: _handleQueryChanged,
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
                  controller: _listController,
                  itemExtent: _commandItemExtent,
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
                      onTap: () => _pop(definition.command),
                    );
                  },
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _pop,
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
