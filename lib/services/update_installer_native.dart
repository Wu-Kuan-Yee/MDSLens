import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'runtime_build_info.dart';
import 'update_installer_models.dart';
import 'update_service.dart';

typedef UpdateAssetLauncher = Future<UpdateInstallResult> Function(
    DownloadedUpdate update);
typedef UpdateManifestLoader = Future<UpdateManifest> Function(
    ReleaseUpdate release);
typedef DetachedCommandLauncher = Future<void> Function(
    String executable, List<String> arguments);

const _updaterChannel = MethodChannel('mdslens/updater');

bool get directUpdateSupported {
  if (Platform.isLinux &&
      ((Platform.environment['FLATPAK_ID'] ?? '').isNotEmpty ||
          (Platform.environment['SNAP'] ?? '').isNotEmpty ||
          File('/.flatpak-info').existsSync())) {
    return false;
  }
  return Platform.isWindows ||
      Platform.isMacOS ||
      Platform.isLinux ||
      Platform.isAndroid;
}

String get directUpdateActionLabel {
  if (Platform.isAndroid) return 'Download & Install';
  return 'Update & Restart';
}

Future<UpdateInstallResult> installLatestReleaseUpdate(
  ReleaseUpdate release,
  RuntimeSystemInfo systemInfo, {
  required UpdateDownloadController controller,
  UpdateProgressCallback? onProgress,
  http.Client? client,
  Directory? downloadDirectory,
  UpdateAssetLauncher? launcher,
  UpdateManifestLoader? manifestLoader,
  String? platformOverride,
  String? architectureOverride,
  String? linuxFormatOverride,
  String? macOSFormatOverride,
}) async {
  if (!directUpdateSupported && platformOverride == null) {
    return const UpdateInstallResult(
      status: UpdateLaunchStatus.unsupported,
      message: 'Direct updates are not supported on this platform.',
    );
  }
  if (controller.isCancelled) throw const UpdateCancelledException();
  final manifest = await (manifestLoader ?? fetchUpdateManifest)(release);
  if (controller.isCancelled) throw const UpdateCancelledException();
  final platform = platformOverride ?? Platform.operatingSystem;
  final architecture = architectureOverride ?? systemInfo.architecture;
  final linuxFormat = linuxFormatOverride ??
      (platform == 'linux' ? await _preferredLinuxPackageFormat() : null);
  final macOSFormat = macOSFormatOverride ??
      (platform == 'macos' ? await _preferredMacOSPackageFormat() : null);
  final asset = selectUpdateAsset(
    manifest,
    platform: platform,
    architecture: architecture,
    preferredLinuxFormat: linuxFormat,
    preferredMacOSFormat: macOSFormat,
  );
  if (asset == null || asset.strategy == 'manual') {
    return const UpdateInstallResult(
      status: UpdateLaunchStatus.unsupported,
      message: 'No compatible direct-update package is available.',
    );
  }
  final downloaded = await downloadVerifiedUpdateAsset(
    asset,
    controller: controller,
    onProgress: onProgress,
    client: client,
    downloadDirectory: downloadDirectory,
  );
  if (controller.isCancelled) throw const UpdateCancelledException();
  return await (launcher ?? launchVerifiedUpdateAsset)(downloaded);
}

Future<DownloadedUpdate> downloadVerifiedUpdateAsset(
  UpdateManifestAsset asset, {
  required UpdateDownloadController controller,
  UpdateProgressCallback? onProgress,
  http.Client? client,
  Directory? downloadDirectory,
}) async {
  if (asset.name.isEmpty ||
      asset.name.contains('/') ||
      asset.name.contains(r'\') ||
      asset.name == '.' ||
      asset.name == '..') {
    throw const FormatException('Unsafe update filename');
  }
  final ownedClient = client == null;
  final activeClient = client ?? http.Client();
  controller.bind(activeClient.close);
  final directory = downloadDirectory ??
      Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}mdslens-updates',
      );
  await directory.create(recursive: true);
  final destination = File(
    '${directory.path}${Platform.pathSeparator}${asset.name}',
  );
  final partial = File('${destination.path}.part');
  IOSink? output;
  try {
    if (partial.existsSync()) await partial.delete();
    final request = http.Request('GET', Uri.parse(asset.url));
    request.headers['Accept'] = 'application/octet-stream';
    final response =
        await activeClient.send(request).timeout(const Duration(seconds: 30));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'GitHub returned HTTP ${response.statusCode} for ${asset.name}',
      );
    }
    output = partial.openWrite();
    var received = 0;
    onProgress?.call(
      UpdateDownloadProgress(received: received, total: asset.size),
    );
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      if (controller.isCancelled) throw const UpdateCancelledException();
      received += chunk.length;
      if (received > asset.size) {
        throw const FormatException('Update download exceeded declared size');
      }
      output.add(chunk);
      onProgress?.call(
        UpdateDownloadProgress(received: received, total: asset.size),
      );
    }
    await output.flush();
    await output.close();
    output = null;
    if (received != asset.size) {
      throw FormatException(
        'Update size mismatch: expected ${asset.size}, received $received',
      );
    }
    final actualDigest = await sha256.bind(partial.openRead()).first;
    if (actualDigest.toString().toLowerCase() != asset.sha256.toLowerCase()) {
      throw const FormatException('Update SHA-256 verification failed');
    }
    if (destination.existsSync()) await destination.delete();
    await partial.rename(destination.path);
    return DownloadedUpdate(asset: asset, path: destination.path);
  } catch (error) {
    if (output != null) {
      try {
        await output.flush();
      } catch (_) {}
      try {
        await output.close();
      } catch (_) {}
    }
    try {
      if (partial.existsSync()) await partial.delete();
    } catch (_) {}
    if (controller.isCancelled && error is! UpdateCancelledException) {
      throw const UpdateCancelledException();
    }
    rethrow;
  } finally {
    controller.unbind();
    if (ownedClient) activeClient.close();
  }
}

