import 'package:web/web.dart' as web;

import 'runtime_build_info.dart';
import 'update_installer_models.dart';
import 'update_service.dart';

// Reloading refreshes browser resources, but it cannot replace the Web Gateway
// deployed by the server administrator. Web builds still detect new releases
// and offer View Details without claiming to perform an application update.
bool get directUpdateSupported => false;
String get directUpdateActionLabel => 'View Details';

Future<void> requestApplicationExitForUpdate() async {}

Future<void> scheduleLinuxPortableRollbackCleanup({
  String? platformOverride,
  String? currentExecutableOverride,
  Duration stabilityWindow = const Duration(seconds: 60),
}) async {}

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
