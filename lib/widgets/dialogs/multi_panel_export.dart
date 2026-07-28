import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/app_state.dart';
import '../../services/platform_file_dialog.dart';
import 'keyboard_safe_dialog.dart';

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
                (series) =>
                    series?.points != null && series!.points!.isNotEmpty,
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

Future<Set<int>?> showMultiPanelExportDialog(
  BuildContext context,
  AppState app,
) async {
  final choices = panelExportChoices(app);
  final selected = <int>{
    for (final choice in choices)
      if (choice.hasData) choice.index,
  };
  return showDialog<Set<int>>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) {
        final selectable = choices.where((choice) => choice.hasData).toList();
        final allSelected = selectable.isNotEmpty &&
            selectable.every((choice) => selected.contains(choice.index));
        final someSelected = selected.isNotEmpty && !allSelected;
        final colors = Theme.of(context).colorScheme;
        return KeyboardSafeDialog(
          maxWidth: 700,
          maxHeight: 760,
          title: const Row(
            children: [
              Icon(Icons.library_add_check_rounded),
              SizedBox(width: 10),
              Flexible(child: Text('Export multiple panels')),
            ],
          ),
          content: SizedBox(
            width: 640,
            height: 440,
            child: Column(
              children: [
                Material(
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
                                  selectable.map((choice) => choice.index),
                                );
                              }
                            }),
                    secondary: const Icon(Icons.select_all_rounded),
                    title: const Text('Select all panels with data'),
                    subtitle: Text(
                      '${selected.length} of ${selectable.length} selected',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Scrollbar(
                    child: ListView.separated(
                      itemCount: choices.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, position) {
                        final choice = choices[position];
                        final title = choice.title.isEmpty
                            ? 'Panel ${choice.index + 1}'
                            : 'Panel ${choice.index + 1} · ${choice.title}';
                        final signals = choice.signalNames.isEmpty
                            ? 'No configured signals'
                            : choice.signalNames.join(', ');
                        return Card(
                          margin: EdgeInsets.zero,
                          clipBehavior: Clip.antiAlias,
                          child: CheckboxListTile(
                            key: ValueKey(
                              'multi-panel-export-${choice.index}',
                            ),
                            value: selected.contains(choice.index),
                            enabled: choice.hasData,
                            onChanged: choice.hasData
                                ? (checked) => setState(() {
                                      if (checked == true) {
                                        selected.add(choice.index);
                                      } else {
                                        selected.remove(choice.index);
                                      }
                                    })
                                : null,
                            secondary: CircleAvatar(
                              backgroundColor: choice.hasData
                                  ? colors.primaryContainer
                                  : colors.surfaceContainerHighest,
                              foregroundColor: choice.hasData
                                  ? colors.onPrimaryContainer
                                  : colors.onSurfaceVariant,
                              child: Text('${choice.index + 1}'),
                            ),
                            title: Text(title),
                            subtitle: Text(
                              choice.hasData
                                  ? '${choice.loadedSeries} loaded curve(s) · $signals'
                                  : 'No loaded data · $signals',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.close_rounded),
              label: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: const ValueKey('multi-panel-export-confirm'),
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, Set<int>.from(selected)),
              icon: const Icon(Icons.file_download_outlined),
              label: Text('Export ${selected.length} panel(s)'),
            ),
          ],
        );
      },
    ),
  );
}

Future<void> exportMultiplePanels(
  BuildContext context,
  AppState app, {
  PlatformSaveDialog? saveDialog,
}) async {
  final selected = await showMultiPanelExportDialog(context, app);
  if (selected == null || selected.isEmpty || !context.mounted) return;

  app.setStatus('Preparing data from ${selected.length} panels...');
  final snapshot = _panelExportSnapshot(app, selected);
  final csv = await Isolate.run(() => encodeMultiplePanelCsv(snapshot));
  final shot = app.displayedShot.trim().isNotEmpty
      ? app.displayedShot.trim()
      : app.shotText.trim();
  final safeShot = shot.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
  final fileName =
      safeShot.isEmpty ? 'mdslens-panels.csv' : 'mdslens-$safeShot-panels.csv';
  try {
    app.setStatus('Choose where to export the selected panel data...');
    await WidgetsBinding.instance.endOfFrame;
    final destination = await saveBytesWithFilePicker(
      dialogTitle: 'Export selected panel data',
      fileName: fileName,
      allowedExtensions: const ['csv'],
      bytes: Uint8List.fromList(utf8.encode(csv)),
      saveDialog: saveDialog,
    );
    app.setStatus(
      destination == null
          ? 'Export cancelled'
          : 'Exported ${selected.length} panels to ${_displayName(destination)}',
    );
  } catch (error) {
    app.setStatus('Export error: $error');
  }
}

List<Map<String, dynamic>> _panelExportSnapshot(
  AppState app,
  Set<int> selected,
) {
  final snapshot = <Map<String, dynamic>>[];
  var index = 0;
  for (var column = 0; column < app.columns.length; column++) {
    for (var row = 0; row < app.columns[column].length; row++) {
      if (!selected.contains(index) || index >= app.plots.length) {
        index++;
        continue;
      }
      final panel = app.columns[column][row];
      final plot = app.plots[index];
      final specs = (panel['signal_specs'] as List?) ?? const [];
      final series = <Map<String, dynamic>>[];
      for (var signal = 0; signal < plot.series.length; signal++) {
        final data = plot.series[signal];
        if (data?.points == null || data!.points!.isEmpty) continue;
        final spec = signal < specs.length && specs[signal] is Map
            ? Map<String, dynamic>.from(specs[signal] as Map)
            : <String, dynamic>{};
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
          'points': data.points,
        });
      }
      snapshot.add({
        'index': index,
        'column': column,
        'row': row,
        'title': plot.title,
        'series': series,
      });
      index++;
    }
  }
  return snapshot;
}

String encodeMultiplePanelCsv(List<Map<String, dynamic>> panels) {
  final output = StringBuffer()
    ..writeln(
      'panel,column,row,panel_title,series,legend,shot,tree,signal,server_ip,'
      'x_name,x_unit,y_unit,x,y',
    );
  for (final panel in panels) {
    final seriesList = (panel['series'] as List?) ?? const [];
    for (final rawSeries in seriesList) {
      final series = rawSeries as Map;
      final points = (series['points'] as List?) ?? const [];
      for (final rawPoint in points) {
        final point = rawPoint as List;
        if (point.length < 2) continue;
        output.writeln(
          [
            (panel['index'] as int) + 1,
            (panel['column'] as int) + 1,
            (panel['row'] as int) + 1,
            panel['title'],
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
          ].map(_csvValue).join(','),
        );
      }
    }
  }
  return output.toString();
}

String _csvValue(Object? value) {
  final text = value?.toString() ?? '';
  if (!text.contains(RegExp(r'[",\r\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}

String _displayName(String path) {
  final parts = Uri.decodeComponent(path).split(RegExp(r'[/\\]'));
  return parts.lastWhere((part) => part.isNotEmpty, orElse: () => path);
}
