import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/app_state.dart';
import '../../services/platform_file_dialog.dart';
import '../../services/simple_zip.dart';
import '../polished_dropdown.dart';
import 'keyboard_safe_dialog.dart';
import '../vim_focus.dart';

enum PanelExportFormat {
  text('Text', 'txt', Icons.description_outlined),
  csv('CSV', 'csv', Icons.table_chart_outlined),
  tsv('TSV', 'tsv', Icons.view_column_outlined),
  json('JSON', 'json', Icons.data_object_rounded);

  const PanelExportFormat(this.label, this.extension, this.icon);

  final String label;
  final String extension;
  final IconData icon;
}

enum PanelExportRange {
  allData('All data', Icons.all_inclusive_rounded),
  currentView('Current view', Icons.center_focus_strong_rounded),
  customXRange('Custom X range', Icons.straighten_rounded);

  const PanelExportRange(this.label, this.icon);

  final String label;
  final IconData icon;
}

class PanelExportRequest {
  const PanelExportRequest({
    required this.panels,
    required this.format,
    required this.range,
    this.xMin,
    this.xMax,
  });

  final Set<int> panels;
  final PanelExportFormat format;
  final PanelExportRange range;
  final double? xMin;
  final double? xMax;
}

class PanelExportChoice {
  const PanelExportChoice({
    required this.index,
    required this.column,
    required this.row,
    required this.title,
    required this.signalNames,
    required this.loadedSeries,
  });

  final int index;
  final int column;
  final int row;
  final String title;
  final List<String> signalNames;
  final int loadedSeries;

  bool get hasData => loadedSeries > 0;
}

class PanelExportFile {
  const PanelExportFile(this.name, this.bytes);

  final String name;
  final Uint8List bytes;
}

typedef PlatformDirectoryDialog = Future<String?> Function();

List<PanelExportChoice> panelExportChoices(AppState app) {
  final result = <PanelExportChoice>[];
  var index = 0;
  for (var column = 0; column < app.columns.length; column++) {
    for (var row = 0; row < app.columns[column].length; row++) {
      final panel = app.columns[column][row];
      final plot = index < app.plots.length ? app.plots[index] : null;
      final specs = (panel['signal_specs'] as List?) ?? const [];
      final names = <String>[
        for (var signal = 0; signal < specs.length; signal++)
          _signalDisplayName(specs[signal], signal),
      ];
      final loaded = plot?.series
              .where(
                (series) => series?.hasData == true,
              )
              .length ??
          0;
      result.add(
        PanelExportChoice(
          index: index,
          column: column,
          row: row,
          title: plot?.title.trim().isNotEmpty == true
              ? plot!.title.trim()
              : panel['title']?.toString().trim() ?? '',
          signalNames: names,
          loadedSeries: loaded,
        ),
      );
      index++;
    }
  }
  return result;
}

List<List<PanelExportChoice>> panelExportChoiceColumns(AppState app) {
  final choices = panelExportChoices(app);
  final columns = <List<PanelExportChoice>>[
    for (var column = 0; column < app.columns.length; column++) [],
  ];
  for (final choice in choices) {
    if (choice.column >= 0 && choice.column < columns.length) {
      columns[choice.column].add(choice);
    }
  }
  return columns.where((column) => column.isNotEmpty).toList();
}

String _signalDisplayName(dynamic raw, int index) {
  if (raw is! Map) return 'Signal ${index + 1}';
  final legend = raw['legend']?.toString().trim() ?? '';
  if (legend.isNotEmpty) return legend;
  final expression = raw['y_expr']?.toString().trim() ??
      raw['signal']?.toString().trim() ??
      '';
  final normalized = expression.replaceFirst(RegExp(r'^\\+'), '');
  return normalized.isEmpty ? 'Signal ${index + 1}' : normalized;
}

