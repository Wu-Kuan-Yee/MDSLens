import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/app_state.dart';
import '../../services/keyboard_shortcuts.dart';
import 'keyboard_safe_dialog.dart';

class KeyboardShortcutsDialog {
  const KeyboardShortcutsDialog._();

  static Future<void> show(BuildContext context) async {
    final app = context.read<AppState>();
    var draft = Map<MdsShortcutCommand, MdsShortcutBinding>.from(
      app.keyboardShortcuts,
    );
    var draftRevision = 0;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          final conflicts = _conflictingStrokes(draft);
          return KeyboardSafeDialog(
            maxWidth: 760,
            maxHeight: 820,
            title: const Row(
              children: [
                Icon(Icons.keyboard_alt_outlined),
                SizedBox(width: 10),
                Flexible(child: Text('Keyboard Shortcuts')),
              ],
            ),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  shortcutPlatformDescription(),
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                for (final category in _categories) ...[
                  Text(
                    category,
                    style: Theme.of(dialogContext).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  for (final definition in mdsShortcutDefinitions.where(
                    (item) => item.category == category,
                  ))
                    _ShortcutRow(
                      key: ValueKey(
                        '${definition.id}-shortcut-$draftRevision',
                      ),
                      definition: definition,
                      binding: draft[definition.command] ??
                          const MdsShortcutBinding(),
                      conflicting: {
                        for (final stroke in (draft[definition.command] ??
                                const MdsShortcutBinding())
                            .strokes)
                          if (conflicts.contains(stroke)) stroke,
                      },
                      onChanged: (binding) => setState(() {
                        draft = Map.of(draft)..[definition.command] = binding;
                      }),
                    ),
                  const SizedBox(height: 12),
                ],
                if (conflicts.isNotEmpty)
                  Text(
                    'Resolve duplicate shortcuts before saving.',
                    style: TextStyle(
                      color: Theme.of(dialogContext).colorScheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            actions: [
              OutlinedButton.icon(
                key: const ValueKey('shortcut-reset-defaults'),
                onPressed: () {
                  FocusManager.instance.primaryFocus?.unfocus();
                  setState(() {
                    draft = restoredDefaultMdsShortcutBindings();
                    draftRevision++;
                  });
                },
                icon: const Icon(Icons.restart_alt_rounded),
                label: const Text('Restore defaults'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const ValueKey('shortcut-save'),
                onPressed: conflicts.isNotEmpty
                    ? null
                    : () {
                        app.applyKeyboardShortcuts(draft);
                        Navigator.pop(dialogContext);
                      },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }
}

const _categories = [
  'General',
  'Panel',
  'Shot',
  'Point tracking',
  'Panel navigation',
];

Set<MdsShortcutStroke> _conflictingStrokes(
  Map<MdsShortcutCommand, MdsShortcutBinding> bindings,
) {
  final counts = <MdsShortcutStroke, int>{};
  for (final binding in bindings.values) {
    for (final stroke in binding.strokes) {
      counts[stroke] = (counts[stroke] ?? 0) + 1;
    }
  }
  return {
    for (final entry in counts.entries)
      if (entry.value > 1) entry.key,
  };
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({
    super.key,
    required this.definition,
    required this.binding,
    required this.conflicting,
    required this.onChanged,
  });

  final MdsShortcutDefinition definition;
  final MdsShortcutBinding binding;
  final Set<MdsShortcutStroke> conflicting;
  final ValueChanged<MdsShortcutBinding> onChanged;

  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final controls = [
                _ShortcutCapture(
                  key: ValueKey('${definition.id}-primary'),
                  label: 'Primary',
                  value: binding.primary,
                  conflicting: binding.primary != null &&
                      conflicting.contains(binding.primary),
                  onChanged: (value) => onChanged(
                    binding.copyWith(
                        primary: value, clearPrimary: value == null),
                  ),
                ),
                _ShortcutCapture(
                  key: ValueKey('${definition.id}-alternative'),
                  label: 'Alternative',
                  value: binding.alternative,
                  conflicting: binding.alternative != null &&
                      conflicting.contains(binding.alternative),
                  onChanged: (value) => onChanged(
                    binding.copyWith(
                      alternative: value,
                      clearAlternative: value == null,
                    ),
                  ),
                ),
              ];
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(definition.label),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: controls),
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: Text(definition.label)),
                  ...controls.map(
                    (control) => Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: control,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      );
}

class _ShortcutCapture extends StatefulWidget {
  const _ShortcutCapture({
    super.key,
    required this.label,
    required this.value,
    required this.conflicting,
    required this.onChanged,
  });

  final String label;
  final MdsShortcutStroke? value;
  final bool conflicting;
  final ValueChanged<MdsShortcutStroke?> onChanged;

  @override
  State<_ShortcutCapture> createState() => _ShortcutCaptureState();
}

class _ShortcutCaptureState extends State<_ShortcutCapture> {
  final _focusNode = FocusNode();
  bool _capturing = false;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!_capturing) return KeyEventResult.ignored;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _capturing = false);
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.backspace ||
            event.logicalKey == LogicalKeyboardKey.delete)) {
      widget.onChanged(null);
      setState(() => _capturing = false);
      return KeyEventResult.handled;
    }
    final stroke = shortcutStrokeFromEvent(event);
    if (stroke == null) return KeyEventResult.handled;
    widget.onChanged(stroke);
    setState(() => _capturing = false);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.conflicting
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.outline;
    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _onKeyEvent,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: color),
          foregroundColor:
              widget.conflicting ? Theme.of(context).colorScheme.error : null,
        ),
        onPressed: () {
          setState(() => _capturing = true);
          _focusNode.requestFocus();
        },
        onLongPress: () => widget.onChanged(null),
        icon: Icon(
          _capturing ? Icons.keyboard_rounded : Icons.keyboard_alt_outlined,
          size: 17,
        ),
        label: Text(
          _capturing
              ? 'Press keys…'
              : '${widget.label}: ${widget.value?.displayText ?? 'None'}',
        ),
      ),
    );
  }
}
