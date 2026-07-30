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

const _updaterChannel = MethodChannel('mdslens/updater');

bool get directUpdateSupported =>
    Platform.isWindows ||
    Platform.isMacOS ||
    Platform.isLinux ||
    Platform.isAndroid;

String get directUpdateActionLabel {
  if (Platform.isMacOS) return 'Download & Open';
  return 'Download & Install';
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
  final asset = selectUpdateAsset(
    manifest,
    platform: platform,
    architecture: architecture,
    preferredLinuxFormat: linuxFormat,
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
  return await (launcher ?? _launchUpdateAsset)(downloaded);
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
    final response = await activeClient.send(request).timeout(
          const Duration(seconds: 30),
        );
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
    await for (final chunk in response.stream) {
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
      await output.flush();
      await output.close();
    }
    if (partial.existsSync()) await partial.delete();
    if (controller.isCancelled && error is! UpdateCancelledException) {
      throw const UpdateCancelledException();
    }
    rethrow;
  } finally {
    controller.unbind();
    if (ownedClient) activeClient.close();
  }
}

Future<UpdateInstallResult> _launchUpdateAsset(
  DownloadedUpdate update,
) async {
  if (Platform.isAndroid) {
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
  if (Platform.isWindows) {
    if (update.asset.format == 'msi') {
      await Process.start(
        'msiexec.exe',
        ['/i', update.path],
        mode: ProcessStartMode.detached,
      );
    } else {
      await Process.start(
        update.path,
        const [],
        mode: ProcessStartMode.detached,
      );
    }
    return UpdateInstallResult(
      status: UpdateLaunchStatus.launched,
      message: 'The Windows installer is ready.',
      downloaded: update,
    );
  }
  if (Platform.isMacOS) {
    final result = await Process.run('open', [update.path]);
    if (result.exitCode != 0) {
      throw Exception('macOS could not open the downloaded update.');
    }
    return UpdateInstallResult(
      status: UpdateLaunchStatus.launched,
      message: 'The downloaded disk image is open.',
      downloaded: update,
    );
  }
  if (Platform.isLinux) {
    final result = await Process.run('xdg-open', [update.path]);
    if (result.exitCode != 0) {
      throw Exception('Linux could not open the downloaded update package.');
    }
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

Future<String> _preferredLinuxPackageFormat() async {
  if ((Platform.environment['APPIMAGE'] ?? '').trim().isNotEmpty) {
    return 'AppImage';
  }
  try {
    final source = (await File('/etc/os-release').readAsString()).toLowerCase();
    if (RegExp(r'(?:^|\s)(?:id|id_like)=[^\n]*(?:debian|ubuntu)')
        .hasMatch(source)) {
      return 'deb';
    }
    if (RegExp(r'(?:^|\s)(?:id|id_like)=[^\n]*(?:fedora|rhel|centos|suse)')
        .hasMatch(source)) {
      return 'rpm';
    }
  } catch (_) {}
  return 'AppImage';
}
