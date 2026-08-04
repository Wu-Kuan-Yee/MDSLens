import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/app_state.dart';
import '../../services/external_url_launcher.dart';
import '../../services/runtime_build_info.dart';
import '../../services/update_installer.dart';
import '../../services/update_service.dart';
import 'keyboard_safe_dialog.dart';

typedef ReleaseUpdateChecker = Future<ReleaseUpdate> Function();
typedef ReleaseUpdateInstaller = Future<UpdateInstallResult> Function(
  ReleaseUpdate release,
  RuntimeSystemInfo systemInfo, {
  required UpdateDownloadController controller,
  UpdateProgressCallback? onProgress,
});
typedef ApplicationExitRequester = Future<void> Function();

enum _UpdateChoice { release, direct }

Future<_UpdateChoice?> _showUpdateChoiceDialog(
  BuildContext context,
  ReleaseUpdate result, {
  bool? directUpdateSupportOverride,
}) {
  final supportsDirectUpdate =
      (directUpdateSupportOverride ?? directUpdateSupported) &&
          result.assetNamed('update-manifest.json') != null;
  return showDialog<_UpdateChoice>(
    context: context,
    builder: (context) => KeyboardSafeDialog(
      title: const Text('Update Available'),
      content: Text(
        supportsDirectUpdate
            ? 'MDSLens ${result.latestVersion} is available. You can download the correct package for this device or inspect the release first.'
            : 'MDSLens ${result.latestVersion} is available. Open the release page?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Not Now'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, _UpdateChoice.release),
          child: const Text('View Details'),
        ),
        if (supportsDirectUpdate)
          FilledButton.icon(
            key: const ValueKey('install-update-directly'),
            onPressed: () => Navigator.pop(context, _UpdateChoice.direct),
            icon: const Icon(Icons.system_update_alt_rounded),
            label: Text(directUpdateActionLabel),
          ),
      ],
    ),
  );
}

Future<void> _showUpdateDownloadDialog(
  BuildContext context,
  ReleaseUpdate release, {
  ReleaseUpdateInstaller? updateInstaller,
  RuntimeSystemInfo? systemInfo,
  RuntimeSystemInfoLoader? systemInfoLoader,
  ExternalUriOpener? urlOpener,
  ApplicationExitRequester? applicationExitRequester,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpdateDownloadDialog(
      release: release,
      updateInstaller: updateInstaller,
      systemInfo: systemInfo,
      systemInfoLoader: systemInfoLoader,
      urlOpener: urlOpener,
      applicationExitRequester: applicationExitRequester,
    ),
  );
}

class _UpdateDownloadDialog extends StatefulWidget {
  const _UpdateDownloadDialog({
    required this.release,
    this.updateInstaller,
    this.systemInfo,
    this.systemInfoLoader,
    this.urlOpener,
    this.applicationExitRequester,
  });

  final ReleaseUpdate release;
  final ReleaseUpdateInstaller? updateInstaller;
  final RuntimeSystemInfo? systemInfo;
  final RuntimeSystemInfoLoader? systemInfoLoader;
  final ExternalUriOpener? urlOpener;
  final ApplicationExitRequester? applicationExitRequester;

