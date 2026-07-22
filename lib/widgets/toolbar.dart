import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/external_url_launcher.dart';
import '../services/rust_bridge.dart';
import 'dialogs/login.dart';
import 'dialogs/ssh.dart';
import 'dialogs/about.dart';
import 'responsive_plot_layout.dart';

class ToolbarWidget extends StatelessWidget {
  const ToolbarWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final uiSize = app.fontUiSize.toDouble();
    final infoStyle = TextStyle(
      fontFamily: app.effectiveFontFamily,
      fontSize: (uiSize - 1).clamp(6, 28).toDouble(),
      color: theme.colorScheme.primary,
    );
    final shot = app.shotText.isNotEmpty ? app.shotText : '--';
    final ip = app.shotInfoIp.isNotEmpty
        ? '${app.shotInfoIp} kA'
        : (app.fetching ? '...' : '--');
    final pulse = app.shotInfoPulse.isNotEmpty
        ? '${app.shotInfoPulse} s'
        : (app.fetching ? '...' : '--');
    final it = app.shotInfoIt.isNotEmpty
        ? '${app.shotInfoIt} A'
        : (app.fetching ? '...' : '--');
    final time = app.shotInfoTime.isNotEmpty
        ? app.shotInfoTime
        : (app.fetching ? '...' : '--');

