import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import 'plot_panel.dart';
import 'responsive_plot_layout.dart';

class PlotGrid extends StatefulWidget {
  const PlotGrid({super.key});

  @override
  State<PlotGrid> createState() => _PlotGridState();
}

class _PlotGridState extends State<PlotGrid> {
  final Set<int> _multiTouchPlots = <int>{};

  void _setMultiTouchActive(int plotIndex, bool active) {
    final changed = active
        ? _multiTouchPlots.add(plotIndex)
        : _multiTouchPlots.remove(plotIndex);
    if (changed && mounted) setState(() {});
  }

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

    return LayoutBuilder(builder: (ctx, constraints) {
      final displayColumns = buildResponsivePlotColumns(
        app.columns.map((column) => column.length).toList(),
        constraints.maxWidth,
      );
      if (displayColumns.isEmpty) return const SizedBox();

      if (usesScrollablePlotList(constraints.maxWidth)) {
        final cells = displayColumns.single;
        return ListView.builder(
          key: const ValueKey('plot-scroll-view'),
          physics: _multiTouchPlots.isNotEmpty
              ? const NeverScrollableScrollPhysics()
              : null,
          itemCount: cells.length,
          itemBuilder: (ctx, i) {
            final cell = cells[i];
            return SizedBox(
              height: cells.length == 1
                  ? constraints.maxHeight
                  : (constraints.maxHeight / 2.5).clamp(220.0, 400.0),
              child: _panelForCell(app, cell),
            );
          },
        );
      }

      return Row(
        children: displayColumns
            .map((column) => Expanded(
                  child: Column(
                    children: column
                        .map(
                            (cell) => Expanded(child: _panelForCell(app, cell)))
                        .toList(),
                  ),
                ))
            .toList(),
      );
    });
  }

  Widget _panelForCell(AppState app, ResponsivePlotCell cell) {
    if (cell.plotIndex >= app.plots.length) return const SizedBox();
    final selected = app.selectedCol == cell.sourceColumn &&
        app.selectedRow == cell.sourceRow;
    return PlotPanel(
      key: ValueKey('plot-panel-${cell.plotIndex}'),
      plotIdx: cell.plotIndex,
      selected: selected,
      onTap: () => app.selectPanel(cell.sourceColumn, cell.sourceRow),
      onMultiTouchChanged: (active) =>
          _setMultiTouchActive(cell.plotIndex, active),
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
