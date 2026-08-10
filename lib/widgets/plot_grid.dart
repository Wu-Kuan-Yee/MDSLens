import 'package:mdslens/i18n/localized_material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import 'plot_panel.dart';
import 'responsive_plot_layout.dart';
import 'vim_focus.dart';

class PlotGrid extends StatelessWidget {
  const PlotGrid({super.key});

  @override
  Widget build(BuildContext context) {
    // Plot data arrives independently for every signal.  Keep this grid
    // subscribed only to structural/selection changes; a data arrival is
    // delivered to the target PlotPanel's own notifier instead of rebuilding
    // the complete grid.
    return Selector<AppState, _PlotGridRevision>(
      selector: (_, app) => _PlotGridRevision.from(app),
      builder: (context, revision, _) {
        final app = context.read<AppState>();
        if (app.columns.isEmpty) return const SizedBox();

        // Maximized mode: single panel fills entire area
        if (app.maximizedPlot != null) {
          final idx = app.maximizedPlot!;
          if (idx >= app.plots.length) return const SizedBox();
          final coordinates = _coordinatesForPlot(app, idx);
          final column = coordinates?.column ?? 0;
          final row = coordinates?.row ?? 0;
          return VimPlotColumnFocus(
            column: column,
            child: PlotPanel(
              // The same plot can move between the regular grid and this
              // branch. Keeping a stable identity prevents Flutter from
              // reusing another panel's local view/menu state when a
              // different panel is maximized.
              key: ValueKey('plot-panel-$idx'),
              plotIdx: idx,
              vimColumn: column,
              vimRow: row,
              selected: true,
              panelShortcutRequests: app.panelShortcutRequests,
              onTap: () => app.selectPanel(column, row),
            ),
          );
        }

        return LayoutBuilder(
          builder: (ctx, constraints) {
            final displayColumns = buildResponsivePlotColumns(
              app.columns.map((column) => column.length).toList(),
              constraints.maxWidth,
            );
            if (displayColumns.isEmpty) return const SizedBox();

            return Row(
              children: displayColumns
                  .map(
                    (column) => Expanded(
                      child: VimPlotColumnFocus(
                        column: column.first.sourceColumn,
                        child: Column(
                          children: column
                              .map(
                                (cell) => Expanded(
                                  child: _panelForCell(app, cell),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        );
      },
    );
  }

  Widget _panelForCell(AppState app, ResponsivePlotCell cell) {
    if (cell.plotIndex >= app.plots.length) return const SizedBox();
    final selected = app.selectedCol == cell.sourceColumn &&
        app.selectedRow == cell.sourceRow;
    return PlotPanel(
      key: ValueKey('plot-panel-${cell.plotIndex}'),
      plotIdx: cell.plotIndex,
      vimColumn: cell.sourceColumn,
      vimRow: cell.sourceRow,
      selected: selected,
      panelShortcutRequests: app.panelShortcutRequests,
      onTap: () => app.selectPanel(cell.sourceColumn, cell.sourceRow),
      onContextAction: (action) {
        switch (action) {
          case 'max':
            app.maximizePlot(cell.plotIndex);
            break;
          case 'showAll':
            app.showAllPanels();
            break;
          case 'reset':
            app.plots[cell.plotIndex].crosshairX = null;
            break;
          case 'delete':
            break;
        }
      },
    );
  }

  ({int column, int row})? _coordinatesForPlot(AppState app, int plotIndex) {
    var remaining = plotIndex;
    for (var column = 0; column < app.columns.length; column++) {
      final rows = app.columns[column].length;
      if (remaining < rows) {
        return (column: column, row: remaining);
      }
      remaining -= rows;
    }
    return null;
  }
}

/// Rebuild keys for the grid itself, but deliberately not for every streamed
/// signal result.  The revision counters are changed only when a structural or
/// visual setting needs all charts to be rebuilt.
class _PlotGridRevision {
  const _PlotGridRevision({
    required this.layout,
    required this.visual,
    required this.selectedCol,
    required this.selectedRow,
    required this.maximizedPlot,
    required this.viewReset,
    required this.rateViewReset,
  });

  factory _PlotGridRevision.from(AppState app) {
    return _PlotGridRevision(
      layout: app.plotLayoutRevision,
      visual: app.plotVisualRevision,
      selectedCol: app.selectedCol,
      selectedRow: app.selectedRow,
      maximizedPlot: app.maximizedPlot,
      viewReset: app.viewResetId,
      rateViewReset: app.rateViewResetId,
    );
  }

  final int layout;
  final int visual;
  final int selectedCol;
  final int selectedRow;
  final int? maximizedPlot;
  final int viewReset;
  final int rateViewReset;

  @override
  bool operator ==(Object other) {
    return other is _PlotGridRevision &&
        other.layout == layout &&
        other.visual == visual &&
        other.selectedCol == selectedCol &&
        other.selectedRow == selectedRow &&
        other.maximizedPlot == maximizedPlot &&
        other.viewReset == viewReset &&
        other.rateViewReset == rateViewReset;
  }

  @override
  int get hashCode => Object.hash(
        layout,
        visual,
        selectedCol,
        selectedRow,
        maximizedPlot,
        viewReset,
        rateViewReset,
      );
}
