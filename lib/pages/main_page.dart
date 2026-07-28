import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/keyboard_shortcuts.dart';
import '../widgets/configuration_drop_region.dart';
import '../widgets/toolbar.dart';
import '../widgets/plot_grid.dart';

class MainPage extends StatelessWidget {
  const MainPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final statusStyle = TextStyle(
      fontFamily: app.effectiveFontFamily,
      fontSize: app.fontUiSize.toDouble(),
    );
    return CallbackShortcuts(
      bindings: _shortcutCallbacks(app),
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SafeArea(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                app.clearSelectedPanel();
              },
              child: Column(
                children: [
                  const ResponsiveToolbar(),
                  Expanded(
                    child: ConfigurationDropRegion(
                      child: app.columns.isEmpty
                          ? const Center(
                              child: SelectableText(
                                'No environment loaded. Use Open to load a .toml or .webscp file.',
                              ),
                            )
                          : const PlotGrid(),
                    ),
                  ),
                  Container(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    child: Row(
                      children: [
                        if (app.fetching)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        const SizedBox(width: 8),
                        if (app.crosshairX != null &&
                            app.crosshairReadout.isNotEmpty)
                          Expanded(
                            child: SelectableText(
                              'x=${app.crosshairX!.toStringAsFixed(4)}  ${app.crosshairReadout.map((e) => '${e.name}:${e.y.toStringAsFixed(4)}').join('  ')}',
                              style: statusStyle,
                            ),
                          )
                        else
                          Expanded(
                            child: SelectableText(
                              app.status,
                              style: statusStyle,
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
    );
  }

  static Map<ShortcutActivator, VoidCallback> _shortcutCallbacks(AppState app) {
    final actions = <MdsShortcutCommand, VoidCallback>{
      MdsShortcutCommand.pointMode: () => app.interactionMode = 1,
      MdsShortcutCommand.zoomMode: () => app.interactionMode = 0,
      MdsShortcutCommand.focusShot: () => app.shotFocusNode.requestFocus(),
      MdsShortcutCommand.toggleRefresh: () =>
          app.fetching ? app.stopFetch() : app.refreshDisplayedShot(),
      MdsShortcutCommand.maximizePanel: app.maximizeSelectedPanel,
      MdsShortcutCommand.showAllPanels: app.showAllPanels,
      MdsShortcutCommand.resetCurrentScale: app.resetSelectedView,
      MdsShortcutCommand.resetAllScales: app.resetAllViews,
      MdsShortcutCommand.previousShot: () => app.loadRelativeShot(-1),
      MdsShortcutCommand.nextShot: () => app.loadRelativeShot(1),
      MdsShortcutCommand.latestShot: app.fetchLatestShot,
      MdsShortcutCommand.pointPrevious: () => _stepCrosshair(app, -1),
      MdsShortcutCommand.pointNext: () => _stepCrosshair(app, 1),
      MdsShortcutCommand.exitPoint: app.handleEscapeKey,
      MdsShortcutCommand.panelLeft: () => app.movePanelSelection(-1, 0),
      MdsShortcutCommand.panelDown: () => app.movePanelSelection(0, 1),
      MdsShortcutCommand.panelUp: () => app.movePanelSelection(0, -1),
      MdsShortcutCommand.panelRight: () => app.movePanelSelection(1, 0),
    };
    final bindings = <ShortcutActivator, VoidCallback>{};
    for (final entry in app.keyboardShortcuts.entries) {
      final action = actions[entry.key];
      if (action == null) continue;
      for (final stroke in entry.value.strokes) {
        bindings[stroke.activator] = () {
          if (_editingText() && entry.key != MdsShortcutCommand.exitPoint) {
            return;
          }
          action();
        };
      }
    }
    return bindings;
  }

  static bool _editingText() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  static void _stepCrosshair(AppState app, int dir) {
    final cx = app.crosshairX;
    if (cx == null) return;
    // Find data series, binary-search nearest sample, step to adjacent
    for (final plot in app.plots) {
      for (final s in plot.series) {
        if (s?.points == null || s!.points!.length < 2) continue;
        final pts = s.points!;
        // Binary search for nearest index
        var lo = 0;
        var hi = pts.length - 1;
        while (lo < hi) {
          final mid = (lo + hi) ~/ 2;
          if (pts[mid][0] < cx) {
            lo = mid + 1;
          } else {
            hi = mid;
          }
        }
        if (lo > 0 && (cx - pts[lo - 1][0]).abs() < (pts[lo][0] - cx).abs()) {
          lo--;
        }
        // Step to adjacent sample
        final next = (lo + dir).clamp(0, pts.length - 1);
        app.setCrosshair(pts[next][0]);
        return;
      }
    }
  }
}
