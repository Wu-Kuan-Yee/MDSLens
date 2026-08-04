import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/external_url_launcher.dart';
import '../services/keyboard_shortcuts.dart';
import '../services/rust_bridge.dart';
import '../services/system_font_service.dart';
import 'dialogs/login.dart';
import 'dialogs/ssh.dart';
import 'dialogs/about.dart';
import 'dialogs/keyboard_safe_dialog.dart';
import 'dialogs/keyboard_shortcuts.dart';
import 'dialogs/keyboard_mode.dart';
import 'dropdown_items.dart';
import 'plot_panel.dart';
import 'polished_dropdown.dart';
import 'polished_popup_menu.dart';
import 'responsive_plot_layout.dart';
import 'configuration_import_prompt.dart';
import 'vim_focus.dart';

class _LayoutDragData {
  const _LayoutDragData.column(this.column) : row = null;
  const _LayoutDragData.panel(this.column, this.row);

  final int column;
  final int? row;
  bool get isColumn => row == null;
}

class _LayoutPanelPosition {
  const _LayoutPanelPosition(this.column, this.row, this.columnIdentity);

  final int column;
  final int row;
  final List<Map<String, dynamic>> columnIdentity;
}

Map<Map<String, dynamic>, _LayoutPanelPosition> _snapshotLayoutPanelPositions(
  List<List<Map<String, dynamic>>> columns,
) {
  final positions = Map<Map<String, dynamic>, _LayoutPanelPosition>.identity();
  for (var column = 0; column < columns.length; column++) {
    for (var row = 0; row < columns[column].length; row++) {
      positions[columns[column][row]] = _LayoutPanelPosition(
        column,
        row,
        columns[column],
      );
    }
  }
  return positions;
}

Map<List<Map<String, dynamic>>, int> _snapshotLayoutColumnPositions(
  List<List<Map<String, dynamic>>> columns,
) {
  final positions = Map<List<Map<String, dynamic>>, int>.identity();
  for (var column = 0; column < columns.length; column++) {
    positions[columns[column]] = column;
  }
  return positions;
}

Map<Map<String, dynamic>, Offset> _layoutPanelMotionOffsets(
  Map<Map<String, dynamic>, _LayoutPanelPosition> before,
  Map<Map<String, dynamic>, _LayoutPanelPosition> after,
) {
  final offsets = Map<Map<String, dynamic>, Offset>.identity();
  for (final entry in after.entries) {
    final oldPosition = before[entry.key];
    if (oldPosition == null) continue;
    final newPosition = entry.value;
    final columnDelta =
        identical(oldPosition.columnIdentity, newPosition.columnIdentity)
            ? 0
            : oldPosition.column - newPosition.column;
    final offset = Offset(
      columnDelta * 164.0,
      (oldPosition.row - newPosition.row) * 119.0,
    );
    if (offset != Offset.zero) offsets[entry.key] = offset;
  }
  return offsets;
}

Map<List<Map<String, dynamic>>, Offset> _layoutColumnMotionOffsets(
  Map<List<Map<String, dynamic>>, int> before,
  Map<List<Map<String, dynamic>>, int> after,
) {
  final offsets = Map<List<Map<String, dynamic>>, Offset>.identity();
  for (final entry in after.entries) {
    final oldColumn = before[entry.key];
    if (oldColumn == null) continue;
    final offset = Offset((oldColumn - entry.value) * 164.0, 0);
    if (offset != Offset.zero) offsets[entry.key] = offset;
  }
  return offsets;
}

class _LayoutSettlingTransform extends StatelessWidget {
  const _LayoutSettlingTransform({
    required this.animationId,
    required this.revision,
    required this.offset,
    required this.appearing,
    required this.child,
  });

