import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/keyboard_shortcuts.dart';
import '../widgets/configuration_drop_region.dart';
import '../widgets/dialogs/multi_panel_export.dart';
import '../widgets/dialogs/keyboard_mode.dart';
import '../widgets/dialogs/keyboard_settings_palette.dart';
import '../widgets/dialogs/vim_command_palette.dart';
import '../widgets/toolbar.dart';
import '../widgets/plot_grid.dart';
import '../widgets/plot_panel.dart';
import '../widgets/vim_focus.dart';

bool allowShortcutWhileEditing(
  MdsShortcutCommand command, {
  required bool shotInputFocused,
}) {
  if (command == MdsShortcutCommand.exitPoint) return true;
  if (command == MdsShortcutCommand.openFile ||
      command == MdsShortcutCommand.openRecentFiles ||
      command == MdsShortcutCommand.openWebMenu ||
      command == MdsShortcutCommand.saveConfiguration ||
      command == MdsShortcutCommand.globalRate ||
      command == MdsShortcutCommand.globalLayout ||
      command == MdsShortcutCommand.globalExport ||
      command == MdsShortcutCommand.refreshData ||
      command == MdsShortcutCommand.exitPoint) {
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
  final _vimWorkspaceFocusNode = FocusNode(debugLabel: 'vim-workspace');

  @override
  void initState() {
    super.initState();
    registerVimWorkspaceFocus(_vimWorkspaceFocusNode);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && context.read<AppState>().vimMode) {
        _vimWorkspaceFocusNode.requestFocus();
      }
    });
    // A Focus.onKeyEvent callback only receives events while this page (or
    // one of its descendants) owns focus. Clicking an empty chart area can
    // intentionally leave the page without a focused child, which made all
    // shortcuts appear to stop working until another control was focused.
    // HardwareKeyboard is the application-wide event boundary and lets the
    // shortcuts remain available in that state while still respecting modal
    // dialogs and popup menus below.
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _shortcutDispatcher.dispose();
    unregisterVimWorkspaceFocus(_vimWorkspaceFocusNode);
    _vimWorkspaceFocusNode.dispose();
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
      focusNode: _vimWorkspaceFocusNode,
      skipTraversal: true,
      child: FocusTraversalGroup(
        policy: OrderedTraversalPolicy(),
        child: Scaffold(
          body: SafeArea(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                FocusManager.instance.primaryFocus?.unfocus();
                if (app.vimMode) _vimWorkspaceFocusNode.requestFocus();
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
      ),
    );
  }

  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    // Plot edit mode owns both key-down and key-up events.  Keeping this
    // before shortcut-stroke parsing prevents a simultaneous H+L/J+K chord
    // from being split into unrelated toolbar shortcuts.
    if (context.read<AppState>().vimMode &&
        handleVimPlotMotionKey(
          FocusManager.instance.primaryFocus?.context ?? context,
          event,
        )) {
      return true;
    }

    final stroke = shortcutStrokeFromEvent(event);
    if (stroke == null) return false;
    final app = context.read<AppState>();
    if (app.vimMode &&
        !_editingText() &&
        (event.logicalKey == LogicalKeyboardKey.colon ||
            (event.logicalKey == LogicalKeyboardKey.semicolon &&
                HardwareKeyboard.instance.isShiftPressed)) &&
        (event is KeyDownEvent || event is KeyRepeatEvent)) {
      unawaited(_openVimCommandPalette(app));
      return true;
    }
    if (app.vimMode && _handleVimWorkspaceKey(event, stroke, app)) {
      return true;
    }
    final fixedPointSeries = fixedPointSeriesOrdinal(stroke);
    if (fixedPointSeries != null &&
        !_editingText() &&
        app.interactionMode == 1 &&
        !app.pointLocked) {
      app.activatePointForCurrentPanel(seriesOrdinal: fixedPointSeries);
      return true;
    }
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
    return handled;
  }

  Future<void> _openVimCommandPalette(AppState app) async {
    final command = await VimCommandPalette.show(context, app);
    if (!mounted || command == null) return;
    _triggerShortcut(app, command);
  }

  /// Direct Vim workspace motions.  The command palette remains available for
  /// every action, while these keys make the high-frequency chart workflow
  /// usable without repeatedly opening a dialog.
  bool _handleVimWorkspaceKey(
    KeyEvent event,
    MdsShortcutStroke stroke,
    AppState app,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    if (stroke.control || stroke.alt || stroke.meta) return false;
    final inputResult = handleVimInputModeKey(context, event);
    if (inputResult == KeyEventResult.handled) return true;
    final focusedContext =
        FocusManager.instance.primaryFocus?.context ?? context;
    if (handleVimPlotEditingKey(focusedContext, event)) return true;
    if (enterVimPlotEditing(focusedContext, event)) return true;
    if (handleVimLayoutNavigationKey(focusedContext, event)) return true;
    if (handleVimPlotNavigationKey(focusedContext, event)) return true;
    final key = stroke.key;
    final shift = stroke.shift;
    final focusedPlot = _focusedPlot();

    if (key == LogicalKeyboardKey.escape && !shift && vimEditingText()) {
      if (leaveVimTextEditing(context)) return true;
    }
    if (key == LogicalKeyboardKey.escape && !shift && focusedPlot) {
      if (app.crosshairX != null) {
        app.handleEscapeKey();
      } else {
        app.clearSelectedPanel();
        FocusManager.instance.primaryFocus?.unfocus();
        _focusFirstVimControl();
      }
      return true;
    }
    if (key == LogicalKeyboardKey.enter && !shift && focusedPlot) {
      app.requestSelectedPanelShortcut('context');
      return true;
    }
    if (key == LogicalKeyboardKey.escape && !shift && !focusedPlot) {
      FocusManager.instance.primaryFocus?.unfocus();
      return true;
    }
    if (vimEditingText() && key != LogicalKeyboardKey.escape) return false;

    // The plot grid has its own virtual matrix: a source Column is a Vim
    // column and a Panel is its row. This branch runs before generic page
    // geometry so a Point-mode plot cannot steal H/L for crosshair movement.
    if (!shift && focusedPlot) {
      final direction = switch (key) {
        LogicalKeyboardKey.keyH ||
        LogicalKeyboardKey.arrowLeft =>
          TraversalDirection.left,
        LogicalKeyboardKey.keyJ ||
        LogicalKeyboardKey.arrowDown =>
          TraversalDirection.down,
        LogicalKeyboardKey.keyK ||
        LogicalKeyboardKey.arrowUp =>
          TraversalDirection.up,
        LogicalKeyboardKey.keyL ||
        LogicalKeyboardKey.arrowRight =>
          TraversalDirection.right,
        _ => null,
      };
      if (direction != null && moveVimPlotFocus(focusedContext, direction)) {
        return true;
      }
    }

    // H/J/K/L are the Vim focus cursor in every non-plot part of the
    // workspace. Shifted motions remain available for chart panning below.
    if (!shift) {
      final direction = switch (key) {
        LogicalKeyboardKey.keyH => TraversalDirection.left,
        LogicalKeyboardKey.keyJ => TraversalDirection.down,
        LogicalKeyboardKey.keyK => TraversalDirection.up,
        LogicalKeyboardKey.keyL => TraversalDirection.right,
        _ => null,
      };
      if (direction != null && moveVimFocus(context, direction)) return true;
    }

    if (key == LogicalKeyboardKey.keyH) {
      if (shift) {
        app.requestSelectedPanelShortcut('pan-left');
      } else {
        app.movePanelSelection(-1, 0);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyL) {
      if (shift) {
        app.requestSelectedPanelShortcut('pan-right');
      } else {
        app.movePanelSelection(1, 0);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyJ) {
      if (shift) {
        app.requestSelectedPanelShortcut('pan-down');
      } else {
        app.movePanelSelection(0, 1);
      }
      return true;
    }
    if (key == LogicalKeyboardKey.keyK) {
      if (shift) {
        app.requestSelectedPanelShortcut('pan-up');
      } else {
        app.movePanelSelection(0, -1);
      }
      return true;
    }

    // Enter or c opens the same context menu as a mouse right click on the
    // selected panel.  The panel computes its own on-screen anchor.
    if (key == LogicalKeyboardKey.keyC) {
      if (focusedPlot && app.selectedPlotIndex != null) {
        app.requestSelectedPanelShortcut('context');
        return true;
      }
      return false;
    }
    if (key == LogicalKeyboardKey.keyP) {
      app.interactionMode = 1;
      app.activatePointForCurrentPanel();
      return true;
    }
    if (key == LogicalKeyboardKey.keyZ) {
      app.interactionMode = 0;
      return true;
    }
    if (key == LogicalKeyboardKey.equal && shift) {
      app.requestSelectedPanelShortcut('zoom-in');
      return true;
    }
    if (key == LogicalKeyboardKey.minus && !shift) {
      app.requestSelectedPanelShortcut('zoom-out');
      return true;
    }
    if (key == LogicalKeyboardKey.bracketLeft) {
      app.requestSelectedPanelShortcut('zoom-out');
      return true;
    }
    if (key == LogicalKeyboardKey.bracketRight) {
      app.requestSelectedPanelShortcut('zoom-in');
      return true;
    }
    if (key == LogicalKeyboardKey.digit0 && !shift) {
      app.resetSelectedView();
      return true;
    }
    if (key == LogicalKeyboardKey.keyO && !shift) {
      unawaited(const ToolbarWidget().openConfigurationShortcut(context, app));
      return true;
    }
    if (key == LogicalKeyboardKey.keyO && shift) {
      unawaited(
        const ToolbarWidget().openRecentConfigurationsShortcut(context, app),
      );
      return true;
    }
    if (key == LogicalKeyboardKey.keyS && !shift) {
      unawaited(const ToolbarWidget().saveConfigurationShortcut(context, app));
      return true;
    }
    return false;
  }

  bool _shortcutEnabled(
    AppState app,
    MdsShortcutCommand command, {
    required bool shotInputFocused,
  }) {
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
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
        return app.interactionMode == 1 && app.crosshairX != null;
      case MdsShortcutCommand.exitPoint:
        // Escape is also the global cancel/restore key (for example after
        // maximizing a panel), so it must not depend on an active crosshair.
        return true;
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
        // PopupMenuRoute owns its focus and arrow/Enter handling.
        return false;
      case MdsShortcutCommand.menuActivate:
        // PopupMenuRoute owns Enter while it is open.  On the main page the
        // same key resumes Point tracking, matching the desktop client.
        return app.interactionMode == 1 && !app.pointLocked;
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
      case MdsShortcutCommand.openRecentFiles:
        unawaited(
          const ToolbarWidget().openRecentConfigurationsShortcut(context, app),
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
      case MdsShortcutCommand.restoreDefaultConfiguration:
        unawaited(
          const ToolbarWidget().restoreDefaultConfigurationShortcut(
            context,
            app,
          ),
        );
        break;
      case MdsShortcutCommand.openLogin:
        const ToolbarWidget().openLoginShortcut(context);
        break;
      case MdsShortcutCommand.openSshTunnel:
        const ToolbarWidget().openSshTunnelShortcut(context);
        break;
      case MdsShortcutCommand.openFontSettings:
        const ToolbarWidget().openFontSettingsShortcut(context, app);
        break;
      case MdsShortcutCommand.openShotHistory:
        unawaited(
          const ToolbarWidget().openShotHistoryShortcut(context, app),
        );
        break;
      case MdsShortcutCommand.openKeyboardShortcuts:
        const ToolbarWidget().openKeyboardShortcutsShortcut(context);
        break;
      case MdsShortcutCommand.openSettings:
        unawaited(_openKeyboardSettings(app));
        break;
      case MdsShortcutCommand.openKeyboardMode:
        unawaited(KeyboardModeDialog.show(context));
        break;
      case MdsShortcutCommand.openAbout:
        const ToolbarWidget().openAboutShortcut(context);
        break;
      case MdsShortcutCommand.restoreAllSettings:
        unawaited(
          const ToolbarWidget().restoreAllSettingsShortcut(context, app),
        );
        break;
      case MdsShortcutCommand.setLightTheme:
        app.themeMode = 0;
        break;
      case MdsShortcutCommand.setAutoTheme:
        app.themeMode = 2;
        break;
      case MdsShortcutCommand.setDarkTheme:
        app.themeMode = 1;
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
        app.activatePointForCurrentPanel();
        break;
      case MdsShortcutCommand.zoomMode:
        app.interactionMode = 0;
        break;
      case MdsShortcutCommand.focusShot:
        app.shotFocusNode.requestFocus();
        app.shotCtrl.selection = TextSelection(
          baseOffset: 0,
          extentOffset: app.shotCtrl.text.length,
        );
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
        app.stepActivePoint(-1);
        break;
      case MdsShortcutCommand.pointNext:
        app.stepActivePoint(1);
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
      case MdsShortcutCommand.menuActivate:
        app.activatePointForCurrentPanel();
        break;
      case MdsShortcutCommand.menuLeft:
      case MdsShortcutCommand.menuDown:
      case MdsShortcutCommand.menuUp:
      case MdsShortcutCommand.menuRight:
        break;
    }
  }

  Future<void> _openKeyboardSettings(AppState app) async {
    final command = await KeyboardSettingsPalette.show(context, app);
    if (!mounted ||
        command == null ||
        command == MdsShortcutCommand.openSettings) {
      return;
    }
    _triggerShortcut(app, command);
  }

  bool _focusedPlot() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext?.findAncestorWidgetOfExactType<PlotPanel>() != null;
  }

  void _focusFirstVimControl() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !context.read<AppState>().vimMode) return;
      final scope = Focus.maybeOf(context, scopeOk: true)?.nearestScope;
      final first = scope?.traversalDescendants
          .where((node) => node.canRequestFocus && !node.skipTraversal)
          .firstOrNull;
      first?.requestFocus();
    });
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

  static void _applySelectedSharedScale(AppState app, {required bool x}) {
    final index = app.selectedPlotIndex;
    if (index == null || index >= app.plots.length) return;
    double? minX, maxX, minY, maxY;
    for (final series in app.plots[index].series) {
      final bounds = series?.dataBounds();
      if (bounds == null) continue;
      minX = minX == null
          ? bounds[0]
          : minX < bounds[0]
              ? minX
              : bounds[0];
      maxX = maxX == null
          ? bounds[1]
          : maxX > bounds[1]
              ? maxX
              : bounds[1];
      minY = minY == null
          ? bounds[2]
          : minY < bounds[2]
              ? minY
              : bounds[2];
      maxY = maxY == null
          ? bounds[3]
          : maxY > bounds[3]
              ? maxY
              : bounds[3];
    }
    if (x && minX != null && maxX != null) {
      app.applySharedXScale(minX, maxX);
    } else if (!x && minY != null && maxY != null) {
      app.applySharedYScale(minY, maxY);
    }
  }
}
