import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/toolbar.dart';
import '../widgets/plot_grid.dart';
class MainPage extends StatelessWidget {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyZ, control: !Platform.isMacOS, meta: Platform.isMacOS): () => app.interactionMode = 0,
        SingleActivator(LogicalKeyboardKey.keyP, control: !Platform.isMacOS, meta: Platform.isMacOS): () => app.interactionMode = 1,
        SingleActivator(LogicalKeyboardKey.escape): () { app.clearCrosshair(); },
        SingleActivator(LogicalKeyboardKey.arrowLeft): () => _stepCrosshair(app, -1),
        SingleActivator(LogicalKeyboardKey.arrowRight): () => _stepCrosshair(app, 1),
      },
      child: Focus(autofocus: true, child: Scaffold(
        body: SafeArea(
          child: Column(
          children: [
            const ToolbarWidget(),
            if (app.columns.isEmpty)
              const Expanded(child: Center(child: SelectableText('No environment loaded. Use Open to load a .toml or .webscp file.')))
            else
              const Expanded(child: PlotGrid()),
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Row(children: [
                if (app.fetching) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                if (app.crosshairX != null && app.crosshairReadout.isNotEmpty)
                  SelectableText('x=${app.crosshairX!.toStringAsFixed(4)}  ${app.crosshairReadout.map((e) => '${e.name}:${e.y.toStringAsFixed(4)}').join('  ')}', style: const TextStyle(fontSize: 11))
                else
                  Expanded(child: SelectableText(app.status, style: const TextStyle(fontSize: 12))),
              ]),
            ),
          ],
          ),
        ),
      )),
    );
  }

  static void _stepCrosshair(AppState app, int dir) {
    final cx = app.crosshairX;
    if (cx == null) return;
    // Find a data series to determine step size
    for (final plot in app.plots) {
      for (final s in plot.series) {
        if (s?.points == null || s!.points!.length < 2) continue;
        final pts = s.points!;
        // Step by average point spacing
        final step = (pts.last[0] - pts.first[0]) / pts.length * 10;
        app.setCrosshair(cx + dir * step.abs());
        return;
      }
    }
  }
}
