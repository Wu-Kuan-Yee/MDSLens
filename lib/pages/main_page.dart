import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/toolbar.dart';
import '../widgets/plot_grid.dart';
class MainPage extends StatelessWidget {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
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
    );
  }
}
