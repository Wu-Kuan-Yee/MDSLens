import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/app_state.dart';
import 'dialogs/keyboard_safe_dialog.dart';

bool isSupportedConfigurationFileName(String name) {
  final lower = name.trim().toLowerCase();
  return lower.endsWith('.toml') || lower.endsWith('.webscp');
}

const _androidDropFileChannel = MethodChannel('mdslens/drop_file_access');

Future<Uint8List> readDroppedConfigurationBytes(
  DropItem file, {
  bool? androidOverride,
  MethodChannel channel = _androidDropFileChannel,
}) async {
  final isAndroid = androidOverride ?? (!kIsWeb && Platform.isAndroid);
  if (isAndroid && file.path.toLowerCase().startsWith('content://')) {
    final bytes = await channel.invokeMethod<Uint8List>(
      'readContentUri',
      file.path,
    );
    if (bytes == null) {
      throw const FileSystemException(
        'The Android document provider returned no file data.',
      );
    }
    return bytes;
  }
  return file.readAsBytes();
}

Future<bool> confirmDroppedConfigurationImport(
  BuildContext context,
  String fileName,
) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final colors = Theme.of(dialogContext).colorScheme;
      return CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.pop(dialogContext, false),
        },
        child: KeyboardSafeDialog(
          maxWidth: 520,
          title: const Row(
            children: [
              Icon(Icons.file_download_outlined),
              SizedBox(width: 10),
              Flexible(child: Text('Import dropped configuration?')),
            ],
          ),
          content: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.description_outlined,
                      color: colors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        fileName,
                        key: const ValueKey('dropped-configuration-name'),
                        style: Theme.of(dialogContext).textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Importing this file will replace the current waveform layout. '
                  'Nothing changes unless you confirm.',
                  style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              key: const ValueKey('cancel-dropped-configuration'),
              autofocus: true,
              onPressed: () => Navigator.pop(dialogContext, false),
              icon: const Icon(Icons.close_rounded),
              label: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: const ValueKey('import-dropped-configuration'),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.file_open_rounded),
              label: const Text('Import'),
            ),
          ],
        ),
      );
    },
  );
  return result ?? false;
}

class ConfigurationDropRegion extends StatefulWidget {
  const ConfigurationDropRegion({super.key, required this.child});

  final Widget child;

  @override
  State<ConfigurationDropRegion> createState() =>
      _ConfigurationDropRegionState();
}

class _ConfigurationDropRegionState extends State<ConfigurationDropRegion> {
  bool _dragOver = false;
  bool _potentiallyValid = false;

  void _onDragEntered() {
    if (!_dragOver || !_potentiallyValid) {
      setState(() {
        _dragOver = true;
        _potentiallyValid = true;
      });
    }
  }

  void _clearDragState() {
    if (!_dragOver && !_potentiallyValid) return;
    setState(() {
      _dragOver = false;
      _potentiallyValid = false;
    });
  }

  Future<void> _onDragDone(DropDoneDetails details) async {
    _clearDragState();
    if (details.files.length != 1) {
      _showError('Drop exactly one .toml or .webscp configuration file.');
      return;
    }

    final file = details.files.single;
    if (!isSupportedConfigurationFileName(file.name)) {
      _showError('Only .toml and .webscp configuration files are accepted.');
      return;
    }
    try {
      final bytes = await readDroppedConfigurationBytes(file);
      if (!kIsWeb && Platform.isIOS && file.path.contains('mdslens-drop-')) {
        await File(file.path).parent.delete(recursive: true);
      }
      if (!mounted) return;
      await _offerImport(file.name, bytes);
    } catch (error) {
      _showError('Could not read dropped file: $error');
    }
  }

  Future<void> _offerImport(String fileName, Uint8List bytes) async {
    if (!await confirmDroppedConfigurationImport(context, fileName) ||
        !mounted) {
      return;
    }
    final app = context.read<AppState>();
    await app.openFile(
      selectionOverride: ConfigOpenSelection(name: fileName, bytes: bytes),
      importedShotDecision: (shot) =>
          _confirmUseImportedConfigurationShot(context, shot),
    );
  }

  Future<bool> _confirmUseImportedConfigurationShot(
    BuildContext context,
    String shot,
  ) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => KeyboardSafeDialog(
        maxWidth: 500,
        title: const Row(
          children: [
            Icon(Icons.numbers_rounded),
            SizedBox(width: 10),
            Flexible(child: Text('Use the configuration shot?')),
          ],
        ),
        content: Text(
          'The dropped configuration contains shot $shot. Keep the current '
          'shot, or use $shot as the initial shot?',
        ),
        actions: [
          FilledButton.icon(
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, false),
            icon: const Icon(Icons.visibility_off_outlined),
            label: const Text('Keep current shot'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.check_circle_outline_rounded),
            label: Text('Use $shot'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DropTarget(
      key: const ValueKey('waveform-configuration-drop-region'),
      onDragEntered: (_) => _onDragEntered(),
      onDragExited: (_) => _clearDragState(),
      onDragDone: _onDragDone,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          IgnorePointer(
            child: AnimatedOpacity(
              key: const ValueKey('configuration-drop-indicator'),
              opacity: _dragOver ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                margin: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: (_potentiallyValid ? colors.primary : colors.error)
                      .withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _potentiallyValid ? colors.primary : colors.error,
                    width: 3,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (_potentiallyValid ? colors.primary : colors.error)
                          .withValues(alpha: 0.22),
                      blurRadius: 18,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    margin: const EdgeInsets.all(24),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: colors.surface.withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: colors.outlineVariant),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _potentiallyValid
                              ? Icons.file_download_done_rounded
                              : Icons.block_rounded,
                          color:
                              _potentiallyValid ? colors.primary : colors.error,
                          size: 34,
                        ),
                        const SizedBox(width: 14),
                        Flexible(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _potentiallyValid
                                    ? 'Release to import configuration'
                                    : 'This item cannot be dropped here',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Accepts one .toml or .webscp file',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
