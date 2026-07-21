import 'dart:io';
import 'package:flutter/material.dart';

class AboutDialogWidget extends StatefulWidget {
  const AboutDialogWidget({super.key});

  static void show(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => const AboutDialogWidget(),
    );
  }

  @override
  State<AboutDialogWidget> createState() => _AboutDialogWidgetState();
}

class _AboutDialogWidgetState extends State<AboutDialogWidget> {
  String _updateStatus = '';
  bool _checkingUpdate = false;

  void _openUrl(String url) {
    if (Platform.isMacOS) {
      Process.run('open', [url]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [url]);
    } else if (Platform.isWindows) {
      Process.run('cmd', ['/c', 'start', '', url]);
    }
  }

  void _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
      _updateStatus = 'Checking for updates...';
    });
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    setState(() {
      _checkingUpdate = false;
      _updateStatus = 'You are running the latest version (v3.0.0)';
    });
    _openUrl('https://github.com/wwktz/MdsScope/releases');
  }

  Widget _buildLink(String label, String url) {
    return InkWell(
      onTap: () => _openUrl(url),
      borderRadius: BorderRadius.circular(3),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF2563EB),
          fontWeight: FontWeight.bold,
          decoration: TextDecoration.underline,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildRow(String name, Widget valueWidget, {bool showBorder = true, required BuildContext context}) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 16),
              Flexible(child: valueWidget),
            ],
          ),
        ),
        if (showBorder)
          Divider(
            height: 1,
            thickness: 1,
            color: theme.dividerColor.withValues(alpha: 0.5),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sysText = '${Platform.operatingSystem} (${Platform.operatingSystemVersion.split(' ').first})';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Container(
        width: 540,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header Card
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      Icons.show_chart_rounded,
                      size: 34,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MdsScope',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Signal data plotting for MDSplus experiments.',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Info Card
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  _buildRow('MdsScope Version', const Text('3.0.0', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), context: context),
                  _buildRow('Git Version', const Text('v3.0.0-flutter', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), context: context),
                  _buildRow('Framework & Engine', const Text('Flutter Desktop & Rust FFI (libmds_bridge)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)), context: context),
                  _buildRow('System', Text(sysText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis), context: context),
                  _buildRow(
                    'Copyright',
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Copyright (C) 2026 ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        _buildLink('Weikang Wang', 'https://github.com/wwktz'),
                      ],
                    ),
                    context: context,
                  ),
                  _buildRow('License', _buildLink('GPL-3.0-or-later', 'https://www.gnu.org/licenses/gpl-3.0.html'), context: context),
                  _buildRow('Source', _buildLink('GitHub', 'https://github.com/wwktz/MdsScope'), showBorder: false, context: context),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Footer
            Row(
              children: [
                OutlinedButton(
                  onPressed: _checkUpdate,
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  child: const Text('Update', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _updateStatus,
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  style: ElevatedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  ),
                  child: const Text('Close', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
