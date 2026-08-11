import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mdslens/i18n/localized_material.dart';

import '../../i18n/language_document.dart';
import '../../i18n/language_service.dart';
import '../../models/app_state.dart';
import '../polished_dropdown.dart';
import '../vim_focus.dart';
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
  bool _languageListEntered = false;
  late final FocusNode _languageListEntryFocusNode;
  late final FocusScopeNode _languageListScopeNode;
  final Set<String> _selectedLanguageSources = <String>{};

  @override
  void initState() {
    super.initState();
    _preference = widget.app.languagePreference;
    _languageListEntryFocusNode = FocusNode(
      debugLabel: 'language-list-page',
    );
    _languageListScopeNode = FocusScopeNode(
      debugLabel: 'language-list-page-scope',
    );
  }

  @override
  void dispose() {
    _languageListEntryFocusNode.dispose();
    _languageListScopeNode.dispose();
    super.dispose();
  }

  void _enterLanguageList() {
    if (_languageListEntered || !mounted) return;
    setState(() => _languageListEntered = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_languageListEntered) return;
      final candidates = _languageListScopeNode.traversalDescendants
          .where((node) => node.canRequestFocus && !node.skipTraversal)
          .toList();
      if (candidates.isNotEmpty) {
        _languageListScopeNode.requestFocus(candidates.first);
      }
    });
  }

  void _leaveLanguageList() {
    if (!_languageListEntered || !mounted) return;
    setState(() => _languageListEntered = false);
    scheduleVimPageParentFocus(
      'language-settings',
      preferredFocus: _languageListEntryFocusNode,
    );
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
        allowMultiple: true,
        // file_picker's macOS backend intentionally does not support
        // `withData`; it returns the selected paths instead.  Keep bytes
        // enabled for web and the other platforms, and use the existing
        // XFile fallback below for macOS.
        withData: kIsWeb || defaultTargetPlatform != TargetPlatform.macOS,
        readSequential: true,
      );
      if (result == null || result.files.isEmpty) return;
      final documents = <StoredLanguageDocument>[];
      for (final file in result.files) {
        final bytes = file.bytes ?? await file.xFile.readAsBytes();
        documents.add(
          StoredLanguageDocument(
            name: file.name,
            content: utf8.decode(bytes),
          ),
        );
      }
      await widget.app.languages.installAll(documents);
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

  void _showUnavailableSystemLanguage() {
    final message = context.tr(
      'No installed language file matches the current system language. Select an installed language instead.',
    );
    unawaited(
      showDialog<void>(
        context: context,
        builder: (dialogContext) => KeyboardSafeDialog(
          pageId: 'language-settings-system-unavailable',
          parentPageId: 'language-settings',
          maxWidth: 440,
          title: Row(
            children: [
              Icon(
                Icons.language_rounded,
                color: Theme.of(dialogContext).colorScheme.primary,
              ),
              const SizedBox(width: 10),
              Flexible(child: Text(context.tr('System (automatic)'))),
            ],
          ),
          content: Text(message),
          actions: [
            FilledButton(
              key: const ValueKey('language-system-unavailable-ok'),
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.tr('OK')),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLanguageRemoval(Iterable<String> sources) async {
    final requested = sources.toSet();
    final languages = widget.app.languages.availableLanguages
        .where((language) => requested.contains(language.source))
        .toList(growable: false);
    if (languages.isEmpty) return;

    final preview =
        languages.map((language) => language.displayName).take(5).join(', ');
    final suffix = languages.length > 5 ? ', …' : '';
    final count = languages.length;
    final parentPageId = _languageListEntered
        ? 'language-settings/languages'
        : 'language-settings';
    final title = count == 1
        ? context.tr('Remove language file?')
        : context.tr('Remove selected language files?');
    final message = count == 1
        ? context.tr(
            'Remove language file "{value1}"? This action cannot be undone.',
            {'value1': preview},
          )
        : context.tr(
            'Remove {value1} selected language files ({value2})? This action cannot be undone.',
            {'value1': count, 'value2': '$preview$suffix'},
          );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return KeyboardSafeDialog(
          pageId: 'language-settings-removal-confirm',
          parentPageId: parentPageId,
          maxWidth: 480,
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: colors.error),
              const SizedBox(width: 10),
              Flexible(child: Text(title)),
            ],
          ),
          content: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.error.withValues(alpha: 0.32)),
            ),
            child: Text(message),
          ),
          actions: [
            TextButton(
              key: const ValueKey('language-removal-confirm-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.tr('Cancel')),
            ),
            FilledButton.icon(
              key: const ValueKey('language-removal-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_rounded),
              label: Text(context.tr('Remove')),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;

    await widget.app.languages.removeAll(
      languages.map((language) => language.source),
    );
    _selectedLanguageSources.removeAll(requested);
    if (mounted) {
      setState(() {});
      // The confirmation route schedules a restoration when it pops. The
      // language list can then remove the focused row, so schedule one more
      // parent-page pass after the list has settled and let it choose the
      // nearest remaining language-settings control.
      scheduleVimPageParentFocus(parentPageId);
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
        final systemLanguageAvailable =
            widget.app.languages.systemLocaleMatch != null;
        final selectedCount = languages
            .where((language) =>
                _selectedLanguageSources.contains(language.source))
            .length;
        final allLanguagesSelected =
            languages.isNotEmpty && selectedCount == languages.length;
        final someLanguagesSelected =
            selectedCount > 0 && !allLanguagesSelected;
        final selected = _preference == systemLanguagePreference ||
                available.contains(_preference)
            ? _preference
            : systemLanguagePreference;
        return KeyboardSafeDialog(
          pageId: 'language-settings',
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
                    enabled: systemLanguageAvailable,
                    onPressed: systemLanguageAvailable
                        ? null
                        : _showUnavailableSystemLanguage,
                  ),
                  for (final language in languages)
                    PolishedDropdownOption(
                      value: language.locale,
                      label: language.displayName,
                      icon: Icons.language_rounded,
                    ),
                ],
                onChanged: (value) {
                  if (value == systemLanguagePreference &&
                      !systemLanguageAvailable) {
                    _showUnavailableSystemLanguage();
                    return;
                  }
                  setState(() => _preference = value);
                },
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                key: const ValueKey('language-select-all'),
                tristate: true,
                value: allLanguagesSelected
                    ? true
                    : someLanguagesSelected
                        ? null
                        : false,
                controlAffinity: ListTileControlAffinity.leading,
                secondary: const Icon(Icons.select_all_rounded),
                title: Text(
                  context.tr('Select all language files'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  languages.isEmpty
                      ? context.tr('No language files detected')
                      : context.tr(
                          '{value1} of {value2} selected',
                          {'value1': selectedCount, 'value2': languages.length},
                        ),
                ),
                onChanged: languages.isEmpty
                    ? null
                    : (checked) => setState(() {
                          if (checked == true) {
                            _selectedLanguageSources
                              ..clear()
                              ..addAll(
                                languages.map((language) => language.source),
                              );
                          } else {
                            _selectedLanguageSources.clear();
                          }
                        }),
              ),
              const Divider(height: 1),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: VimLanguageListEntry(
                      onEnter: _enterLanguageList,
                      child: VimActivatable(
                        onActivate: _enterLanguageList,
                        child: Focus(
                          key: const ValueKey('language-list-page'),
                          focusNode: _languageListEntryFocusNode,
                          autofocus: !_languageListEntered &&
                              VimModeScope.enabled(context),
                          canRequestFocus: !_languageListEntered,
                          skipTraversal: _languageListEntered,
                          descendantsAreFocusable: false,
                          descendantsAreTraversable: false,
                          onKeyEvent: (node, event) {
                            if (!VimModeScope.enabled(
                                    node.context ?? context) ||
                                (event is! KeyDownEvent &&
                                    event is! KeyRepeatEvent)) {
                              return KeyEventResult.ignored;
                            }
                            final keyboard = HardwareKeyboard.instance;
                            if (keyboard.isShiftPressed ||
                                keyboard.isControlPressed ||
                                keyboard.isAltPressed ||
                                keyboard.isMetaPressed) {
                              return KeyEventResult.ignored;
                            }
                            final enters = event.logicalKey ==
                                    LogicalKeyboardKey.keyI ||
                                event.logicalKey == LogicalKeyboardKey.enter ||
                                event.logicalKey ==
                                    LogicalKeyboardKey.numpadEnter ||
                                event.logicalKey == LogicalKeyboardKey.space;
                            if (!enters) return KeyEventResult.ignored;
                            if (!claimVimActivation(
                                node.context ?? context, event)) {
                              return KeyEventResult.handled;
                            }
                            _enterLanguageList();
                            return KeyEventResult.handled;
                          },
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: _enterLanguageList,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 7,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.view_list_rounded,
                                      size: 20,
                                      color: colors.primary,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        context.tr(
                                          '{count} language file(s) detected',
                                          {'count': languages.length},
                                        ),
                                        style: TextStyle(
                                          color: colors.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
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
              FocusScope(
                node: _languageListScopeNode,
                canRequestFocus: _languageListEntered,
                skipTraversal: !_languageListEntered,
                child: VimLanguageListPage(
                  onExit: _leaveLanguageList,
                  child: VimPageScope(
                    pageId: 'language-settings/languages',
                    parentPageId: 'language-settings',
                    transient: true,
                    child: ExcludeFocus(
                      excluding: !_languageListEntered,
                      child: Column(
                        children: [
                          if (languages.isEmpty)
                            VimLanguageListItem(
                              row: 0,
                              child: Focus(
                                key: const ValueKey('language-list-empty'),
                                canRequestFocus: _languageListEntered,
                                child: ListTile(
                                  leading: const Icon(Icons.language_rounded),
                                  title: Text(
                                    context.tr('No language files detected'),
                                  ),
                                ),
                              ),
                            )
                          else
                            for (var index = 0;
                                index < languages.length;
                                index++)
                              VimLanguageListItem(
                                row: index,
                                child: CheckboxListTile(
                                  key: ValueKey(
                                    'language-select-${languages[index].source}',
                                  ),
                                  value: _selectedLanguageSources.contains(
                                    languages[index].source,
                                  ),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  secondary: IconButton(
                                    key: ValueKey(
                                      'language-remove-${languages[index].source}',
                                    ),
                                    tooltip: context.tr(
                                      'Remove language file',
                                    ),
                                    onPressed: () => unawaited(
                                      _confirmLanguageRemoval({
                                        languages[index].source,
                                      }),
                                    ),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                  ),
                                  title: Text(languages[index].displayName),
                                  subtitle: Text(
                                    languages[index].source,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onChanged: (checked) => setState(() {
                                    final source = languages[index].source;
                                    if (checked == true) {
                                      _selectedLanguageSources.add(source);
                                    } else {
                                      _selectedLanguageSources.remove(source);
                                    }
                                  }),
                                ),
                              ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            FilledButton.icon(
              key: const ValueKey('language-delete-selected'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: selectedCount == 0
                  ? null
                  : () => unawaited(
                        _confirmLanguageRemoval(_selectedLanguageSources),
                      ),
              icon: const Icon(Icons.delete_rounded),
              label: Text(
                selectedCount == 0
                    ? context.tr('Select language files')
                    : context.tr(
                        'Delete ({value1})',
                        {'value1': selectedCount},
                      ),
              ),
            ),
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
