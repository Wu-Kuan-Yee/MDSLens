import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/keyboard_shortcuts.dart';
import '../widgets/configuration_drop_region.dart';
import '../widgets/dialogs/multi_panel_export.dart';
import '../widgets/toolbar.dart';
import '../widgets/plot_grid.dart';

bool allowShortcutWhileEditing(
  MdsShortcutCommand command, {
  required bool shotInputFocused,
}) {
  if (command == MdsShortcutCommand.exitPoint) return true;
  if (command == MdsShortcutCommand.openFile ||
      command == MdsShortcutCommand.openWebMenu ||
      command == MdsShortcutCommand.saveConfiguration ||
      command == MdsShortcutCommand.globalRate ||
      command == MdsShortcutCommand.globalLayout ||
      command == MdsShortcutCommand.globalExport ||
      command == MdsShortcutCommand.refreshData ||
      command == MdsShortcutCommand.toggleRefresh) {
    return true;
  }
  return shotInputFocused &&
      (command == MdsShortcutCommand.previousShot ||
          command == MdsShortcutCommand.nextShot ||
          command == MdsShortcutCommand.latestShot);
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final _shortcutDispatcher = MdsShortcutDispatcher();

  @override
  void dispose() {
    _shortcutDispatcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final statusStyle = TextStyle(
      fontFamily: app.effectiveFontFamily,
      fontSize: app.fontUiSize.toDouble(),
    );
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
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
                                'This configuration contains no panels. '
                                'Use Settings > Layout Setup to add one.',
                                textAlign: TextAlign.center,
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
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final stroke = shortcutStrokeFromEvent(event);
    if (stroke == null) return KeyEventResult.ignored;
    final app = context.read<AppState>();
    final handled = _shortcutDispatcher.handle(
      stroke,
      bindings: app.keyboardShortcuts,
      isEnabled: (command) => _shortcutEnabled(
        app,
        command,
        shotInputFocused: app.shotFocusNode.hasFocus,
      ),
      onTrigger: (command) => _triggerShortcut(app, command),
    );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _shortcutEnabled(
    AppState app,
    MdsShortcutCommand command, {
    required bool shotInputFocused,
  }) {
    if (_editingText() &&
        !allowShortcutWhileEditing(
          command,
          shotInputFocused: shotInputFocused,
        )) {
      return false;
    }
    switch (command) {
      case MdsShortcutCommand.pointPrevious:
      case MdsShortcutCommand.pointNext:
      case MdsShortcutCommand.exitPoint:
        return app.interactionMode == 1 && app.crosshairX != null;
      case MdsShortcutCommand.panelLeft:
      case MdsShortcutCommand.panelDown:
      case MdsShortcutCommand.panelUp:
      case MdsShortcutCommand.panelRight:
        return !(app.interactionMode == 1 && app.pointLocked);
      case MdsShortcutCommand.panelRate:
      case MdsShortcutCommand.panelSourceSetup:
      case MdsShortcutCommand.panelExport:
      case MdsShortcutCommand.panelSetup:
      case MdsShortcutCommand.maximizePanel:
      case MdsShortcutCommand.resetCurrentScale:
        return app.selectedPlotIndex != null;
      case MdsShortcutCommand.menuLeft:
      case MdsShortcutCommand.menuDown:
      case MdsShortcutCommand.menuUp:
      case MdsShortcutCommand.menuRight:
      case MdsShortcutCommand.menuActivate:
        // PopupMenuRoute owns its focus and arrow/Enter handling.
        return false;
      default:
        return true;
    }
  }

  void _triggerShortcut(AppState app, MdsShortcutCommand command) {
    switch (command) {
      case MdsShortcutCommand.openFile:
        unawaited(
          const ToolbarWidget().openConfigurationShortcut(context, app),
        );
        break;
      case MdsShortcutCommand.openWebMenu:
        const ToolbarWidget().openInternalWebPagesShortcut(context, app);
        break;
      case MdsShortcutCommand.saveConfiguration:
        unawaited(
          const ToolbarWidget().saveConfigurationShortcut(context, app),
        );
        break;
      case MdsShortcutCommand.globalRate:
        unawaited(showRateShortcutMenu(context, app));
        break;
      case MdsShortcutCommand.globalLayout:
        const ToolbarWidget().openLayoutSetupShortcut(context, app);
        break;
      case MdsShortcutCommand.globalExport:
        unawaited(exportMultiplePanels(context, app));
        break;
      case MdsShortcutCommand.pointMode:
        app.interactionMode = 1;
        break;
      case MdsShortcutCommand.zoomMode:
        app.interactionMode = 0;
        break;
      case MdsShortcutCommand.focusShot:
        app.shotFocusNode.requestFocus();
        break;
      case MdsShortcutCommand.refreshData:
        app.refreshDisplayedShot();
        break;
      case MdsShortcutCommand.toggleRefresh:
        app.fetching ? app.stopFetch() : app.refreshDisplayedShot();
        break;
      case MdsShortcutCommand.maximizePanel:
        app.maximizeSelectedPanel();
        break;
      case MdsShortcutCommand.showAllPanels:
        app.showAllPanels();
        break;
      case MdsShortcutCommand.resetCurrentScale:
        app.resetSelectedView();
        break;
      case MdsShortcutCommand.resetAllScales:
        app.resetAllViews();
        break;
      case MdsShortcutCommand.sameXScale:
        _applySelectedSharedScale(app, x: true);
        break;
      case MdsShortcutCommand.sameYScale:
        _applySelectedSharedScale(app, x: false);
        break;
      case MdsShortcutCommand.previousShot:
        _prepareShotNavigation(app);
        app.loadRelativeShot(-1);
        break;
      case MdsShortcutCommand.nextShot:
        _prepareShotNavigation(app);
        app.loadRelativeShot(1);
        break;
      case MdsShortcutCommand.latestShot:
        _prepareShotNavigation(app);
        app.fetchLatestShot();
        break;
      case MdsShortcutCommand.pointPrevious:
        _stepCrosshair(app, -1);
        break;
      case MdsShortcutCommand.pointNext:
        _stepCrosshair(app, 1);
        break;
      case MdsShortcutCommand.panelRate:
        unawaited(
          showRateShortcutMenu(
            context,
            app,
            selectedPanelOnly: true,
          ),
        );
        break;
      case MdsShortcutCommand.panelSourceSetup:
        app.requestSelectedPanelShortcut('source');
        break;
      case MdsShortcutCommand.panelExport:
        app.requestSelectedPanelShortcut('export');
        break;
      case MdsShortcutCommand.panelSetup:
        app.requestSelectedPanelShortcut('setup');
        break;
      case MdsShortcutCommand.panelLeft:
        app.movePanelSelection(-1, 0);
        break;
      case MdsShortcutCommand.panelDown:
        app.movePanelSelection(0, 1);
        break;
      case MdsShortcutCommand.panelUp:
        app.movePanelSelection(0, -1);
        break;
      case MdsShortcutCommand.panelRight:
        app.movePanelSelection(1, 0);
        break;
      case MdsShortcutCommand.exitPoint:
        app.handleEscapeKey();
        break;
      case MdsShortcutCommand.menuLeft:
      case MdsShortcutCommand.menuDown:
      case MdsShortcutCommand.menuUp:
      case MdsShortcutCommand.menuRight:
      case MdsShortcutCommand.menuActivate:
        break;
    }
  }

  static bool _editingText() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  static void _prepareShotNavigation(AppState app) {
    if (!app.shotFocusNode.hasFocus) return;
    app.shotFocusNode.unfocus();
    app.restoreDisplayedShotForNavigation();
  }

  static void _stepCrosshair(AppState app, int dir) {
    final cx = app.crosshairX;
    if (cx == null) return;
    // Find data series, binary-search nearest sample, step to adjacent
    for (final plot in app.plots) {
      for (final s in plot.series) {
        if (s == null || s.pointCount < 2) continue;
        final nearest = s.nearestPointIndex(cx);
        final next = (nearest + dir).clamp(0, s.pointCount - 1);
        app.setCrosshair(s.pointXAt(next));
        return;
      }
    }
  }

  static void _applySelectedSharedScale(AppState app, {required bool x}) {
    final index = app.selectedPlotIndex;
    if (index == null || index >= app.plots.length) return;
    double? minX, maxX, minY, maxY;
    for (final series in app.plots[index].series) {
      final bounds = series?.dataBounds();
      if (bounds == null) continue;
      minX = minX == null ? bounds[0] : minX < bounds[0] ? minX : bounds[0];
      maxX = maxX == null ? bounds[1] : maxX > bounds[1] ? maxX : bounds[1];
      minY = minY == null ? bounds[2] : minY < bounds[2] ? minY : bounds[2];
      maxY = maxY == null ? bounds[3] : maxY > bounds[3] ? maxY : bounds[3];
    }
    if (x && minX != null && maxX != null) {
      app.applySharedXScale(minX, maxX);
    } else if (!x && minY != null && maxY != null) {
      app.applySharedYScale(minY, maxY);
    }
  }
}
