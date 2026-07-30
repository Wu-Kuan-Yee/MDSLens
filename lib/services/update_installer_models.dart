import 'update_service.dart';

class UpdateDownloadController {
  bool _cancelled = false;
  void Function()? _cancelActiveOperation;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    _cancelActiveOperation?.call();
  }

  void bind(void Function() cancelActiveOperation) {
    _cancelActiveOperation = cancelActiveOperation;
    if (_cancelled) cancelActiveOperation();
  }

  void unbind() {
    _cancelActiveOperation = null;
  }
}

class UpdateDownloadProgress {
  const UpdateDownloadProgress({required this.received, required this.total});

  final int received;
  final int total;

  double? get fraction => total <= 0 ? null : received / total;
}

class DownloadedUpdate {
  const DownloadedUpdate({required this.asset, required this.path});

  final UpdateManifestAsset asset;
  final String path;
}

enum UpdateLaunchStatus {
  launched,
  installed,
  permissionRequired,
  downloaded,
  reloaded,
  unsupported,
}

class UpdateInstallResult {
  const UpdateInstallResult({
    required this.status,
    required this.message,
    this.downloaded,
    this.closeApplication = false,
  });

  final UpdateLaunchStatus status;
  final String message;
  final DownloadedUpdate? downloaded;
  final bool closeApplication;
}

class UpdateCancelledException implements Exception {
  const UpdateCancelledException();

  @override
  String toString() => 'Update download cancelled';
}

typedef UpdateProgressCallback = void Function(UpdateDownloadProgress progress);
