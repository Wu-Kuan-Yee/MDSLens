import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import 'dialogs/login.dart';
import 'dialogs/ssh.dart';

class ToolbarWidget extends StatelessWidget {
  const ToolbarWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
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
            if (app.shotInfoIp.isNotEmpty) Text('Ip:${app.shotInfoIp}', style: const TextStyle(fontSize: 11)),
            if (app.shotInfoPulse.isNotEmpty) Text(' Pulse:${app.shotInfoPulse}', style: const TextStyle(fontSize: 11)),
            if (app.shotInfoIt.isNotEmpty) Text(' It:${app.shotInfoIt}', style: const TextStyle(fontSize: 11)),
            const Spacer(),
            _themeBtns(context, app),
            const SizedBox(width: 8),
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
            _btn(context, 'Prev', () { final s = int.tryParse(app.shotText); if (s != null) { app.shotText = (s - 1).toString(); app.startRefresh(); } }),
            _btn(context, 'Next', () { final s = int.tryParse(app.shotText); if (s != null) { app.shotText = (s + 1).toString(); app.startRefresh(); } }),
            _btn(context, 'Latest', () async => app.fetchLatestShot()),
            const SizedBox(width: 8),
            _modeBtn(context, 'Zoom/Move', app.interactionMode == 0, () => app.interactionMode = 0),
            _modeBtn(context, 'Point', app.interactionMode == 1, () => app.interactionMode = 1),
          ]),
        ],
      ),
    );
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
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 1),
      child: OutlinedButton(onPressed: onTap,
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap, textStyle: TextStyle(fontSize: 11, color: active ? Theme.of(ctx).colorScheme.primary : null), backgroundColor: active ? Theme.of(ctx).colorScheme.primaryContainer.withValues(alpha: 0.3) : null),
        child: Text(label)));
  }
}
