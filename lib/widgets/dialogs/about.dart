import 'package:flutter/material.dart';

import '../../services/external_url_launcher.dart';
import '../../services/runtime_build_info.dart';
import '../../services/update_service.dart';
import 'keyboard_safe_dialog.dart';

typedef ReleaseUpdateChecker = Future<ReleaseUpdate> Function();

class AboutDialogWidget extends StatefulWidget {
  final ExternalUriOpener? urlOpener;
  final ReleaseUpdateChecker? updateChecker;
  final RuntimeSystemInfoLoader? systemInfoLoader;
  final AppVersionLoader? versionLoader;
  final GitVersionLoader? gitVersionLoader;

  const AboutDialogWidget({
    super.key,
    this.urlOpener,
    this.updateChecker,
    this.systemInfoLoader,
    this.versionLoader,
    this.gitVersionLoader,
  });

  static void show(BuildContext context) {
    showDialog(context: context, builder: (ctx) => const AboutDialogWidget());
  }

  @override
  State<AboutDialogWidget> createState() => _AboutDialogWidgetState();
}

class _AboutDialogWidgetState extends State<AboutDialogWidget> {
  String _updateStatus = '';
  bool _checkingUpdate = false;
  late RuntimeSystemInfo _systemInfo;
  String _mdsLensVersion = 'Loading...';
  String _gitVersion = 'Loading...';

  @override
  void initState() {
    super.initState();
    _systemInfo = RuntimeSystemInfo.fallback();
    _loadBuildInformation();
  }

  Future<void> _loadBuildInformation() async {
    final values = await Future.wait<Object>([
      (widget.systemInfoLoader ?? loadRuntimeSystemInfo)(),
      (widget.versionLoader ?? loadMDSLensVersion)(),
      (widget.gitVersionLoader ?? loadMDSLensGitVersion)(),
    ]);
    if (!mounted) return;
    setState(() {
      _systemInfo = values[0] as RuntimeSystemInfo;
      _mdsLensVersion = values[1] as String;
      _gitVersion = values[2] as String;
    });
  }

