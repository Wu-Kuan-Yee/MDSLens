import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import 'plot_panel.dart';

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

    final nCols = app.columns.length;

    return LayoutBuilder(builder: (ctx, constraints) {
      final panelW = constraints.maxWidth / nCols;

      return Row(
        children: List.generate(nCols, (col) => SizedBox(
          width: panelW,
          child: Column(
            children: List.generate(app.columns[col].length, (row) {
              final plotIdx = app.columns.take(col).map((c) => c.length).fold(0, (a, b) => a + b) + row;
              if (plotIdx >= app.plots.length) return const SizedBox();
              final selected = app.selectedCol == col && app.selectedRow == row;
              return Expanded(
                child: PlotPanel(
                  plotIdx: plotIdx,
                  selected: selected,
                  onTap: () { app.selectPanel(col, row); },
                  onContextAction: (action) {
                    switch (action) {
                      case 'max': app.maximizePlot(plotIdx); break;
                      case 'showAll': app.showAllPanels(); break;
                      case 'reset': app.plots[plotIdx].crosshairX = null; break;
                      case 'delete': break;
                    }
                  },
                ),
              );
            }),
          ),
        )),
      );
    });
  }
}
