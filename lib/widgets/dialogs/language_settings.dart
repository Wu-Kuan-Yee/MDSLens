import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:mdslens/i18n/localized_material.dart';

import '../../i18n/language_service.dart';
import '../../models/app_state.dart';
import '../polished_dropdown.dart';
import 'keyboard_safe_dialog.dart';

class LanguageSettingsDialog extends StatefulWidget {
  const LanguageSettingsDialog({
    super.key,
    required this.app,
  });

  final AppState app;

  static Future<void> show(BuildContext context, AppState app) {
    return showDialog<void>(
      context: context,
      builder: (_) => LanguageSettingsDialog(app: app),
    );
  }

  @override
  State<LanguageSettingsDialog> createState() => _LanguageSettingsDialogState();
}

class _LanguageSettingsDialogState extends State<LanguageSettingsDialog> {
  late String _preference;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _preference = widget.app.languagePreference;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.app.refreshLanguages();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _importLanguage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['toml'],
        allowMultiple: false,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      if (bytes == null) {
        throw const FormatException(
            'The selected language file is unreadable.');
      }
      await widget.app.languages.install(file.name, utf8.decode(bytes));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              'Could not import the language file: {value1}',
              {'value1': error},
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: widget.app.languages,
      builder: (context, _) {
        final languages = widget.app.languages.availableLanguages;
        final available = languages.map((item) => item.locale).toSet();
        final selected = _preference == systemLanguagePreference ||
                available.contains(_preference)
            ? _preference
            : systemLanguagePreference;
        return KeyboardSafeDialog(
          maxWidth: 520,
          title: Row(
            children: [
              Icon(Icons.translate_rounded, color: colors.primary),
              const SizedBox(width: 10),
              Flexible(child: Text(context.tr('Language Settings'))),
            ],
          ),
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr(
                  'The language follows the operating system and changes without restarting MDSLens.',
                ),
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Text(
                context.tr('Available languages'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              PolishedDropdown<String>(
                key: const ValueKey('language-dropdown'),
                id: 'language',
                value: selected,
                leadingIcon: Icons.translate_rounded,
                menuMaxHeight: 360,
                menuLabelMaxLines: null,
                matchAnchorWidth: true,
                showScrollbar: true,
                options: [
                  PolishedDropdownOption(
                    value: systemLanguagePreference,
                    label: context.tr('System (automatic)'),
                    icon: Icons.devices_rounded,
                  ),
                  for (final language in languages)
                    PolishedDropdownOption(
                      value: language.locale,
                      label: language.displayName,
                      icon: Icons.language_rounded,
                    ),
                ],
                onChanged: (value) => setState(() => _preference = value),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr(
                        '{count} language file(s) detected',
                        {'count': languages.length},
                      ),
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('refresh-language-files'),
                    tooltip: context.tr('Refresh language files'),
                    onPressed: _refreshing ? null : () => unawaited(_refresh()),
                    icon: _refreshing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                  const SizedBox(width: 4),
                  OutlinedButton.icon(
                    key: const ValueKey('import-language-file'),
                    onPressed: () => unawaited(_importLanguage()),
                    icon: const Icon(Icons.file_open_rounded),
                    label: Text(context.tr('Import...')),
                  ),
                ],
              ),
              for (final language in languages)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.description_outlined),
                  title: Text(language.displayName),
                  subtitle: Text(language.source),
                  trailing: IconButton(
                    tooltip: context.tr('Remove language file'),
                    onPressed: () => unawaited(
                      widget.app.languages.remove(language.source),
                    ),
                    icon: const Icon(Icons.delete_outline_rounded),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.tr('Cancel')),
            ),
            FilledButton(
              key: const ValueKey('apply-language'),
              onPressed: () {
                widget.app.setLanguagePreference(selected);
                Navigator.pop(context);
              },
              child: Text(context.tr('Apply')),
            ),
          ],
        );
      },
    );
  }
}