Future<PanelExportRequest?> showMultiPanelExportDialog(
  BuildContext context,
  AppState app, {
  Set<int>? initialSelection,
  bool allowPanelSelection = true,
}) async {
  final vimInput = VimInputModeScope.maybeOf(context);
  if (app.vimMode) {
    // The selection grid is a fresh two-level document every time the dialog
    // opens. Never inherit a previously entered Panel page from the live plot
    // workspace.
    vimInput?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
  }
  final choices = panelExportChoices(app);
  final choiceColumns = panelExportChoiceColumns(app);
  final selected = initialSelection == null
      ? <int>{
          for (final choice in choices)
            if (choice.hasData) choice.index,
        }
      : Set<int>.from(initialSelection);
  var format = PanelExportFormat.csv;
  var range = PanelExportRange.allData;
  final xMinController = TextEditingController();
  final xMaxController = TextEditingController();
  final horizontalController = ScrollController();
  final verticalController = ScrollController();
  String? rangeError;
  try {
    return await showDialog<PanelExportRequest>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) {
          final selectable = choices.where((choice) => choice.hasData).toList();
          final allSelected = selectable.isNotEmpty &&
              selectable.every((choice) => selected.contains(choice.index));
          final someSelected = selected.isNotEmpty && !allSelected;
          final colors = Theme.of(context).colorScheme;
          // The Export Multiple Panels dialog is a semantic document in Vim
          // mode.  Its rows are intentionally independent of the rendered
          // card heights: format/range, optional X bounds, Select All, source
          // Columns, then the action row.  This makes J/K deterministic even
          // when the source Columns have very different numbers of Panels.
          final hasCustomXRange = range == PanelExportRange.customXRange;
          final selectAllRow = hasCustomXRange ? 2 : 1;
          final actionRow = selectAllRow + 2;

          void submit() {
            double? xMin;
            double? xMax;
            if (range == PanelExportRange.customXRange) {
              xMin = double.tryParse(xMinController.text.trim());
              xMax = double.tryParse(xMaxController.text.trim());
              if (xMin == null ||
                  xMax == null ||
                  !xMin.isFinite ||
                  !xMax.isFinite ||
                  xMin >= xMax) {
                setState(() {
                  rangeError =
                      'Enter finite X values with minimum less than maximum.';
                });
                return;
              }
            }
            Navigator.pop(
              dialogContext,
              PanelExportRequest(
                panels: Set<int>.from(selected),
                format: format,
                range: range,
                xMin: xMin,
                xMax: xMax,
              ),
            );
          }

          return KeyboardSafeDialog(
            pageId: 'panel-export',
            maxWidth: 700,
            maxHeight: 820,
            title: Row(
              children: [
                const Icon(Icons.file_download_outlined),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    allowPanelSelection
                        ? 'Export multiple panels'
                        : 'Export panel data',
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 640,
              height: allowPanelSelection ? 560 : 240,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: VimPanelExportControl(
                          row: 0,
                          column: 0,
                          child: PolishedDropdown<PanelExportFormat>(
                            key: const ValueKey('panel-export-format'),
                            id: 'panel-export-format',
                            value: format,
                            leadingIcon: format.icon,
                            options: [
                              for (final option in PanelExportFormat.values)
                                PolishedDropdownOption(
                                  value: option,
                                  label: option.label,
                                  icon: option.icon,
                                ),
                            ],
                            onChanged: (value) =>
                                setState(() => format = value),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: VimPanelExportControl(
                          row: 0,
                          column: 1,
                          child: PolishedDropdown<PanelExportRange>(
                            key: const ValueKey('panel-export-range'),
                            id: 'panel-export-range',
                            value: range,
                            leadingIcon: range.icon,
                            options: [
                              for (final option in PanelExportRange.values)
                                PolishedDropdownOption(
                                  value: option,
                                  label: option.label,
                                  icon: option.icon,
                                ),
                            ],
                            onChanged: (value) => setState(() {
                              range = value;
                              rangeError = null;
                            }),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (range == PanelExportRange.customXRange) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: VimPanelExportControl(
                            row: 1,
                            column: 0,
                            child: TextField(
                              key: const ValueKey('panel-export-x-min'),
                              controller: xMinController,
                              readOnly: vimTextFieldReadOnly(context),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                signed: true,
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'X minimum',
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: VimPanelExportControl(
                            row: 1,
                            column: 1,
                            child: TextField(
                              key: const ValueKey('panel-export-x-max'),
                              controller: xMaxController,
                              readOnly: vimTextFieldReadOnly(context),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                signed: true,
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'X maximum',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (rangeError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          rangeError!,
                          style: TextStyle(color: colors.error),
                        ),
                      ),
                  ],
                  if (allowPanelSelection) ...[
                    const SizedBox(height: 12),
                    VimPanelExportControl(
                      row: selectAllRow,
                      column: 0,
                      child: Material(
                        color: colors.surfaceContainerLow,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                          side: BorderSide(color: colors.outlineVariant),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: CheckboxListTile(
                          key: const ValueKey('multi-panel-export-select-all'),
                          tristate: true,
                          value: someSelected ? null : allSelected,
                          onChanged: selectable.isEmpty
                              ? null
                              : (_) => setState(() {
                                    if (allSelected) {
                                      selected.clear();
                                    } else {
                                      selected.addAll(
                                        selectable.map(
                                          (choice) => choice.index,
                                        ),
                                      );
                                    }
                                  }),
                          secondary: const Icon(Icons.select_all_rounded),
                          title: const Text('Select All Panels With Data'),
                          subtitle: Text(
                            '${selected.length} of ${selectable.length} selected',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _PanelExportLayoutGrid(
                        columns: choiceColumns,
                        selected: selected,
                        horizontalController: horizontalController,
                        verticalController: verticalController,
                        onToggle: (choice) => setState(() {
                          if (!selected.remove(choice.index)) {
                            selected.add(choice.index);
                          }
                        }),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              VimPanelExportControl(
                row: actionRow,
                column: 0,
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Cancel'),
                ),
              ),
              VimPanelExportControl(
                row: actionRow,
                column: 1,
                child: FilledButton.icon(
                  key: const ValueKey('multi-panel-export-confirm'),
                  onPressed: selected.isEmpty ? null : submit,
                  icon: const Icon(Icons.file_download_outlined),
                  label: Text('Export ${selected.length} panel(s)'),
                ),
              ),
            ],
          );
        },
      ),
    );
  } finally {
    if (app.vimMode) {
      vimInput?.setPlotSelectionLevel(VimPlotSelectionLevel.column);
    }
    xMinController.dispose();
    xMaxController.dispose();
    horizontalController.dispose();
    verticalController.dispose();
  }
}

class _PanelExportLayoutGrid extends StatelessWidget {
  const _PanelExportLayoutGrid({
    required this.columns,
    required this.selected,
    required this.horizontalController,
    required this.verticalController,
    required this.onToggle,
  });

  final List<List<PanelExportChoice>> columns;
  final Set<int> selected;
  final ScrollController horizontalController;
  final ScrollController verticalController;
  final ValueChanged<PanelExportChoice> onToggle;

  @override
  Widget build(BuildContext context) {
    if (columns.isEmpty) {
      return const Center(child: Text('No panels are available.'));
    }
    final colors = Theme.of(context).colorScheme;
    final maxRows = columns.fold<int>(
      1,
      (maximum, column) => math.max(maximum, column.length),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasWidth = math.max(
          constraints.maxWidth,
          columns.length * 154.0,
        );
        final canvasHeight = math.max(
          constraints.maxHeight,
          maxRows * 104.0 + 34,
        );
        final horizontalOverflow = canvasWidth > constraints.maxWidth + 0.5;
        final verticalOverflow = canvasHeight > constraints.maxHeight + 0.5;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Scrollbar(
              key: const ValueKey('panel-export-horizontal-scrollbar'),
              controller: horizontalController,
              thumbVisibility: horizontalOverflow,
              interactive: true,
              notificationPredicate: (notification) =>
                  notification.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                key: const ValueKey('panel-export-horizontal-scroll'),
                controller: horizontalController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: canvasWidth,
                  height: constraints.maxHeight,
                  child: Scrollbar(
                    key: const ValueKey('panel-export-vertical-scrollbar'),
                    controller: verticalController,
                    thumbVisibility: verticalOverflow,
                    interactive: true,
                    notificationPredicate: (notification) =>
                        notification.metrics.axis == Axis.vertical,
                    child: SingleChildScrollView(
                      key: const ValueKey('panel-export-vertical-scroll'),
                      controller: verticalController,
                      child: SizedBox(
                        width: canvasWidth,
                        height: canvasHeight,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var columnIndex = 0;
                                  columnIndex < columns.length;
                                  columnIndex++)
                                Expanded(
                                  child: VimPlotColumnFocus(
                                    column: columns[columnIndex].first.column,
                                    child: Padding(
                                      padding: EdgeInsets.only(
                                        left: columnIndex == 0 ? 0 : 4,
                                        right: columnIndex == columns.length - 1
                                            ? 0
                                            : 4,
                                      ),
                                      child: Column(
                                        children: [
                                          SizedBox(
                                            height: 26,
                                            child: Center(
                                              child: Text(
                                                'Column ${columnIndex + 1}',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .labelMedium
                                                    ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                            ),
                                          ),
                                          Expanded(
                                            child: Column(
                                              children: [
                                                for (final choice
                                                    in columns[columnIndex])
                                                  Expanded(
                                                    child: Padding(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        vertical: 4,
                                                      ),
                                                      child: _PanelExportTile(
                                                        choice: choice,
                                                        selected:
                                                            selected.contains(
                                                          choice.index,
                                                        ),
                                                        onTap: choice.hasData
                                                            ? () =>
                                                                onToggle(choice)
                                                            : null,
                                                      ),
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
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PanelExportTile extends StatelessWidget {
  const _PanelExportTile({
    required this.choice,
    required this.selected,
    required this.onTap,
  });

  final PanelExportChoice choice;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final title =
        choice.title.isEmpty ? 'Panel ${choice.index + 1}' : choice.title;
    final signals = choice.signalNames.isEmpty
        ? 'No configured signals'
        : choice.signalNames.join(', ');
    final tooltip = 'Panel ${choice.index + 1}'
        '${choice.title.isEmpty ? "" : " · ${choice.title}"}\n'
        '${choice.hasData ? "${choice.loadedSeries} loaded curve(s)" : "No loaded data"}'
        '\n$signals';
    return VimPlotFocus(
      column: choice.column,
      row: choice.row,
      child: Semantics(
        button: choice.hasData,
        selected: selected,
        enabled: choice.hasData,
        label: tooltip,
        child: Tooltip(
          message: tooltip,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 140),
            opacity: choice.hasData ? 1 : 0.48,
            child: Material(
              color: selected
                  ? colors.primaryContainer.withValues(alpha: 0.86)
                  : colors.surfaceContainerLow,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: selected ? colors.primary : colors.outlineVariant,
                  width: selected ? 2 : 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                key: ValueKey('multi-panel-export-${choice.index}'),
                onTap: onTap,
                child: Stack(
                  children: [
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 24, 8, 8),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              signals,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 7,
                      top: 6,
                      child: Text(
                        'Panel ${choice.index + 1}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      top: 5,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 140),
                        child: Icon(
                          selected
                              ? Icons.check_circle_rounded
                              : choice.hasData
                                  ? Icons.radio_button_unchecked_rounded
                                  : Icons.block_rounded,
                          key: ValueKey(
                            '${choice.index}-$selected-${choice.hasData}',
                          ),
                          size: 18,
                          color: selected
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> exportMultiplePanels(
  BuildContext context,
  AppState app, {
  PlatformSaveDialog? saveDialog,
  PlatformDirectoryDialog? directoryDialog,
  bool? mobileOverride,
  Set<int>? initialSelection,
  bool allowPanelSelection = true,
}) async {
  final request = await showMultiPanelExportDialog(
    context,
    app,
    initialSelection: initialSelection,
    allowPanelSelection: allowPanelSelection,
  );
  if (request == null || request.panels.isEmpty || !context.mounted) return;

  final browser = kIsWeb;
  final mobile =
      mobileOverride ?? (!browser && (Platform.isAndroid || Platform.isIOS));
  _DesktopPanelExportDestination? desktopDestination;
  // A full waveform export can take noticeable time simply to materialize the
  // selected points. On a desktop, FilePicker does not need the bytes in order
  // to ask for a destination, so make that native sheet the next visible
  // action. This keeps the Export button responsive instead of making the
  // user wait behind serialization before they can choose a file or folder.
  if (!mobile && !browser && saveDialog == null) {
    try {
      app.setStatus('Choose where to export the selected panel data...');
      // The export dialog has just been popped. Let its reverse transition
      // settle before attaching a native sheet to the owning window.
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(Duration.zero);
      desktopDestination = await _chooseDesktopPanelExportDestination(
        app,
        request,
        directoryDialog: directoryDialog,
      );
      if (desktopDestination == null) {
        app.setStatus('Export cancelled');
        return;
      }
    } catch (error) {
      app.setStatus('Export error: $error');
      return;
    }
  }

  app.setStatus('Preparing data from ${request.panels.length} panels...');
  // Render the status update before the snapshot walks potentially large
  // TypedData series on the UI isolate.
  await Future<void>.delayed(Duration.zero);
  final snapshot = panelExportSnapshot(app, request);
  final files = await Isolate.run(
    () => buildPanelExportFiles(snapshot, request.format),
  );
  if (files.isEmpty) {
    app.setStatus('Export error: no data exists in the selected range');
    return;
  }

  try {
    if (desktopDestination != null) {
      await _writeDesktopPanelExport(desktopDestination, files);
      app.setStatus(
        desktopDestination.filePath != null
            ? 'Exported ${_displayName(desktopDestination.filePath!)}'
            : 'Exported ${files.length} independent panel files to '
                '${_displayName(desktopDestination.directoryPath!)}',
      );
      return;
    }

    app.setStatus('Choose where to export the selected panel data...');
    if (saveDialog == null && directoryDialog == null) {
      await WidgetsBinding.instance.endOfFrame;
    }
    if (files.length == 1) {
      final file = files.single;
      final destination = await saveBytesWithFilePicker(
        dialogTitle: 'Export panel data',
        fileName: file.name,
        allowedExtensions: [request.format.extension],
        bytes: file.bytes,
        mobileOverride: mobile,
        saveDialog: saveDialog,
      );
      app.setStatus(
        destination == null
            ? 'Export cancelled'
            : 'Exported ${_displayName(destination)}',
      );
      return;
    }

    if (mobile || browser || saveDialog != null) {
      final archiveName = _archiveFileName(app);
      final archive = createStoredZip({
        for (final file in files) file.name: file.bytes,
      });
      final destination = await saveBytesWithFilePicker(
        dialogTitle: 'Export panel data files',
        fileName: archiveName,
        allowedExtensions: const ['zip'],
        bytes: archive,
        mobileOverride: mobile,
        webOverride: browser,
        saveDialog: saveDialog,
      );
      app.setStatus(
        destination == null
            ? 'Export cancelled'
            : 'Exported ${files.length} panel files to '
                '${_displayName(destination)}',
      );
      return;
    }

    final directory = await (directoryDialog ??
        () => FilePicker.platform.getDirectoryPath(
              dialogTitle: 'Export each panel to this folder',
              lockParentWindow: true,
            ))();
    if (directory == null || directory.trim().isEmpty) {
      app.setStatus('Export cancelled');
      return;
    }
    for (final file in files) {
      await File(
        '$directory${Platform.pathSeparator}${file.name}',
      ).writeAsBytes(file.bytes, flush: true);
    }
    app.setStatus(
      'Exported ${files.length} independent panel files to '
      '${_displayName(directory)}',
    );
  } catch (error) {
    app.setStatus('Export error: $error');
  }
}

class _DesktopPanelExportDestination {
  const _DesktopPanelExportDestination.file(this.filePath)
      : directoryPath = null;

  const _DesktopPanelExportDestination.directory(this.directoryPath)
      : filePath = null;

  final String? filePath;
  final String? directoryPath;
}

Future<_DesktopPanelExportDestination?> _chooseDesktopPanelExportDestination(
  AppState app,
  PanelExportRequest request, {
  PlatformDirectoryDialog? directoryDialog,
}) async {
  // One selected Panel always produces one independent file. With two or more
  // Panels, asking for a folder before serialization preserves the original
  // independent-file desktop behavior.
  if (request.panels.length == 1) {
    final selectedIndex = request.panels.single;
    final choices = panelExportChoices(app);
    final matching = choices.where((choice) => choice.index == selectedIndex);
    final choice = matching.isEmpty ? null : matching.first;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export panel data',
      fileName: _anticipatedPanelFileName(choice, request.format),
      type: FileType.custom,
      allowedExtensions: [request.format.extension],
      // Native desktop save panels return a destination before any bytes are
      // available. The actual write happens after Isolate serialization.
      bytes: null,
      lockParentWindow: true,
    );
    if (path == null || path.trim().isEmpty) return null;
    return _DesktopPanelExportDestination.file(
      _withExportExtension(path, request.format.extension),
    );
  }

  final directory = await (directoryDialog ??
      () => FilePicker.platform.getDirectoryPath(
            dialogTitle: 'Export each panel to this folder',
            lockParentWindow: true,
          ))();
  if (directory == null || directory.trim().isEmpty) return null;
  return _DesktopPanelExportDestination.directory(directory);
}

String _anticipatedPanelFileName(
  PanelExportChoice? choice,
  PanelExportFormat format,
) {
  if (choice == null) return 'panel-data.${format.extension}';
  return _panelFileName(
    {'index': choice.index, 'title': choice.title},
    format.extension,
  );
}

String _withExportExtension(String path, String extension) {
  if (path.toLowerCase().endsWith('.${extension.toLowerCase()}')) return path;
  return '$path.$extension';
}

Future<void> _writeDesktopPanelExport(
  _DesktopPanelExportDestination destination,
  List<PanelExportFile> files,
) async {
  final filePath = destination.filePath;
  if (filePath != null) {
    // A single requested Panel produces one file. Keep this guard defensive in
    // case a future range mode can split an individual Panel into parts.
    if (files.length != 1) {
      throw StateError(
          'A single-file destination received ${files.length} files');
    }
    await File(filePath).writeAsBytes(files.single.bytes, flush: true);
    return;
  }
  final directory = destination.directoryPath;
  if (directory == null) {
    throw StateError('No desktop export destination was selected');
  }
  for (final file in files) {
    await File(
      '$directory${Platform.pathSeparator}${file.name}',
    ).writeAsBytes(file.bytes, flush: true);
  }
}

List<Map<String, dynamic>> panelExportSnapshot(
  AppState app,
  PanelExportRequest request,
) {
  final snapshot = <Map<String, dynamic>>[];
  var index = 0;
  for (var column = 0; column < app.columns.length; column++) {
    for (var row = 0; row < app.columns[column].length; row++) {
      if (!request.panels.contains(index) || index >= app.plots.length) {
        index++;
        continue;
      }
      final panel = app.columns[column][row];
      final plot = app.plots[index];
      final specs = (panel['signal_specs'] as List?) ?? const [];
      final series = <Map<String, dynamic>>[];
      final (rangeMin, rangeMax) = switch (request.range) {
        PanelExportRange.allData => (null, null),
        PanelExportRange.currentView => (plot.viewMinX, plot.viewMaxX),
        PanelExportRange.customXRange => (request.xMin, request.xMax),
      };
      for (var signal = 0; signal < plot.series.length; signal++) {
        final data = plot.series[signal];
        if (data?.hasData != true) continue;
        final sourcePoints = data!.materializePoints();
        final spec = signal < specs.length && specs[signal] is Map
            ? Map<String, dynamic>.from(specs[signal] as Map)
            : <String, dynamic>{};
        final points = [
          for (final point in sourcePoints)
            if ((rangeMin == null || point[0] >= rangeMin) &&
                (rangeMax == null || point[0] <= rangeMax))
              List<double>.from(point),
        ];
        if (points.isEmpty) continue;
        series.add({
          'index': signal,
          'legend': _signalDisplayName(spec, signal),
          'tree': spec['experiment']?.toString() ?? '',
          'signal': spec['y_expr']?.toString() ?? '',
          'server': spec['server_ip']?.toString() ?? '',
          'shot': spec['shot']?.toString() ?? app.displayedShot,
          'x_name': data.xName,
          'x_unit': data.xUnit,
          'y_unit': data.unit,
          'points': points,
        });
      }
      if (series.isNotEmpty) {
        snapshot.add({
          'index': index,
          'column': column,
          'row': row,
          'title': plot.title,
          'series': series,
        });
      }
      index++;
    }
  }
  return snapshot;
}

List<PanelExportFile> buildPanelExportFiles(
  List<Map<String, dynamic>> panels,
  PanelExportFormat format,
) {
  return [
    for (final panel in panels)
      PanelExportFile(
        _panelFileName(panel, format.extension),
        Uint8List.fromList(
          utf8.encode(
            switch (format) {
              PanelExportFormat.text => _encodePanelText(panel),
              PanelExportFormat.csv => _encodePanelDelimited(panel, ','),
              PanelExportFormat.tsv => _encodePanelDelimited(panel, '\t'),
              PanelExportFormat.json =>
                const JsonEncoder.withIndent('  ').convert(panel),
            },
          ),
        ),
      ),
  ];
}

String encodeMultiplePanelCsv(List<Map<String, dynamic>> panels) {
  final output = StringBuffer();
  for (final panel in panels) {
    if (output.isNotEmpty) output.writeln();
    output.write(_encodePanelDelimited(panel, ','));
  }
  return output.toString();
}

String _encodePanelDelimited(Map<String, dynamic> panel, String delimiter) {
  final output = StringBuffer()
    ..writeln(
      [
        'series',
        'legend',
        'shot',
        'tree',
        'signal',
        'server_ip',
        'x_name',
        'x_unit',
        'y_unit',
        'x',
        'y',
      ].join(delimiter),
    );
  final seriesList = (panel['series'] as List?) ?? const [];
  for (final rawSeries in seriesList) {
    final series = rawSeries as Map;
    final points = (series['points'] as List?) ?? const [];
    for (final rawPoint in points) {
      final point = rawPoint as List;
      if (point.length < 2) continue;
      final fields = [
        (series['index'] as int) + 1,
        series['legend'],
        series['shot'],
        series['tree'],
        series['signal'],
        series['server'],
        series['x_name'],
        series['x_unit'],
        series['y_unit'],
        point[0],
        point[1],
      ];
      output.writeln(
        fields
            .map(
              delimiter == ',' ? _csvValue : (value) => _tsvValue(value),
            )
            .join(delimiter),
      );
    }
  }
  return output.toString();
}

String _encodePanelText(Map<String, dynamic> panel) {
  final output = StringBuffer()
    ..writeln('MDSLens waveform export')
    ..writeln('Panel: ${(panel['index'] as int) + 1}')
    ..writeln('Title: ${panel['title']}')
    ..writeln();
  for (final rawSeries in (panel['series'] as List?) ?? const []) {
    final series = rawSeries as Map;
    output
      ..writeln('Series: ${(series['index'] as int) + 1}')
      ..writeln('Legend: ${series['legend']}')
      ..writeln('Shot: ${series['shot']}')
      ..writeln('Tree: ${series['tree']}')
      ..writeln('Signal: ${series['signal']}')
      ..writeln(
        '${series['x_name']} [${series['x_unit']}]\t'
        'value [${series['y_unit']}]',
      );
    for (final rawPoint in (series['points'] as List?) ?? const []) {
      final point = rawPoint as List;
      if (point.length >= 2) output.writeln('${point[0]}\t${point[1]}');
    }
    output.writeln();
  }
  return output.toString();
}

String _panelFileName(Map<String, dynamic> panel, String extension) {
  final number = ((panel['index'] as int) + 1).toString().padLeft(2, '0');
  final title = _safeName(panel['title']?.toString() ?? '');
  return title.isEmpty
      ? 'panel-$number.$extension'
      : 'panel-$number-$title.$extension';
}

String _archiveFileName(AppState app) {
  final shot = app.displayedShot.trim().isNotEmpty
      ? app.displayedShot.trim()
      : app.shotText.trim();
  final safeShot = _safeName(shot);
  return safeShot.isEmpty
      ? 'mdslens-panels.zip'
      : 'mdslens-$safeShot-panels.zip';
}

String _safeName(String value) => value
    .trim()
    .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-')
    .replaceAll(RegExp(r'^-+|-+$'), '');

String _csvValue(Object? value) {
  final text = value?.toString() ?? '';
  if (!text.contains(RegExp(r'[",\r\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}

String _tsvValue(Object? value) =>
    (value?.toString() ?? '').replaceAll(RegExp(r'[\t\r\n]+'), ' ');

String _displayName(String path) {
  final parts = Uri.decodeComponent(path).split(RegExp(r'[/\\]'));
  return parts.lastWhere((part) => part.isNotEmpty, orElse: () => path);
}