Future<void> _startDetached(String executable, List<String> arguments) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

Future<ProcessResult> _runCommand(
  String executable,
  List<String> arguments,
) {
  return Process.run(executable, arguments);
}

typedef CommandRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

Future<void> requestApplicationExitForUpdate() async {
  exit(0);
}

Future<UpdateInstallResult> launchVerifiedUpdateAsset(
  DownloadedUpdate update, {
  String? platformOverride,
  DetachedCommandLauncher? commandLauncher,
  CommandRunner? commandRunner,
  String? currentExecutableOverride,
  String? currentAppImageOverride,
  int? currentPidOverride,
}) async {
  final platform = platformOverride ?? Platform.operatingSystem;
  final launch = commandLauncher ?? _startDetached;
  final run = commandRunner ?? _runCommand;
  if (platform == 'android') {
    final status = await _updaterChannel.invokeMethod<String>(
      'installApk',
      update.path,
    );
    return UpdateInstallResult(
      status: status == 'permission_required'
          ? UpdateLaunchStatus.permissionRequired
          : UpdateLaunchStatus.launched,
      message: status == 'permission_required'
          ? 'Allow MDSLens to install apps, then choose Install Update again.'
          : 'The Android system installer is ready.',
      downloaded: update,
    );
  }
  if (platform == 'windows') {
    if (update.asset.format == 'msi') {
      await launch('msiexec.exe', [
        '/i',
        update.path,
        '/qn',
        '/norestart',
        'REBOOT=ReallySuppress',
      ]);
    } else {
      await launch(update.path, const [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/CLOSEAPPLICATIONS',
        '/RESTARTAPPLICATIONS',
        '/SP-',
      ]);
    }
    return UpdateInstallResult(
      status: UpdateLaunchStatus.launched,
      message: 'Installing the update. MDSLens will restart automatically.',
      downloaded: update,
      closeApplication: true,
    );
  }
  if (platform == 'macos') {
    if (update.asset.format == 'zip') {
      final prepared = await prepareMacOSApplicationUpdate(
        update,
        currentExecutable:
            currentExecutableOverride ?? Platform.resolvedExecutable,
        currentPid: currentPidOverride ?? pid,
        commandLauncher: launch,
        commandRunner: run,
      );
      if (prepared != null) return prepared;
    }
    final result = await run('open', [update.path]);
    if (result.exitCode != 0) {
      throw Exception('macOS could not open the downloaded update.');
    }
    return UpdateInstallResult(
      status: UpdateLaunchStatus.launched,
      message: update.asset.format == 'dmg'
          ? 'The downloaded disk image is open.'
          : 'Automatic replacement was unavailable, so the update archive is open.',
      downloaded: update,
    );
  }
  if (platform == 'linux') {
    final currentAppImage = currentAppImageOverride ??
        (Platform.environment['APPIMAGE'] ?? '').trim();
    if (update.asset.format == 'AppImage' && currentAppImage.isNotEmpty) {
      if (await replaceAppImageForUpdate(update, currentAppImage)) {
        await scheduleApplicationRelaunch(
          currentAppImage,
          currentPid: currentPidOverride ?? pid,
          commandLauncher: launch,
        );
        return UpdateInstallResult(
          status: UpdateLaunchStatus.installed,
          message: 'The AppImage was updated. MDSLens will restart now.',
          downloaded: update,
          closeApplication: true,
        );
      }
    }
    if (update.asset.format == 'AppImage') {
      await run('chmod', ['+x', update.path]);
    }
    await launch('xdg-open', [update.path]);
    return UpdateInstallResult(
      status: UpdateLaunchStatus.launched,
      message: 'The downloaded package is open in the system installer.',
      downloaded: update,
    );
  }
  return UpdateInstallResult(
    status: UpdateLaunchStatus.downloaded,
    message: 'The update was downloaded to ${update.path}.',
    downloaded: update,
  );
}

