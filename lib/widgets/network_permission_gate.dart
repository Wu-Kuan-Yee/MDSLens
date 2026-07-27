import 'dart:async';

import 'package:flutter/material.dart';

import '../models/app_state.dart';
import '../services/network_permission_service.dart';
import 'dialogs/keyboard_safe_dialog.dart';

enum _NetworkPermissionAction { cancel, settings, retry }

class NetworkPermissionGate extends StatefulWidget {
  const NetworkPermissionGate({
    required this.app,
    required this.child,
    this.enabled,
    this.requestOnStartup,
    super.key,
  });

  final AppState app;
  final Widget child;
  final bool? enabled;
  final bool? requestOnStartup;

  @override
  State<NetworkPermissionGate> createState() => _NetworkPermissionGateState();
}

class _NetworkPermissionGateState extends State<NetworkPermissionGate> {
  int _presentedRevision = 0;
  bool _dialogOpen = false;
  bool _promptScheduled = false;
  bool _startupRequestScheduled = false;

  bool get _enabled =>
      widget.enabled ??
      NetworkPermissionService.needsLocalNetworkPrivacyHandling;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_onAppChanged);
    _onAppChanged();
    _scheduleStartupRequest();
  }

  @override
  void didUpdateWidget(NetworkPermissionGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.app != widget.app) {
      oldWidget.app.removeListener(_onAppChanged);
      widget.app.addListener(_onAppChanged);
      _presentedRevision = 0;
    }
    _onAppChanged();
  }

  @override
  void dispose() {
    widget.app.removeListener(_onAppChanged);
    super.dispose();
  }

  void _onAppChanged() {
    if (!_enabled || _dialogOpen || _promptScheduled) return;
    if (widget.app.networkPermissionFailureRevision <= _presentedRevision) {
      return;
    }
    _promptScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _promptScheduled = false;
      if (mounted) unawaited(_showPermissionPrompt());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _scheduleStartupRequest() {
    final shouldRequest =
        widget.requestOnStartup ??
        NetworkPermissionService.requestsLocalNetworkOnStartup;
    if (!shouldRequest || _startupRequestScheduled) return;
    _startupRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(NetworkPermissionService.requestInitialLocalNetworkAccess());
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _showPermissionPrompt() async {
    if (_dialogOpen ||
        widget.app.networkPermissionFailureRevision <= _presentedRevision) {
      return;
    }
    _dialogOpen = true;
    _presentedRevision = widget.app.networkPermissionFailureRevision;
    final details = widget.app.networkPermissionFailureDetails;
    final action = await showDialog<_NetworkPermissionAction>(
      context: context,
      builder: (dialogContext) => KeyboardSafeDialog(
        key: const ValueKey('network-permission-dialog'),
        title: const Row(
          children: [
            Icon(Icons.lan_outlined),
            SizedBox(width: 10),
            Expanded(child: Text('Local Network Access Required')),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MDSLens needs local network access to connect to your '
                  'MDSplus or SSH server. If access was denied, enable Local '
                  'Network for MDSLens in system settings, then retry.',
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  SelectableText(
                    details,
                    style: Theme.of(dialogContext).textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('network-permission-cancel'),
            onPressed: () =>
                Navigator.pop(dialogContext, _NetworkPermissionAction.cancel),
            child: const Text('Cancel'),
          ),
          OutlinedButton.icon(
            key: const ValueKey('network-permission-settings'),
            onPressed: () =>
                Navigator.pop(dialogContext, _NetworkPermissionAction.settings),
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Open Settings'),
          ),
          FilledButton.icon(
            key: const ValueKey('network-permission-retry'),
            onPressed: widget.app.canRetryNetworkOperation
                ? () => Navigator.pop(
                    dialogContext,
                    _NetworkPermissionAction.retry,
                  )
                : null,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
    _dialogOpen = false;
    if (!mounted) return;
    if (action == _NetworkPermissionAction.settings) {
      final opened = await NetworkPermissionService.openAppSettings();
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unable to open system settings automatically.'),
          ),
        );
      }
    } else if (action == _NetworkPermissionAction.retry) {
      try {
        await widget.app.retryLastNetworkOperation();
      } catch (_) {
        // AppState records the failure and schedules a fresh, actionable prompt.
      }
    }
    _onAppChanged();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
