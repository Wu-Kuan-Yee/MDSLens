import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import 'plot_panel.dart';
import 'responsive_plot_layout.dart';

class PlotGrid extends StatelessWidget {
  const PlotGrid({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.columns.isEmpty) return const SizedBox();

    // Maximized mode: single panel fills entire area
    if (app.maximizedPlot != null) {
      final idx = app.maximizedPlot!;
      if (idx >= app.plots.length) return const SizedBox();
      return PlotPanel(plotIdx: idx, selected: true);
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
                  child: Column(
                    children: column
                        .map(
                          (cell) => Expanded(child: _panelForCell(app, cell)),
                        )
                        .toList(),
                  ),
                ),
              )
              .toList(),
        );
      },
    );
  }

  Widget _panelForCell(AppState app, ResponsivePlotCell cell) {
    if (cell.plotIndex >= app.plots.length) return const SizedBox();
    final selected =
        app.selectedCol == cell.sourceColumn &&
        app.selectedRow == cell.sourceRow;
    return PlotPanel(
      key: ValueKey('plot-panel-${cell.plotIndex}'),
      plotIdx: cell.plotIndex,
      selected: selected,
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
}