String? macOSBundlePathFromExecutable(String executablePath) {
  final executable = File(executablePath);
  final macOSDirectory = executable.parent;
  final contentsDirectory = macOSDirectory.parent;
  final bundle = contentsDirectory.parent;
  if (macOSDirectory.path.split(Platform.pathSeparator).last != 'MacOS' ||
      contentsDirectory.path.split(Platform.pathSeparator).last != 'Contents' ||
      !bundle.path.endsWith('.app')) {
    return null;
  }
  return bundle.path;
}

Future<bool> _directoryIsWritable(Directory directory) async {
  final probe = File(
    '${directory.path}${Platform.pathSeparator}'
    '.mdslens-update-write-test-$pid',
  );
  try {
    await probe.create(exclusive: true);
    await probe.delete();
    return true;
  } catch (_) {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {}
    return false;
  }
}

Future<String> _preferredMacOSPackageFormat() async {
  try {
    final resolved =
        await File(Platform.resolvedExecutable).resolveSymbolicLinks();
    final bundlePath = macOSBundlePathFromExecutable(resolved);
    if (bundlePath != null &&
        await Directory(bundlePath).exists() &&
        await _directoryIsWritable(Directory(bundlePath).parent)) {
      return 'zip';
    }
  } catch (_) {}
  return 'dmg';
}

Future<UpdateInstallResult?> prepareMacOSApplicationUpdate(
  DownloadedUpdate update, {
  required String currentExecutable,
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
  required CommandRunner commandRunner,
}) async {
  String resolvedExecutable;
  try {
    resolvedExecutable = await File(currentExecutable).resolveSymbolicLinks();
  } catch (_) {
    resolvedExecutable = currentExecutable;
  }
  final bundlePath = macOSBundlePathFromExecutable(resolvedExecutable);
  if (bundlePath == null) return null;
  final currentBundle = Directory(bundlePath);
  if (!await currentBundle.exists() ||
      !await _directoryIsWritable(currentBundle.parent)) {
    return null;
  }

  final nonce = '$currentPid-${DateTime.now().microsecondsSinceEpoch}';
  final stagedBundle = Directory('$bundlePath.mdslens-update-$nonce');
  final backupBundle = Directory('$bundlePath.mdslens-backup-$nonce');
  final work = await Directory.systemTemp.createTemp('mdslens-macos-update-');
  final extracted = Directory(
    '${work.path}${Platform.pathSeparator}extracted',
  );
  final candidate = Directory(
    '${extracted.path}${Platform.pathSeparator}MDSLens.app',
  );
  var helperLaunched = false;
  try {
    await extracted.create();
    final unpack = await commandRunner('/usr/bin/ditto', [
      '-x',
      '-k',
      update.path,
      extracted.path,
    ]);
    if (unpack.exitCode != 0 || !await candidate.exists()) return null;
    final identity = await commandRunner('/usr/bin/plutil', [
      '-extract',
      'CFBundleIdentifier',
      'raw',
      '-o',
      '-',
      '${candidate.path}/Contents/Info.plist',
    ]);
    if (identity.exitCode != 0 ||
        identity.stdout.toString().trim() != 'com.mdslens.app') {
      return null;
    }
    final signature = await commandRunner('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      candidate.path,
    ]);
    if (signature.exitCode != 0) return null;

    final stage = await commandRunner('/usr/bin/ditto', [
      candidate.path,
      stagedBundle.path,
    ]);
    if (stage.exitCode != 0 || !await stagedBundle.exists()) return null;
    final stagedSignature = await commandRunner('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      stagedBundle.path,
    ]);
    if (stagedSignature.exitCode != 0) return null;

    final helper = File(
      '${work.path}${Platform.pathSeparator}apply-update.sh',
    );
    await helper.writeAsString(r'''#!/bin/sh
set -u
parent_pid="$1"
current_bundle="$2"
staged_bundle="$3"
backup_bundle="$4"
archive="$5"
work_dir="$6"

attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ "$attempt" -ge 3000 ]; then
    /bin/rm -rf "$staged_bundle" "$work_dir"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done

if /bin/mv "$current_bundle" "$backup_bundle" &&
   /bin/mv "$staged_bundle" "$current_bundle"; then
  /bin/rm -rf "$backup_bundle"
  /bin/rm -f "$archive"
  /usr/bin/open "$current_bundle"
  /bin/rm -rf "$work_dir"
  exit 0
fi

if [ ! -e "$current_bundle" ] && [ -e "$backup_bundle" ]; then
  /bin/mv "$backup_bundle" "$current_bundle"
fi
/bin/rm -rf "$staged_bundle"
if [ -e "$current_bundle" ]; then
  /usr/bin/open "$current_bundle"
fi
/bin/rm -rf "$work_dir"
exit 1
''');
    final chmod = await commandRunner('/bin/chmod', ['700', helper.path]);
    if (chmod.exitCode != 0) return null;
    await commandLauncher('/bin/sh', [
      helper.path,
      '$currentPid',
      currentBundle.path,
      stagedBundle.path,
      backupBundle.path,
      update.path,
      work.path,
    ]);
    helperLaunched = true;
    return UpdateInstallResult(
      status: UpdateLaunchStatus.installed,
      message: 'The update is ready. MDSLens will restart automatically.',
      downloaded: update,
      closeApplication: true,
    );
  } finally {
    // A successfully launched helper owns these paths and removes them after
    // the current process exits. On preparation failure no backup exists yet,
    // so cleaning only the unique staging paths is safe.
    if (!helperLaunched) {
      try {
        if (await stagedBundle.exists()) {
          await stagedBundle.delete(recursive: true);
        }
      } catch (_) {}
      try {
        if (await work.exists()) await work.delete(recursive: true);
      } catch (_) {}
    }
  }
}

