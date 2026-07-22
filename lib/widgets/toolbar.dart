import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/external_url_launcher.dart';
import '../services/rust_bridge.dart';
import 'dialogs/login.dart';
import 'dialogs/ssh.dart';
import 'dialogs/about.dart';
import 'dropdown_items.dart';
import 'plot_panel.dart';
import 'responsive_plot_layout.dart';

List<(String, String)> _shotMetadata(AppState app) {
  String valueWithUnit(String value, String unit) {
    if (value.isEmpty) return app.fetching ? '...' : '--';
    if (RegExp(r'[a-zA-Z]$').hasMatch(value.trim())) return value;
    return '$value $unit';
  }

  return [
    ('Shot', app.shotText.isEmpty ? '--' : app.shotText),
    ('Ip', valueWithUnit(app.shotInfoIp, 'kA')),
    ('Pulse', valueWithUnit(app.shotInfoPulse, 's')),
    ('It', valueWithUnit(app.shotInfoIt, 'A')),
    (
      'Time',
      app.shotInfoTime.isEmpty
          ? (app.fetching ? '...' : '--')
          : app.shotInfoTime
    ),
  ];
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
        final metadata = _shotMetadata(app)
            .map((entry) => '${entry.$1}: ${entry.$2}')
            .join('   •   ');
        final collapseBar = app.toolbarCollapsed
            ? SizedBox(
                height: 40,
                child: Row(
                  children: [
                    InkWell(
                      key: const ValueKey('toolbar-collapse-control'),
                      onTap: () => app.toolbarCollapsed = false,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.keyboard_arrow_down_rounded,
                              size: 22,
                              color: theme.colorScheme.primary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Expand controls',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      indent: 9,
                      endIndent: 9,
                      color: theme.dividerColor,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        key:
                            const ValueKey('toolbar-collapsed-metadata-scroll'),
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Center(
                          child: Text(
                            metadata,
                            key: const ValueKey('toolbar-collapsed-summary'),
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              )
            : InkWell(
                key: const ValueKey('toolbar-collapse-control'),
                onTap: () => app.toolbarCollapsed = true,
                child: SizedBox(
                  height: 40,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      children: [
                        Icon(
                          Icons.keyboard_arrow_up_rounded,
                          size: 22,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'Collapse controls',
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              );
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: app.toolbarCollapsed
                  ? const SizedBox(width: double.infinity)
                  : const ToolbarWidget(),
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

class ToolbarWidget extends StatelessWidget {
  const ToolbarWidget({super.key});

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
          tooltip: 'Open configuration',
          onPressed: () => app.openFile(),
        ),
        _toolbarIconButton(
          context,
          icon: Icons.save_rounded,
          tooltip: 'Save configuration',
          onPressed: () => app.saveFile(),
        ),
        _toolbarIconButton(
          context,
          icon: app.fetching ? Icons.stop_circle_outlined : Icons.refresh,
          tooltip: app.fetching ? 'Stop loading' : 'Refresh waveforms',
          onPressed: () => app.fetching ? app.stopFetch() : app.startRefresh(),
          active: app.fetching,
        ),
      ],
    );
    final rateSelector = Row(key: const ValueKey('toolbar-rate'), children: [
      Text('Rate:',
          style:
              TextStyle(fontSize: uiSize, color: theme.colorScheme.onSurface)),
      const SizedBox(width: 6),
      Expanded(
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(10),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              key: const ValueKey('toolbar-rate-dropdown'),
              value: app.dataMode,
              isExpanded: true,
              isDense: true,
              itemHeight: 48,
              menuMaxHeight: 320,
              elevation: 12,
              borderRadius: BorderRadius.circular(12),
              iconSize: 18,
              style: TextStyle(
                  fontSize: uiSize, color: theme.colorScheme.onSurface),
              dropdownColor: theme.colorScheme.surfaceContainerHigh,
              selectedItemBuilder: (_) => ['Thin', 'Medium', 'Full']
                  .map((label) => Align(
                        alignment: Alignment.centerLeft,
                        child: Text(label,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              items: [
                for (var index = 0;
                    index < const ['Thin', 'Medium', 'Full'].length;
                    index++)
                  DropdownMenuItem(
                    value: index,
                    child: separatedDropdownItem(
                      context,
                      key: ValueKey('rate-option-$index'),
                      isLast: index == 2,
                      child: Text(
                        const ['Thin', 'Medium', 'Full'][index],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: uiSize,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) {
                  app.dataMode = v;
                  app.startRefresh();
                }
              },
            ),
          ),
        ),
      ),
    ]);
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
    final shotEntry = Row(key: const ValueKey('toolbar-shot-entry'), children: [
      Text('Shot:',
          style:
              TextStyle(fontSize: uiSize, color: theme.colorScheme.onSurface)),
      if (app.shotHistory.isNotEmpty)
        PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          iconSize: 16,
          icon: Icon(Icons.arrow_drop_down,
              size: 16, color: theme.colorScheme.onSurface),
          tooltip: 'Shot history',
          position: PopupMenuPosition.under,
          onSelected: (v) {
            app.shotText = v;
            app.startRefresh();
          },
          itemBuilder: (_) => separatedPopupMenuItems(
            app.shotHistory
                .map((s) => PopupMenuItem(
                    value: s,
                    child: Text(s, style: TextStyle(fontSize: uiSize))))
                .toList(),
          ),
        ),
      const SizedBox(width: 6),
      Expanded(
        flex: 3,
        child: TextField(
          controller: app.shotCtrl,
          style: TextStyle(fontSize: uiSize),
          decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(6))),
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
    ]);
    final shotNavigation = _equalActionRow(
      key: const ValueKey('toolbar-shot-navigation'),
      children: [
        _toolbarIconButton(context,
            icon: Icons.skip_previous_rounded,
            tooltip: 'Previous shot', onPressed: () {
          final cur = app.shotCtrl.text.trim().isNotEmpty
              ? app.shotCtrl.text.trim()
              : app.shotText;
          final s = int.tryParse(cur);
          if (s != null) {
            app.shotText = (s - 1).toString();
            app.startRefresh();
          }
        }),
        _toolbarIconButton(context,
            icon: Icons.skip_next_rounded, tooltip: 'Next shot', onPressed: () {
          final cur = app.shotCtrl.text.trim().isNotEmpty
              ? app.shotCtrl.text.trim()
              : app.shotText;
          final s = int.tryParse(cur);
          if (s != null) {
            app.shotText = (s + 1).toString();
            app.startRefresh();
          }
        }),
        _toolbarIconButton(
          context,
          icon: Icons.last_page_rounded,
          tooltip: 'Latest shot',
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
          tooltip: 'Zoom and move mode',
          active: app.interactionMode == 0,
          onPressed: () => app.interactionMode = 0,
        ),
        _toolbarIconButton(
          context,
          icon: Icons.gps_fixed_rounded,
          tooltip: 'Point mode',
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
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final compact = width < 560;
        final wide = width >= 940;
        final rateSelectorWidth =
            (140 + (uiSize - 12).clamp(0, 16) * 2).clamp(140, 172).toDouble();
        final shotInfo = _shotInfoPanel(
          context,
          compact: compact,
          entries: shotMetadata,
          labelStyle: infoLabelStyle,
          valueStyle: infoValueStyle,
        );

        Widget topActions;
        if (compact) {
          topActions = Column(children: [
            Row(children: [
              SizedBox(width: 108, child: themeActions),
              const SizedBox(width: 8),
              Expanded(child: appActions),
            ]),
            const SizedBox(height: 8),
            if (width < rateSelectorWidth + 152) ...[
              SizedBox(width: double.infinity, child: fileActions),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: rateSelector),
            ] else
              Row(children: [
                Expanded(child: fileActions),
                const SizedBox(width: 8),
                SizedBox(width: rateSelectorWidth, child: rateSelector),
              ]),
          ]);
        } else if (wide) {
          topActions = Row(children: [
            SizedBox(width: 280, child: fileActions),
            const SizedBox(width: 8),
            SizedBox(width: rateSelectorWidth, child: rateSelector),
            const Spacer(),
            SizedBox(width: 108, child: themeActions),
            const SizedBox(width: 8),
            SizedBox(width: 190, child: appActions),
          ]);
        } else {
          final fileWidth = (width * 0.56).clamp(250.0, 320.0);
          final appWidth = (width * 0.46).clamp(230.0, 300.0);
          topActions = Column(children: [
            Row(children: [
              SizedBox(width: 108, child: themeActions),
              const Spacer(),
              SizedBox(width: appWidth, child: appActions),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              SizedBox(width: fileWidth, child: fileActions),
              const Spacer(),
              SizedBox(width: rateSelectorWidth, child: rateSelector),
            ]),
          ]);
        }

        Widget shotControls;
        if (compact) {
          shotControls = Column(children: [
            SizedBox(width: double.infinity, child: shotEntry),
            const SizedBox(height: 8),
            if (width >= 340)
              Row(children: [
                Expanded(flex: 3, child: shotNavigation),
                const SizedBox(width: 8),
                Expanded(flex: 2, child: modeActions),
              ])
            else ...[
              SizedBox(width: double.infinity, child: shotNavigation),
              const SizedBox(height: 8),
              SizedBox(width: double.infinity, child: modeActions),
            ],
          ]);
        } else if (wide) {
          shotControls = Row(children: [
            SizedBox(width: 300, child: shotEntry),
            const SizedBox(width: 8),
            SizedBox(width: 260, child: shotNavigation),
            const SizedBox(width: 8),
            SizedBox(width: 220, child: modeActions),
            const Spacer(),
          ]);
        } else {
          shotControls = Row(children: [
            Expanded(flex: 4, child: shotEntry),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: shotNavigation),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: modeActions),
          ]);
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
      }),
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

    Widget infoCell(int index) => _infoCell(
          entries[index].$1,
          entries[index].$2,
          labelStyle,
          valueStyle,
        );

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
          ? Column(children: [
              compactRow([0, 1, 2]),
              Divider(height: 1, thickness: 1, color: divider),
              compactRow([3, 4], lastFlex: 2),
            ])
          : IntrinsicHeight(
              child: Row(children: [
                for (var i = 0; i < entries.length; i++) ...[
                  if (i > 0)
                    VerticalDivider(width: 1, thickness: 1, color: divider),
                  Expanded(flex: i == 4 ? 2 : 1, child: infoCell(i)),
                ],
              ]),
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
          TextSpan(children: [
            TextSpan(text: '$label: ', style: labelStyle),
            TextSpan(text: value, style: valueStyle),
          ]),
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
        child: Icon(Icons.settings,
            size: 22, color: Theme.of(ctx).colorScheme.onSurface),
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
        ),
        _settingsMenuItem(
          value: 'layout',
          icon: Icons.dashboard_customize_rounded,
          label: 'Layout setup',
        ),
        _settingsMenuItem(
          value: 'fonts',
          icon: Icons.font_download_outlined,
          label: 'Customize fonts',
        ),
        _settingsMenuItem(
          value: 'about',
          icon: Icons.info_outline_rounded,
          label: 'About MdsScope',
        ),
      ]),
    );
  }

  PopupMenuItem<String> _settingsMenuItem({
    required String value,
    required IconData icon,
    required String label,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 21),
          const SizedBox(width: 12),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }

  void _showWebBookmarks(BuildContext ctx, AppState app) {
    final bookmarks = app.webBookmarks;
    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
                title: const Text('Internal Web Pages'),
                content: SizedBox(
                  width: 400,
                  height: 300,
                  child: bookmarks.isEmpty
                      ? const Center(
                          child: Text('No Saved Web Addresses',
                              style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          itemCount: bookmarks.length,
                          itemBuilder: (_, i) => ListTile(
                            title: Text(bookmarks[i].keys.first),
                            subtitle: Text(bookmarks[i].values.first,
                                style: const TextStyle(fontSize: 11)),
                            onTap: () {
                              Navigator.pop(ctx);
                              _openUrl(bookmarks[i].values.first, app);
                            },
                          ),
                        ),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close')),
                  TextButton(
                      onPressed: () {
                        _addBookmark(ctx, app, setState);
                      },
                      child: const Text('Add...')),
                  if (bookmarks.isNotEmpty)
                    TextButton(
                        onPressed: () {
                          _removeBookmark(ctx, app, setState);
                        },
                        child: const Text('Remove...')),
                ],
              )),
    );
  }

  void _addBookmark(
      BuildContext ctx, AppState app, void Function(VoidCallback) setState) {
    final aliasCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    showDialog(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Web Bookmark'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: aliasCtrl,
              decoration: const InputDecoration(labelText: 'Alias')),
          const SizedBox(height: 8),
          TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(labelText: 'URL')),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
              child: const Text('Add')),
        ],
      ),
    );
  }

  void _removeBookmark(
      BuildContext ctx, AppState app, void Function(VoidCallback) setState) {
    final bookmarks = app.webBookmarks;
    showDialog(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Bookmark'),
        content: SizedBox(
          width: 300,
          height: 200,
          child: ListView.builder(
            itemCount: bookmarks.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(bookmarks[i].keys.first),
              onTap: () {
                app.removeWebBookmark(i);
                Navigator.pop(ctx);
                setState(() {});
              },
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))
        ],
      ),
    );
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
    app.setStatus(opened
        ? 'Opened internal web page'
        : 'Could not open the default browser');
  }

  void _showLayoutSetup(BuildContext ctx, AppState app) {
    final draftColumns = _cloneLayoutColumns(app.columns);
    if (draftColumns.isEmpty) draftColumns.add([_emptyPanelConfig()]);
    var selectedCol = -1, selectedRow = -1;

    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        final screenSize = MediaQuery.sizeOf(ctx);
        final displayColumns = buildResponsivePlotColumns(
          draftColumns.map((column) => column.length).toList(),
          screenSize.width,
        );
        final contentWidth = (screenSize.width - 64).clamp(240.0, 700.0);
        final contentHeight = (screenSize.height * 0.58).clamp(260.0, 540.0);

        return GestureDetector(
          key: const ValueKey('layout-setup-surface'),
          behavior: HitTestBehavior.translucent,
          onTap: () => setState(() {
            selectedCol = -1;
            selectedRow = -1;
          }),
          child: AlertDialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
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
                      onTap: () => setState(() {
                        selectedCol = -1;
                        selectedRow = -1;
                      }),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'Overview · ${displayColumns.length} columns · all panels visible',
                          style: Theme.of(ctx).textTheme.bodySmall,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var displayColumn = 0;
                              displayColumn < displayColumns.length;
                              displayColumn++) ...[
                            if (displayColumn > 0) const SizedBox(width: 6),
                            Expanded(
                              child: Container(
                                key: ValueKey(
                                    'layout-preview-column-$displayColumn'),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Theme.of(ctx).dividerColor),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Column(children: [
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: () => setState(() {
                                      selectedCol = -1;
                                      selectedRow = -1;
                                    }),
                                    child: SizedBox(
                                      height: 28,
                                      child: Center(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            'Column ${displayColumn + 1}',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      children: displayColumns[displayColumn]
                                          .map((cell) {
                                        final selected =
                                            selectedCol == cell.sourceColumn &&
                                                selectedRow == cell.sourceRow;
                                        final panel =
                                            draftColumns[cell.sourceColumn]
                                                [cell.sourceRow];
                                        return Expanded(
                                          child: GestureDetector(
                                            onTap: () => setState(() {
                                              selectedCol = cell.sourceColumn;
                                              selectedRow = cell.sourceRow;
                                            }),
                                            child: Container(
                                              key: ValueKey(
                                                  'layout-preview-panel-${cell.plotIndex}'),
                                              width: double.infinity,
                                              margin: const EdgeInsets.all(4),
                                              decoration: BoxDecoration(
                                                border: Border.all(
                                                  color: selected
                                                      ? Theme.of(ctx)
                                                          .colorScheme
                                                          .primary
                                                      : Colors.grey.shade400,
                                                  width: selected ? 2 : 1,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                                color: Theme.of(ctx)
                                                    .colorScheme
                                                    .primaryContainer
                                                    .withValues(alpha: 0.3),
                                              ),
                                              child: _buildLayoutPanelPreview(
                                                ctx,
                                                panel: panel,
                                                panelNumber: cell.plotIndex + 1,
                                                selected: selected,
                                                onEdit: () async {
                                                  final changed =
                                                      await _editLayoutPanel(
                                                    ctx,
                                                    app,
                                                    panel,
                                                    cell.plotIndex + 1,
                                                  );
                                                  if (changed && ctx.mounted) {
                                                    setState(() {});
                                                  }
                                                },
                                                onDelete: () {
                                                  final panelCount =
                                                      draftColumns.fold(
                                                    0,
                                                    (count, column) =>
                                                        count + column.length,
                                                  );
                                                  if (panelCount <= 1) return;
                                                  draftColumns[
                                                          cell.sourceColumn]
                                                      .removeAt(cell.sourceRow);
                                                  if (draftColumns[
                                                          cell.sourceColumn]
                                                      .isEmpty) {
                                                    draftColumns.removeAt(
                                                      cell.sourceColumn,
                                                    );
                                                  }
                                                  selectedCol = -1;
                                                  selectedRow = -1;
                                                  setState(() {});
                                                },
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ]),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      TextButton.icon(
                        onPressed: () {
                          final targetColumn = selectedCol >= 0 &&
                                  selectedCol < draftColumns.length
                              ? selectedCol
                              : draftColumns.length - 1;
                          draftColumns[targetColumn].add(_emptyPanelConfig());
                          setState(() {});
                        },
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add panel'),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          draftColumns.add([_emptyPanelConfig()]);
                          setState(() {});
                        },
                        icon: const Icon(Icons.view_column_outlined, size: 16),
                        label: const Text('Add column'),
                      ),
                    ]),
                  ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              TextButton(
                onPressed: () {
                  if (draftColumns.isNotEmpty) {
                    app.applyLayoutColumns(draftColumns);
                    app.startRefresh();
                  }
                  Navigator.pop(ctx);
                },
                child: const Text('Apply'),
              ),
            ],
          ),
        );
      }),
    );
  }

  List<List<Map<String, dynamic>>> _cloneLayoutColumns(
    List<List<Map<String, dynamic>>> columns,
  ) {
    return columns
        .map(
          (column) => column
              .map(
                (panel) => Map<String, dynamic>.from(
                  _cloneLayoutValue(panel) as Map,
                ),
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
        'grid': true,
        'signal_specs': <Map<String, dynamic>>[],
      };

  Widget _buildLayoutPanelPreview(
    BuildContext context, {
    required Map<String, dynamic> panel,
    required int panelNumber,
    required bool selected,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
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
      details.add(Text(
        'Title: $title',
        key: ValueKey('layout-panel-title-$panelNumber'),
        style: TextStyle(fontSize: 9, color: textColor),
      ));
    }
    final signals = panel['signal_specs'] as List? ?? const [];
    for (var signalIndex = 0; signalIndex < signals.length; signalIndex++) {
      final rawSignal = signals[signalIndex];
      if (rawSignal is! Map) continue;
      final tree = rawSignal['experiment']?.toString().trim() ?? '';
      final signal = rawSignal['y_expr']?.toString().trim() ?? '';
      if (tree.isNotEmpty) {
        details.add(Text(
          'Curve ${signalIndex + 1} Tree: $tree',
          key: ValueKey(
              'layout-panel-$panelNumber-curve-${signalIndex + 1}-tree'),
          style: TextStyle(fontSize: 8, color: textColor),
        ));
      }
      if (signal.isNotEmpty) {
        details.add(Text(
          'Curve ${signalIndex + 1} Signal: $signal',
          key: ValueKey(
              'layout-panel-$panelNumber-curve-${signalIndex + 1}-signal'),
          style: TextStyle(fontSize: 8, color: textColor),
        ));
      }
    }

    return Stack(
      children: [
        Positioned.fill(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(4, 4, 4, selected ? 32 : 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: details,
            ),
          ),
        ),
        if (selected)
          Positioned(
            left: 2,
            right: 2,
            bottom: 2,
            height: 28,
            child: Row(
              children: [
                Expanded(
                  child: TextButton(
                    key: ValueKey('layout-edit-panel-$panelNumber'),
                    onPressed: onEdit,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Edit', style: TextStyle(fontSize: 8)),
                  ),
                ),
                Expanded(
                  child: TextButton(
                    key: ValueKey('layout-delete-panel-$panelNumber'),
                    onPressed: onDelete,
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Delete', style: TextStyle(fontSize: 8)),
                  ),
                ),
              ],
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
      (panel['signal_specs'] as List?)
              ?.whereType<Map>()
              .map((signal) => Map<String, dynamic>.from(signal)) ??
          const [],
    );
    if (signals.isEmpty) {
      signals.add({
        'experiment': 'pcs_east',
        'server_ip': '202.127.204.12',
      });
    }
    final saved = await showDataSourceSetupEditor(
      context,
      signals: signals,
      defaultShot: (panel['shot']?.toString() ?? app.shotText).trim(),
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
    const families = [
      'System',
      'Arial',
      'Helvetica',
      'Times New Roman',
      'Courier New',
      'Georgia',
      'Verdana',
      'Monaco'
    ];
    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
                title: const Text('Customize Fonts'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    const SizedBox(width: 100, child: Text('Font')),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: families.contains(fontFamily)
                            ? fontFamily
                            : 'System',
                        isDense: true,
                        itemHeight: 48,
                        menuMaxHeight: 360,
                        elevation: 12,
                        borderRadius: BorderRadius.circular(12),
                        selectedItemBuilder: (_) => families
                            .map((family) => Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    family,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontFamily:
                                          family == 'System' ? null : family,
                                    ),
                                  ),
                                ))
                            .toList(),
                        decoration: InputDecoration(
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        items: [
                          for (var index = 0; index < families.length; index++)
                            DropdownMenuItem(
                              value: families[index],
                              child: separatedDropdownItem(
                                ctx,
                                isLast: index == families.length - 1,
                                child: Text(
                                  families[index],
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: families[index] == 'System'
                                        ? null
                                        : families[index],
                                  ),
                                ),
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => fontFamily = v);
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  _fontRow('Legend size', legendSize,
                      (v) => setState(() => legendSize = v)),
                  _fontRow('Axis size', axisSize,
                      (v) => setState(() => axisSize = v)),
                  _fontRow('Unit size', unitSize,
                      (v) => setState(() => unitSize = v)),
                  _fontRow(
                      'UI size', uiSize, (v) => setState(() => uiSize = v)),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel')),
                  TextButton(
                      onPressed: () {
                        app.applyFontSettings(
                            fontFamily, legendSize, axisSize, unitSize, uiSize);
                        Navigator.pop(ctx);
                      },
                      child: const Text('OK')),
                ],
              )),
    );
  }

  Widget _fontRow(String label, int value, void Function(int) onChanged) {
    return Row(children: [
      SizedBox(width: 100, child: Text(label)),
      IconButton(
          icon: const Icon(Icons.remove, size: 16),
          onPressed: value > 6 ? () => onChanged(value - 1) : null),
      SizedBox(width: 30, child: Text('$value', textAlign: TextAlign.center)),
      IconButton(
          icon: const Icon(Icons.add, size: 16),
          onPressed: value < 28 ? () => onChanged(value + 1) : null),
    ]);
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
                  borderRadius: BorderRadius.circular(10)),
              side: BorderSide(
                color: active ? highlight : colors.outlineVariant,
                width: active ? 1.5 : 1,
              ),
              backgroundColor: active
                  ? Color.alphaBlend(
                      highlight.withValues(alpha: 0.18), colors.surface)
                  : null,
              foregroundColor: active ? highlight : colors.onSurface,
            ),
            child: Icon(icon, size: 22),
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
                left: selectedIndex * (100 / 3) - 1 / 3,
                top: 1,
                child: Container(
                  width: 34,
                  height: 34,
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
                    icon: Icons.light_mode_rounded,
                    active: app.themeMode == 0,
                    activeColor: const Color(0xFFF59E0B),
                    onTap: () => app.themeMode = 0,
                  ),
                  _themeSegment(
                    ctx,
                    key: const ValueKey('theme-mode-auto'),
                    label: 'Automatic system theme',
                    icon: Icons.computer_rounded,
                    active: app.themeMode == 2,
                    activeColor: const Color(0xFF22C55E),
                    onTap: () => app.themeMode = 2,
                  ),
                  _themeSegment(
                    ctx,
                    key: const ValueKey('theme-mode-dark'),
                    label: 'Dark theme',
                    icon: Icons.dark_mode_rounded,
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
    required IconData icon,
    required bool active,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    return Expanded(
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
              child: Icon(
                icon,
                size: 18,
                color: active
                    ? activeColor
                    : Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
