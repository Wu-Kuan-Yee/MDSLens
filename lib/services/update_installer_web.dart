import 'package:web/web.dart' as web;

import 'runtime_build_info.dart';
import 'update_installer_models.dart';
import 'update_service.dart';

bool get directUpdateSupported => true;
String get directUpdateActionLabel => 'Reload Now';

Future<void> requestApplicationExitForUpdate() async {}

Future<UpdateInstallResult> installLatestReleaseUpdate(
  ReleaseUpdate release,
  RuntimeSystemInfo systemInfo, {
  required UpdateDownloadController controller,
  UpdateProgressCallback? onProgress,
  Object? client,
  Object? downloadDirectory,
  Object? launcher,
  Object? manifestLoader,
  String? platformOverride,
  String? architectureOverride,
  String? linuxFormatOverride,
}) async {
  web.window.location.reload();
  return const UpdateInstallResult(
    status: UpdateLaunchStatus.reloaded,
    message: 'Reload the page to use the latest Web release.',
  );
}