Future<void> scheduleApplicationRelaunch(
  String executablePath, {
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
}) async {
  final work = await Directory.systemTemp.createTemp('mdslens-relaunch-');
  final helper = File('${work.path}${Platform.pathSeparator}relaunch.sh');
  await helper.writeAsString(r'''#!/bin/sh
set -u
parent_pid="$1"
executable="$2"
work_dir="$3"
attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ "$attempt" -ge 3000 ]; then
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
"$executable" >/dev/null 2>&1 &
/bin/rm -rf "$work_dir"
''');
  final chmod = await Process.run('/bin/chmod', ['700', helper.path]);
  if (chmod.exitCode != 0) {
    await work.delete(recursive: true);
    throw Exception('Could not prepare the update relaunch helper.');
  }
  await commandLauncher('/bin/sh', [
    helper.path,
    '$currentPid',
    executablePath,
    work.path,
  ]);
}

Future<bool> replaceAppImageForUpdate(
  DownloadedUpdate update,
  String currentPath,
) async {
  File current;
  try {
    current = File(await File(currentPath).resolveSymbolicLinks());
  } catch (_) {
    return false;
  }
  if (FileSystemEntity.typeSync(current.path) != FileSystemEntityType.file) {
    return false;
  }
  final staged = File('${current.path}.mdslens-update');
  final backup = File('${current.path}.mdslens-backup');
  try {
    if (staged.existsSync()) await staged.delete();
    if (backup.existsSync()) await backup.delete();
    await File(update.path).copy(staged.path);
    final chmod = await Process.run('chmod', ['+x', staged.path]);
    if (chmod.exitCode != 0) {
      await staged.delete();
      return false;
    }
    await current.rename(backup.path);
    try {
      await staged.rename(current.path);
    } catch (_) {
      await backup.rename(current.path);
      rethrow;
    }
    try {
      await backup.delete();
    } catch (_) {}
    try {
      if (File(update.path).existsSync()) await File(update.path).delete();
    } catch (_) {}
    return true;
  } catch (_) {
    if (!current.existsSync() && backup.existsSync()) {
      try {
        await backup.rename(current.path);
      } catch (_) {}
    }
    if (staged.existsSync()) {
      try {
        await staged.delete();
      } catch (_) {}
    }
    return false;
  }
}

Future<String> _preferredLinuxPackageFormat() async {
  if ((Platform.environment['APPIMAGE'] ?? '').trim().isNotEmpty) {
    return 'AppImage';
  }
  try {
    final source = (await File('/etc/os-release').readAsString()).toLowerCase();
    if (RegExp(
      r'(?:^|\s)(?:id|id_like)=[^\n]*(?:debian|ubuntu)',
    ).hasMatch(source)) {
      return 'deb';
    }
    if (RegExp(
      r'(?:^|\s)(?:id|id_like)=[^\n]*(?:fedora|rhel|centos|suse)',
    ).hasMatch(source)) {
      return 'rpm';
    }
  } catch (_) {}
  return 'AppImage';
}
