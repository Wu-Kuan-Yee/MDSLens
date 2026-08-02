import 'package:flutter/material.dart';

import '../models/app_state.dart';
import 'dialogs/keyboard_safe_dialog.dart';

/// Ask how the shot metadata in an external document should be applied.
///
/// The document is already parsed before this dialog is shown, so the user
/// can see every distinct shot rather than being asked about an arbitrary
/// first value.  Returning null means the dialog was dismissed/cancelled.
Future<ImportedConfigurationDecision?> showImportedConfigurationDecision(
  BuildContext context,
  ImportedConfigurationSummary summary,
) {
  var retainShots = false;
  var retainFixedShots = false;

  return showDialog<ImportedConfigurationDecision>(
    context: context,
    builder: (dialogContext) {
      final colors = Theme.of(dialogContext).colorScheme;
      return StatefulBuilder(
        builder: (context, setState) {
          final shotLabel = summary.shots.length == 1 ? 'shot' : 'shots';
          final fixedLabel = summary.fixedSignalCount == 1
              ? 'signal is marked fixed'
              : 'signals are marked fixed';
          return KeyboardSafeDialog(
            maxWidth: 560,
            title: const Row(
              children: [
                Icon(Icons.numbers_rounded),
                SizedBox(width: 10),
                Flexible(child: Text('Use the configuration shot?')),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Text(
                      summary.hasShots
                          ? 'This file contains ${summary.shots.length} distinct $shotLabel. '
                              'Choose which shot metadata to keep for the initial load.'
                          : 'This file does not contain a shot number. You can still choose '
                              'whether to keep its per-signal fixed-shot settings.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                  if (summary.hasShots) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Recognized shots',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 150),
                      child: Scrollbar(
                        thumbVisibility: summary.shots.length > 5,
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: summary.shots.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, index) => ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 13,
                              backgroundColor: colors.primaryContainer,
                              foregroundColor: colors.onPrimaryContainer,
                              child: Text('${index + 1}'),
                            ),
                            title: Text(summary.shots[index]),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  CheckboxListTile(
                    key: const ValueKey(
                      'retain-imported-configuration-shots',
                    ),
                    value: retainShots,
                    onChanged: summary.hasShots
                        ? (value) => setState(() {
                              retainShots = value ?? false;
                            })
                        : null,
                    title: const Text('Keep all recognized shot numbers'),
                    subtitle: const Text(
                      'Preserve global, panel, and per-signal shots for the initial load.',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                  CheckboxListTile(
                    key: const ValueKey(
                      'retain-imported-configuration-shot-fixed',
                    ),
                    value: retainFixedShots,
                    onChanged: summary.hasSignals
                        ? (value) => setState(() {
                              retainFixedShots = value ?? false;
                            })
                        : null,
                    title: const Text('Keep fixed-shot settings'),
                    subtitle: Text(
                      summary.hasSignals
                          ? '${summary.signalCount} signals; $fixedLabel.'
                          : 'No signal settings were found.',
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            actions: [
              FilledButton.icon(
                key: const ValueKey('ignore-imported-configuration-shot'),
                autofocus: true,
                onPressed: () => Navigator.pop(
                  dialogContext,
                  const ImportedConfigurationDecision(),
                ),
                icon: const Icon(Icons.visibility_off_outlined),
                label: const Text('Ignore imported shot settings'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('use-imported-configuration-shot'),
                onPressed: () => Navigator.pop(
                  dialogContext,
                  ImportedConfigurationDecision(
                    retainShots: retainShots,
                    retainFixedShots: retainFixedShots,
                  ),
                ),
                icon: const Icon(Icons.check_circle_outline_rounded),
                label: const Text('Apply selected settings'),
              ),
            ],
          );
        },
      );
    },
  );
}