  final int animationId;
  final int revision;
  final Offset offset;
  final bool appearing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey('layout-item-settle-$animationId-$revision'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 210),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (context, value, child) {
        final translation = Offset.lerp(offset, Offset.zero, value)!;
        final scale = appearing ? 0.96 + 0.04 * value : 1.0;
        return Opacity(
          opacity: appearing ? 0.45 + 0.55 * value : 1,
          child: Transform.translate(
            offset: translation,
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

bool reorderLayoutColumn(
  List<List<Map<String, dynamic>>> columns,
  int sourceColumn,
  int insertionIndex,
) {
  if (sourceColumn < 0 ||
      sourceColumn >= columns.length ||
      insertionIndex < 0 ||
      insertionIndex > columns.length) {
    return false;
  }
  final column = columns.removeAt(sourceColumn);
  final adjusted =
      insertionIndex > sourceColumn ? insertionIndex - 1 : insertionIndex;
  columns.insert(adjusted.clamp(0, columns.length), column);
  return adjusted != sourceColumn;
}

bool reorderLayoutPanel(
  List<List<Map<String, dynamic>>> columns, {
  required int sourceColumn,
  required int sourceRow,
  required int targetColumn,
  required int insertionRow,
}) {
  if (sourceColumn < 0 ||
      sourceColumn >= columns.length ||
      targetColumn < 0 ||
      targetColumn >= columns.length ||
      sourceRow < 0 ||
      sourceRow >= columns[sourceColumn].length ||
      insertionRow < 0 ||
      insertionRow > columns[targetColumn].length) {
    return false;
  }
  if (sourceColumn == targetColumn &&
      (insertionRow == sourceRow || insertionRow == sourceRow + 1)) {
    return false;
  }

  final panel = columns[sourceColumn].removeAt(sourceRow);
  var adjustedTargetColumn = targetColumn;
  var adjustedInsertionRow = insertionRow;
  if (sourceColumn == targetColumn && insertionRow > sourceRow) {
    adjustedInsertionRow--;
  } else if (columns[sourceColumn].isEmpty) {
    columns.removeAt(sourceColumn);
    if (targetColumn > sourceColumn) adjustedTargetColumn--;
  }
  final target = columns[adjustedTargetColumn];
  target.insert(adjustedInsertionRow.clamp(0, target.length), panel);
  return true;
}

bool moveLayoutPanelToNewColumn(
  List<List<Map<String, dynamic>>> columns, {
  required int sourceColumn,
  required int sourceRow,
  required int insertionIndex,
}) {
  if (sourceColumn < 0 ||
      sourceColumn >= columns.length ||
      sourceRow < 0 ||
      sourceRow >= columns[sourceColumn].length ||
      insertionIndex < 0 ||
      insertionIndex > columns.length) {
    return false;
  }

  final sourceWasSingleton = columns[sourceColumn].length == 1;
  final panel = columns[sourceColumn].removeAt(sourceRow);
  var adjustedInsertionIndex = insertionIndex;
  if (columns[sourceColumn].isEmpty) {
    columns.removeAt(sourceColumn);
    if (insertionIndex > sourceColumn) adjustedInsertionIndex--;
  }
  adjustedInsertionIndex = adjustedInsertionIndex.clamp(0, columns.length);
  columns.insert(adjustedInsertionIndex, [panel]);
  return !sourceWasSingleton || adjustedInsertionIndex != sourceColumn;
}

bool layoutColumnIsSelected(
  List<Map<String, dynamic>> column,
  Set<Map<String, dynamic>> selectedPanels,
) =>
    column.isNotEmpty && column.every(selectedPanels.contains);

void toggleLayoutPanelSelection(
  Map<String, dynamic> panel,
  Set<Map<String, dynamic>> selectedPanels,
) {
  if (!selectedPanels.remove(panel)) selectedPanels.add(panel);
}

void toggleLayoutColumnSelection(
  List<Map<String, dynamic>> column,
  Set<Map<String, dynamic>> selectedPanels,
) {
  if (layoutColumnIsSelected(column, selectedPanels)) {
    selectedPanels.removeAll(column);
  } else {
    selectedPanels.addAll(column);
  }
}

int deleteSelectedLayoutPanels(
  List<List<Map<String, dynamic>>> columns,
  Set<Map<String, dynamic>> selectedPanels,
) {
  final before = columns.fold<int>(0, (count, column) => count + column.length);
  for (final column in columns) {
    column.removeWhere(selectedPanels.contains);
  }
  columns.removeWhere((column) => column.isEmpty);
  selectedPanels.clear();
  final after = columns.fold<int>(0, (count, column) => count + column.length);
  return before - after;
}

List<(String, String)> _shotMetadata(AppState app) {
  String valueWithUnit(String value, String unit) {
    if (value.isEmpty) return app.fetching ? '...' : '--';
    if (RegExp(r'[a-zA-Z]$').hasMatch(value.trim())) return value;
    return '$value $unit';
  }

  return [
    (
      'Shot',
      app.displayedShot.isNotEmpty
          ? app.displayedShot
          : (app.shotText.isEmpty ? '--' : app.shotText),
    ),
    ('Ip', valueWithUnit(app.shotInfoIp, 'kA')),
    ('Pulse', valueWithUnit(app.shotInfoPulse, 's')),
    ('It', valueWithUnit(app.shotInfoIt, 'A')),
    (
      'Time',
      app.shotInfoTime.isEmpty
          ? (app.fetching ? '...' : '--')
          : app.shotInfoTime,
    ),
  ];
}

GlobalKey _rateDropdownAnchorKey(AppState app) =>
    GlobalObjectKey<State<StatefulWidget>>(app);

Future<void> showRateShortcutMenu(
  BuildContext context,
  AppState app, {
  bool selectedPanelOnly = false,
}) async {
  final overlay = Navigator.of(context).overlay?.context.findRenderObject();
  final rateAnchor =
      _rateDropdownAnchorKey(app).currentContext?.findRenderObject();
  final position = rateAnchor is RenderBox && rateAnchor.hasSize
      ? rateAnchor.localToGlobal(Offset(0, rateAnchor.size.height + 6))
      : overlay is RenderBox
          ? overlay.localToGlobal(
              Offset(overlay.size.width / 2, overlay.size.height / 2),
            )
          : Offset.zero;
  final value = await showPolishedPopupMenu<int>(
    context: context,
    globalPosition: position,
    id: selectedPanelOnly ? 'shortcut-panel-rate-menu' : 'shortcut-rate-menu',
    keyboardShortcuts: app.keyboardShortcuts,
    groups: [
      PolishedPopupMenuGroup(
        label: selectedPanelOnly ? 'Selected panel rate' : 'Rate',
        options: const [
          PolishedPopupMenuOption(
            id: 'thin',
            value: 0,
            label: 'Thin',
            icon: Icons.compress_rounded,
          ),
          PolishedPopupMenuOption(
            id: 'medium',
            value: 1,
            label: 'Medium',
            icon: Icons.format_line_spacing_rounded,
          ),
          PolishedPopupMenuOption(
            id: 'full',
            value: 2,
            label: 'Full',
            icon: Icons.stacked_line_chart_rounded,
          ),
        ],
      ),
    ],
  );
  if (value == null) return;
  if (selectedPanelOnly) {
    app.changeSelectedPanelDataModeAndRefresh(value);
  } else {
    app.changeDataModeAndRefresh(value);
  }
}

class ResponsiveToolbar extends StatelessWidget {
  const ResponsiveToolbar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final screenHeight = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final offersCollapse = constraints.maxWidth < 600 || screenHeight < 720;
        if (!offersCollapse) return const ToolbarWidget();

        final theme = Theme.of(context);
        final tinyWidth = constraints.maxWidth < 320;
        final tinyHeight = screenHeight < 520;
        final tinyScreen = tinyWidth || tinyHeight;
        final collapseControlWidth = math.min(
          170.0,
          constraints.maxWidth * 0.75,
        );
        final expandedToolbar = tinyScreen
            ? SizedBox(
                height: (screenHeight * 0.42).clamp(80.0, 260.0),
                child: AdaptiveTwoAxisScrollView(
                  keyPrefix: 'toolbar-controls',
                  enableHorizontal: tinyWidth,
                  enableVertical: tinyHeight,
                  showHorizontalScrollbar: tinyWidth,
                  showVerticalScrollbar: tinyHeight,
                  minContentWidth: 320,
                  child: SizedBox(
                    width: tinyWidth ? 320 : constraints.maxWidth,
                    child: const ToolbarWidget(),
                  ),
                ),
              )
            : const ToolbarWidget();
        final metadata = _shotMetadata(
          app,
        ).map((entry) => '${entry.$1}: ${entry.$2}').join('   •   ');
        Widget collapseToggle({required bool collapsed}) {
          final label = collapsed ? 'Expand controls' : 'Collapse controls';
          return Focus(
            canRequestFocus: true,
            skipTraversal: false,
            descendantsAreTraversable: false,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              if (event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space) {
                app.toolbarCollapsed = !collapsed;
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: InkWell(
              key: const ValueKey('toolbar-collapse-control'),
              onTap: () => app.toolbarCollapsed = !collapsed,
              child: SizedBox(
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(
                        collapsed
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_up_rounded,
                        size: 22,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final collapseBar = app.toolbarCollapsed
            ? SizedBox(
                height: 40,
                child: Row(
                  children: [
                    SizedBox(
                      width: collapseControlWidth,
                      child: collapseToggle(collapsed: true),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      indent: 9,
                      endIndent: 9,
                      color: theme.dividerColor,
                    ),
                    Expanded(
                      child: _CollapsedMetadataScroller(metadata: metadata),
                    ),
                  ],
                ),
              )
            : collapseToggle(collapsed: false);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: app.toolbarCollapsed
                  ? const SizedBox(width: double.infinity)
                  : expandedToolbar,
            ),
            Material(
              color: theme.colorScheme.surfaceContainerHigh,
              child: collapseBar,
            ),
          ],
        );
      },
    );
  }
}

String _shortcutTooltip(
  AppState app,
  String label,
  MdsShortcutCommand command,
) =>
    _shortcutTooltipFor(app, label, [command]);

String _shortcutTooltipFor(
  AppState app,
  String label,
  Iterable<MdsShortcutCommand> commands,
) {
  final shortcuts = <String>{
    for (final command in commands)
      ...app
          .shortcutText(command)
          .split(' / ')
          .where((text) => text.isNotEmpty),
  };
  final shortcut = shortcuts.join(' / ');
  return shortcut.isEmpty ? label : '$label ($shortcut)';
}

class _CollapsedMetadataScroller extends StatefulWidget {
  const _CollapsedMetadataScroller({required this.metadata});

  final String metadata;

  @override
  State<_CollapsedMetadataScroller> createState() =>
      _CollapsedMetadataScrollerState();
}

class _CollapsedMetadataScrollerState
    extends State<_CollapsedMetadataScroller> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      key: const ValueKey('toolbar-collapsed-metadata-scrollbar'),
      controller: _controller,
      thumbVisibility: true,
      interactive: true,
      thickness: 2,
      radius: const Radius.circular(2),
      scrollbarOrientation: ScrollbarOrientation.bottom,
      notificationPredicate: (notification) =>
          notification.metrics.axis == Axis.horizontal,
      child: SingleChildScrollView(
        key: const ValueKey('toolbar-collapsed-metadata-scroll'),
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 3),
        child: Center(
          child: Text(
            widget.metadata,
            key: const ValueKey('toolbar-collapsed-summary'),
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class ToolbarWidget extends StatelessWidget {
  const ToolbarWidget({super.key});

  Future<void> openConfigurationShortcut(
    BuildContext context,
    AppState app,
  ) =>
      _openConfiguration(context, app);

  Future<void> openRecentConfigurationsShortcut(
    BuildContext context,
    AppState app,
  ) =>
      _showRecentConfigurations(context, app);

  Future<void> saveConfigurationShortcut(
    BuildContext context,
    AppState app,
  ) =>
      _chooseConfigurationSaveFormat(context, app);

  Future<void> restoreDefaultConfigurationShortcut(
    BuildContext context,
    AppState app,
  ) =>
      _confirmRestoreDefaultConfiguration(context, app);

  void openLoginShortcut(BuildContext context) {
    LoginDialog.show(context);
  }

  void openSshTunnelShortcut(BuildContext context) {
    SshDialog.show(context);
  }

  void openFontSettingsShortcut(BuildContext context, AppState app) {
    _showFontDialog(context, app);
  }

  Future<void> openShotHistoryShortcut(
    BuildContext context,
    AppState app,
  ) =>
      _showShotHistoryManager(context, app);

  void openKeyboardShortcutsShortcut(BuildContext context) {
    KeyboardShortcutsDialog.show(context);
  }

  void openAboutShortcut(BuildContext context) {
    AboutDialogWidget.show(context);
  }

  Future<void> restoreAllSettingsShortcut(
    BuildContext context,
    AppState app,
  ) =>
      _confirmRestoreAllSettings(context, app);

  void openInternalWebPagesShortcut(BuildContext context, AppState app) {
    _showWebBookmarks(context, app);
  }

  void openLayoutSetupShortcut(BuildContext context, AppState app) {
    _showLayoutSetup(context, app);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final uiSize = app.fontUiSize.toDouble();
    final infoValueStyle = TextStyle(
      fontFamily: app.effectiveFontFamily,
      fontSize: (uiSize - 1).clamp(6, 28).toDouble(),
      color: theme.colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final infoLabelStyle = infoValueStyle.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w500,
    );
    final shotMetadata = _shotMetadata(app);

    final fileActions = _equalActionRow(
      key: const ValueKey('toolbar-file-actions'),
      children: [
        _toolbarIconButton(
          context,
          icon: Icons.folder_open_rounded,
          tooltip: _shortcutTooltip(
            app,
            'Open configuration',
            MdsShortcutCommand.openFile,
          ),
          onPressed: () => _openConfiguration(context, app),
        ),
        _toolbarRecentConfigurationButton(
          context,
          app,
        ),
        _toolbarIconButton(
          context,
          icon: Icons.save_rounded,
          tooltip: _shortcutTooltip(
            app,
            'Save configuration',
            MdsShortcutCommand.saveConfiguration,
          ),
          onPressed: () => _chooseConfigurationSaveFormat(context, app),
        ),
        _toolbarIconButton(
          context,
          icon: Icons.settings_backup_restore_rounded,
          tooltip: 'Restore default configuration',
          onPressed: () => _confirmRestoreDefaultConfiguration(context, app),
        ),
        _toolbarIconButton(
          context,
          icon: app.fetching ? Icons.stop_circle_outlined : Icons.refresh,
          tooltip: _shortcutTooltip(
            app,
            app.fetching ? 'Stop loading' : 'Refresh waveforms',
            app.fetching
                ? MdsShortcutCommand.toggleRefresh
                : MdsShortcutCommand.refreshData,
          ),
          onPressed: () =>
              app.fetching ? app.stopFetch() : app.refreshDisplayedShot(),
          active: app.fetching,
        ),
      ],
    );
    final rateSelector = Row(
      key: const ValueKey('toolbar-rate'),
      children: [
        Text(
          'Rate:',
          style: TextStyle(
            fontSize: uiSize,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SizedBox(
            key: _rateDropdownAnchorKey(app),
            child: PolishedDropdown<int>(
              key: const ValueKey('toolbar-rate-dropdown'),
              id: 'toolbar-rate',
              value: app.dataMode,
              leadingIcon: Icons.speed_rounded,
              fontSize: uiSize,
              minimumMenuWidth: 190,
              tooltip: _shortcutTooltip(
                app,
                'Rate',
                MdsShortcutCommand.globalRate,
              ),
              options: const [
                PolishedDropdownOption(
                  value: 0,
                  label: 'Thin',
                  icon: Icons.compress_rounded,
                ),
                PolishedDropdownOption(
                  value: 1,
                  label: 'Medium',
                  icon: Icons.format_line_spacing_rounded,
                ),
                PolishedDropdownOption(
                  value: 2,
                  label: 'Full',
                  icon: Icons.stacked_line_chart_rounded,
                ),
              ],
              onChanged: (value) {
                app.changeDataModeAndRefresh(value);
              },
            ),
          ),
        ),
      ],
    );
    final appActions = _equalActionRow(
      key: const ValueKey('toolbar-app-actions'),
      spacing: 6,
      children: [
        _settingsMenu(context, app),
        _toolbarIconButton(
          context,
          icon: Icons.account_box_rounded,
          tooltip: app.hasActiveSession ? 'Account — signed in' : 'Login',
          onPressed: () => LoginDialog.show(context),
          active: app.hasActiveSession,
          activeColor: const Color(0xFF16A34A),
        ),
        _sshBtn(context, app),
      ],
    );
    final shotEntry = Row(
      key: const ValueKey('toolbar-shot-entry'),
      children: [
        Text(
          'Shot:',
          style: TextStyle(
            fontSize: uiSize,
            color: theme.colorScheme.onSurface,
          ),
        ),
        if (app.shotHistory.isNotEmpty) ...[
          const SizedBox(width: 6),
          PolishedDropdown<String>(
            key: const ValueKey('toolbar-shot-history-dropdown'),
            id: 'toolbar-shot-history',
            value: app.shotText,
            leadingIcon: Icons.history_rounded,
            height: 40,
            fontSize: uiSize,
            minimumMenuWidth: 180,
            menuMaxHeight: 320,
            iconOnly: true,
            tooltip: 'Shot history',
            menuAction: PolishedDropdownAction(
              label: 'Manage shot history',
              icon: Icons.manage_history_rounded,
              onPressed: () => _showShotHistoryManager(context, app),
            ),
            options: app.shotHistory
                .map(
                  (shot) => PolishedDropdownOption(
                    value: shot,
                    label: shot,
                    icon: Icons.history_rounded,
                  ),
                )
                .toList(),
            onChanged: (v) {
              app.shotText = v;
              app.startRefresh();
            },
          ),
        ],
        const SizedBox(width: 6),
        Expanded(
          flex: 3,
          child: TextField(
            controller: app.shotCtrl,
            focusNode: app.shotFocusNode,
            readOnly: vimTextFieldReadOnly(context),
            style: TextStyle(fontSize: uiSize),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            onSubmitted: (_) => app.startRefresh(),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          flex: 2,
          child: _toolbarIconButton(
            context,
            icon: Icons.play_arrow_rounded,
            tooltip: 'Load shot',
            onPressed: () => app.startRefresh(),
          ),
        ),
      ],
    );
    final shotNavigation = _equalActionRow(
      key: const ValueKey('toolbar-shot-navigation'),
      children: [
        _toolbarIconButton(
          context,
          icon: Icons.skip_previous_rounded,
          tooltip: _shortcutTooltip(
            app,
            'Previous shot',
            MdsShortcutCommand.previousShot,
          ),
          onPressed: () => app.loadRelativeShot(-1),
        ),
        _toolbarIconButton(
          context,
          icon: Icons.skip_next_rounded,
          tooltip: _shortcutTooltip(
            app,
            'Next shot',
            MdsShortcutCommand.nextShot,
          ),
          onPressed: () => app.loadRelativeShot(1),
        ),
        _toolbarIconButton(
          context,
          icon: Icons.last_page_rounded,
          tooltip: _shortcutTooltip(
            app,
            'Latest shot',
            MdsShortcutCommand.latestShot,
          ),
          onPressed: () => app.fetchLatestShot(),
        ),
      ],
    );
    final modeActions = _equalActionRow(
      key: const ValueKey('toolbar-mode-actions'),
      children: [
        _toolbarIconButton(
          context,
          icon: Icons.pan_tool_alt_rounded,
          tooltip: _shortcutTooltip(
            app,
            'Zoom and move mode',
            MdsShortcutCommand.zoomMode,
          ),
          active: app.interactionMode == 0,
          onPressed: () => app.interactionMode = 0,
        ),
        _toolbarIconButton(
          context,
          icon: Icons.gps_fixed_rounded,
          tooltip: _shortcutTooltip(
            app,
            'Point mode',
            MdsShortcutCommand.pointMode,
          ),
          active: app.interactionMode == 1,
          onPressed: () => app.interactionMode = 1,
        ),
      ],
    );
    final themeActions = KeyedSubtree(
      key: const ValueKey('toolbar-theme-actions'),
      child: _themeBtns(context, app),
    );

    return Container(
      key: const ValueKey('toolbar-root'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final compact = width < 560;
          final wide = width >= 940;
          final rateSelectorWidth =
              (190 + (uiSize - 12).clamp(0, 16) * 2).clamp(190, 222).toDouble();
          final shotInfo = _shotInfoPanel(
            context,
            compact: compact,
            entries: shotMetadata,
            labelStyle: infoLabelStyle,
            valueStyle: infoValueStyle,
          );

          Widget topActions;
          if (compact) {
            topActions = Column(
              children: [
                Row(
                  children: [
                    SizedBox(width: 108, child: themeActions),
                    const SizedBox(width: 8),
                    Expanded(child: appActions),
                  ],
                ),
                const SizedBox(height: 8),
                if (width < rateSelectorWidth + 152) ...[
                  SizedBox(width: double.infinity, child: fileActions),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: rateSelector),
                ] else
                  Row(
                    children: [
                      Expanded(child: fileActions),
                      const SizedBox(width: 8),
                      SizedBox(width: rateSelectorWidth, child: rateSelector),
                    ],
                  ),
              ],
            );
          } else if (wide) {
            topActions = Row(
              children: [
                SizedBox(width: 280, child: fileActions),
                const SizedBox(width: 8),
                SizedBox(width: rateSelectorWidth, child: rateSelector),
                const Spacer(),
                SizedBox(width: 108, child: themeActions),
                const SizedBox(width: 8),
                SizedBox(width: 190, child: appActions),
              ],
            );
          } else {
            final fileWidth = (width * 0.56).clamp(250.0, 320.0);
            final appWidth = (width * 0.46).clamp(230.0, 300.0);
            topActions = Column(
              children: [
                Row(
                  children: [
                    SizedBox(width: 108, child: themeActions),
                    const Spacer(),
                    SizedBox(width: appWidth, child: appActions),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(width: fileWidth, child: fileActions),
                    const Spacer(),
                    SizedBox(width: rateSelectorWidth, child: rateSelector),
                  ],
                ),
              ],
            );
          }

          Widget shotControls;
          if (compact) {
            shotControls = Column(
              children: [
                SizedBox(width: double.infinity, child: shotEntry),
                const SizedBox(height: 8),
                if (width >= 340)
                  Row(
                    children: [
                      Expanded(flex: 3, child: shotNavigation),
                      const SizedBox(width: 8),
                      Expanded(flex: 2, child: modeActions),
                    ],
                  )
                else ...[
                  SizedBox(width: double.infinity, child: shotNavigation),
                  const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: modeActions),
                ],
              ],
            );
          } else if (wide) {
            shotControls = Row(
              children: [
                SizedBox(width: 300, child: shotEntry),
                const SizedBox(width: 8),
                SizedBox(width: 260, child: shotNavigation),
                const SizedBox(width: 8),
                SizedBox(width: 220, child: modeActions),
                const Spacer(),
              ],
            );
          } else {
            shotControls = Row(
              children: [
                Expanded(flex: 4, child: shotEntry),
                const SizedBox(width: 8),
                Expanded(flex: 3, child: shotNavigation),
                const SizedBox(width: 8),
                Expanded(flex: 3, child: modeActions),
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              topActions,
              Divider(height: 17, color: theme.dividerColor),
              shotControls,
              const SizedBox(height: 8),
              shotInfo,
            ],
          );
        },
      ),
    );
  }

  Widget _equalActionRow({
    Key? key,
    required List<Widget> children,
    double spacing = 6,
  }) {
    return Row(
      key: key,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          Expanded(child: children[i]),
        ],
      ],
    );
  }

  Widget _shotInfoPanel(
    BuildContext context, {
    required bool compact,
    required List<(String, String)> entries,
    required TextStyle labelStyle,
    required TextStyle valueStyle,
  }) {
    final theme = Theme.of(context);
    final divider = theme.dividerColor.withValues(alpha: 0.65);

    Widget infoCell(int index) =>
        _infoCell(entries[index].$1, entries[index].$2, labelStyle, valueStyle);

    Widget compactRow(List<int> indices, {int lastFlex = 1}) {
      return IntrinsicHeight(
        child: Row(
          children: [
            for (var i = 0; i < indices.length; i++) ...[
              if (i > 0)
                VerticalDivider(width: 1, thickness: 1, color: divider),
              Expanded(
                flex: i == indices.length - 1 ? lastFlex : 1,
                child: infoCell(indices[i]),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      key: const ValueKey('toolbar-shot-info'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.36),
        border: Border.all(color: divider),
        borderRadius: BorderRadius.circular(6),
      ),
      child: compact
          ? Column(
              children: [
                compactRow([0, 1, 2]),
                Divider(height: 1, thickness: 1, color: divider),
                compactRow([3, 4], lastFlex: 2),
              ],
            )
          : IntrinsicHeight(
              child: Row(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0)
                      VerticalDivider(width: 1, thickness: 1, color: divider),
                    Expanded(flex: i == 4 ? 2 : 1, child: infoCell(i)),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _infoCell(
    String label,
    String value,
    TextStyle labelStyle,
    TextStyle valueStyle,
  ) {
    final message = '$label: $value';
    return Tooltip(
      message: message,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '$label: ', style: labelStyle),
              TextSpan(text: value, style: valueStyle),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  Widget _settingsMenu(BuildContext ctx, AppState app) {
    return PopupMenuButton<String>(
      tooltip: 'Settings',
      position: PopupMenuPosition.under,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(ctx).colorScheme.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          Icons.settings,
          size: app.iconSize.toDouble(),
          color: Theme.of(ctx).colorScheme.onSurface,
        ),
      ),
      onSelected: (v) {
        switch (v) {
          case 'web':
            _showWebBookmarks(ctx, app);
            break;
          case 'layout':
            _showLayoutSetup(ctx, app);
            break;
          case 'fonts':
            _showFontDialog(ctx, app);
            break;
          case 'shortcuts':
            KeyboardShortcutsDialog.show(ctx);
            break;
          case 'keyboard-mode':
            KeyboardModeDialog.show(ctx, previewToggle: true);
            break;
          case 'restore-all':
            _confirmRestoreAllSettings(ctx, app);
            break;
          case 'about':
            AboutDialogWidget.show(ctx);
            break;
        }
      },
      itemBuilder: (_) => separatedPopupMenuItems([
        _settingsMenuItem(
          value: 'web',
          icon: Icons.language_rounded,
          label: 'Internal web pages',
          shortcut: app.shortcutText(MdsShortcutCommand.openWebMenu),
        ),
        _settingsMenuItem(
          value: 'layout',
          icon: Icons.dashboard_customize_rounded,
          label: 'Layout setup',
          shortcut: app.shortcutText(MdsShortcutCommand.globalLayout),
        ),
        _settingsMenuItem(
          value: 'fonts',
          icon: Icons.font_download_outlined,
          label: 'Customize fonts',
        ),
        _settingsMenuItem(
          value: 'shortcuts',
          icon: Icons.keyboard_alt_outlined,
          label: 'Keyboard shortcuts',
        ),
        _settingsMenuItem(
          key: const ValueKey('settings-vim-mode'),
          value: 'keyboard-mode',
          icon: Icons.terminal_rounded,
          label: 'Keyboard mode',
          trailing: app.vimMode ? 'Vim' : 'Standard',
          caption: 'Vim mode (keyboard-only)',
        ),
        _settingsMenuItem(
          value: 'restore-all',
          icon: Icons.restore_rounded,
          label: 'Restore all settings',
        ),
        _settingsMenuItem(
          value: 'about',
          icon: Icons.info_outline_rounded,
          label: 'About MDSLens',
        ),
      ]),
    );
  }

  PopupMenuItem<String> _settingsMenuItem({
    Key? key,
    required String value,
    required IconData icon,
    required String label,
    String? shortcut,
    String? trailing,
    String? caption,
  }) {
    final tooltip =
        shortcut == null || shortcut.isEmpty ? label : '$label ($shortcut)';
    return VimPopupMenuItem(
      key: key,
      value: value,
      autofocus: value == 'web',
      child: Tooltip(
        message: tooltip,
        child: Row(
          children: [
            Icon(icon, size: 21),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  if (caption != null)
                    Text(
                      caption,
                      style: const TextStyle(fontSize: 10),
                    ),
                ],
              ),
            ),
            if (trailing != null && trailing.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                trailing,
                style: const TextStyle(fontSize: 11),
              ),
            ],
            if (shortcut != null && shortcut.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                '($shortcut)',
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showWebBookmarks(BuildContext ctx, AppState app) {
    final bookmarks = app.webBookmarks;
    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => KeyboardSafeDialog(
          maxWidth: 460,
          title: const Text('Internal Web Pages'),
          content: SizedBox(
            width: 400,
            height: 300,
            child: bookmarks.isEmpty
                ? const Center(
                    child: Text(
                      'No Saved Web Addresses',
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    key: const ValueKey('internal-web-pages-list'),
                    itemCount: bookmarks.length,
                    separatorBuilder: (_, i) => Divider(
                      key: ValueKey('internal-web-page-divider-$i'),
                      height: 12,
                      thickness: 1,
                      indent: 14,
                      endIndent: 14,
                    ),
                    itemBuilder: (_, i) => Material(
                      key: ValueKey('internal-web-page-$i'),
                      color: Theme.of(ctx).colorScheme.surfaceContainerLow,
                      shape: RoundedRectangleBorder(
                        side: BorderSide(
                          color: Theme.of(ctx).colorScheme.outlineVariant,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 5,
                        ),
                        leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: Theme.of(
                            ctx,
                          ).colorScheme.primaryContainer,
                          foregroundColor: Theme.of(ctx).colorScheme.primary,
                          child: const Icon(Icons.language_rounded, size: 19),
                        ),
                        title: Text(
                          bookmarks[i].keys.first,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            bookmarks[i].values.first,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              key: ValueKey('internal-web-page-edit-$i'),
                              tooltip: 'Edit web page',
                              visualDensity: VisualDensity.compact,
                              onPressed: () =>
                                  _editBookmark(ctx, app, setState, i),
                              icon: const Icon(Icons.edit_rounded, size: 19),
                            ),
                            Icon(
                              Icons.open_in_new_rounded,
                              size: 19,
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                          ],
                        ),
                        onTap: () {
                          Navigator.pop(ctx);
                          _openUrl(bookmarks[i].values.first, app);
                        },
                      ),
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            TextButton.icon(
              onPressed: () {
                _addBookmark(ctx, app, setState);
              },
              icon: const Icon(Icons.add_link_rounded, size: 18),
              label: const Text('Add...'),
            ),
            if (bookmarks.isNotEmpty)
              TextButton.icon(
                onPressed: () {
                  _removeBookmark(ctx, app, setState);
                },
                icon: const Icon(Icons.link_off_rounded, size: 18),
                label: const Text('Remove...'),
              ),
          ],
        ),
      ),
    );
  }

  void _addBookmark(
    BuildContext ctx,
    AppState app,
    void Function(VoidCallback) setState,
  ) {
    final aliasCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    showDialog(
      context: ctx,
      builder: (ctx) => KeyboardSafeDialog(
        title: const Text('Add Web Bookmark'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: aliasCtrl,
              readOnly: vimTextFieldReadOnly(ctx),
              decoration: const InputDecoration(labelText: 'Alias'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlCtrl,
              readOnly: vimTextFieldReadOnly(ctx),
              decoration: const InputDecoration(labelText: 'URL'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final alias = aliasCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (alias.isNotEmpty && url.isNotEmpty) {
                app.addWebBookmark(alias, url);
                Navigator.pop(ctx);
                setState(() {});
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _editBookmark(
    BuildContext context,
    AppState app,
    void Function(VoidCallback) refreshParent,
    int index,
  ) {
    if (index < 0 || index >= app.webBookmarks.length) return;
    final bookmark = app.webBookmarks[index];
    final aliasCtrl = TextEditingController(text: bookmark.keys.first);
    final urlCtrl = TextEditingController(text: bookmark.values.first);
    final formKey = GlobalKey<FormState>();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => KeyboardSafeDialog(
        maxWidth: 480,
        title: const Row(
          children: [
            Icon(Icons.edit_rounded),
            SizedBox(width: 10),
            Flexible(child: Text('Edit Web Page')),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                key: const ValueKey('edit-web-page-alias'),
                controller: aliasCtrl,
                autofocus: true,
                readOnly: vimTextFieldReadOnly(dialogContext),
                decoration: const InputDecoration(
                  labelText: 'Alias',
                  prefixIcon: Icon(Icons.label_outline_rounded),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a display name'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                key: const ValueKey('edit-web-page-url'),
                controller: urlCtrl,
                readOnly: vimTextFieldReadOnly(dialogContext),
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  prefixIcon: Icon(Icons.link_rounded),
                ),
                validator: (value) => value == null || value.trim().isEmpty
                    ? 'Enter a web address'
                    : null,
                onFieldSubmitted: (_) async {
                  if (formKey.currentState?.validate() != true) return;
                  await app.updateWebBookmark(
                    index,
                    aliasCtrl.text,
                    urlCtrl.text,
                  );
                  if (dialogContext.mounted) Navigator.pop(dialogContext);
                  refreshParent(() {});
                },
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
            key: const ValueKey('edit-web-page-save'),
            onPressed: () async {
              if (formKey.currentState?.validate() != true) return;
              await app.updateWebBookmark(index, aliasCtrl.text, urlCtrl.text);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              refreshParent(() {});
            },
            icon: const Icon(Icons.save_rounded),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _removeBookmark(
    BuildContext ctx,
    AppState app,
    void Function(VoidCallback) setState,
  ) {
    final bookmarks = app.webBookmarks
        .asMap()
        .entries
        .map((entry) => (index: entry.key, value: entry.value))
        .toList();
    final selected = <int>{};
    final scrollController = ScrollController();
    final dialog = showDialog<void>(
      context: ctx,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final allSelected =
              bookmarks.isNotEmpty && selected.length == bookmarks.length;
          final colors = Theme.of(dialogContext).colorScheme;
          return KeyboardSafeDialog(
            maxWidth: 520,
            maxHeight: 680,
            title: const Row(
              children: [
                Icon(Icons.link_off_rounded),
                SizedBox(width: 10),
                Flexible(child: Text('Remove Bookmark')),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckboxListTile(
                  key: const ValueKey('bookmark-select-all'),
                  value: allSelected,
                  controlAffinity: ListTileControlAffinity.leading,
                  secondary: const Icon(Icons.select_all_rounded),
                  title: const Text(
                    'Select all',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    bookmarks.isEmpty
                        ? 'No bookmarks remain'
                        : '${selected.length} of ${bookmarks.length} selected',
                  ),
                  onChanged: bookmarks.isEmpty
                      ? null
                      : (checked) => setDialogState(() {
                            if (checked == true) {
                              selected.addAll(
                                bookmarks.map((bookmark) => bookmark.index),
                              );
                            } else {
                              selected.clear();
                            }
                          }),
                ),
                const Divider(height: 1),
                const SizedBox(height: 10),
                SizedBox(
                  width: 420,
                  height: 310,
                  child: bookmarks.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.bookmarks_outlined,
                                size: 42,
                                color: colors.onSurfaceVariant,
                              ),
                              const SizedBox(height: 8),
                              const Text('No bookmarks remain'),
                            ],
                          ),
                        )
                      : Material(
                          color: colors.surfaceContainerLow,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(color: colors.outlineVariant),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Scrollbar(
                            controller: scrollController,
                            thumbVisibility: bookmarks.length > 5,
                            interactive: true,
                            child: ListView.separated(
                              key: const ValueKey(
                                'bookmark-removal-selection-list',
                              ),
                              controller: scrollController,
                              itemCount: bookmarks.length,
                              separatorBuilder: (_, index) => Divider(
                                key: ValueKey(
                                  'bookmark-removal-divider-$index',
                                ),
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                              itemBuilder: (_, listIndex) {
                                final bookmark = bookmarks[listIndex];
                                final alias = bookmark.value.keys.first;
                                final url = bookmark.value.values.first;
                                return CheckboxListTile(
                                  key: ValueKey(
                                    'bookmark-remove-${bookmark.index}',
                                  ),
                                  value: selected.contains(bookmark.index),
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  secondary: const Icon(Icons.language_rounded),
                                  title: Text(
                                    alias,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    url,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onChanged: (checked) => setDialogState(() {
                                    checked == true
                                        ? selected.add(bookmark.index)
                                        : selected.remove(bookmark.index);
                                  }),
                                );
                              },
                            ),
                          ),
                        ),
                ),
              ],
            ),
            actions: [
              TextButton.icon(
                key: const ValueKey('bookmark-removal-close'),
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close_rounded),
                label: const Text('Close'),
              ),
              FilledButton.icon(
                key: const ValueKey('bookmark-delete-selected'),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.error,
                  foregroundColor: colors.onError,
                ),
                onPressed: selected.isEmpty
                    ? null
                    : () async {
                        final pending = Set<int>.of(selected);
                        final aliases = bookmarks
                            .where(
                              (bookmark) => pending.contains(bookmark.index),
                            )
                            .map((bookmark) => bookmark.value.keys.first)
                            .toList();
                        final preview = aliases.take(5).join(', ');
                        final suffix = aliases.length > 5 ? ', …' : '';
                        final confirmed = await _confirmBookmarkRemoval(
                          dialogContext,
                          count: pending.length,
                          preview: '$preview$suffix',
                        );
                        if (!confirmed || !dialogContext.mounted) return;
                        await app.removeWebBookmarks(pending);
                        bookmarks
                          ..clear()
                          ..addAll(
                            app.webBookmarks.asMap().entries.map(
                                  (entry) =>
                                      (index: entry.key, value: entry.value),
                                ),
                          );
                        selected.clear();
                        if (dialogContext.mounted) {
                          setDialogState(() {});
                          setState(() {});
                        }
                      },
                icon: const Icon(Icons.delete_rounded),
                label: Text(
                  selected.isEmpty
                      ? 'Select bookmarks'
                      : 'Remove (${selected.length})',
                ),
              ),
            ],
          );
        },
      ),
    );
    dialog.whenComplete(scrollController.dispose);
  }

  Future<bool> _confirmBookmarkRemoval(
    BuildContext context, {
    required int count,
    required String preview,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return KeyboardSafeDialog(
          maxWidth: 460,
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: colors.error),
              const SizedBox(width: 10),
              const Flexible(child: Text('Remove selected bookmarks?')),
            ],
          ),
          content: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.error.withValues(alpha: 0.32)),
            ),
            child: Text(
              'Remove $count selected bookmark${count == 1 ? '' : 's'} '
              '($preview)? This action cannot be undone.',
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('bookmark-removal-confirm-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: const ValueKey('bookmark-removal-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_rounded),
              label: const Text('Remove'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _openUrl(String url, AppState app) async {
    var finalUrl = url;
    var usedSsh = false;
    if (app.sshMode > 0 && app.sshHost.isNotEmpty) {
      try {
        final settings = jsonEncode({
          'host': app.sshHost,
          'port': app.sshPort,
          'user': app.sshUser,
          'password': app.sshPass,
          'identity_file': app.sshIdentity,
          'mode': 2,
        });
        final prepared = RustBridge.instance.prepareUrl(url, settings);
        if (prepared.startsWith('http') && !prepared.contains('"error"')) {
          finalUrl = prepared;
          usedSsh = true;
        }
      } catch (_) {}
    }
    app.recordSshUsage(usedSsh);
    final opened = await openExternalWebUrl(finalUrl);
    app.setStatus(
      opened
          ? 'Opened internal web page'
          : 'Could not open the default browser',
    );
  }

  void _showLayoutSetup(BuildContext ctx, AppState app) {
    final openingColumns = _cloneLayoutColumns(app.columns);
    final draftColumns = _cloneLayoutColumns(openingColumns);
    final horizontalController = ScrollController();
    final verticalControllers = <int, ScrollController>{};
    final selectedPanels = Set<Map<String, dynamic>>.identity();
    var panelMotionOffsets = Map<Map<String, dynamic>, Offset>.identity();
    var columnMotionOffsets =
        Map<List<Map<String, dynamic>>, Offset>.identity();
    var appearingPanels = Set<Map<String, dynamic>>.identity();
    var appearingColumns = Set<List<Map<String, dynamic>>>.identity();
    var layoutRevision = 0;

    final dialogFuture = showDialog<void>(
      context: ctx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          void animateLayoutChange(VoidCallback change) {
            final oldPanels = _snapshotLayoutPanelPositions(draftColumns);
            final oldColumns = _snapshotLayoutColumnPositions(draftColumns);
            setState(() {
              change();
              final newPanels = _snapshotLayoutPanelPositions(draftColumns);
              final newColumns = _snapshotLayoutColumnPositions(draftColumns);
              panelMotionOffsets = _layoutPanelMotionOffsets(
                oldPanels,
                newPanels,
              );
              columnMotionOffsets = _layoutColumnMotionOffsets(
                oldColumns,
                newColumns,
              );
              appearingPanels = Set<Map<String, dynamic>>.identity()
                ..addAll(
                  newPanels.keys
                      .where((panel) => !oldPanels.containsKey(panel)),
                );
              appearingColumns = Set<List<Map<String, dynamic>>>.identity()
                ..addAll(
                  newColumns.keys.where(
                    (column) => !oldColumns.containsKey(column),
                  ),
                );
              layoutRevision++;
            });
          }

          void clearSelection() => setState(selectedPanels.clear);

          final screenSize = MediaQuery.sizeOf(ctx);
          final displayColumns = buildResponsivePlotColumns(
            draftColumns.map((column) => column.length).toList(),
            screenSize.width,
          );
          final contentWidth = (screenSize.width - 64).clamp(240.0, 700.0);
          final contentHeight = (screenSize.height * 0.58).clamp(260.0, 540.0);
          final layoutWidth = math.max(
            contentWidth,
            displayColumns.length * 156.0 + (displayColumns.length + 1) * 8.0,
          );
          final needsHorizontalScroll = layoutWidth > contentWidth + 0.5;

          return GestureDetector(
            key: const ValueKey('layout-setup-surface'),
            behavior: HitTestBehavior.translucent,
            onTap: clearSelection,
            child: KeyboardSafeDialog(
              maxWidth: 760,
              maxHeight: 860,
              title: const Text('Layout Setup'),
              content: SizedBox(
                width: contentWidth,
                height: contentHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      key: const ValueKey('layout-setup-blank-area'),
                      behavior: HitTestBehavior.opaque,
                      onTap: clearSelection,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'Overview · ${displayColumns.length} columns · '
                          '${selectedPanels.length} panels selected',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Scrollbar(
                        key: const ValueKey('layout-horizontal-scrollbar'),
                        controller: horizontalController,
                        thumbVisibility: needsHorizontalScroll,
                        interactive: true,
                        child: SingleChildScrollView(
                          key: const ValueKey('layout-horizontal-scroll'),
                          controller: horizontalController,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width: layoutWidth,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var displayColumn = 0;
                                    displayColumn < displayColumns.length;
                                    displayColumn++) ...[
                                  _layoutColumnDropTarget(
                                    context: ctx,
                                    columns: draftColumns,
                                    insertionIndex: displayColumn,
                                    onLayoutChange: animateLayoutChange,
                                  ),
                                  Expanded(
                                    child: _LayoutSettlingTransform(
                                      animationId: identityHashCode(
                                        draftColumns[displayColumn],
                                      ),
                                      revision: layoutRevision,
                                      offset: columnMotionOffsets[
                                              draftColumns[displayColumn]] ??
                                          Offset.zero,
                                      appearing: appearingColumns.contains(
                                        draftColumns[displayColumn],
                                      ),
                                      child:
                                          LongPressDraggable<_LayoutDragData>(
                                        key: ValueKey(
                                          'layout-column-drag-${displayColumn + 1}',
                                        ),
                                        data: _LayoutDragData.column(
                                          displayColumn,
                                        ),
                                        delay: const Duration(
                                          milliseconds: 320,
                                        ),
                                        hapticFeedbackOnStart: true,
                                        feedback: _layoutDragFeedback(
                                          ctx,
                                          icon: Icons.view_column_rounded,
                                          label: 'Column ${displayColumn + 1}',
                                          subtitle:
                                              '${draftColumns[displayColumn].length} panels',
                                        ),
                                        childWhenDragging: Opacity(
                                          opacity: 0.22,
                                          child: Container(
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                color: Theme.of(
                                                  ctx,
                                                ).dividerColor,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                        ),
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.translucent,
                                          onTap: () => setState(() {
                                            toggleLayoutColumnSelection(
                                              draftColumns[displayColumn],
                                              selectedPanels,
                                            );
                                          }),
                                          child: Container(
                                            key: ValueKey(
                                              'layout-preview-column-$displayColumn',
                                            ),
                                            decoration: BoxDecoration(
                                              border: Border.all(
                                                color: layoutColumnIsSelected(
                                                  draftColumns[displayColumn],
                                                  selectedPanels,
                                                )
                                                    ? Theme.of(
                                                        ctx,
                                                      ).colorScheme.primary
                                                    : Theme.of(
                                                        ctx,
                                                      ).dividerColor,
                                                width: layoutColumnIsSelected(
                                                  draftColumns[displayColumn],
                                                  selectedPanels,
                                                )
                                                    ? 2
                                                    : 1,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Column(
                                              children: [
                                                GestureDetector(
                                                  key: ValueKey(
                                                    'layout-column-header-${displayColumn + 1}',
                                                  ),
                                                  behavior:
                                                      HitTestBehavior.opaque,
                                                  onTap: () => setState(() {
                                                    toggleLayoutColumnSelection(
                                                      draftColumns[
                                                          displayColumn],
                                                      selectedPanels,
                                                    );
                                                  }),
                                                  child: SizedBox(
                                                    height: 32,
                                                    child: Row(
                                                      children: [
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .only(
                                                            left: 3,
                                                          ),
                                                          child:
                                                              _layoutDragHandle(
                                                            context: ctx,
                                                            key: ValueKey(
                                                              'layout-column-drag-handle-${displayColumn + 1}',
                                                            ),
                                                            data:
                                                                _LayoutDragData
                                                                    .column(
                                                              displayColumn,
                                                            ),
                                                            tooltip:
                                                                'Drag column ${displayColumn + 1}',
                                                            feedback:
                                                                _layoutDragFeedback(
                                                              ctx,
                                                              icon: Icons
                                                                  .view_column_rounded,
                                                              label:
                                                                  'Column ${displayColumn + 1}',
                                                              subtitle:
                                                                  '${draftColumns[displayColumn].length} panels',
                                                            ),
                                                          ),
                                                        ),
                                                        Expanded(
                                                          child: Center(
                                                            child: FittedBox(
                                                              fit: BoxFit
                                                                  .scaleDown,
                                                              child: Text(
                                                                'Column ${displayColumn + 1}',
                                                                style:
                                                                    const TextStyle(
                                                                  fontSize: 10,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .only(
                                                            right: 5,
                                                          ),
                                                          child:
                                                              AnimatedSwitcher(
                                                            duration:
                                                                const Duration(
                                                              milliseconds: 140,
                                                            ),
                                                            child: layoutColumnIsSelected(
                                                              draftColumns[
                                                                  displayColumn],
                                                              selectedPanels,
                                                            )
                                                                ? Icon(
                                                                    Icons
                                                                        .check_circle_rounded,
                                                                    key:
                                                                        ValueKey(
                                                                      'layout-column-selected-${displayColumn + 1}',
                                                                    ),
                                                                    size: 17,
                                                                    color: Theme.of(
                                                                            ctx)
                                                                        .colorScheme
                                                                        .primary,
                                                                  )
                                                                : const SizedBox(
                                                                    width: 17,
                                                                  ),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                                Expanded(
                                                  child: LayoutBuilder(
                                                    builder:
                                                        (context, constraints) {
                                                      final panelCount =
                                                          displayColumns[
                                                                  displayColumn]
                                                              .length;
                                                      final requiredHeight =
                                                          panelCount * 112.0 +
                                                              (panelCount + 1) *
                                                                  7.0;
                                                      final needsVerticalScroll =
                                                          requiredHeight >
                                                              constraints
                                                                      .maxHeight +
                                                                  0.5;
                                                      final controller =
                                                          verticalControllers
                                                              .putIfAbsent(
                                                        displayColumn,
                                                        ScrollController.new,
                                                      );
                                                      return Scrollbar(
                                                        key: ValueKey(
                                                          'layout-column-scrollbar-$displayColumn',
                                                        ),
                                                        controller: controller,
                                                        thumbVisibility:
                                                            needsVerticalScroll,
                                                        interactive: true,
                                                        child:
                                                            SingleChildScrollView(
                                                          key: ValueKey(
                                                            'layout-column-scroll-$displayColumn',
                                                          ),
                                                          controller:
                                                              controller,
                                                          child: SizedBox(
                                                            height: math.max(
                                                              constraints
                                                                  .maxHeight,
                                                              requiredHeight,
                                                            ),
                                                            child: Column(
                                                              children: [
                                                                _layoutPanelDropTarget(
                                                                  context: ctx,
                                                                  columns:
                                                                      draftColumns,
                                                                  targetColumn:
                                                                      displayColumn,
                                                                  insertionRow:
                                                                      0,
                                                                  onLayoutChange:
                                                                      animateLayoutChange,
                                                                ),
                                                                for (final cell
                                                                    in displayColumns[
                                                                        displayColumn]) ...[
                                                                  _buildDraggableLayoutPanel(
                                                                    ctx,
                                                                    panel: draftColumns[
                                                                        cell
                                                                            .sourceColumn][cell
                                                                        .sourceRow],
                                                                    sourceColumn:
                                                                        cell.sourceColumn,
                                                                    sourceRow: cell
                                                                        .sourceRow,
                                                                    panelNumber:
                                                                        cell.plotIndex +
                                                                            1,
                                                                    selected:
                                                                        selectedPanels
                                                                            .contains(
                                                                      draftColumns[
                                                                          cell
                                                                              .sourceColumn][cell
                                                                          .sourceRow],
                                                                    ),
                                                                    settleOffset: panelMotionOffsets[draftColumns[
                                                                            cell
                                                                                .sourceColumn][cell
                                                                            .sourceRow]] ??
                                                                        Offset
                                                                            .zero,
                                                                    appearing:
                                                                        appearingPanels
                                                                            .contains(
                                                                      draftColumns[
                                                                          cell
                                                                              .sourceColumn][cell
                                                                          .sourceRow],
                                                                    ),
                                                                    layoutRevision:
                                                                        layoutRevision,
                                                                    onSelect: () =>
                                                                        setState(
                                                                            () {
                                                                      toggleLayoutPanelSelection(
                                                                        draftColumns[
                                                                            cell
                                                                                .sourceColumn][cell
                                                                            .sourceRow],
                                                                        selectedPanels,
                                                                      );
                                                                    }),
                                                                    onEdit:
                                                                        () async {
                                                                      final panel = draftColumns[
                                                                          cell
                                                                              .sourceColumn][cell
                                                                          .sourceRow];
                                                                      final changed =
                                                                          await _editLayoutPanel(
                                                                        ctx,
                                                                        app,
                                                                        panel,
                                                                        cell.plotIndex +
                                                                            1,
                                                                      );
                                                                      if (changed &&
                                                                          ctx.mounted) {
                                                                        setState(
                                                                          () {},
                                                                        );
                                                                      }
                                                                    },
                                                                  ),
                                                                  _layoutPanelDropTarget(
                                                                    context:
                                                                        ctx,
                                                                    columns:
                                                                        draftColumns,
                                                                    targetColumn:
                                                                        displayColumn,
                                                                    insertionRow:
                                                                        cell.sourceRow +
                                                                            1,
                                                                    onLayoutChange:
                                                                        animateLayoutChange,
                                                                  ),
                                                                ],
                                                              ],
                                                            ),
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                _layoutColumnDropTarget(
                                  context: ctx,
                                  columns: draftColumns,
                                  insertionIndex: displayColumns.length,
                                  onLayoutChange: animateLayoutChange,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            final targetColumn = draftColumns.indexWhere(
                              (column) => column.any(selectedPanels.contains),
                            );
                            animateLayoutChange(() {
                              if (draftColumns.isEmpty) {
                                draftColumns.add([_emptyPanelConfig()]);
                              } else {
                                draftColumns[targetColumn < 0
                                        ? draftColumns.length - 1
                                        : targetColumn]
                                    .add(_emptyPanelConfig());
                              }
                            });
                          },
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('Add panel'),
                        ),
                        TextButton.icon(
                          onPressed: () => animateLayoutChange(() {
                            draftColumns.add([_emptyPanelConfig()]);
                          }),
                          icon: const Icon(
                            Icons.view_column_outlined,
                            size: 16,
                          ),
                          label: const Text('Add column'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                OutlinedButton.icon(
                  key: const ValueKey('layout-reset'),
                  onPressed: () => animateLayoutChange(() {
                    draftColumns
                      ..clear()
                      ..addAll(_cloneLayoutColumns(openingColumns));
                    selectedPanels.clear();
                  }),
                  icon: const Icon(Icons.restart_alt_rounded),
                  label: const Text('Reset'),
                ),
                FilledButton.tonalIcon(
                  key: const ValueKey('layout-delete-selected'),
                  onPressed: selectedPanels.isEmpty
                      ? null
                      : () => animateLayoutChange(() {
                            deleteSelectedLayoutPanels(
                              draftColumns,
                              selectedPanels,
                            );
                          }),
                  style: FilledButton.styleFrom(
                    foregroundColor: Theme.of(ctx).colorScheme.error,
                  ),
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: Text(
                    selectedPanels.isEmpty
                        ? 'Delete'
                        : 'Delete ${selectedPanels.length}',
                  ),
                ),
                TextButton(
                  key: const ValueKey('layout-cancel'),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  key: const ValueKey('layout-apply'),
                  onPressed: () {
                    app.applyLayoutColumns(draftColumns);
                    if (app.plots.isNotEmpty) {
                      app.startRefresh();
                    }
                    Navigator.pop(ctx);
                  },
                  child: const Text('Apply'),
                ),
              ],
            ),
          );
        },
      ),
    );
    dialogFuture.whenComplete(() {
      horizontalController.dispose();
      for (final controller in verticalControllers.values) {
        controller.dispose();
      }
    });
  }

  List<List<Map<String, dynamic>>> _cloneLayoutColumns(
    List<List<Map<String, dynamic>>> columns,
  ) {
    return columns
        .map(
          (column) => column
              .map(
                (panel) =>
                    Map<String, dynamic>.from(_cloneLayoutValue(panel) as Map),
              )
              .toList(),
        )
        .toList();
  }

  dynamic _cloneLayoutValue(dynamic value) {
    if (value is List) return value.map(_cloneLayoutValue).toList();
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _cloneLayoutValue(item)),
      );
    }
    return value;
  }

  Map<String, dynamic> _emptyPanelConfig() => {
        'title': '',
        'x_label': 's',
        'y_label': 'a.u.',
        'extraction_points': 2000,
        'grid': true,
        'signal_specs': <Map<String, dynamic>>[],
      };

  Widget _layoutIconButton({
    required BuildContext context,
    required Key key,
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool destructive = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    final foreground = destructive ? colors.error : colors.primary;
    final background = destructive
        ? colors.errorContainer.withValues(alpha: 0.72)
        : colors.primaryContainer.withValues(alpha: 0.8);
    return IconButton(
      key: key,
      onPressed: onPressed,
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 26, height: 26),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor: background,
        disabledForegroundColor: colors.onSurfaceVariant.withValues(
          alpha: 0.35,
        ),
        disabledBackgroundColor: colors.surfaceContainerHighest.withValues(
          alpha: 0.5,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 15),
    );
  }

  Widget _layoutColumnDropTarget({
    required BuildContext context,
    required List<List<Map<String, dynamic>>> columns,
    required int insertionIndex,
    required ValueChanged<VoidCallback> onLayoutChange,
  }) {
    return DragTarget<_LayoutDragData>(
      key: ValueKey('layout-column-drop-$insertionIndex'),
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) {
        onLayoutChange(() {
          if (details.data.isColumn) {
            reorderLayoutColumn(
              columns,
              details.data.column,
              insertionIndex,
            );
          } else {
            moveLayoutPanelToNewColumn(
              columns,
              sourceColumn: details.data.column,
              sourceRow: details.data.row!,
              insertionIndex: insertionIndex,
            );
          }
        });
      },
      builder: (context, candidates, rejected) {
        final isPanel = candidates.any(
          (data) => data != null && !data.isColumn,
        );
        final active = candidates.isNotEmpty;
        return Tooltip(
          message: 'Drop a panel here to create a new column',
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: active ? 32 : 14,
            margin: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: active
                  ? Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.9)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: active
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary,
                      width: 1.5,
                    )
                  : null,
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.35),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: active
                ? Icon(
                    isPanel ? Icons.add_box_rounded : Icons.swap_horiz_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
          ),
        );
      },
    );
  }

  Widget _layoutDragHandle({
    required BuildContext context,
    required Key key,
    required _LayoutDragData data,
    required String tooltip,
    required Widget feedback,
  }) {
    final colors = Theme.of(context).colorScheme;
    final handle = Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: colors.surfaceContainerHighest.withValues(alpha: 0.84),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Icon(
            Icons.drag_indicator_rounded,
            size: 17,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
    return Draggable<_LayoutDragData>(
      key: key,
      data: data,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: feedback,
      childWhenDragging: Opacity(opacity: 0.35, child: handle),
      child: handle,
    );
  }

  Widget _layoutPanelDropTarget({
    required BuildContext context,
    required List<List<Map<String, dynamic>>> columns,
    required int targetColumn,
    required int insertionRow,
    required ValueChanged<VoidCallback> onLayoutChange,
  }) {
    return DragTarget<_LayoutDragData>(
      key: ValueKey('layout-panel-drop-$targetColumn-$insertionRow'),
      onWillAcceptWithDetails: (details) => !details.data.isColumn,
      onAcceptWithDetails: (details) {
        onLayoutChange(() {
          reorderLayoutPanel(
            columns,
            sourceColumn: details.data.column,
            sourceRow: details.data.row!,
            targetColumn: targetColumn,
            insertionRow: insertionRow,
          );
        });
      },
      builder: (context, candidates, rejected) => AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        height: candidates.isEmpty ? 7 : 12,
        margin: const EdgeInsets.symmetric(horizontal: 5),
        decoration: BoxDecoration(
          color: candidates.isEmpty
              ? Colors.transparent
              : Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(8),
          boxShadow: candidates.isEmpty
              ? null
              : [
                  BoxShadow(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.35),
                    blurRadius: 8,
                  ),
                ],
        ),
      ),
    );
  }

  Widget _layoutDragFeedback(
    BuildContext context, {
    required IconData icon,
    required String label,
    String subtitle = '',
    double width = 150,
  }) {
    final colors = Theme.of(context).colorScheme;
    return Transform.scale(
      scale: 1.03,
      alignment: Alignment.topCenter,
      child: Material(
        elevation: 14,
        shadowColor: colors.shadow.withValues(alpha: 0.4),
        color: colors.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: width,
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: colors.primary.withValues(alpha: 0.55)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: colors.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDraggableLayoutPanel(
    BuildContext context, {
    required Map<String, dynamic> panel,
    required int sourceColumn,
    required int sourceRow,
    required int panelNumber,
    required bool selected,
    required Offset settleOffset,
    required bool appearing,
    required int layoutRevision,
    required VoidCallback onSelect,
    required VoidCallback onEdit,
  }) {
    final colors = Theme.of(context).colorScheme;
    final title = panel['title']?.toString().trim() ?? '';
    final dragData = _LayoutDragData.panel(sourceColumn, sourceRow);
    final dragFeedback = _layoutDragFeedback(
      context,
      icon: Icons.space_dashboard_rounded,
      label: 'Panel $panelNumber',
      subtitle: title,
      width: 170,
    );
    return Expanded(
      child: _LayoutSettlingTransform(
        animationId: identityHashCode(panel),
        revision: layoutRevision,
        offset: settleOffset,
        appearing: appearing,
        child: LongPressDraggable<_LayoutDragData>(
          key: ValueKey('layout-panel-drag-$panelNumber'),
          data: dragData,
          delay: const Duration(milliseconds: 320),
          hapticFeedbackOnStart: true,
          feedback: dragFeedback,
          childWhenDragging: Opacity(
            opacity: 0.22,
            child: Container(
              margin: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),
          child: GestureDetector(
            onTap: onSelect,
            child: Container(
              key: ValueKey('layout-preview-panel-${panelNumber - 1}'),
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                border: Border.all(
                  color: selected ? colors.primary : Colors.grey.shade400,
                  width: selected ? 2 : 1,
                ),
                borderRadius: BorderRadius.circular(6),
                color: colors.primaryContainer.withValues(alpha: 0.3),
              ),
              child: _buildLayoutPanelPreview(
                context,
                panel: panel,
                panelNumber: panelNumber,
                selected: selected,
                onEdit: onEdit,
                dragHandle: _layoutDragHandle(
                  context: context,
                  key: ValueKey('layout-panel-drag-handle-$panelNumber'),
                  data: dragData,
                  tooltip: 'Drag panel $panelNumber',
                  feedback: dragFeedback,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLayoutPanelPreview(
    BuildContext context, {
    required Map<String, dynamic> panel,
    required int panelNumber,
    required bool selected,
    required VoidCallback onEdit,
    required Widget dragHandle,
  }) {
    final textColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final details = <Widget>[
      Text(
        'Panel $panelNumber',
        key: ValueKey('layout-panel-number-$panelNumber'),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: textColor,
        ),
      ),
    ];
    final title = panel['title']?.toString().trim() ?? '';
    if (title.isNotEmpty) {
      details.add(
        Text(
          'Title: $title',
          key: ValueKey('layout-panel-title-$panelNumber'),
          style: TextStyle(fontSize: 9, color: textColor),
        ),
      );
    }
    final signals = panel['signal_specs'] as List? ?? const [];
    for (var signalIndex = 0; signalIndex < signals.length; signalIndex++) {
      final rawSignal = signals[signalIndex];
      if (rawSignal is! Map) continue;
      final tree = rawSignal['experiment']?.toString().trim() ?? '';
      final signal = rawSignal['y_expr']?.toString().trim() ?? '';
      if (tree.isNotEmpty) {
        details.add(
          Text(
            'Curve ${signalIndex + 1} Tree: $tree',
            key: ValueKey(
              'layout-panel-$panelNumber-curve-${signalIndex + 1}-tree',
            ),
            style: TextStyle(fontSize: 8, color: textColor),
          ),
        );
      }
      if (signal.isNotEmpty) {
        details.add(
          Text(
            'Curve ${signalIndex + 1} Signal: $signal',
            key: ValueKey(
              'layout-panel-$panelNumber-curve-${signalIndex + 1}-signal',
            ),
            style: TextStyle(fontSize: 8, color: textColor),
          ),
        );
      }
    }

    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(4, 4, 31, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: details,
            ),
          ),
        ),
        Positioned(right: 2, top: 2, child: dragHandle),
        Positioned(
          right: 2,
          bottom: 2,
          child: _layoutIconButton(
            context: context,
            key: ValueKey('layout-edit-panel-$panelNumber'),
            icon: Icons.edit_rounded,
            tooltip: 'Edit panel $panelNumber',
            onPressed: onEdit,
          ),
        ),
        if (selected)
          Positioned(
            left: 4,
            bottom: 6,
            child: Icon(
              Icons.check_circle_rounded,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
      ],
    );
  }

  Future<bool> _editLayoutPanel(
    BuildContext context,
    AppState app,
    Map<String, dynamic> panel,
    int panelNumber,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: ValueKey('layout-panel-setup-$panelNumber'),
              leading: const Icon(Icons.tune),
              title: const Text('Panel Setup'),
              onTap: () => Navigator.pop(context, 'panel'),
            ),
            ListTile(
              key: ValueKey('layout-data-source-setup-$panelNumber'),
              leading: const Icon(Icons.show_chart),
              title: const Text('Data Source Setup'),
              onTap: () => Navigator.pop(context, 'dataSource'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return false;
    if (action == 'panel') {
      return showPanelSetupEditor(context, panel);
    }

    final signals = List<Map<String, dynamic>>.from(
      (panel['signal_specs'] as List?)?.whereType<Map>().map(
                (signal) => Map<String, dynamic>.from(signal),
              ) ??
          const [],
    );
    if (signals.isEmpty) {
      signals.add({'experiment': 'pcs_east', 'server_ip': '202.127.204.12'});
    }
    final saved = await showDataSourceSetupEditor(
      context,
      signals: signals,
      defaultShot: resolveDataSourceShot(
        panelShot: panel['shot'],
        displayedShot: app.displayedShot,
        inputShot: app.shotText,
      ),
    );
    if (saved) panel['signal_specs'] = signals;
    return saved;
  }

  void _showFontDialog(BuildContext ctx, AppState app) {
    var fontFamily = app.fontFamily;
    var legendSize = app.fontLegendSize;
    var axisSize = app.fontAxisSize;
    var unitSize = app.fontUnitSize;
    var uiSize = app.fontUiSize;
    var iconSize = app.iconSize;
    var families = <String>['System', ...SystemFontService.fallbackFamilies];
    var fontLoadScheduled = false;
    showDialog<void>(
      context: ctx,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          if (!fontLoadScheduled) {
            fontLoadScheduled = true;
            SystemFontService.loadFamilies().then((discovered) {
              if (!ctx.mounted) return;
              setState(() {
                families = ['System', ...discovered];
                if (!families.contains(fontFamily)) fontFamily = 'System';
              });
            });
          }
          return KeyboardSafeDialog(
            title: const Text('Customize Fonts'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const SizedBox(width: 100, child: Text('Font')),
                    Expanded(
                      child: PolishedDropdown<String>(
                        key: const ValueKey('font-family-dropdown'),
                        id: 'font-family',
                        value: families.contains(fontFamily)
                            ? fontFamily
                            : 'System',
                        leadingIcon: Icons.font_download_outlined,
                        fontSize: 12,
                        minimumMenuWidth: 220,
                        menuMaxHeight: 360,
                        options: [
                          for (final family in families)
                            PolishedDropdownOption(
                              value: family,
                              label: family,
                              fontFamily: family == 'System' ? null : family,
                              icon: family == 'System'
                                  ? Icons.devices_rounded
                                  : Icons.text_fields_rounded,
                            ),
                        ],
                        onChanged: (value) =>
                            setState(() => fontFamily = value),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _fontRow(
                  'Legend size',
                  legendSize,
                  (v) => setState(() => legendSize = v),
                ),
                _fontRow(
                  'Axis size',
                  axisSize,
                  (v) => setState(() => axisSize = v),
                ),
                _fontRow(
                  'Unit size',
                  unitSize,
                  (v) => setState(() => unitSize = v),
                ),
                _fontRow('UI size', uiSize, (v) => setState(() => uiSize = v)),
                _fontRow(
                  'Icon size',
                  iconSize,
                  (v) => setState(() => iconSize = v),
                  minimum: 18,
                  maximum: 32,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    await SystemFontService.prepareFamily(fontFamily);
                    app.applyFontSettings(
                      fontFamily,
                      legendSize,
                      axisSize,
                      unitSize,
                      uiSize,
                      iconSize: iconSize,
                    );
                    if (ctx.mounted) Navigator.pop(ctx);
                  } catch (error) {
                    if (!ctx.mounted) return;
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(
                        content: Text(
                          'The browser could not load this local font: $error',
                        ),
                      ),
                    );
                  }
                },
                child: const Text('OK'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _fontRow(
    String label,
    int value,
    void Function(int) onChanged, {
    int minimum = 6,
    int maximum = 28,
  }) {
    return Row(
      children: [
        SizedBox(width: 100, child: Text(label)),
        IconButton(
          icon: const Icon(Icons.remove, size: 16),
          onPressed: value > minimum ? () => onChanged(value - 1) : null,
        ),
        SizedBox(width: 30, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          icon: const Icon(Icons.add, size: 16),
          onPressed: value < maximum ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }

  Future<void> _showShotHistoryManager(
    BuildContext context,
    AppState app,
  ) async {
    if (!context.mounted || app.shotHistory.isEmpty) return;
    final history = List<String>.of(app.shotHistory);
    final selected = <String>{};
    final scrollController = ScrollController();
    final limitController = TextEditingController(
      text: app.shotHistoryLimit.toString(),
    );
    String? limitError;

    void syncHistory() {
      history
        ..clear()
        ..addAll(app.shotHistory);
      selected.removeWhere((shot) => !history.contains(shot));
    }

    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setState) {
            final allSelected =
                history.isNotEmpty && selected.length == history.length;
            final colors = Theme.of(dialogContext).colorScheme;
            return KeyboardSafeDialog(
              maxWidth: 480,
              maxHeight: 660,
              title: const Row(
                children: [
                  Icon(Icons.manage_history_rounded),
                  SizedBox(width: 10),
                  Flexible(child: Text('Manage Shot History')),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Material(
                    color: colors.surfaceContainerLow,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: BorderSide(color: colors.outlineVariant),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                      child: Column(
                        children: [
                          SwitchListTile(
                            key: const ValueKey(
                              'shot-history-retention-enabled',
                            ),
                            value: app.limitShotHistory,
                            controlAffinity: ListTileControlAffinity.leading,
                            secondary: const Icon(Icons.auto_delete_outlined),
                            title: Text(
                              app.limitShotHistory
                                  ? 'Keep only the most recent '
                                      '${app.shotHistoryLimit} shots'
                                  : 'Keep all shot history',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              app.limitShotHistory
                                  ? 'Older entries are removed automatically.'
                                  : 'Entries remain until you delete them.',
                            ),
                            onChanged: (enabled) {
                              app.setShotHistoryRetentionEnabled(enabled);
                              syncHistory();
                              setState(() {});
                            },
                          ),
                          Row(
                            children: [
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  key: const ValueKey(
                                    'shot-history-retention-limit',
                                  ),
                                  controller: limitController,
                                  readOnly: vimTextFieldReadOnly(context),
                                  enabled: app.limitShotHistory,
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText: 'Maximum saved shots',
                                    helperText:
                                        'From 1 to ${AppState.maximumShotHistoryLimit}',
                                    errorText: limitError,
                                    isDense: true,
                                  ),
                                  onChanged: (raw) {
                                    final value = int.tryParse(raw.trim());
                                    if (value == null ||
                                        value < 1 ||
                                        value >
                                            AppState.maximumShotHistoryLimit) {
                                      setState(() {
                                        limitError = 'Enter a valid number';
                                      });
                                      return;
                                    }
                                    app.setShotHistoryLimit(value);
                                    syncHistory();
                                    setState(() => limitError = null);
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filledTonal(
                                key: const ValueKey(
                                  'shot-history-retention-restore-default',
                                ),
                                tooltip: 'Restore the default limit '
                                    '(${AppState.defaultShotHistoryLimit})',
                                onPressed: () {
                                  app.restoreDefaultShotHistoryLimit();
                                  limitController.text = AppState
                                      .defaultShotHistoryLimit
                                      .toString();
                                  limitController.selection =
                                      TextSelection.collapsed(
                                    offset: limitController.text.length,
                                  );
                                  syncHistory();
                                  setState(() => limitError = null);
                                },
                                icon: const Icon(Icons.restore_rounded),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    key: const ValueKey('shot-history-select-all'),
                    value: allSelected,
                    controlAffinity: ListTileControlAffinity.leading,
                    secondary: const Icon(Icons.select_all_rounded),
                    title: const Text(
                      'Select all',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      history.isEmpty
                          ? 'No saved shot numbers remain'
                          : '${selected.length} of ${history.length} selected',
                    ),
                    onChanged: history.isEmpty
                        ? null
                        : (checked) => setState(() {
                              if (checked == true) {
                                selected.addAll(history);
                              } else {
                                selected.clear();
                              }
                            }),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 180,
                    child: history.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.history_toggle_off_rounded,
                                  size: 42,
                                  color: colors.onSurfaceVariant,
                                ),
                                const SizedBox(height: 8),
                                const Text('Shot history is empty'),
                              ],
                            ),
                          )
                        : Material(
                            color: colors.surfaceContainerLow,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(color: colors.outlineVariant),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Scrollbar(
                              controller: scrollController,
                              thumbVisibility: history.length > 6,
                              interactive: true,
                              child: ListView.separated(
                                key: const ValueKey(
                                  'shot-history-selection-list',
                                ),
                                controller: scrollController,
                                itemCount: history.length,
                                separatorBuilder: (_, index) => Divider(
                                  key: ValueKey(
                                    'shot-history-selection-divider-$index',
                                  ),
                                  height: 1,
                                  indent: 16,
                                  endIndent: 16,
                                ),
                                itemBuilder: (_, index) {
                                  final shot = history[index];
                                  return CheckboxListTile(
                                    key: ValueKey('shot-history-select-$shot'),
                                    value: selected.contains(shot),
                                    controlAffinity:
                                        ListTileControlAffinity.leading,
                                    secondary: const Icon(
                                      Icons.show_chart_rounded,
                                    ),
                                    title: Text(
                                      shot,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    onChanged: (checked) => setState(() {
                                      checked == true
                                          ? selected.add(shot)
                                          : selected.remove(shot);
                                    }),
                                  );
                                },
                              ),
                            ),
                          ),
                  ),
                ],
              ),
              actions: [
                TextButton.icon(
                  key: const ValueKey('shot-history-manager-close'),
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                  label: const Text('Close'),
                ),
                FilledButton.icon(
                  key: const ValueKey('shot-history-delete-selected'),
                  style: FilledButton.styleFrom(
                    backgroundColor: colors.error,
                    foregroundColor: colors.onError,
                  ),
                  onPressed: selected.isEmpty
                      ? null
                      : () async {
                          final pending = Set<String>.of(selected);
                          final preview = pending.take(6).join(', ');
                          final suffix = pending.length > 6 ? ', …' : '';
                          final confirmed = await _confirmShotHistoryClear(
                            dialogContext,
                            title: 'Delete selected shot history?',
                            message:
                                'Remove ${pending.length} selected shot number'
                                '${pending.length == 1 ? '' : 's'} '
                                '($preview$suffix)? This action cannot be undone.',
                            confirmLabel: 'Delete',
                            confirmKey: const ValueKey(
                              'shot-history-confirm-selected',
                            ),
                          );
                          if (!confirmed || !dialogContext.mounted) return;
                          await app.removeShotHistory(pending);
                          history.removeWhere(pending.contains);
                          selected.clear();
                          if (dialogContext.mounted) setState(() {});
                        },
                  icon: const Icon(Icons.delete_rounded),
                  label: Text(
                    selected.isEmpty
                        ? 'Select shots'
                        : 'Delete (${selected.length})',
                  ),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      // showDialog completes when the route is popped, before its reverse
      // transition has completely detached the text field.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      scrollController.dispose();
      limitController.dispose();
    }
  }

  Future<bool> _confirmShotHistoryClear(
    BuildContext context, {
    required String title,
    required String message,
    required String confirmLabel,
    required Key confirmKey,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return KeyboardSafeDialog(
          maxWidth: 460,
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: colors.error),
              const SizedBox(width: 10),
              Flexible(child: Text(title)),
            ],
          ),
          content: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.error.withValues(alpha: 0.32)),
            ),
            child: Text(message),
          ),
          actions: [
            TextButton(
              key: const ValueKey('shot-history-confirm-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: confirmKey,
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.delete_rounded),
              label: Text(confirmLabel),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _confirmRestoreDefaultConfiguration(
    BuildContext context,
    AppState app,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return KeyboardSafeDialog(
          maxWidth: 480,
          title: Row(
            children: [
              Icon(Icons.settings_backup_restore_rounded, color: colors.error),
              const SizedBox(width: 10),
              const Flexible(child: Text('Restore default configuration?')),
            ],
          ),
          content: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.errorContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colors.error.withValues(alpha: 0.32)),
            ),
            child: const Text(
              'This will discard the current waveform layout and panel '
              'settings, then restore the built-in default configuration. '
              'This action cannot be undone.',
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('restore-default-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: const ValueKey('restore-default-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.settings_backup_restore_rounded),
              label: const Text('Restore defaults'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await app.restoreDefaultConfig();
    }
  }

  Future<void> _confirmRestoreAllSettings(
    BuildContext context,
    AppState app,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        return KeyboardSafeDialog(
          maxWidth: 520,
          title: Row(
            children: [
              Icon(Icons.restore_rounded, color: colors.error),
              const SizedBox(width: 10),
              const Flexible(child: Text('Restore all settings?')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: colors.errorContainer.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: colors.error.withValues(alpha: 0.32)),
                ),
                child: const Text(
                  'This restores the entire application to its initial state. '
                  'Your saved configuration files will not be deleted.',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'It will reset themes, fonts, shortcuts, layout, waveform '
                'rate and mode, shot history, web pages, learned Tree/Signal '
                'suggestions, Login and SSH settings. Saved passwords and '
                'session tokens will also be removed.',
              ),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey('restore-all-settings-cancel'),
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              key: const ValueKey('restore-all-settings-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(dialogContext, true),
              icon: const Icon(Icons.restore_rounded),
              label: const Text('Restore all settings'),
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await app.restoreAllDefaults();
    }
  }

  Future<void> _openConfiguration(BuildContext context, AppState app) {
    return app.openFile(
      importedConfigurationDecision: (summary) =>
          showImportedConfigurationDecision(context, summary),
    );
  }

  Future<void> _showRecentConfigurations(
    BuildContext context,
    AppState app,
  ) async {
    final selected = await showDialog<RecentConfiguration>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final colors = Theme.of(dialogContext).colorScheme;
          final entries = app.recentConfigurations;
          return KeyboardSafeDialog(
            key: const ValueKey('recent-configurations-dialog'),
            maxWidth: 620,
            title: Row(
              children: [
                Icon(Icons.history_rounded, color: colors.primary),
                const SizedBox(width: 10),
                const Flexible(child: Text('Recent configurations')),
              ],
            ),
            content: entries.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      'No local configurations have been opened yet. '
                      'Use Open configuration to choose one.',
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  )
                : SizedBox(
                    height: math.min(380, 88.0 * entries.length),
                    child: Scrollbar(
                      thumbVisibility: entries.length > 4,
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (itemContext, index) {
                          final entry = entries[index];
                          return ListTile(
                            key: ValueKey('recent-configuration-$index'),
                            leading: CircleAvatar(
                              backgroundColor: colors.primaryContainer,
                              foregroundColor: colors.onPrimaryContainer,
                              child: const Icon(Icons.description_outlined),
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              entry.path,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  key: ValueKey(
                                    'recent-configuration-remove-$index',
                                  ),
                                  tooltip: 'Remove from recent list',
                                  onPressed: () async {
                                    await app.removeRecentConfiguration(entry);
                                    setDialogState(() {});
                                  },
                                  icon: const Icon(Icons.close_rounded),
                                ),
                                const Icon(Icons.chevron_right_rounded),
                              ],
                            ),
                            onTap: () => Navigator.pop(dialogContext, entry),
                          );
                        },
                      ),
                    ),
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Close'),
              ),
              if (entries.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('recent-configurations-clear'),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: dialogContext,
                      builder: (confirmContext) => AlertDialog(
                        title: const Text('Clear recent configurations?'),
                        content: const Text(
                          'This removes the entries from the recent list. '
                          'The configuration files themselves will not be deleted.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.pop(confirmContext, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.pop(confirmContext, true),
                            child: const Text('Clear list'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await app.clearRecentConfigurations();
                      setDialogState(() {});
                    }
                  },
                  icon: const Icon(Icons.delete_sweep_rounded),
                  label: const Text('Clear list'),
                ),
              FilledButton.icon(
                key: const ValueKey('recent-configurations-open-file'),
                onPressed: () {
                  Navigator.pop(dialogContext);
                  unawaited(_openConfiguration(context, app));
                },
                icon: const Icon(Icons.folder_open_rounded),
                label: const Text('Open configuration'),
              ),
            ],
          );
        },
      ),
    );
    if (selected != null) {
      await app.openRecentConfiguration(selected);
    }
  }

  Future<void> _chooseConfigurationSaveFormat(
    BuildContext context,
    AppState app,
  ) async {
    final format = await showDialog<ConfigurationFileFormat>(
      context: context,
      builder: (dialogContext) {
        final colors = Theme.of(dialogContext).colorScheme;
        Widget formatCard({
          required ConfigurationFileFormat format,
          required IconData icon,
          required String description,
        }) {
          return Card(
            margin: const EdgeInsets.only(bottom: 10),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: ValueKey('save-format-${format.extension}'),
              onTap: () => Navigator.pop(dialogContext, format),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(icon, color: colors.onPrimaryContainer),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            format.label,
                            style: Theme.of(dialogContext).textTheme.titleSmall,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            description,
                            style: Theme.of(dialogContext)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
          );
        }

        return KeyboardSafeDialog(
          maxWidth: 520,
          title: const Row(
            children: [
              Icon(Icons.save_as_rounded),
              SizedBox(width: 10),
              Flexible(child: Text('Save configuration as')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              formatCard(
                format: ConfigurationFileFormat.toml,
                icon: Icons.data_object_rounded,
                description:
                    'Recommended. Preserves every MDSLens configuration setting.',
              ),
              formatCard(
                format: ConfigurationFileFormat.webscp,
                icon: Icons.swap_horiz_rounded,
                description:
                    'Compatible with WebScope; MDSLens settings are retained as safe extension fields.',
              ),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.close_rounded),
              label: const Text('Cancel'),
            ),
          ],
        );
      },
    );
    if (format != null) {
      // Let the format route finish its reverse animation before preparing
      // bytes or asking the OS to attach a native save sheet to this window.
      // The encoders themselves run on a helper isolate, so the application
      // remains responsive while a large layout is serialized.
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(Duration.zero);
      await app.saveFile(format: format);
    }
  }

  Widget _toolbarIconButton(
    BuildContext context, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool active = false,
    Color? activeColor,
  }) {
    final colors = Theme.of(context).colorScheme;
    final highlight = activeColor ?? colors.primary;
    return Semantics(
      button: true,
      selected: active,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            boxShadow: active
                ? [
                    BoxShadow(
                      color: highlight.withValues(alpha: 0.28),
                      blurRadius: 9,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: OutlinedButton(
            onPressed: onPressed,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(44, 44),
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              side: BorderSide(
                color: active ? highlight : colors.outlineVariant,
                width: active ? 1.5 : 1,
              ),
              backgroundColor: active
                  ? Color.alphaBlend(
                      highlight.withValues(alpha: 0.18),
                      colors.surface,
                    )
                  : null,
              foregroundColor: active ? highlight : colors.onSurface,
            ),
            child: Icon(
              icon,
              size: context.read<AppState>().iconSize.toDouble(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolbarRecentConfigurationButton(
    BuildContext context,
    AppState app,
  ) {
    final colors = Theme.of(context).colorScheme;
    final tooltip = _shortcutTooltip(
      app,
      'Recent configurations',
      MdsShortcutCommand.openRecentFiles,
    );
    return Semantics(
      button: true,
      label: tooltip,
      child: Focus(
        canRequestFocus: true,
        skipTraversal: false,
        descendantsAreTraversable: false,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            _showRecentConfigurations(context, app);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Tooltip(
          message: tooltip,
          child: Material(
            color: Colors.transparent,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Ink(
                decoration: BoxDecoration(
                  border: Border.all(color: colors.outlineVariant),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _showRecentConfigurations(context, app),
                  child: Center(
                    child: Icon(
                      Icons.history_rounded,
                      size: app.iconSize.toDouble(),
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sshBtn(BuildContext ctx, AppState app) {
    final tooltip = app.sshConnected
        ? 'SSH tunnel — in use'
        : app.sshTunnelReachable
            ? 'SSH tunnel — reachable, not in use'
            : 'SSH tunnel';
    return _toolbarIconButton(
      ctx,
      icon: Icons.terminal_rounded,
      tooltip: tooltip,
      onPressed: () => SshDialog.show(ctx),
      active: app.sshConnected,
      activeColor: const Color(0xFF16A34A),
    );
  }

  Widget _themeBtns(BuildContext ctx, AppState app) {
    const switchWidth = 108.0;
    const trackPadding = 4.0;
    const trackBorderWidth = 1.0;
    const thumbSize = 30.0;
    const trackContentWidth =
        switchWidth - (trackPadding + trackBorderWidth) * 2;
    const trackContentHeight = 44.0 - (trackPadding + trackBorderWidth) * 2;
    const segmentWidth = trackContentWidth / 3;
    const modes = [0, 2, 1];
    final theme = Theme.of(ctx);
    final selectedIndex = modes.indexOf(app.themeMode).clamp(0, 2);
    final selectedColor = switch (app.themeMode) {
      0 => const Color(0xFFF59E0B),
      1 => const Color(0xFF60A5FA),
      _ => const Color(0xFF22C55E),
    };

    void selectAt(double x) {
      final index =
          (x.clamp(0.0, switchWidth - 0.01) / (switchWidth / modes.length))
              .floor();
      app.themeMode = modes[index];
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        onHorizontalDragStart: (details) => selectAt(details.localPosition.dx),
        onHorizontalDragUpdate: (details) => selectAt(details.localPosition.dx),
        child: Container(
          key: const ValueKey('theme-mode-switch'),
          width: switchWidth,
          height: 44,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedPositioned(
                key: const ValueKey('theme-mode-thumb'),
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOutCubic,
                left: selectedIndex * segmentWidth +
                    (segmentWidth - thumbSize) / 2,
                top: (trackContentHeight - thumbSize) / 2,
                child: Container(
                  width: thumbSize,
                  height: thumbSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: theme.colorScheme.surface,
                    border: Border.all(color: selectedColor, width: 1.4),
                    boxShadow: [
                      BoxShadow(
                        color: selectedColor.withValues(alpha: 0.42),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  _themeSegment(
                    ctx,
                    key: const ValueKey('theme-mode-light'),
                    label: 'Light theme',
                    glyph: _ThemeGlyph.light,
                    active: app.themeMode == 0,
                    activeColor: const Color(0xFFF59E0B),
                    onTap: () => app.themeMode = 0,
                  ),
                  _themeSegment(
                    ctx,
                    key: const ValueKey('theme-mode-auto'),
                    label: 'Automatic system theme',
                    glyph: _ThemeGlyph.auto,
                    active: app.themeMode == 2,
                    activeColor: const Color(0xFF22C55E),
                    onTap: () => app.themeMode = 2,
                  ),
                  _themeSegment(
                    ctx,
                    key: const ValueKey('theme-mode-dark'),
                    label: 'Dark theme',
                    glyph: _ThemeGlyph.dark,
                    active: app.themeMode == 1,
                    activeColor: const Color(0xFF60A5FA),
                    onTap: () => app.themeMode = 1,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _themeSegment(
    BuildContext ctx, {
    required Key key,
    required String label,
    required _ThemeGlyph glyph,
    required bool active,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Focus(
        canRequestFocus: true,
        skipTraversal: false,
        descendantsAreTraversable: false,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          if (event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          key: key,
          button: true,
          selected: active,
          label: label,
          child: Tooltip(
            message: label,
            child: InkResponse(
              onTap: onTap,
              radius: 18,
              containedInkWell: true,
              customBorder: const CircleBorder(),
              child: Center(
                child: CustomPaint(
                  size: const Size.square(22),
                  painter: _ThemeGlyphPainter(
                    glyph,
                    active
                        ? activeColor
                        : Theme.of(ctx).colorScheme.onSurfaceVariant,
                    filled: active,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _ThemeGlyph { light, auto, dark }

class _ThemeGlyphPainter extends CustomPainter {
  const _ThemeGlyphPainter(this.glyph, this.color, {required this.filled});

  final _ThemeGlyph glyph;
  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    switch (glyph) {
      case _ThemeGlyph.light:
        _paintSun(canvas, center);
      case _ThemeGlyph.auto:
        _paintSystem(canvas, center);
      case _ThemeGlyph.dark:
        _paintMoon(canvas, center);
    }
  }

  void _paintSun(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = color
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, 4.6, paint);
    paint.style = PaintingStyle.stroke;
    for (var i = 0; i < 8; i++) {
      final angle = 3.14159265358979323846 / 4 * i;
      final direction = Offset.fromDirection(angle);
      canvas.drawLine(
        center + direction * 7.8,
        center + direction * 10.4,
        paint,
      );
    }
  }

  void _paintSystem(Canvas canvas, Offset center) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(center.dx - 8, center.dy - 6.8, 16, 10.8),
        const Radius.circular(2),
      ),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + 4.2),
      Offset(center.dx, center.dy + 7.6),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx - 5.2, center.dy + 7.6),
      Offset(center.dx + 5.2, center.dy + 7.6),
      paint,
    );
  }

  void _paintMoon(Canvas canvas, Offset center) {
    final path = Path()
      ..moveTo(center.dx + 3.5, center.dy - 8.7)
      ..cubicTo(
        center.dx - 5.8,
        center.dy - 6,
        center.dx - 6.3,
        center.dy + 6.1,
        center.dx + 3.4,
        center.dy + 8.7,
      )
      ..cubicTo(
        center.dx - 0.9,
        center.dy + 4.7,
        center.dx - 0.9,
        center.dy - 4.7,
        center.dx + 3.5,
        center.dy - 8.7,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _ThemeGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.filled != filled;
}
