import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/rust_bridge.dart';
import 'dialogs/login.dart';
import 'dialogs/ssh.dart';

class ToolbarWidget extends StatelessWidget {
  const ToolbarWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final infoStyle = TextStyle(fontSize: 11, color: theme.colorScheme.primary);
    final shot = app.shotText.isNotEmpty ? app.shotText : '--';
    final ip = app.shotInfoIp.isNotEmpty ? '${app.shotInfoIp} kA' : (app.fetching ? '...' : '--');
    final pulse = app.shotInfoPulse.isNotEmpty ? '${app.shotInfoPulse} s' : (app.fetching ? '...' : '--');
    final it = app.shotInfoIt.isNotEmpty ? '${app.shotInfoIt} A' : (app.fetching ? '...' : '--');
    final time = app.shotInfoTime.isNotEmpty ? app.shotInfoTime : (app.fetching ? '...' : '--');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Column(
        children: [
          Row(children: [
            _btn(context, 'Open', () => app.openFile()),
            const SizedBox(width: 4),
            _btn(context, 'Save', () => app.saveFile()),
            const SizedBox(width: 8),
            _btn(context, app.fetching ? 'Stop' : 'Refresh', () => app.fetching ? app.stopFetch() : app.startRefresh()),
            const SizedBox(width: 8),
            Text('Rate:', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface)),
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(border: Border.all(color: theme.dividerColor), borderRadius: BorderRadius.circular(4)),
              child: DropdownButton<int>(
                value: app.dataMode, underline: const SizedBox(), isDense: true,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface),
                dropdownColor: theme.colorScheme.surface,
                items: [
                  DropdownMenuItem(value: 0, child: Text('Thin', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface))),
                  DropdownMenuItem(value: 1, child: Text('Medium', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface))),
                  DropdownMenuItem(value: 2, child: Text('Full', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface))),
                ],
                onChanged: (v) { if (v != null) { app.dataMode = v; app.startRefresh(); } },
              ),
            ),
            const SizedBox(width: 8),
            Text('Shot: $shot', style: infoStyle),
            const SizedBox(width: 4),
            Text('Ip: $ip', style: infoStyle),
            const SizedBox(width: 4),
            Text('Pulse: $pulse', style: infoStyle),
            const SizedBox(width: 4),
            Text('It: $it', style: infoStyle),
            const SizedBox(width: 4),
            Text('Time: $time', style: infoStyle),
            const Spacer(),
            _themeBtns(context, app),
            const SizedBox(width: 4),
            _settingsMenu(context, app),
            const SizedBox(width: 4),
            _btn(context, app.loggedIn ? 'Logout' : 'Login', () => app.loggedIn ? app.logout() : LoginDialog.show(context)),
            const SizedBox(width: 4),
            _sshBtn(context, app),
          ]),
          const SizedBox(height: 2),
          Row(children: [
            Text('Shot:', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface)),
            const SizedBox(width: 2),
            if (app.shotHistory.isNotEmpty)
              PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                iconSize: 14,
                icon: Icon(Icons.arrow_drop_down, size: 14, color: theme.colorScheme.onSurface),
                tooltip: 'Shot history',
                onSelected: (v) { app.shotText = v; app.startRefresh(); },
                itemBuilder: (_) => app.shotHistory.map((s) => PopupMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 12)))).toList(),
              ),
            const SizedBox(width: 2),
            SizedBox(
              width: 80,
              child: TextField(
                controller: app.shotCtrl,
                style: const TextStyle(fontSize: 12),
                decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2), border: OutlineInputBorder()),
                onSubmitted: (_) => app.startRefresh(),
              ),
            ),
            const SizedBox(width: 4),
            _btn(context, 'Apply', () => app.startRefresh()),
            _btn(context, 'Prev', () { final cur = app.shotCtrl.text.trim().isNotEmpty ? app.shotCtrl.text.trim() : app.shotText; final s = int.tryParse(cur); if (s != null) { app.shotText = (s - 1).toString(); app.startRefresh(); } }),
            _btn(context, 'Next', () { final cur = app.shotCtrl.text.trim().isNotEmpty ? app.shotCtrl.text.trim() : app.shotText; final s = int.tryParse(cur); if (s != null) { app.shotText = (s + 1).toString(); app.startRefresh(); } }),
            _btn(context, 'Latest', () async => app.fetchLatestShot()),
            const SizedBox(width: 8),
            _modeBtn(context, 'Zoom/Move', app.interactionMode == 0, () => app.interactionMode = 0),
            _modeBtn(context, 'Point', app.interactionMode == 1, () => app.interactionMode = 1),
          ]),
        ],
      ),
    );
  }

  Widget _settingsMenu(BuildContext ctx, AppState app) {
    return PopupMenuButton<String>(
      tooltip: 'Settings',
      icon: Icon(Icons.settings, size: 18, color: Theme.of(ctx).colorScheme.onSurface),
      onSelected: (v) {
        switch (v) {
          case 'web': _showWebBookmarks(ctx, app); break;
          case 'layout': _showLayoutSetup(ctx, app); break;
          case 'fonts': _showFontDialog(ctx, app); break;
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'web', child: Text('Internal web pages')),
        const PopupMenuItem(value: 'layout', child: Text('Layout setup')),
        const PopupMenuItem(value: 'fonts', child: Text('Customize fonts')),
      ],
    );
  }

  void _showWebBookmarks(BuildContext ctx, AppState app) {
    final bookmarks = app.webBookmarks;
    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => AlertDialog(
        title: const Text('Internal Web Pages'),
        content: SizedBox(width: 400, height: 300,
          child: bookmarks.isEmpty
              ? const Center(child: Text('No Saved Web Addresses', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: bookmarks.length,
                  itemBuilder: (_, i) => ListTile(
                    title: Text(bookmarks[i].keys.first),
                    subtitle: Text(bookmarks[i].values.first, style: const TextStyle(fontSize: 11)),
                    onTap: () { Navigator.pop(ctx); _openUrl(bookmarks[i].values.first, app); },
                  ),
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          TextButton(onPressed: () { _addBookmark(ctx, app, setState); }, child: const Text('Add...')),
          if (bookmarks.isNotEmpty)
            TextButton(onPressed: () { _removeBookmark(ctx, app, setState); }, child: const Text('Remove...')),
        ],
      )),
    );
  }

  void _addBookmark(BuildContext ctx, AppState app, void Function(VoidCallback) setState) {
    final aliasCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    showDialog(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Web Bookmark'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: aliasCtrl, decoration: const InputDecoration(labelText: 'Alias')),
          const SizedBox(height: 8),
          TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: 'URL')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () {
            final alias = aliasCtrl.text.trim();
            final url = urlCtrl.text.trim();
            if (alias.isNotEmpty && url.isNotEmpty) {
              app.addWebBookmark(alias, url);
              Navigator.pop(ctx);
              setState(() {});
            }
          }, child: const Text('Add')),
        ],
      ),
    );
  }

  void _removeBookmark(BuildContext ctx, AppState app, void Function(VoidCallback) setState) {
    final bookmarks = app.webBookmarks;
    showDialog(
      context: ctx,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Bookmark'),
        content: SizedBox(width: 300, height: 200,
          child: ListView.builder(
            itemCount: bookmarks.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(bookmarks[i].keys.first),
              onTap: () { app.removeWebBookmark(i); Navigator.pop(ctx); setState(() {}); },
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
      ),
    );
  }

  void _openUrl(String url, AppState app) {
    var finalUrl = url;
    // Route through SSH tunnel if connected (matching C++ behaviour)
    if (app.sshConnected && app.sshHost.isNotEmpty) {
      try {
        final settings = jsonEncode({
          'host': app.sshHost, 'port': app.sshPort,
          'user': app.sshUser, 'password': app.sshPass,
          'identity_file': app.sshIdentity, 'mode': 2,
        });
        final prepared = RustBridge.instance.prepareUrl(url, settings);
        if (prepared.startsWith('http') && !prepared.contains('"error"')) {
          finalUrl = prepared;
        }
      } catch (_) {}
    }
    if (Platform.isMacOS) {
      Process.run('open', [finalUrl]);
    } else if (Platform.isWindows) {
      Process.run('start', [finalUrl], runInShell: true);
    } else {
      Process.run('xdg-open', [finalUrl]);
    }
  }

  void _showLayoutSetup(BuildContext ctx, AppState app) {
    var layout = app.columns.map((col) => col.length).toList();
    if (layout.isEmpty) layout = [1];
    var selectedCol = -1, selectedRow = -1;

    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => AlertDialog(
        title: Row(children: [
          const Text('Layout Setup'),
          const Spacer(),
          IconButton(icon: const Icon(Icons.add, size: 18), tooltip: 'Add Panel After Selected', onPressed: () {
            if (selectedCol >= 0 && selectedCol < layout.length && selectedRow >= 0 && selectedRow < layout[selectedCol]) {
              layout[selectedCol] = layout[selectedCol] + 1;
              setState(() {});
            }
          }),
        ]),
        content: SizedBox(
          width: (layout.length * 120.0 + 16).clamp(200.0, 700.0),
          height: (layout.reduce((a, b) => a > b ? a : b) * 90.0 + 16).clamp(100.0, 500.0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(
              child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (var c = 0; c < layout.length; c++) ...[
                  if (c > 0) const VerticalDivider(width: 1),
                  Column(mainAxisSize: MainAxisSize.min, children: [
                    // Column header with delete button
                    SizedBox(height: 28, child: Center(child: Text('Col ${c + 1}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)))),
                    for (var r = 0; r < layout[c]; r++)
                      GestureDetector(
                        onTap: () => setState(() { selectedCol = c; selectedRow = r; }),
                        child: Container(
                          width: 110, height: 80, margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border.all(color: selectedCol == c && selectedRow == r ? Theme.of(ctx).colorScheme.primary : Colors.grey.shade400, width: selectedCol == c && selectedRow == r ? 2 : 1),
                            borderRadius: BorderRadius.circular(4),
                            color: Theme.of(ctx).colorScheme.primaryContainer.withValues(alpha: 0.3),
                          ),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('Panel ${_panelIndex(app, c, r) + 1}', style: TextStyle(fontSize: 10, color: Theme.of(ctx).colorScheme.onSurface.withValues(alpha: 0.7))),
                            if (selectedCol == c && selectedRow == r)
                              TextButton(onPressed: () {
                                if (layout.length == 1 && layout[0] == 1) return; // keep at least 1
                                layout[c] = layout[c] - 1;
                                if (layout[c] <= 0) layout.removeAt(c);
                                selectedCol = -1; selectedRow = -1;
                                setState(() {});
                              }, child: const Text('Delete', style: TextStyle(fontSize: 9))),
                          ]),
                        ),
                      ),
                    // Add panel button at bottom of column
                    TextButton(onPressed: () {
                      layout[c] = layout[c] + 1;
                      setState(() {});
                    }, child: const Text('+ Add', style: TextStyle(fontSize: 10))),
                  ]),
                ],
                const SizedBox(width: 8),
                // Add column button
                Column(children: [
                  const SizedBox(height: 28),
                  TextButton(onPressed: () { layout.add(1); setState(() {}); }, child: const Text('+ Col', style: TextStyle(fontSize: 10))),
                ]),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () {
            final cols = layout.where((n) => n > 0).toList();
            if (cols.isNotEmpty) { app.applyLayoutList(cols); app.startRefresh(); }
            Navigator.pop(ctx);
          }, child: const Text('Apply')),
        ],
      )),
    );
  }

  int _panelIndex(AppState app, int col, int row) {
    var idx = 0;
    for (var c = 0; c < col; c++) {
      idx += app.columns.length > c ? app.columns[c].length : 0;
    }
    return idx + row;
  }

  void _showFontDialog(BuildContext ctx, AppState app) {
    var fontFamily = app.fontFamily;
    var legendSize = app.fontLegendSize;
    var axisSize = app.fontAxisSize;
    var unitSize = app.fontUnitSize;
    var uiSize = app.fontUiSize;
    const families = ['System', 'Arial', 'Helvetica', 'Times New Roman', 'Courier New', 'Georgia', 'Verdana', 'Monaco'];
    showDialog(
      context: ctx,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setState) => AlertDialog(
        title: const Text('Customize Fonts'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            const SizedBox(width: 100, child: Text('Font')),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: families.contains(fontFamily) ? fontFamily : 'System',
                isDense: true,
                decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4), border: OutlineInputBorder()),
                items: families.map((f) => DropdownMenuItem(value: f, child: Text(f, style: TextStyle(fontSize: 12, fontFamily: f == 'System' ? null : f)))).toList(),
                onChanged: (v) { if (v != null) setState(() => fontFamily = v); },
              ),
            ),
          ]),
          const SizedBox(height: 8),
          _fontRow('Legend size', legendSize, (v) => setState(() => legendSize = v)),
          _fontRow('Axis size', axisSize, (v) => setState(() => axisSize = v)),
          _fontRow('Unit size', unitSize, (v) => setState(() => unitSize = v)),
          _fontRow('UI size', uiSize, (v) => setState(() => uiSize = v)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () { app.applyFontSettings(fontFamily, legendSize, axisSize, unitSize, uiSize); Navigator.pop(ctx); }, child: const Text('OK')),
        ],
      )),
    );
  }

  Widget _fontRow(String label, int value, void Function(int) onChanged) {
    return Row(children: [
      SizedBox(width: 100, child: Text(label)),
      IconButton(icon: const Icon(Icons.remove, size: 16), onPressed: value > 6 ? () => onChanged(value - 1) : null),
      SizedBox(width: 30, child: Text('$value', textAlign: TextAlign.center)),
      IconButton(icon: const Icon(Icons.add, size: 16), onPressed: value < 28 ? () => onChanged(value + 1) : null),
    ]);
  }

  Widget _btn(BuildContext ctx, String label, VoidCallback onTap) {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ElevatedButton(onPressed: onTap,
        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, textStyle: const TextStyle(fontSize: 12)),
        child: Text(label)));
  }

  Widget _modeBtn(BuildContext ctx, String label, bool active, VoidCallback onTap) {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 2),
      child: OutlinedButton(onPressed: onTap,
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, textStyle: TextStyle(fontSize: 12, fontWeight: active ? FontWeight.bold : FontWeight.normal), backgroundColor: active ? Theme.of(ctx).colorScheme.primaryContainer : null),
        child: Text(label)));
  }

  Widget _sshBtn(BuildContext ctx, AppState app) {
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ElevatedButton(onPressed: () => SshDialog.show(ctx),
        style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, textStyle: TextStyle(fontSize: 12, color: app.sshConnected ? Colors.green : null)),
        child: const Text('SSH')));
  }

  Widget _themeBtns(BuildContext ctx, AppState app) {
    return Row(children: [
      _themeBtn(ctx, 'Auto', app.themeMode == 2, () => app.themeMode = 2),
      _themeBtn(ctx, 'Light', app.themeMode == 0, () => app.themeMode = 0),
      _themeBtn(ctx, 'Dark', app.themeMode == 1, () => app.themeMode = 1),
    ]);
  }

  Widget _themeBtn(BuildContext ctx, String label, bool active, VoidCallback onTap) {
    final theme = Theme.of(ctx);
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 1),
      child: OutlinedButton(onPressed: onTap,
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, textStyle: TextStyle(fontSize: 11, fontWeight: active ? FontWeight.bold : FontWeight.normal, color: active ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurface), backgroundColor: active ? theme.colorScheme.primaryContainer : null),
        child: Text(label)));
  }
}