  Future<bool> _openUrl(String url) async {
    final opened = await openExternalWebUrl(url, opener: widget.urlOpener);
    if (!opened && mounted) {
      setState(() => _updateStatus = 'Could not open the default browser');
    }
    return opened;
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() {
      _checkingUpdate = true;
      _updateStatus = 'Checking for updates...';
    });
    try {
      final result = await (widget.updateChecker != null
          ? widget.updateChecker!()
          : checkLatestMDSLensRelease(_mdsLensVersion));
      if (!mounted) return;
      if (!result.updateAvailable) {
        setState(() {
          _checkingUpdate = false;
          _updateStatus = 'MDSLens $_mdsLensVersion is up to date';
        });
        return;
      }
      setState(() {
        _checkingUpdate = false;
        _updateStatus = '${result.latestVersion} is available';
      });
      final openRelease = await showDialog<bool>(
        context: context,
        builder: (context) => KeyboardSafeDialog(
          title: const Text('Update available'),
          content: Text(
            'MDSLens ${result.latestVersion} is available. Open the release page?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Release'),
            ),
          ],
        ),
      );
      if (openRelease == true) await _openUrl(result.releaseUrl);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkingUpdate = false;
        _updateStatus = 'Could not check for updates';
      });
      final openReleases = await showDialog<bool>(
        context: context,
        builder: (context) => KeyboardSafeDialog(
          title: const Text('Update check failed'),
          content: const Text(
            'The latest version could not be checked. You can still open the releases page.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Releases'),
            ),
          ],
        ),
      );
      if (openReleases == true) await _openUrl(mdsLensReleasesUrl);
    }
  }

  Widget _buildLink(String label, String url) {
    final style = Theme.of(context).textTheme.bodySmall;
    return InkWell(
      onTap: () => _openUrl(url),
      borderRadius: BorderRadius.circular(3),
      child: Text(
        label,
        softWrap: true,
        style: style?.copyWith(
          color: const Color(0xFF2563EB),
          fontWeight: FontWeight.bold,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }

  Widget _buildRow(String name, Widget valueWidget, {bool showBorder = true}) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final label = Text(
                name,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              );
              if (constraints.maxWidth < 390) {
                return Column(
                  key: ValueKey('about-row-narrow-$name'),
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Center(child: label),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.center,
                      widthFactor: 1,
                      child: valueWidget,
                    ),
                  ],
                );
              }
              return Row(
                key: ValueKey('about-row-wide-$name'),
                children: [
                  label,
                  const SizedBox(width: 16),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: valueWidget,
                    ),
                  ),
                ],
              );
            },
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

  TextStyle? _valueStyle(BuildContext context) {
    return Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final maxHeight = (screenSize.height - 32).clamp(240.0, 720.0);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SizedBox(
          width: 540,
          child: AdaptiveTwoAxisScrollView(
            keyPrefix: 'about-dialog',
            enableHorizontal: screenSize.width < 360,
            enableVertical: true,
            showHorizontalScrollbar: screenSize.width < 360,
            showVerticalScrollbar: screenSize.height < 480,
            minContentWidth: 320,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      border: Border.all(color: theme.dividerColor),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Image.asset(
                            'assets/app_icon.png',
                            width: 52,
                            height: 52,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                Icons.show_chart_rounded,
                                size: 34,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'MDSLens',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'Signal data plotting for MDSplus experiments.',
                                softWrap: true,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 3,
                                runSpacing: 3,
                                children: [
                                  Text(
                                    'Independent cross-platform application built with Flutter and Rust, based on the original',
                                    softWrap: true,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                  _buildLink(
                                    'MdsScope project',
                                    originalMdsScopeRepositoryUrl,
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      border: Border.all(color: theme.dividerColor),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      children: [
                        _buildRow(
                          'MDSLens Version',
                          Text(_mdsLensVersion, style: _valueStyle(context)),
                        ),
                        _buildRow(
                          'Git Version',
                          Text(_gitVersion, style: _valueStyle(context)),
                        ),
                        _buildRow(
                          'Framework & Engine',
                          Text(
                            'Flutter & Rust FFI (libmds_bridge)',
                            style: _valueStyle(context),
                            softWrap: true,
                          ),
                        ),
                        _buildRow(
                          'Runtime System',
                          Text(
                            _systemInfo.displayText,
                            style: _valueStyle(context),
                            softWrap: true,
                          ),
                        ),
                        _buildRow(
                          'Copyright',
                          Wrap(
                            spacing: 3,
                            runSpacing: 3,
                            children: [
                              Text(
                                'Copyright (C) 2026',
                                style: _valueStyle(context),
                              ),
                              _buildLink('Pingzhong Wu', mdsLensMaintainerUrl),
                            ],
                          ),
                        ),
                        _buildRow(
                          'License',
                          _buildLink(
                            'GPL-3.0-or-later',
                            'https://www.gnu.org/licenses/gpl-3.0.html',
                          ),
                        ),
                        _buildRow(
                          'Source',
                          _buildLink('GitHub', mdsLensSourceUrl),
                          showBorder: false,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final updateButton = OutlinedButton(
                        onPressed: _checkingUpdate ? null : _checkUpdate,
                        child: Text(_checkingUpdate ? 'Checking...' : 'Update'),
                      );
                      final closeButton = FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      );
                      final status = Text(
                        _updateStatus,
                        softWrap: true,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      );
                      if (constraints.maxWidth < 390) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            updateButton,
                            if (_updateStatus.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              status,
                            ],
                            const SizedBox(height: 8),
                            closeButton,
                          ],
                        );
                      }
                      return Row(
                        children: [
                          updateButton,
                          const SizedBox(width: 8),
                          Expanded(child: status),
                          closeButton,
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