    final fileActions = Row(mainAxisSize: MainAxisSize.min, children: [
      _btn(context, 'Open', () => app.openFile()),
      _btn(context, 'Save', () => app.saveFile()),
      _btn(context, app.fetching ? 'Stop' : 'Refresh',
          () => app.fetching ? app.stopFetch() : app.startRefresh()),
    ]);
    final rateSelector = Row(mainAxisSize: MainAxisSize.min, children: [
      Text('Rate:',
          style:
              TextStyle(fontSize: uiSize, color: theme.colorScheme.onSurface)),
      const SizedBox(width: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(4)),
        child: DropdownButton<int>(
          value: app.dataMode,
          underline: const SizedBox(),
          isDense: true,
          style:
              TextStyle(fontSize: uiSize, color: theme.colorScheme.onSurface),
          dropdownColor: theme.colorScheme.surface,
          items: [
            DropdownMenuItem(
                value: 0,
                child: Text('Thin',
                    style: TextStyle(
                        fontSize: uiSize, color: theme.colorScheme.onSurface))),
            DropdownMenuItem(
                value: 1,
                child: Text('Medium',
                    style: TextStyle(
                        fontSize: uiSize, color: theme.colorScheme.onSurface))),
            DropdownMenuItem(
                value: 2,
                child: Text('Full',
                    style: TextStyle(
                        fontSize: uiSize, color: theme.colorScheme.onSurface))),
          ],
          onChanged: (v) {
            if (v != null) {
              app.dataMode = v;
              app.startRefresh();
            }
          },
        ),
      ),
    ]);
    final shotInfo = Wrap(
        spacing: 8,
        runSpacing: 4,
        alignment: WrapAlignment.center,
        children: [
          Text('Shot: $shot', style: infoStyle),
          Text('Ip: $ip', style: infoStyle),
          Text('Pulse: $pulse', style: infoStyle),
          Text('It: $it', style: infoStyle),
          Text('Time: $time', style: infoStyle),
        ]);
    final appActions = Row(mainAxisSize: MainAxisSize.min, children: [
      _settingsMenu(context, app),
      IconButton(
        icon: Icon(Icons.info_outline,
            size: 18, color: theme.colorScheme.onSurface),
        tooltip: 'About MdsScope',
        onPressed: () => AboutDialogWidget.show(context),
      ),
      _btn(context, app.loggedIn ? 'Logout' : 'Login',
          () => app.loggedIn ? app.logout() : LoginDialog.show(context)),
      _sshBtn(context, app),
    ]);
    final shotEntry = Row(mainAxisSize: MainAxisSize.min, children: [
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
          onSelected: (v) {
            app.shotText = v;
            app.startRefresh();
          },
          itemBuilder: (_) => app.shotHistory
              .map((s) => PopupMenuItem(
                  value: s, child: Text(s, style: TextStyle(fontSize: uiSize))))
              .toList(),
        ),
      const SizedBox(width: 4),
      SizedBox(
        width: 95,
        child: TextField(
          controller: app.shotCtrl,
          style: TextStyle(fontSize: uiSize),
          decoration: const InputDecoration(
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              border: OutlineInputBorder()),
          onSubmitted: (_) => app.startRefresh(),
        ),
      ),
      _btn(context, 'Apply', () => app.startRefresh()),
    ]);
    final shotNavigation = Row(mainAxisSize: MainAxisSize.min, children: [
      _btn(context, 'Prev', () {
        final cur = app.shotCtrl.text.trim().isNotEmpty
            ? app.shotCtrl.text.trim()
            : app.shotText;
        final s = int.tryParse(cur);
        if (s != null) {
          app.shotText = (s - 1).toString();
          app.startRefresh();
        }
      }),
      _btn(context, 'Next', () {
        final cur = app.shotCtrl.text.trim().isNotEmpty
            ? app.shotCtrl.text.trim()
            : app.shotText;
        final s = int.tryParse(cur);
        if (s != null) {
          app.shotText = (s + 1).toString();
          app.startRefresh();
        }
      }),
      _btn(context, 'Latest', () async => app.fetchLatestShot()),
    ]);
    final modeActions = Row(mainAxisSize: MainAxisSize.min, children: [
      _modeBtn(context, 'Zoom/Move', app.interactionMode == 0,
          () => app.interactionMode = 0),
      _modeBtn(context, 'Point', app.interactionMode == 1,
          () => app.interactionMode = 1),
    ]);

    return Container(
      key: const ValueKey('toolbar-root'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      color: theme.colorScheme.surfaceContainerHighest,
      child: LayoutBuilder(builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1180;
        final wrapAlignment = constraints.maxWidth < 600
            ? WrapAlignment.center
            : WrapAlignment.spaceBetween;
        return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isWide)
                Row(children: [
                  fileActions,
                  const SizedBox(width: 8),
                  rateSelector,
                  const SizedBox(width: 12),
                  Expanded(child: shotInfo),
                  const SizedBox(width: 12),
                  _themeBtns(context, app),
                  appActions,
                ])
              else
                Wrap(
                  alignment: wrapAlignment,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    fileActions,
                    rateSelector,
                    shotInfo,
                    _themeBtns(context, app),
                    appActions
                  ],
                ),
              const SizedBox(height: 6),
              Wrap(
                alignment: isWide ? WrapAlignment.start : wrapAlignment,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 6,
                children: [shotEntry, shotNavigation, modeActions],
              ),
            ]);
      }),
    );
  }

  Widget _settingsMenu(BuildContext ctx, AppState app) {
    return PopupMenuButton<String>(
      tooltip: 'Settings',
      icon: Icon(Icons.settings,
          size: 18, color: Theme.of(ctx).colorScheme.onSurface),
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
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'web', child: Text('Internal web pages')),
        const PopupMenuItem(value: 'layout', child: Text('Layout setup')),
        const PopupMenuItem(value: 'fonts', child: Text('Customize fonts')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'about', child: Text('About MdsScope')),
      ],
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
    // Route through SSH tunnel if connected (matching C++ behaviour)
    if (app.sshConnected && app.sshHost.isNotEmpty) {
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
        }
      } catch (_) {}
    }
    final opened = await openExternalWebUrl(finalUrl);
    app.setStatus(opened
        ? 'Opened internal web page'
        : 'Could not open the default browser');
  }

  void _showLayoutSetup(BuildContext ctx, AppState app) {
    var layout = app.columns.map((col) => col.length).toList();
    if (layout.isEmpty) layout = [1];
    var selectedCol = -1, selectedRow = -1;

    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
        final screenSize = MediaQuery.sizeOf(ctx);
        final displayColumns = buildResponsivePlotColumns(
          layout,
          screenSize.width,
        );
        final maxRows = displayColumns
            .map((column) => column.length)
            .fold(1, (current, rows) => rows > current ? rows : current);
        final previewHeight = (maxRows * 72.0).clamp(90.0, 430.0);
        final contentWidth = (screenSize.width - 64).clamp(240.0, 700.0);
        final contentHeight = (screenSize.height * 0.58).clamp(260.0, 540.0);
        final compact = usesScrollablePlotList(screenSize.width);

        return AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          title: const Text('Layout Setup'),
          content: SizedBox(
            width: contentWidth,
            height: contentHeight,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    compact
                        ? 'Phone preview · single scrollable column'
                        : 'Responsive preview · ${displayColumns.length} columns',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SingleChildScrollView(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var displayColumn = 0;
                                displayColumn < displayColumns.length;
                                displayColumn++) ...[
                              if (displayColumn > 0) const SizedBox(width: 6),
                              Container(
                                key: ValueKey(
                                    'layout-preview-column-$displayColumn'),
                                width: 118,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Theme.of(ctx).dividerColor),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Column(children: [
                                  SizedBox(
                                    height: 28,
                                    child: Center(
                                      child: Text(
                                        compact
                                            ? 'Scroll column'
                                            : 'Column ${displayColumn + 1}',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    height: previewHeight,
                                    child: Column(
                                      children: displayColumns[displayColumn]
                                          .map((cell) {
                                        final selected =
                                            selectedCol == cell.sourceColumn &&
                                                selectedRow == cell.sourceRow;
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
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Text(
                                                    'Panel ${cell.plotIndex + 1}',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: Theme.of(ctx)
                                                          .colorScheme
                                                          .onSurfaceVariant,
                                                    ),
                                                  ),
                                                  if (selected)
                                                    TextButton(
                                                      onPressed: () {
                                                        if (layout.length ==
                                                                1 &&
                                                            layout[0] == 1) {
                                                          return;
                                                        }
                                                        layout[cell
                                                            .sourceColumn]--;
                                                        if (layout[cell
                                                                .sourceColumn] <=
                                                            0) {
                                                          layout.removeAt(cell
                                                              .sourceColumn);
                                                        }
                                                        selectedCol = -1;
                                                        selectedRow = -1;
                                                        setState(() {});
                                                      },
                                                      child: const Text(
                                                        'Delete',
                                                        style: TextStyle(
                                                            fontSize: 9),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                ]),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    TextButton.icon(
                      onPressed: () {
                        final targetColumn =
                            selectedCol >= 0 && selectedCol < layout.length
                                ? selectedCol
                                : layout.length - 1;
                        layout[targetColumn]++;
                        setState(() {});
                      },
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add panel'),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        layout.add(1);
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
                final columns = layout.where((count) => count > 0).toList();
                if (columns.isNotEmpty) {
                  app.applyLayoutList(columns);
                  app.startRefresh();
                }
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        );
      }),
    );
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
                        decoration: const InputDecoration(
                            contentPadding: EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            border: OutlineInputBorder()),
                        items: families
                            .map((f) => DropdownMenuItem(
                                value: f,
                                child: Text(f,
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontFamily: f == 'System' ? null : f))))
                            .toList(),
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

  Widget _btn(BuildContext ctx, String label, VoidCallback onTap) {
    final app = ctx.read<AppState>();
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: ElevatedButton(
            onPressed: onTap,
            style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: TextStyle(
                    fontFamily: app.effectiveFontFamily,
                    fontSize: app.fontUiSize.toDouble(),
                    fontWeight: FontWeight.w500)),
            child: Text(label)));
  }

  Widget _modeBtn(
      BuildContext ctx, String label, bool active, VoidCallback onTap) {
    final app = ctx.read<AppState>();
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: TextStyle(
                    fontFamily: app.effectiveFontFamily,
                    fontSize: app.fontUiSize.toDouble(),
                    fontWeight: active ? FontWeight.bold : FontWeight.w500),
                backgroundColor:
                    active ? Theme.of(ctx).colorScheme.primaryContainer : null),
            child: Text(label)));
  }

  Widget _sshBtn(BuildContext ctx, AppState app) {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: ElevatedButton(
            onPressed: () => SshDialog.show(ctx),
            style: ElevatedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: TextStyle(
                    fontFamily: app.effectiveFontFamily,
                    fontSize: app.fontUiSize.toDouble(),
                    color: app.sshConnected ? Colors.green : null)),
            child: const Text('SSH')));
  }

  Widget _themeBtns(BuildContext ctx, AppState app) {
    return Row(children: [
      _themeBtn(ctx, 'Auto', app.themeMode == 2, () => app.themeMode = 2),
      _themeBtn(ctx, 'Light', app.themeMode == 0, () => app.themeMode = 0),
      _themeBtn(ctx, 'Dark', app.themeMode == 1, () => app.themeMode = 1),
    ]);
  }

  Widget _themeBtn(
      BuildContext ctx, String label, bool active, VoidCallback onTap) {
    final theme = Theme.of(ctx);
    final app = ctx.read<AppState>();
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: OutlinedButton(
            onPressed: onTap,
            style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(4)),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: TextStyle(
                    fontFamily: app.effectiveFontFamily,
                    fontSize: app.fontUiSize.toDouble(),
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    color: active
                        ? theme.colorScheme.onPrimaryContainer
                        : theme.colorScheme.onSurface),
                backgroundColor:
                    active ? theme.colorScheme.primaryContainer : null),
            child: Text(label)));
  }
}