  @override
  State<_UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<_UpdateDownloadDialog> {
  final _controller = UpdateDownloadController();
  UpdateDownloadProgress? _progress;
  String _status = 'Preparing a secure download...';
  bool _running = true;
  bool _failed = false;
  bool _dismissed = false;
  bool _canCancel = true;
  bool _allowRouteExit = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_installUpdate());
    });
  }

  @override
  void dispose() {
    _controller.cancel();
    super.dispose();
  }

  Future<void> _installUpdate() async {
    try {
      final systemInfo = widget.systemInfo ??
          await (widget.systemInfoLoader ?? loadRuntimeSystemInfo)();
      if (!mounted || _controller.isCancelled) return;
      final result =
          await (widget.updateInstaller ?? installLatestReleaseUpdate)(
        widget.release,
        systemInfo,
        controller: _controller,
        onProgress: (progress) {
          if (!mounted || _controller.isCancelled) return;
          setState(() {
            _progress = progress;
            final fraction = progress.fraction;
            if (fraction != null && fraction >= 1) _canCancel = false;
            _status = fraction == null
                ? 'Downloading the update...'
                : fraction >= 1
                    ? 'Verifying and preparing the update...'
                    : 'Downloading ${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _running = false;
        _failed = result.status == UpdateLaunchStatus.unsupported;
        _status = result.message;
        if (!result.closeApplication) _allowRouteExit = true;
      });
      if (result.closeApplication) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await (widget.applicationExitRequester ??
            requestApplicationExitForUpdate)();
        if (mounted) setState(() => _allowRouteExit = true);
      }
    } on UpdateCancelledException {
      if (mounted && !_dismissed) {
        _dismissed = true;
        setState(() => _allowRouteExit = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).pop();
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _failed = true;
        _allowRouteExit = true;
        final detail = switch (error) {
          PlatformException(message: final message?)
              when message.trim().isNotEmpty =>
            message.trim(),
          FormatException(message: final message) when message.isNotEmpty =>
            message,
          _ => '',
        };
        _status = detail.isEmpty
            ? 'The update could not be downloaded, verified, or handed to the system installer. No unverified package was opened.'
            : 'The update was not installed. $detail';
      });
    }
  }

  void _cancelDownload() {
    if (!_running || !_canCancel) return;
    _dismissed = true;
    _controller.cancel();
    setState(() => _allowRouteExit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _openRelease() async {
    await openExternalWebUrl(
      widget.release.releaseUrl,
      opener: widget.urlOpener,
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kib = bytes / 1024;
    if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
    final mib = kib / 1024;
    if (mib < 1024) return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
    final gib = mib / 1024;
    return '${gib.toStringAsFixed(gib < 10 ? 1 : 0)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = _progress?.fraction;
    final progress = _progress;
    final icon = _failed
        ? Icons.error_outline_rounded
        : _running
            ? Icons.downloading_rounded
            : Icons.check_circle_outline_rounded;
    final accent = _failed
        ? theme.colorScheme.error
        : _running
            ? theme.colorScheme.primary
            : theme.colorScheme.tertiary;

    return PopScope(
      canPop: _allowRouteExit,
      child: KeyboardSafeDialog(
        key: const ValueKey('update-download-dialog'),
        maxWidth: 480,
        title: Row(
          children: [
            Icon(Icons.system_update_alt_rounded, color: accent),
            const SizedBox(width: 10),
            const Expanded(child: Text('MDSLens Update')),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(icon, color: accent, size: 34),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _running
                  ? 'Downloading ${widget.release.latestVersion}'
                  : _failed
                      ? 'Update could not be completed'
                      : 'Update is ready',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _status,
              textAlign: TextAlign.center,
              softWrap: true,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (_running) ...[
              const SizedBox(height: 20),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  key: const ValueKey('update-download-progress'),
                  value: fraction,
                  minHeight: 9,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      progress == null
                          ? 'Connecting securely...'
                          : progress.total > 0
                              ? '${_formatBytes(progress.received)} of ${_formatBytes(progress.total)}'
                              : _formatBytes(progress.received),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (fraction != null)
                    Text(
                      '${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: accent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.verified_user_outlined,
                    size: 16,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'The package is verified before it is opened.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          if (_running && _canCancel)
            OutlinedButton.icon(
              key: const ValueKey('cancel-update-download'),
              onPressed: _cancelDownload,
              icon: const Icon(Icons.close_rounded),
              label: const Text('Cancel download'),
            )
          else if (!_allowRouteExit)
            FilledButton.icon(
              onPressed: null,
              icon: const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              label: const Text('Finishing update...'),
            )
          else ...[
            TextButton.icon(
              onPressed: _openRelease,
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('View Details'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ],
      ),
    );
  }
}

class AboutDialogWidget extends StatefulWidget {
  final ExternalUriOpener? urlOpener;
  final ReleaseUpdateChecker? updateChecker;
  final ReleaseUpdateInstaller? updateInstaller;
  final RuntimeSystemInfoLoader? systemInfoLoader;
  final AppVersionLoader? versionLoader;
  final GitVersionLoader? gitVersionLoader;
  final ApplicationExitRequester? applicationExitRequester;
  final bool? directUpdateSupportOverride;

  const AboutDialogWidget({
    super.key,
    this.urlOpener,
    this.updateChecker,
    this.updateInstaller,
    this.systemInfoLoader,
    this.versionLoader,
    this.gitVersionLoader,
    this.applicationExitRequester,
    this.directUpdateSupportOverride,
  });

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => const AboutDialogWidget(),
    );
  }

  static Future<void> checkAutomatically(
    BuildContext context, {
    ExternalUriOpener? urlOpener,
    ReleaseUpdateChecker? updateChecker,
    ReleaseUpdateInstaller? updateInstaller,
    RuntimeSystemInfoLoader? systemInfoLoader,
    AppVersionLoader? versionLoader,
    GitVersionLoader? gitVersionLoader,
    ApplicationExitRequester? applicationExitRequester,
    bool? directUpdateSupportOverride,
    Future<void> Function(Duration duration)? retryWaiter,
    List<Duration> retryDelays = const [
      Duration(seconds: 3),
      Duration(seconds: 15),
    ],
  }) async {
    ReleaseUpdate? result;
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      try {
        final currentVersion = await (versionLoader ?? loadMDSLensVersion)();
        result = await (updateChecker != null
            ? updateChecker()
            : checkLatestMDSLensRelease(currentVersion));
        break;
      } catch (_) {
        if (attempt >= retryDelays.length) return;
        await (retryWaiter != null
            ? retryWaiter(retryDelays[attempt])
            : Future<void>.delayed(retryDelays[attempt]));
        if (!context.mounted) return;
      }
    }
    if (!context.mounted || result == null || !result.updateAvailable) return;
    final choice = await _showUpdateChoiceDialog(
      context,
      result,
      directUpdateSupportOverride: directUpdateSupportOverride,
    );
    if (!context.mounted) return;
    if (choice == _UpdateChoice.release) {
      await openExternalWebUrl(result.releaseUrl, opener: urlOpener);
    } else if (choice == _UpdateChoice.direct) {
      await _showUpdateDownloadDialog(
        context,
        result,
        updateInstaller: updateInstaller,
        systemInfoLoader: systemInfoLoader,
        urlOpener: urlOpener,
        applicationExitRequester: applicationExitRequester,
      );
    }
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
      final choice = await _showUpdateChoiceDialog(
        context,
        result,
        directUpdateSupportOverride: widget.directUpdateSupportOverride,
      );
      if (choice == _UpdateChoice.release) {
        await _openUrl(result.releaseUrl);
      } else if (choice == _UpdateChoice.direct) {
        await _installUpdate(result);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkingUpdate = false;
        _updateStatus = 'Could not check for updates';
      });
      final openReleases = await showDialog<bool>(
        context: context,
        builder: (context) => KeyboardSafeDialog(
          title: const Text('Update Check Failed'),
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

  Future<void> _installUpdate(ReleaseUpdate release) async {
    await _showUpdateDownloadDialog(
      context,
      release,
      updateInstaller: widget.updateInstaller,
      systemInfo: _systemInfo,
      urlOpener: widget.urlOpener,
      applicationExitRequester: widget.applicationExitRequester,
    );
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
    final app = context.watch<AppState?>();
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
                                    'Cross-platform rewrite written with Flutter and Rust from the original',
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
                  if (app != null) ...[
                    Material(
                      color: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      shape: RoundedRectangleBorder(
                        side: BorderSide(color: theme.dividerColor),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: CheckboxListTile(
                        key: const ValueKey('about-auto-update-check'),
                        value: app.autoCheckUpdates,
                        onChanged: (value) =>
                            app.setAutoCheckUpdates(value ?? false),
                        secondary: Icon(
                          Icons.update_rounded,
                          color: theme.colorScheme.primary,
                        ),
                        title: const Text('Check For Updates Automatically'),
                        subtitle: const Text(
                          'Check quietly when MDSLens starts.',
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final updateButton = OutlinedButton(
                        onPressed: _checkingUpdate ? null : _checkUpdate,
                        child: Text(
                          _checkingUpdate ? 'Checking...' : 'Update',
                        ),
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
