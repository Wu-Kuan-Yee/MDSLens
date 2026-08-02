import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
// Update helpers poll at 100 ms.  The timeout is only a safety boundary for
// a helper that never starts or a replacement that never becomes usable;
// normal updates finish as soon as the replacement writes its health and
// commit nonces.
const _updateHealthTimeoutAttempts = 1200; // 120 seconds
// Used only by recovery of transactions created by older releases. Current
// helpers commit and clean up immediately after startup acknowledgement.
const _updateStabilityAttempts = 600; // legacy recovery window
const _defaultUpdateStabilityWindow = Duration(
  seconds: _updateStabilityAttempts ~/ 10,
);

class _UpdateHandshake {
  _UpdateHandshake({
    required this.healthFile,
    required this.token,
    required this.commitMarker,
  });

  final File healthFile;
  final String token;
  final String commitMarker;

  List<String> get applicationArguments => [
        '--mdslens-update-health=${healthFile.path}',
        '--mdslens-update-token=$token',
        '--mdslens-update-commit=$commitMarker',
      ];
}

_UpdateHandshake _createUpdateHandshake(
  Directory work, {
  required String commitMarker,
}) {
  final random = Random.secure();
  final token = base64Url
      .encode(List<int>.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
  return _UpdateHandshake(
    healthFile: File(
      '${work.path}${Platform.pathSeparator}replacement-health',
    ),
    token: token,
    commitMarker: commitMarker,
  );
}

bool get directUpdateSupported => nativeDirectUpdateSupported(
      platform: Platform.operatingSystem,
      resolvedExecutable: resolvedExecutableForUpdate(),
      environment: Platform.environment,
      flatpakInfoExists: File('/.flatpak-info').existsSync(),
      linuxOsRelease: _linuxOsReleaseSync(),
      linuxPortableRootExists:
          linuxPortableRootFromExecutable(resolvedExecutableForUpdate()) !=
              null,
      windowsPortableRootExists:
          windowsPortableRootFromExecutable(Platform.resolvedExecutable) !=
              null,
    );

bool nativeDirectUpdateSupported({
  required String platform,
  required String resolvedExecutable,
  required Map<String, String> environment,
  bool flatpakInfoExists = false,
  String linuxOsRelease = '',
  bool linuxPortableRootExists = false,
  bool windowsPortableRootExists = false,
}) {
  switch (platform.toLowerCase()) {
    case 'android':
      return true;
    case 'macos':
      return !resolvedExecutable.contains('/AppTranslocation/') &&
          !resolvedExecutable.startsWith('/Volumes/');
    case 'windows':
      // An MSIX package lives in the protected WindowsApps directory and must
      // be serviced by Windows/App Installer using the package identity. The
      // unsigned standalone EXE/MSI updater must never create a second install.
      return windowsPortableRootExists ||
          !resolvedExecutable
              .replaceAll('/', r'\')
              .toLowerCase()
              .contains(r'\windowsapps\');
    case 'linux':
      if ((environment['FLATPAK_ID'] ?? '').isNotEmpty ||
          (environment['SNAP'] ?? '').isNotEmpty ||
          flatpakInfoExists) {
        return false;
      }
      if ((environment['APPIMAGE'] ?? '').trim().isNotEmpty) return true;
      if (linuxPortableRootExists) return true;
      final executable = resolvedExecutable.replaceAll(r'\', '/');
      // Native packages install below /usr. Marked portable directories and
      // AppImages were handled above; unmarked extracted directories must not
      // be overwritten because their ownership boundary is ambiguous.
      final systemInstall = executable == '/usr/bin/mdslens' ||
          executable.startsWith('/usr/lib/mdslens/');
      if (!systemInstall) return false;
      return RegExp(
        r'(?:^|\s)(?:id|id_like)=[^\n]*(?:debian|ubuntu|fedora|rhel|centos|suse|arch|manjaro)',
      ).hasMatch(linuxOsRelease.toLowerCase());
    default:
      return false;
  }
}

/// Finds the executable that is actually running, rather than trusting a
/// launcher symlink or a desktop-entry path.  Linux exposes this through
/// `/proc/self/exe`; resolving it is important for portable bundles because
/// the update must replace the directory containing the running binary.
String resolvedExecutableForUpdate() {
  final candidates = <String>[];
  if (Platform.isLinux) candidates.add('/proc/self/exe');
  candidates.add(Platform.resolvedExecutable);
  for (final candidate in candidates) {
    try {
      final file = File(candidate);
      if (!file.existsSync()) continue;
      final resolved = file.resolveSymbolicLinksSync();
      if (resolved.trim().isNotEmpty) return resolved;
    } catch (_) {}
  }
  return Platform.resolvedExecutable;
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
  String? windowsFormatOverride,
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
  final windowsFormat = windowsFormatOverride ??
      (platform == 'windows' ? _preferredWindowsPackageFormat() : null);
  final asset = selectUpdateAsset(
    manifest,
    platform: platform,
    architecture: architecture,
    preferredLinuxFormat: linuxFormat,
    preferredMacOSFormat: macOSFormat,
    preferredWindowsFormat: windowsFormat,
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
  final directory = downloadDirectory ?? await _defaultUpdateDirectory();
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

Future<Directory> _defaultUpdateDirectory() async {
  if (Platform.isAndroid) {
    final cachePath = await _updaterChannel.invokeMethod<String>(
      'getUpdateCacheDirectory',
    );
    if (cachePath == null || cachePath.trim().isEmpty) {
      throw const FileSystemException(
        'Android did not provide an application update cache directory.',
      );
    }
    return Directory(cachePath);
  }
  return Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}mdslens-updates',
  );
}

Future<void> _startDetached(String executable, List<String> arguments) async {
  await Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

/// Starts a Windows update helper outside the host application's process job.
///
/// Flutter desktop launchers are sometimes placed in a Windows job that uses
/// kill-on-close.  A normal detached child (and even `cmd start`) can still be
/// assigned to that job, so it disappears when the Flutter process exits.  The
/// Windows runner exposes a small native launcher that requests
/// CREATE_BREAKAWAY_FROM_JOB.  We keep the old shell invocation as a fallback
/// for older runners and for test/embedding environments that do not provide
/// the channel.
Future<void> _startWindowsDetached(
  String executable,
  List<String> arguments,
) async {
  if (!Platform.isWindows) {
    await _startDetached(executable, arguments);
    return;
  }

  // Existing call sites pass the historical `cmd start` form.  Convert it to
  // a direct `cmd /c call` invocation before handing it to the native launcher
  // so the only process created by the runner is the breakaway child.
  var launchExecutable = executable;
  var launchArguments = List<String>.from(arguments);
  if (executable.toLowerCase().endsWith(r'cmd.exe') &&
      arguments.length >= 7 &&
      arguments[0] == '/d' &&
      arguments[1] == '/s' &&
      arguments[2] == '/c' &&
      arguments[3].toLowerCase() == 'start') {
    launchArguments = <String>[
      '/d',
      '/s',
      '/c',
      'call',
      ...arguments.sublist(6),
    ];
  }
  if (launchExecutable.toLowerCase().endsWith(r'cmd.exe')) {
    final root = (Platform.environment['SystemRoot'] ??
            Platform.environment['WINDIR'] ??
            '')
        .replaceFirst(RegExp(r'[\\/]+$'), '');
    if (root.isNotEmpty) {
      launchExecutable =
          '$root${Platform.pathSeparator}System32${Platform.pathSeparator}cmd.exe';
    }
  }

  try {
    final launched = await _updaterChannel.invokeMethod<bool>(
      'spawnDetached',
      <String, Object?>{
        'executable': launchExecutable,
        'arguments': launchArguments,
        'workingDirectory': Directory.current.path,
      },
    );
    if (launched == true) return;
  } on MissingPluginException {
    // Older builds do not have the Windows runner channel.
  } on PlatformException {
    // Fall through to the compatibility launch below.
  }

  await Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.detached,
  );
}

/// Builds the compatibility `cmd start` invocation used by older Windows
/// runners. Current runners convert this into a direct breakaway process via
/// [_startWindowsDetached]; keeping this shape lets already-embedded/test
/// launchers continue to use the previous handoff when the native channel is
/// unavailable.
List<String> _windowsDetachedStartArguments(
  String executable,
  List<String> arguments,
) {
  return <String>[
    '/d',
    '/s',
    '/c',
    'start',
    'MDSLens Update Helper',
    '/b',
    executable,
    ...arguments,
  ];
}

String _windowsPowerShellExecutable() {
  if (!Platform.isWindows) return 'powershell.exe';
  final root = (Platform.environment['SystemRoot'] ??
          Platform.environment['WINDIR'] ??
          '')
      .replaceFirst(RegExp(r'[\\/]+$'), '');
  if (root.isNotEmpty) {
    final systemPowerShell = File(
      '$root${Platform.pathSeparator}System32${Platform.pathSeparator}'
      'WindowsPowerShell${Platform.pathSeparator}v1.0${Platform.pathSeparator}'
      'powershell.exe',
    );
    if (systemPowerShell.existsSync()) return systemPowerShell.path;
  }
  return 'powershell.exe';
}

Future<ProcessResult> _runCommand(
  String executable,
  List<String> arguments,
) {
  return Process.run(executable, arguments);
}

typedef CommandRunner = Future<ProcessResult> Function(
    String executable, List<String> arguments);

const _macOSApplyUpdateScript = r'''
set -u
parent_pid="$1"
current_bundle="$2"
staged_bundle="$3"
backup_bundle="$4"
archive="$5"
work_dir="$6"
health_file="$7"
health_token="$8"
commit_marker="$9"
# POSIX shells treat $10 as "$1" followed by a literal zero.  The ready
# marker is the tenth argument, so use the braced form or the helper will wait
# forever even though the updater process was launched successfully.
ready_file="${10}"
previous_bundle="${current_bundle}.mdslens-previous"

launch_bundle() {
  bundle="$1"
  shift
  executable="$bundle/Contents/MacOS/MDSLens"
  [ -x "$executable" ] || return 1
  "$executable" "$@" >/dev/null 2>&1 &
  launched_pid=$!
}

case "$current_bundle" in ""|"/") exit 1 ;; esac
case "$staged_bundle" in "${current_bundle}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_bundle" in "${current_bundle}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ ! -d "$staged_bundle" ] && exit 1
[ -e "$backup_bundle" ] && exit 1
[ -L "$backup_bundle" ] && exit 1
: > "$ready_file"

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
  if ! launch_bundle "$current_bundle" \
      "--mdslens-update-health=$health_file" \
      "--mdslens-update-token=$health_token" \
      "--mdslens-update-commit=$commit_marker"; then
    /bin/rm -rf "$current_bundle"
    /bin/mv "$backup_bundle" "$current_bundle"
    /bin/rm -rf "$staged_bundle" "$work_dir"
    exit 1
  fi
  new_pid=$launched_pid
  attempt=0
  healthy=0
  while [ "$attempt" -lt 1200 ]; do
    if ! kill -0 "$new_pid" 2>/dev/null; then
      /bin/rm -rf "$current_bundle"
      /bin/mv "$backup_bundle" "$current_bundle"
      launch_bundle "$current_bundle" || true
      /bin/rm -rf "$work_dir"
      exit 1
    fi
    if [ -f "$health_file" ] &&
       [ "$(/bin/cat "$health_file" 2>/dev/null || true)" = "$health_token" ]; then
      healthy=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  if [ "$healthy" -ne 1 ]; then
    /bin/rm -rf "$current_bundle"
    /bin/mv "$backup_bundle" "$current_bundle"
    launch_bundle "$current_bundle" || true
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  committed=0
  commit_attempt=0
  while [ "$commit_attempt" -lt 1200 ]; do
    if [ -f "$commit_marker" ] &&
       [ "$(/bin/cat "$commit_marker" 2>/dev/null || true)" = "$health_token" ]; then
      committed=1
      break
    fi
    if ! kill -0 "$new_pid" 2>/dev/null; then
      break
    fi
    commit_attempt=$((commit_attempt + 1))
    sleep 0.1
  done
  if [ "$committed" -ne 1 ]; then
    /bin/rm -rf "$current_bundle"
    /bin/mv "$backup_bundle" "$current_bundle"
    launch_bundle "$current_bundle" || true
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  previous_owned=0
  if [ -f "$previous_bundle/Contents/Info.plist" ]; then
    previous_id=$(/usr/libexec/PlistBuddy -c 'Print:CFBundleIdentifier' \
      "$previous_bundle/Contents/Info.plist" 2>/dev/null || true)
    [ "$previous_id" = "com.mdslens.app" ] && previous_owned=1
  fi
  [ "$previous_owned" -eq 1 ] && /bin/rm -rf "$previous_bundle"
  if [ ! -e "$previous_bundle" ]; then
    /bin/mv "$backup_bundle" "$previous_bundle"
  fi
  /bin/rm -rf "$previous_bundle"
  /bin/rm -f "$commit_marker" "$health_file" "$archive"
  /bin/rm -rf "$work_dir"
  exit 0
fi

if [ ! -e "$current_bundle" ] && [ -e "$backup_bundle" ]; then
  /bin/mv "$backup_bundle" "$current_bundle"
fi
/bin/rm -rf "$staged_bundle"
if [ -e "$current_bundle" ]; then
  launch_bundle "$current_bundle" || true
fi
/bin/rm -rf "$work_dir"
exit 1
''';

const _linuxAppImageApplyUpdateScript = r'''
set -u
parent_pid="$1"
current_image="$2"
staged_image="$3"
backup_image="$4"
downloaded_image="$5"
health_file="$6"
health_token="$7"
commit_marker="$8"
work_dir=$(/usr/bin/dirname "$health_file")
previous_image="${current_image}.mdslens-previous"
previous_owner="${previous_image}.owner"

process_is_running() {
  candidate_pid="$1"
  kill -0 "$candidate_pid" 2>/dev/null || return 1
  if [ -r "/proc/$candidate_pid/stat" ]; then
    process_state=$(awk '{print $3}' "/proc/$candidate_pid/stat" 2>/dev/null || true)
    [ "$process_state" = "Z" ] && return 1
  fi
  return 0
}

case "$current_image" in ""|"/") exit 1 ;; esac
case "$staged_image" in "${current_image}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_image" in "${current_image}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ -e "$backup_image" ] && exit 1
[ -L "$backup_image" ] && exit 1

attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ "$attempt" -ge 3000 ]; then
    /bin/rm -f "$staged_image" "$downloaded_image"
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done

if /bin/mv -T -- "$current_image" "$backup_image" &&
   /bin/mv -T -- "$staged_image" "$current_image"; then
  /bin/chmod +x "$current_image"
  "$current_image" "--mdslens-update-health=$health_file" \
    "--mdslens-update-token=$health_token" \
    "--mdslens-update-commit=$commit_marker" >/dev/null 2>&1 &
  new_pid=$!
  attempt=0
  healthy=0
  while [ "$attempt" -lt 1200 ]; do
    if ! process_is_running "$new_pid"; then
      /bin/rm -f "$current_image"
      /bin/mv -T -- "$backup_image" "$current_image"
      "$current_image" >/dev/null 2>&1 &
      /bin/rm -f "$downloaded_image"
      /bin/rm -rf "$work_dir"
      exit 1
    fi
    if [ -f "$health_file" ] &&
       [ "$(/bin/cat "$health_file" 2>/dev/null || true)" = "$health_token" ]; then
      healthy=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  if [ "$healthy" -ne 1 ]; then
    /bin/rm -f "$current_image"
    /bin/mv -T -- "$backup_image" "$current_image"
    "$current_image" >/dev/null 2>&1 &
    /bin/rm -f "$downloaded_image"
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  committed=0
  commit_attempt=0
  while [ "$commit_attempt" -lt 1200 ]; do
    if [ -f "$commit_marker" ] &&
       [ "$(/bin/cat "$commit_marker" 2>/dev/null || true)" = "$health_token" ]; then
      committed=1
      break
    fi
    if ! process_is_running "$new_pid"; then
      break
    fi
    commit_attempt=$((commit_attempt + 1))
    sleep 0.1
  done
  if [ "$committed" -ne 1 ]; then
    /bin/rm -f "$current_image"
    /bin/mv -T -- "$backup_image" "$current_image"
    "$current_image" >/dev/null 2>&1 &
    /bin/rm -f "$downloaded_image"
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  previous_owned=0
  if [ -f "$previous_owner" ] &&
     [ "$(/bin/cat "$previous_owner")" = "com.mdslens.app" ]; then
    previous_owned=1
  fi
  if [ "$previous_owned" -eq 1 ]; then
    /bin/rm -f "$previous_image" "$previous_owner"
  fi
  if [ ! -e "$previous_image" ]; then
    /bin/mv -T -- "$backup_image" "$previous_image"
    echo 'com.mdslens.app' > "$previous_owner"
  fi
  /bin/rm -f "$previous_image" "$previous_owner" "$commit_marker" \
    "$health_file" "$downloaded_image"
  /bin/rm -rf "$work_dir"
  exit 0
fi

if [ ! -e "$current_image" ] && [ -e "$backup_image" ]; then
  /bin/mv -T -- "$backup_image" "$current_image"
fi
/bin/rm -f "$staged_image"
if [ -x "$current_image" ]; then
  "$current_image" >/dev/null 2>&1 &
fi
/bin/rm -f "$downloaded_image"
/bin/rm -rf "$work_dir"
exit 1
''';

const _linuxAppImagePrivilegedApplyScript = r'''
set -u
parent_pid="$1"
current_image="$2"
staged_image="$3"
backup_image="$4"
downloaded_image="$5"
health_file="$6"
health_token="$7"
commit_marker="$8"
ready_file="$9"
healthy_file="${10}"
failed_file="${11}"
rollback_file="${12}"
pid_file="${13}"
previous_image="${current_image}.mdslens-previous"
previous_owner="${previous_image}.owner"
work_dir=$(/usr/bin/dirname "$health_file")

case "$current_image" in ""|"/") exit 1 ;; esac
case "$staged_image" in "${current_image}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_image" in "${current_image}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ -e "$backup_image" ] && exit 1
[ -L "$backup_image" ] && exit 1

attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ "$attempt" -ge 3000 ]; then exit 1; fi
  attempt=$((attempt + 1))
  sleep 0.1
done

if /bin/mv -T -- "$current_image" "$backup_image" &&
   /bin/mv -T -- "$staged_image" "$current_image"; then
  /bin/chmod +x "$current_image"
  : > "$ready_file"
  attempt=0
  while [ "$attempt" -lt 1200 ]; do
    if [ -e "$healthy_file" ]; then
      new_pid=''
      if [ -f "$pid_file" ]; then
        new_pid=$(/bin/cat "$pid_file" 2>/dev/null || true)
      fi
      if [ -z "$new_pid" ]; then
        /bin/rm -f "$current_image"
        /bin/mv -T -- "$backup_image" "$current_image"
        : > "$rollback_file"
        /bin/rm -rf "$work_dir"
        exit 1
      fi
      committed=0
      commit_attempt=0
      while [ "$commit_attempt" -lt 1200 ]; do
        if [ -f "$commit_marker" ] &&
           [ "$(/bin/cat "$commit_marker" 2>/dev/null || true)" = "$health_token" ]; then
          committed=1
          break
        fi
        if [ -n "$new_pid" ] && ! kill -0 "$new_pid" 2>/dev/null; then
          break
        fi
        commit_attempt=$((commit_attempt + 1))
        sleep 0.1
      done
      if [ "$committed" -ne 1 ]; then
        /bin/rm -f "$current_image"
        /bin/mv -T -- "$backup_image" "$current_image"
        : > "$rollback_file"
        sleep 1
        /bin/rm -rf "$work_dir"
        exit 1
      fi
      previous_owned=0
      if [ -f "$previous_owner" ] &&
         [ "$(/bin/cat "$previous_owner")" = "com.mdslens.app" ]; then
        previous_owned=1
      fi
      if [ "$previous_owned" -eq 1 ]; then
        /bin/rm -f "$previous_image" "$previous_owner"
      fi
      if [ ! -e "$previous_image" ]; then
        /bin/mv -T -- "$backup_image" "$previous_image"
        echo 'com.mdslens.app' > "$previous_owner"
      fi
      /bin/rm -f "$previous_image" "$previous_owner" "$commit_marker" \
        "$health_file" "$downloaded_image" "$pid_file"
      /bin/rm -rf "$work_dir"
      exit 0
    fi
    if [ -e "$failed_file" ]; then break; fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  /bin/rm -f "$current_image"
  /bin/mv -T -- "$backup_image" "$current_image"
  : > "$rollback_file"
  sleep 1
  /bin/rm -rf "$work_dir"
  exit 1
fi

if [ ! -e "$current_image" ] && [ -e "$backup_image" ]; then
  /bin/mv -T -- "$backup_image" "$current_image"
fi
: > "$rollback_file"
sleep 1
/bin/rm -rf "$work_dir"
exit 1
''';

const _linuxAppImageUserRelaunchScript = r'''
set -u
current_image="$1"
ready_file="$2"
healthy_file="$3"
failed_file="$4"
rollback_file="$5"
cancel_file="$6"
health_file="$7"
health_token="$8"
pid_file="$9"
commit_marker="${10}"

attempt=0
while [ "$attempt" -lt 300 ]; do
  [ -e "$cancel_file" ] && exit 1
  if [ -e "$ready_file" ]; then
    "$current_image" "--mdslens-update-health=$health_file" \
      "--mdslens-update-token=$health_token" \
      "--mdslens-update-commit=$commit_marker" >/dev/null 2>&1 &
    new_pid=$!
    /bin/printf '%s\n' "$new_pid" > "$pid_file"
    health_attempt=0
    while [ "$health_attempt" -lt 1200 ]; do
      if ! kill -0 "$new_pid" 2>/dev/null; then
        : > "$failed_file"
        rollback_attempt=0
        while [ "$rollback_attempt" -lt 300 ]; do
          if [ -e "$rollback_file" ]; then
            "$current_image" >/dev/null 2>&1 &
            exit 1
          fi
          rollback_attempt=$((rollback_attempt + 1))
          sleep 0.1
        done
        exit 1
      fi
      if [ -f "$health_file" ] &&
         [ "$(/bin/cat "$health_file" 2>/dev/null || true)" = "$health_token" ]; then
        : > "$healthy_file"
        exit 0
      fi
      health_attempt=$((health_attempt + 1))
      sleep 0.1
    done
    : > "$failed_file"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
exit 1
''';

const _linuxAuthorizeUpdateScript = r'''
set -eu
apply_script="$1"
downloaded_image="$2"
staged_image="$3"
shift 3
/bin/cp "$downloaded_image" "$staged_image"
/bin/chmod +x "$staged_image"
nohup /bin/sh -c "$apply_script" mdslens-updater "$@" >/dev/null 2>&1 &
''';

const _linuxPortableApplyUpdateScript = r'''
set -u
parent_pid="$1"
current_root="$2"
staged_root="$3"
backup_root="$4"
downloaded_archive="$5"
work_dir="$6"
health_file="$7"
health_token="$8"
commit_marker="$9"
previous_root="${current_root}.mdslens-previous"

case "$current_root" in ""|"/") exit 1 ;; esac
case "$staged_root" in "${current_root}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_root" in "${current_root}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ -e "$backup_root" ] && exit 1
[ -L "$backup_root" ] && exit 1

launch_from_root() {
  root="$1"
  shift
  (cd "$root" && exec ./mdslens "$@") >/dev/null 2>&1 &
  launched_pid=$!
}

process_is_running() {
  candidate_pid="$1"
  kill -0 "$candidate_pid" 2>/dev/null || return 1
  if [ -r "/proc/$candidate_pid/stat" ]; then
    process_state=$(awk '{print $3}' "/proc/$candidate_pid/stat" 2>/dev/null || true)
    [ "$process_state" = "Z" ] && return 1
  fi
  return 0
}

attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ "$attempt" -ge 3000 ]; then
    /bin/rm -rf "$staged_root" "$work_dir"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done

if /bin/mv -T -- "$current_root" "$backup_root" &&
   /bin/mv -T -- "$staged_root" "$current_root"; then
  launch_from_root "$current_root" \
    "--mdslens-update-health=$health_file" \
    "--mdslens-update-token=$health_token" \
    "--mdslens-update-commit=$commit_marker"
  new_pid=$launched_pid
  attempt=0
  healthy=0
  while [ "$attempt" -lt 1200 ]; do
    if ! process_is_running "$new_pid"; then
      /bin/rm -rf "$current_root"
      /bin/mv -T -- "$backup_root" "$current_root"
      launch_from_root "$current_root"
      /bin/rm -rf "$work_dir"
      exit 1
    fi
    if [ -f "$health_file" ] &&
       [ "$(/bin/cat "$health_file" 2>/dev/null || true)" = "$health_token" ]; then
      healthy=1
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  if [ "$healthy" -ne 1 ]; then
    /bin/rm -rf "$current_root"
    /bin/mv -T -- "$backup_root" "$current_root"
    launch_from_root "$current_root"
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  committed=0
  commit_attempt=0
  while [ "$commit_attempt" -lt 1200 ]; do
    if [ -f "$commit_marker" ] &&
       [ "$(/bin/cat "$commit_marker" 2>/dev/null || true)" = "$health_token" ]; then
      committed=1
      break
    fi
    if ! process_is_running "$new_pid"; then
      break
    fi
    commit_attempt=$((commit_attempt + 1))
    sleep 0.1
  done
  if [ "$committed" -ne 1 ]; then
    /bin/rm -rf "$current_root"
    /bin/mv -T -- "$backup_root" "$current_root"
    launch_from_root "$current_root"
    /bin/rm -f "$downloaded_archive"
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  /bin/rm -rf "$previous_root"
  /bin/mv -T -- "$backup_root" "$previous_root"
  /bin/rm -rf "$previous_root"
  /bin/rm -f "$downloaded_archive" "$health_file" "$commit_marker"
  /bin/rm -rf "$work_dir"
  exit 0
fi

if [ ! -e "$current_root" ] && [ -e "$backup_root" ]; then
  /bin/mv -T -- "$backup_root" "$current_root"
fi
/bin/rm -rf "$staged_root"
if [ -x "$current_root/mdslens" ]; then
  launch_from_root "$current_root"
fi
/bin/rm -rf "$work_dir"
exit 1
''';

const _linuxPortableAuthorizeScript = r'''
set -eu
candidate="$1"
staged_root="$2"
apply_script="$3"
shift 3
[ -e "$staged_root" ] && exit 1
[ -L "$staged_root" ] && exit 1
/bin/mkdir -- "$staged_root"
/bin/cp -a "$candidate/." "$staged_root/"
/bin/chmod +x "$staged_root/mdslens"
nohup /bin/sh -c "$apply_script" mdslens-portable-updater "$@" \
  >/dev/null 2>&1 &
''';

const _linuxPortablePrivilegedApplyScript = r'''
set -u
parent_pid="$1"
current_root="$2"
staged_root="$3"
backup_root="$4"
downloaded_archive="$5"
work_dir="$6"
health_file="$7"
health_token="$8"
commit_marker="$9"
ready_file="${10}"
healthy_file="${11}"
failed_file="${12}"
pid_file="${13}"
cancel_file="${14}"
previous_root="${current_root}.mdslens-previous"

case "$current_root" in ""|"/") exit 1 ;; esac
case "$staged_root" in "${current_root}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_root" in "${current_root}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ -e "$backup_root" ] && exit 1
[ -L "$backup_root" ] && exit 1

process_is_running() {
  candidate_pid="$1"
  kill -0 "$candidate_pid" 2>/dev/null || return 1
  if [ -r "/proc/$candidate_pid/stat" ]; then
    process_state=$(awk '{print $3}' "/proc/$candidate_pid/stat" 2>/dev/null || true)
    [ "$process_state" = "Z" ] && return 1
  fi
  return 0
}

attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ -e "$cancel_file" ]; then
    /bin/rm -rf "$staged_root" "$work_dir"
    exit 1
  fi
  if [ "$attempt" -ge 3000 ]; then
    /bin/rm -rf "$staged_root" "$work_dir"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done

if /bin/mv -T -- "$current_root" "$backup_root" &&
   /bin/mv -T -- "$staged_root" "$current_root"; then
  : > "$ready_file"
  attempt=0
  while [ "$attempt" -lt 1200 ]; do
    if [ -e "$cancel_file" ]; then break; fi
    if [ -e "$healthy_file" ]; then
      new_pid=''
      if [ -r "$pid_file" ]; then
        new_pid=$(cat "$pid_file" 2>/dev/null || true)
      fi
      if [ -z "$new_pid" ]; then
        /bin/rm -rf "$current_root"
        /bin/mv -T -- "$backup_root" "$current_root"
        /bin/rm -rf "$work_dir"
        exit 1
      fi
      committed=0
      commit_attempt=0
      while [ "$commit_attempt" -lt 1200 ]; do
        if [ -f "$commit_marker" ] &&
           [ "$(/bin/cat "$commit_marker" 2>/dev/null || true)" = "$health_token" ]; then
          committed=1
          break
        fi
        if [ -n "$new_pid" ] && ! process_is_running "$new_pid"; then
          break
        fi
        commit_attempt=$((commit_attempt + 1))
        sleep 0.1
      done
      if [ "$committed" -ne 1 ]; then
        /bin/rm -rf "$current_root"
        /bin/mv -T -- "$backup_root" "$current_root"
        /bin/rm -rf "$work_dir"
        exit 1
      fi
      /bin/rm -rf "$previous_root"
      /bin/mv -T -- "$backup_root" "$previous_root"
      /bin/rm -rf "$previous_root" "$commit_marker"
      /bin/rm -f "$downloaded_archive" "$health_file"
      /bin/rm -rf "$work_dir"
      exit 0
    fi
    if [ -e "$failed_file" ]; then break; fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  /bin/rm -rf "$current_root"
  /bin/mv -T -- "$backup_root" "$current_root"
  /bin/rm -rf "$work_dir"
  exit 1
fi

if [ ! -e "$current_root" ] && [ -e "$backup_root" ]; then
  /bin/mv -T -- "$backup_root" "$current_root"
fi
/bin/rm -rf "$staged_root" "$work_dir"
exit 1
''';

const _linuxPortableUserRelaunchScript = r'''
set -u
current_root="$1"
ready_file="$2"
healthy_file="$3"
failed_file="$4"
cancel_file="$5"
pid_file="$6"
health_file="$7"
health_token="$8"
commit_marker="$9"

attempt=0
while [ "$attempt" -lt 1200 ]; do
  if [ -e "$cancel_file" ]; then
    : > "$failed_file"
    exit 1
  fi
  if [ -e "$ready_file" ]; then
    (cd "$current_root" && exec ./mdslens \
      "--mdslens-update-health=$health_file" \
      "--mdslens-update-token=$health_token" \
      "--mdslens-update-commit=$commit_marker") >/dev/null 2>&1 &
    new_pid=$!
    printf '%s\n' "$new_pid" > "$pid_file"
    health_attempt=0
    while [ "$health_attempt" -lt 1200 ]; do
      if ! kill -0 "$new_pid" 2>/dev/null; then
        : > "$failed_file"
        exit 1
      fi
      if [ -f "$health_file" ] &&
         [ "$(/bin/cat "$health_file" 2>/dev/null || true)" = "$health_token" ]; then
        : > "$healthy_file"
        exit 0
      fi
      health_attempt=$((health_attempt + 1))
      sleep 0.1
    done
    : > "$failed_file"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
: > "$failed_file"
exit 1
''';

const _windowsApplyUpdateScript = r'''
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "ParentPid=%~1"
set "Installer=%~2"
set "InstallDirectory=%~3"
set "TargetExecutable=%~4"
set "Format=%~5"
set "Scope=%~6"
set "WorkDirectory=%~7"
set "ReadyFile=%~8"
set "LogFile=%~9"
rem Batch parameter expansion only addresses %0 through %9 directly.
rem Shift the first nine values out before reading the handshake values;
rem a double-digit parameter reference would otherwise expand incorrectly.
shift
shift
shift
shift
shift
shift
shift
shift
shift
set "HealthFile=%~1"
set "HealthToken=%~2"
set "CommitMarker=%~3"

>"%ReadyFile%" echo ready
>>"%LogFile%" echo [%date% %time%] Update helper started for PID %ParentPid%.

set /a WaitAttempts=0
:wait_for_parent
%SystemRoot%\System32\tasklist.exe /FI "PID eq %ParentPid%" /NH 2>NUL | %SystemRoot%\System32\find.exe "%ParentPid%" >NUL
if errorlevel 1 goto parent_exited
set /a WaitAttempts+=1
if %WaitAttempts% GEQ 300 goto parent_timeout
%SystemRoot%\System32\ping.exe -n 2 127.0.0.1 >NUL
goto wait_for_parent

:parent_timeout
>>"%LogFile%" echo [%date% %time%] Timed out waiting for MDSLens to exit.
goto relaunch

:parent_exited
>>"%LogFile%" echo [%date% %time%] Installing "%Installer%".
if /I "%Format%"=="msi" goto install_msi
start "" /wait "%Installer%" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART ^
  /CLOSEAPPLICATIONS /SP- %Scope% /DIR="%InstallDirectory%" ^
  /LOG="%LogFile%.installer.log"
set "InstallerExitCode=%errorlevel%"
goto installation_finished

:install_msi
start "" /wait msiexec.exe /i "%Installer%" /qn /norestart ^
  REBOOT=ReallySuppress INSTALLFOLDER="%InstallDirectory%" ^
  /L*v "%LogFile%.installer.log"
set "InstallerExitCode=%errorlevel%"

:installation_finished
>>"%LogFile%" echo [%date% %time%] Installer exit code: %InstallerExitCode%.
if "%InstallerExitCode%"=="0" goto installation_succeeded
if "%InstallerExitCode%"=="1641" goto installation_succeeded
if "%InstallerExitCode%"=="3010" goto installation_succeeded
goto relaunch

:installation_succeeded
del /F /Q "%Installer%" >NUL 2>&1
goto relaunch_new

:relaunch
if exist "%TargetExecutable%" (
  >>"%LogFile%" echo [%date% %time%] Relaunching "%TargetExecutable%".
  start "" /D "%InstallDirectory%" "%TargetExecutable%"
) else (
  >>"%LogFile%" echo [%date% %time%] Target executable is missing after update.
)
goto cleanup

:relaunch_new
if not exist "%TargetExecutable%" goto target_missing
>>"%LogFile%" echo [%date% %time%] Relaunching "%TargetExecutable%" with health handshake.
start "" /D "%InstallDirectory%" "%TargetExecutable%" "--mdslens-update-health=%HealthFile%" "--mdslens-update-token=%HealthToken%" "--mdslens-update-commit=%CommitMarker%"
set /a HealthAttempts=0
:wait_for_health
if not exist "%HealthFile%" goto health_poll
%SystemRoot%\System32\findstr.exe /R /X /C:"%HealthToken%" "%HealthFile%" >NUL 2>&1
if not errorlevel 1 goto health_ok
:health_poll
set /a HealthAttempts+=1
if %HealthAttempts% GEQ 1200 goto health_timeout
%SystemRoot%\System32\ping.exe -n 2 127.0.0.1 >NUL
goto wait_for_health
:health_ok
>>"%LogFile%" echo [%date% %time%] Replacement reported healthy startup.
set /a CommitAttempts=0
:wait_for_commit
if not exist "%CommitMarker%" goto commit_poll
%SystemRoot%\System32\findstr.exe /R /X /C:"%HealthToken%" "%CommitMarker%" >NUL 2>&1
if not errorlevel 1 goto commit_ok
:commit_poll
set /a CommitAttempts+=1
if %CommitAttempts% GEQ 1200 goto commit_timeout
%SystemRoot%\System32\ping.exe -n 2 127.0.0.1 >NUL
goto wait_for_commit
:commit_ok
>>"%LogFile%" echo [%date% %time%] Replacement committed the update transaction.
goto cleanup
:commit_timeout
>>"%LogFile%" echo [%date% %time%] Replacement did not commit the update transaction within 120 seconds.
goto cleanup
:health_timeout
>>"%LogFile%" echo [%date% %time%] Replacement did not report healthy startup within 120 seconds.
goto cleanup
:target_missing
>>"%LogFile%" echo [%date% %time%] Target executable is missing after update.

:cleanup
%SystemRoot%\System32\ping.exe -n 2 127.0.0.1 >NUL
rmdir /S /Q "%WorkDirectory%" >NUL 2>&1
endlocal
''';

const _windowsPortableApplyUpdateScript = r'''
$ErrorActionPreference = 'Stop'
$parentPid = [int]$args[0]
$currentRoot = [IO.Path]::GetFullPath($args[1])
$stagedRoot = [IO.Path]::GetFullPath($args[2])
$backupRoot = [IO.Path]::GetFullPath($args[3])
$archive = $args[4]
$workRoot = $args[5]
$healthFile = $args[6]
$healthToken = $args[7]
$commitMarker = $args[8]
$readyFile = $args[9]
$previousRoot = "$currentRoot.mdslens-previous"

if ($currentRoot -eq [IO.Path]::GetPathRoot($currentRoot)) { exit 1 }
if (-not $stagedRoot.StartsWith("$currentRoot.mdslens-update-")) { exit 1 }
if (-not $backupRoot.StartsWith("$currentRoot.mdslens-backup-")) { exit 1 }
if (-not (Test-Path -LiteralPath $stagedRoot -PathType Container)) { exit 1 }
if (Test-Path -LiteralPath $backupRoot) { exit 1 }
Set-Content -LiteralPath $readyFile -Value 'ready' -Encoding Ascii

for ($attempt = 0; $attempt -lt 300; $attempt++) {
  if (-not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 100
}
if (Get-Process -Id $parentPid -ErrorAction SilentlyContinue) {
  Remove-Item -LiteralPath $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}

try {
  Move-Item -LiteralPath $currentRoot -Destination $backupRoot
  Move-Item -LiteralPath $stagedRoot -Destination $currentRoot
  $target = Join-Path $currentRoot 'mdslens.exe'
  $process = Start-Process -FilePath $target -WorkingDirectory $currentRoot `
    -ArgumentList @("--mdslens-update-health=$healthFile", "--mdslens-update-token=$healthToken", "--mdslens-update-commit=$commitMarker") `
    -PassThru
  $healthy = $false
  for ($attempt = 0; $attempt -lt 1200; $attempt++) {
    $process.Refresh()
    if ($process.HasExited) { throw 'The replacement exited before reporting healthy startup.' }
    if (Test-Path -LiteralPath $healthFile) {
      try {
        $reported = (Get-Content -LiteralPath $healthFile -Raw).Trim()
        if ($reported -eq $healthToken) { $healthy = $true; break }
      } catch {}
    }
    Start-Sleep -Milliseconds 100
  }
  if (-not $healthy) { throw 'The replacement did not report healthy startup within 120 seconds.' }

  $committed = $false
  for ($attempt = 0; $attempt -lt 1200; $attempt++) {
    if (Test-Path -LiteralPath $commitMarker) {
      try {
        $reported = (Get-Content -LiteralPath $commitMarker -Raw).Trim()
        if ($reported -eq $healthToken) { $committed = $true; break }
      } catch {}
    }
    $process.Refresh()
    if ($process.HasExited) { break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $committed) { throw 'The replacement did not commit the update transaction.' }
  $previousOwned = $false
  $previousMarker = Join-Path $previousRoot '.mdslens-portable.json'
  if (Test-Path -LiteralPath $previousMarker -PathType Leaf) {
    try {
      $metadata = Get-Content -LiteralPath $previousMarker -Raw | ConvertFrom-Json
      $previousOwned = $metadata.product -eq 'com.mdslens.app' -and
        $metadata.platform -eq 'windows'
    } catch {}
  }
  if ($previousOwned) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
  if (-not (Test-Path -LiteralPath $previousRoot)) {
    Move-Item -LiteralPath $backupRoot -Destination $previousRoot
  }
  Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $previousRoot) {
    Remove-Item -LiteralPath $previousRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $commitMarker -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $healthFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
} catch {
  if (Test-Path -LiteralPath $currentRoot) {
    Remove-Item -LiteralPath $currentRoot -Recurse -Force
  }
  if (Test-Path -LiteralPath $backupRoot) {
    Move-Item -LiteralPath $backupRoot -Destination $currentRoot
    Start-Process -FilePath (Join-Path $currentRoot 'mdslens.exe') `
      -WorkingDirectory $currentRoot
  }
  Remove-Item -LiteralPath $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $healthFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}
''';

const _windowsPortablePrivilegedUpdateScript = r'''
$ErrorActionPreference = 'Stop'
$parentPid = [int]$args[0]
$archive = [IO.Path]::GetFullPath($args[1])
$expectedTopLevel = $args[2]
$expectedSha256 = $args[3]
$currentRoot = [IO.Path]::GetFullPath($args[4])
$stagedRoot = [IO.Path]::GetFullPath($args[5])
$backupRoot = [IO.Path]::GetFullPath($args[6])
$preparedFile = $args[7]
$swapReadyFile = $args[8]
$healthyFile = $args[9]
$failedFile = $args[10]
$rollbackReadyFile = $args[11]
$healthFile = $args[12]
$healthToken = $args[13]
$commitMarker = $args[14]
$newPidFile = $args[15]
$previousRoot = "$currentRoot.mdslens-previous"
$workRoot = Split-Path -Parent $preparedFile
$extractionRoot = "$stagedRoot-extracted"
trap {
  Remove-Item -LiteralPath $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $extractionRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}

if ($currentRoot -eq [IO.Path]::GetPathRoot($currentRoot)) { exit 1 }
if ([IO.Path]::GetDirectoryName($stagedRoot) -ne [IO.Path]::GetDirectoryName($currentRoot)) { exit 1 }
if ([IO.Path]::GetDirectoryName($backupRoot) -ne [IO.Path]::GetDirectoryName($currentRoot)) { exit 1 }
if (-not $stagedRoot.StartsWith("$currentRoot.mdslens-update-")) { exit 1 }
if (-not $backupRoot.StartsWith("$currentRoot.mdslens-backup-")) { exit 1 }
if ($expectedTopLevel -notmatch '^mdslens-windows-(x64|arm64)$') { exit 1 }
$expectedArchitecture = if ($expectedTopLevel.EndsWith('-arm64')) { 'arm64' } else { 'x64' }
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedSha256.ToLowerInvariant()) { exit 1 }
if ((Test-Path -LiteralPath $stagedRoot) -or (Test-Path -LiteralPath $backupRoot) -or (Test-Path -LiteralPath $extractionRoot)) { exit 1 }
Expand-Archive -LiteralPath $archive -DestinationPath $extractionRoot
$candidateRoot = Join-Path $extractionRoot $expectedTopLevel
$marker = Join-Path $candidateRoot '.mdslens-portable.json'
$target = Join-Path $candidateRoot 'mdslens.exe'
if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { exit 1 }
$metadata = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
if ($metadata.product -ne 'com.mdslens.app' -or $metadata.platform -ne 'windows' -or $metadata.architecture -ne $expectedArchitecture -or $metadata.executable -ne 'mdslens.exe') { exit 1 }
Move-Item -LiteralPath $candidateRoot -Destination $stagedRoot
Remove-Item -LiteralPath $extractionRoot -Recurse -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath $preparedFile -Value 'prepared' -Encoding Ascii
for ($attempt = 0; $attempt -lt 600; $attempt++) {
  if (-not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { break }
  Start-Sleep -Milliseconds 100
}
if (Get-Process -Id $parentPid -ErrorAction SilentlyContinue) {
  Remove-Item -LiteralPath $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $extractionRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}

try {
  Move-Item -LiteralPath $currentRoot -Destination $backupRoot
  Move-Item -LiteralPath $stagedRoot -Destination $currentRoot
  Set-Content -LiteralPath $swapReadyFile -Value 'ready' -Encoding Ascii
  for ($attempt = 0; $attempt -lt 1200; $attempt++) {
    if (Test-Path -LiteralPath $healthyFile) { break }
    if (Test-Path -LiteralPath $failedFile) { throw 'Replacement failed health check.' }
    Start-Sleep -Milliseconds 100
  }
  if (-not (Test-Path -LiteralPath $healthyFile)) { throw 'Replacement health check timed out.' }

  $replacementPid = 0
  if (Test-Path -LiteralPath $newPidFile) {
    $replacementPid = [int](Get-Content -LiteralPath $newPidFile -Raw).Trim()
  }
  if ($replacementPid -le 0) {
    throw 'Replacement process did not provide a PID.'
  }
  $committed = $false
  for ($attempt = 0; $attempt -lt 1200; $attempt++) {
    if (Test-Path -LiteralPath $commitMarker) {
      try {
        $reported = (Get-Content -LiteralPath $commitMarker -Raw).Trim()
        if ($reported -eq $healthToken) { $committed = $true; break }
      } catch {}
    }
    if (-not (Get-Process -Id $replacementPid -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 100
  }
  if (-not $committed) {
    throw 'Replacement did not commit the update transaction.'
  }
  $previousOwned = $false
  $previousMarker = Join-Path $previousRoot '.mdslens-portable.json'
  if (Test-Path -LiteralPath $previousMarker -PathType Leaf) {
    try {
      $previousMetadata = Get-Content -LiteralPath $previousMarker -Raw | ConvertFrom-Json
      $previousOwned = $previousMetadata.product -eq 'com.mdslens.app' -and $previousMetadata.platform -eq 'windows'
    } catch {}
  }
  if ($previousOwned) { Remove-Item -LiteralPath $previousRoot -Recurse -Force }
  if (-not (Test-Path -LiteralPath $previousRoot)) { Move-Item -LiteralPath $backupRoot -Destination $previousRoot }
  if (Test-Path -LiteralPath $previousRoot) {
    Remove-Item -LiteralPath $previousRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $commitMarker -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $healthFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $newPidFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  exit 0
} catch {
  if (Test-Path -LiteralPath $currentRoot) { Remove-Item -LiteralPath $currentRoot -Recurse -Force }
  if (Test-Path -LiteralPath $backupRoot) { Move-Item -LiteralPath $backupRoot -Destination $currentRoot }
  Remove-Item -LiteralPath $stagedRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $extractionRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $healthFile -Force -ErrorAction SilentlyContinue
  Set-Content -LiteralPath $rollbackReadyFile -Value 'ready' -Encoding Ascii
  exit 1
}
''';

const _windowsPortableUserRelaunchScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$currentRoot = [IO.Path]::GetFullPath($args[0])
$swapReadyFile = $args[1]
$healthyFile = $args[2]
$failedFile = $args[3]
$rollbackReadyFile = $args[4]
$archive = $args[5]
$workRoot = $args[6]
$healthFile = $args[7]
$healthToken = $args[8]
$commitMarker = $args[9]
$newPidFile = $args[10]
for ($attempt = 0; $attempt -lt 600; $attempt++) {
  if (Test-Path -LiteralPath $swapReadyFile) { break }
  Start-Sleep -Milliseconds 100
}
if (-not (Test-Path -LiteralPath $swapReadyFile)) {
  Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
  exit 1
}
$target = Join-Path $currentRoot 'mdslens.exe'
$process = Start-Process -FilePath $target -WorkingDirectory $currentRoot `
  -ArgumentList @("--mdslens-update-health=$healthFile", "--mdslens-update-token=$healthToken", "--mdslens-update-commit=$commitMarker") `
  -PassThru
Set-Content -LiteralPath $newPidFile -Value $process.Id -Encoding Ascii
for ($attempt = 0; $attempt -lt 1200; $attempt++) {
  $process.Refresh()
  if ($process.HasExited) { break }
  if (Test-Path -LiteralPath $healthFile) {
    try {
      $reported = (Get-Content -LiteralPath $healthFile -Raw).Trim()
      if ($reported -eq $healthToken) {
        Set-Content -LiteralPath $healthyFile -Value 'healthy' -Encoding Ascii
        exit 0
      }
    } catch {}
  }
  Start-Sleep -Milliseconds 100
}
Set-Content -LiteralPath $failedFile -Value 'failed' -Encoding Ascii
for ($attempt = 0; $attempt -lt 300; $attempt++) {
  if (Test-Path -LiteralPath $rollbackReadyFile) { break }
  Start-Sleep -Milliseconds 100
}
if (Test-Path -LiteralPath (Join-Path $currentRoot 'mdslens.exe')) {
  Start-Process -FilePath (Join-Path $currentRoot 'mdslens.exe') -WorkingDirectory $currentRoot
}
Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
exit 1
''';

Future<void> requestApplicationExitForUpdate() async {
  exit(0);
}

/// Removes an owned Linux portable rollback directory left by an older
/// transaction or by a helper that was interrupted after the replacement had
/// already committed. Current helpers clean it in the same transaction.
Future<void> scheduleLinuxPortableRollbackCleanup({
  String? platformOverride,
  String? currentExecutableOverride,
  Duration stabilityWindow = _defaultUpdateStabilityWindow,
}) async {
  final platform = platformOverride ?? Platform.operatingSystem;
  if (platform.toLowerCase() != 'linux') return;
  final executable = currentExecutableOverride ?? resolvedExecutableForUpdate();
  final currentRoot = linuxPortableRootFromExecutable(executable);
  if (currentRoot == null) return;

  final currentMarker = File(
    '$currentRoot${Platform.pathSeparator}.mdslens-portable.json',
  );
  final previous = Directory('$currentRoot.mdslens-previous');
  if (await FileSystemEntity.type(
        previous.path,
        followLinks: false,
      ) !=
      FileSystemEntityType.directory) {
    return;
  }
  if (!await _validLinuxPortableMarker(currentMarker)) return;
  final previousMarker = File(
    '${previous.path}${Platform.pathSeparator}.mdslens-portable.json',
  );
  if (!await _validLinuxPortableMarker(previousMarker)) return;

  if (stabilityWindow > Duration.zero) {
    await Future<void>.delayed(stabilityWindow);
  }
  // Re-check ownership after the delay so a concurrent update or a manually
  // replaced directory cannot turn this cleanup into an unsafe deletion.
  if (!await _validLinuxPortableMarker(currentMarker) ||
      !await _validLinuxPortableMarker(previousMarker)) {
    return;
  }
  try {
    await previous.delete(recursive: true);
    // Linux portable helpers from older releases only removed the rollback
    // directory.  Remove the matching transaction marker as well so a
    // successful update cannot leave a misleading "committed" artifact next
    // to the installation forever.
    final commit = File('$currentRoot.mdslens-update-committed');
    if (await _validUpdateCommitMarker(commit)) {
      await commit.delete();
    }
  } catch (_) {
    // A protected installation may be owned by root. The privileged updater
    // performs the same delayed cleanup when it has the required authority.
  }
}

/// Schedules recovery cleanup for every native self-replacing channel. The
/// helper normally removes the rollback copy itself; this startup path is a
/// compatibility safety net for transactions created by older releases or a
/// helper interrupted during final cleanup.
Future<void> scheduleNativeRollbackCleanup({
  String? platformOverride,
  String? currentExecutableOverride,
  String? currentAppImageOverride,
  Duration stabilityWindow = _defaultUpdateStabilityWindow,
}) async {
  final platform = (platformOverride ?? Platform.operatingSystem).toLowerCase();
  switch (platform) {
    case 'windows':
      await scheduleWindowsPortableRollbackCleanup(
        platformOverride: platform,
        currentExecutableOverride: currentExecutableOverride,
        stabilityWindow: stabilityWindow,
      );
    case 'macos':
      await scheduleMacOSRollbackCleanup(
        platformOverride: platform,
        currentExecutableOverride: currentExecutableOverride,
        stabilityWindow: stabilityWindow,
      );
    case 'linux':
      final appImage = currentAppImageOverride ??
          (Platform.environment['APPIMAGE'] ?? '').trim();
      if (appImage.isNotEmpty) {
        await scheduleLinuxAppImageRollbackCleanup(
          platformOverride: platform,
          currentAppImageOverride: appImage,
          stabilityWindow: stabilityWindow,
        );
      } else {
        await scheduleLinuxPortableRollbackCleanup(
          platformOverride: platform,
          currentExecutableOverride: currentExecutableOverride,
          stabilityWindow: stabilityWindow,
        );
      }
  }
}

Future<void> scheduleWindowsPortableRollbackCleanup({
  String? platformOverride,
  String? currentExecutableOverride,
  Duration stabilityWindow = _defaultUpdateStabilityWindow,
}) async {
  final platform = platformOverride ?? Platform.operatingSystem;
  if (platform.toLowerCase() != 'windows') return;
  final executable = currentExecutableOverride ?? Platform.resolvedExecutable;
  final currentRoot = windowsPortableRootFromExecutable(executable);
  if (currentRoot == null) return;

  final currentMarker = File(
    '$currentRoot${Platform.pathSeparator}.mdslens-portable.json',
  );
  final previous = Directory('$currentRoot.mdslens-previous');
  final commit = File('$currentRoot.mdslens-update-committed');
  if (!await _validWindowsPortableMarker(currentMarker) ||
      !await _validUpdateCommitMarker(commit) ||
      await FileSystemEntity.type(
            previous.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory) {
    return;
  }
  final previousMarker = File(
    '${previous.path}${Platform.pathSeparator}.mdslens-portable.json',
  );
  if (!await _validWindowsPortableMarker(previousMarker)) return;

  if (stabilityWindow > Duration.zero) {
    await Future<void>.delayed(stabilityWindow);
  }
  if (!await _validWindowsPortableMarker(currentMarker) ||
      !await _validUpdateCommitMarker(commit) ||
      !await _validWindowsPortableMarker(previousMarker)) {
    return;
  }
  try {
    await previous.delete(recursive: true);
    await commit.delete();
  } catch (_) {
    // A protected installation is cleaned by the privileged helper.  Do not
    // ask for a second authorization prompt during ordinary startup.
  }
}

Future<void> scheduleMacOSRollbackCleanup({
  String? platformOverride,
  String? currentExecutableOverride,
  Duration stabilityWindow = _defaultUpdateStabilityWindow,
}) async {
  final platform = platformOverride ?? Platform.operatingSystem;
  if (platform.toLowerCase() != 'macos') return;
  final executable = currentExecutableOverride ?? Platform.resolvedExecutable;
  final bundlePath = macOSBundlePathFromExecutable(executable);
  if (bundlePath == null) return;
  final current = Directory(bundlePath);
  final previous = Directory('$bundlePath.mdslens-previous');
  final commit = File('$bundlePath.mdslens-update-committed');
  if (!await current.exists() ||
      !await _validUpdateCommitMarker(commit) ||
      await FileSystemEntity.type(
            previous.path,
            followLinks: false,
          ) !=
          FileSystemEntityType.directory ||
      !await File('${previous.path}/Contents/Info.plist').exists()) {
    return;
  }
  if (stabilityWindow > Duration.zero) {
    await Future<void>.delayed(stabilityWindow);
  }
  if (!await current.exists() ||
      !await _validUpdateCommitMarker(commit) ||
      !await File('${previous.path}/Contents/Info.plist').exists()) {
    return;
  }
  try {
    await previous.delete(recursive: true);
    await commit.delete();
  } catch (_) {}
}

Future<void> scheduleLinuxAppImageRollbackCleanup({
  String? platformOverride,
  String? currentAppImageOverride,
  Duration stabilityWindow = _defaultUpdateStabilityWindow,
}) async {
  final platform = platformOverride ?? Platform.operatingSystem;
  if (platform.toLowerCase() != 'linux') return;
  final rawPath = currentAppImageOverride ??
      (Platform.environment['APPIMAGE'] ?? '').trim();
  if (rawPath.trim().isEmpty) return;
  String currentPath;
  try {
    currentPath = await File(rawPath).resolveSymbolicLinks();
  } catch (_) {
    return;
  }
  final current = File(currentPath);
  final previous = File('$currentPath.mdslens-previous');
  final owner = File('$currentPath.mdslens-previous.owner');
  final commit = File('$currentPath.mdslens-update-committed');
  if (!await current.exists() ||
      !await _validUpdateCommitMarker(commit) ||
      !await previous.exists() ||
      !await owner.exists() ||
      (await owner.readAsString()).trim() != 'com.mdslens.app') {
    return;
  }
  if (stabilityWindow > Duration.zero) {
    await Future<void>.delayed(stabilityWindow);
  }
  if (!await current.exists() ||
      !await _validUpdateCommitMarker(commit) ||
      !await previous.exists() ||
      (await owner.readAsString()).trim() != 'com.mdslens.app') {
    return;
  }
  try {
    await previous.delete();
    await owner.delete();
    await commit.delete();
  } catch (_) {}
}

Future<bool> _validUpdateCommitMarker(File marker) async {
  try {
    if (await FileSystemEntity.type(
          marker.path,
          followLinks: false,
        ) ==
        FileSystemEntityType.link) {
      return false;
    }
    final value = (await marker.readAsString()).trim();
    return RegExp(r'^[A-Za-z0-9_-]{32,}$').hasMatch(value);
  } catch (_) {
    return false;
  }
}

Future<UpdateInstallResult> launchVerifiedUpdateAsset(
  DownloadedUpdate update, {
  String? platformOverride,
  DetachedCommandLauncher? commandLauncher,
  CommandRunner? commandRunner,
  String? currentExecutableOverride,
  String? currentAppImageOverride,
  String? currentPortableRootOverride,
  int? currentPidOverride,
  int windowsHelperReadyAttempts = 300,
  String? linuxPackageManagerPathOverride,
  String? linuxPkexecPathOverride,
}) async {
  final platform = platformOverride ?? Platform.operatingSystem;
  final launch = commandLauncher ??
      (platform == 'windows' ? _startWindowsDetached : _startDetached);
  final run = commandRunner ?? _runCommand;
  if (platform == 'android') {
    final status = await _updaterChannel.invokeMethod<String>(
      'installApk',
      update.path,
    );
    return switch (status) {
      'launched' => UpdateInstallResult(
          status: UpdateLaunchStatus.launched,
          message: 'The Android system installer is ready.',
          downloaded: update,
        ),
      'permission_required' => UpdateInstallResult(
          status: UpdateLaunchStatus.permissionRequired,
          message:
              'Allow MDSLens to install apps. The verified package will continue to the system installer when you return.',
          downloaded: update,
        ),
      'signature_mismatch' => UpdateInstallResult(
          status: UpdateLaunchStatus.unsupported,
          message:
              'This installed copy and the update use different Android signing keys. Export any configuration you need, uninstall this copy once, then install the latest release. Updates after that migration can install normally.',
          downloaded: update,
        ),
      'not_newer' => UpdateInstallResult(
          status: UpdateLaunchStatus.unsupported,
          message:
              'Android rejected this package because its version is not newer than the installed copy.',
          downloaded: update,
        ),
      'invalid_package' => UpdateInstallResult(
          status: UpdateLaunchStatus.unsupported,
          message:
              'The verified download is not a valid MDSLens Android package.',
          downloaded: update,
        ),
      'installer_unavailable' => UpdateInstallResult(
          status: UpdateLaunchStatus.unsupported,
          message:
              'No Android package installer is available for this device profile.',
          downloaded: update,
        ),
      _ => throw PlatformException(
          code: 'INSTALL_UPDATE_FAILED',
          message: 'Android returned an unknown update status: $status',
        ),
    };
  }
  if (platform == 'windows') {
    final currentExecutable =
        currentExecutableOverride ?? Platform.resolvedExecutable;
    final portableRoot = windowsPortableRootFromExecutable(currentExecutable);
    if (update.asset.format == 'zip' && portableRoot != null) {
      return await prepareWindowsPortableUpdate(
        update,
        portableRoot: portableRoot,
        currentPid: currentPidOverride ?? pid,
        commandLauncher: launch,
        commandRunner: run,
        helperReadyAttempts: windowsHelperReadyAttempts,
      );
    }
    final installDirectory =
        Directory(windowsInstallDirectoryFromExecutable(currentExecutable));
    final installDirectoryWritable = await _directoryIsWritable(
      installDirectory,
    );
    final scopeArgument =
        installDirectoryWritable ? '/CURRENTUSER' : '/ALLUSERS';
    final work = await Directory.systemTemp.createTemp(
      'mdslens-windows-update-',
    );
    final helper = File(
      '${work.path}${Platform.pathSeparator}apply-update.cmd',
    );
    final ready = File(
      '${work.path}${Platform.pathSeparator}helper-ready',
    );
    final handshake = _createUpdateHandshake(
      work,
      commitMarker: '${work.path}${Platform.pathSeparator}committed',
    );
    final localAppData = (Platform.environment['LOCALAPPDATA'] ?? '').trim();
    final logDirectory = localAppData.isEmpty
        ? Directory.systemTemp
        : Directory(
            '$localAppData${Platform.pathSeparator}MDSLens${Platform.pathSeparator}updates',
          );
    await logDirectory.create(recursive: true);
    final log = File(
      '${logDirectory.path}${Platform.pathSeparator}latest-update.log',
    );
    await helper.writeAsString(_windowsApplyUpdateScript);
    final helperArguments = <String>[
      '${currentPidOverride ?? pid}',
      update.path,
      installDirectory.path,
      currentExecutable,
      update.asset.format,
      scopeArgument,
      work.path,
      ready.path,
      log.path,
      handshake.healthFile.path,
      handshake.token,
      handshake.commitMarker,
    ];

    // Always use `cmd start` for the first hop.  A direct detached `cmd`
    // process can still belong to the Flutter runner's Windows job and be
    // terminated as soon as this application exits.  `start` creates the
    // actual update helper as an independent process before we hand control
    // back to the caller.
    var helperLaunched = false;
    var directFallbackLaunched = false;
    try {
      await launch(
        'cmd.exe',
        _windowsDetachedStartArguments(helper.path, helperArguments),
      );
      helperLaunched = true;
    } catch (_) {
      // The direct call below is retained as a compatibility fallback for
      // unusual Windows environments where `start` is unavailable.
      try {
        await launch('cmd.exe', [
          '/d',
          '/s',
          '/c',
          'call',
          helper.path,
          ...helperArguments,
        ]);
        helperLaunched = true;
        directFallbackLaunched = true;
      } catch (_) {}
    }
    final initialAttempts = min(windowsHelperReadyAttempts, 20);
    var helperReady =
        helperLaunched && await _waitForFile(ready, attempts: initialAttempts);
    if (!helperReady && helperLaunched && !directFallbackLaunched) {
      // Some older Windows shells do not support the detached `start` form
      // with a .cmd target. Give the legacy invocation a chance, but only
      // after the first helper has failed to claim the ready marker.
      try {
        await launch('cmd.exe', [
          '/d',
          '/s',
          '/c',
          'call',
          helper.path,
          ...helperArguments,
        ]);
      } catch (_) {}
      helperReady = await _waitForFile(
        ready,
        attempts: max(0, windowsHelperReadyAttempts - initialAttempts),
      );
    } else if (!helperReady) {
      helperReady = await _waitForFile(
        ready,
        attempts: max(0, windowsHelperReadyAttempts - initialAttempts),
      );
    }
    if (!helperReady) {
      try {
        await work.delete(recursive: true);
      } catch (_) {}
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message:
            'Windows did not start the update helper, so MDSLens stayed open and the installed version was left unchanged.',
        downloaded: update,
      );
    }
    return UpdateInstallResult(
      status: UpdateLaunchStatus.installed,
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
    final currentExecutable =
        currentExecutableOverride ?? resolvedExecutableForUpdate();
    final currentAppImage = currentAppImageOverride ??
        (Platform.environment['APPIMAGE'] ?? '').trim();
    final portableRoot = currentPortableRootOverride ??
        linuxPortableRootFromExecutable(currentExecutable);

    // Never hand a package from another installation channel to the system
    // installer.  Doing so is especially confusing for portable launches:
    // the new process would come from /usr while the original directory would
    // still contain the old release.
    if (currentAppImage.isNotEmpty && update.asset.format != 'AppImage') {
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message:
            'The verified update does not match the running AppImage installation.',
        downloaded: update,
      );
    }
    if (currentAppImage.isEmpty &&
        portableRoot != null &&
        update.asset.format != 'tar.gz') {
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message:
            'The verified update does not match the running portable installation.',
        downloaded: update,
      );
    }
    if (update.asset.format == 'AppImage' && currentAppImage.isNotEmpty) {
      final prepared = await prepareAppImageUpdate(
        update,
        currentAppImage,
        currentPid: currentPidOverride ?? pid,
        commandLauncher: launch,
      );
      if (prepared != null) return prepared;
      final elevated = await prepareElevatedAppImageUpdate(
        update,
        currentAppImage,
        currentPid: currentPidOverride ?? pid,
        commandLauncher: launch,
        commandRunner: run,
      );
      if (elevated != null) return elevated;
    }
    if (update.asset.format == 'tar.gz' && portableRoot != null) {
      final prepared = await prepareLinuxPortableUpdate(
        update,
        portableRoot: portableRoot,
        currentPid: currentPidOverride ?? pid,
        commandLauncher: launch,
        commandRunner: run,
        pkexecPathOverride: linuxPkexecPathOverride,
      );
      if (prepared != null) return prepared;
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message:
            'The verified portable update could not be prepared safely. The current application was left unchanged.',
        downloaded: update,
      );
    }
    if (const {'rpm', 'deb', 'pkg.tar.zst', 'pkg.tar.xz'}
        .contains(update.asset.format)) {
      final installed = await prepareLinuxSystemPackageUpdate(
        update,
        currentExecutable: currentExecutable,
        currentPid: currentPidOverride ?? pid,
        commandLauncher: launch,
        commandRunner: run,
        packageManagerPathOverride: linuxPackageManagerPathOverride,
        pkexecPathOverride: linuxPkexecPathOverride,
      );
      if (installed != null) return installed;
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

Future<UpdateInstallResult> prepareWindowsPortableUpdate(
  DownloadedUpdate update, {
  required String portableRoot,
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
  required CommandRunner commandRunner,
  String? nonceOverride,
  int helperReadyAttempts = 300,
  int authorizationReadyAttempts = 600,
  bool? parentWritableOverride,
}) async {
  final powershell = _windowsPowerShellExecutable();
  final currentRoot = Directory(portableRoot);
  if (!await currentRoot.exists() ||
      windowsPortableRootFromExecutable(
            '${currentRoot.path}${Platform.pathSeparator}mdslens.exe',
          ) !=
          currentRoot.path) {
    return const UpdateInstallResult(
      status: UpdateLaunchStatus.unsupported,
      message: 'The Windows portable installation marker is invalid.',
    );
  }
  final expectedTopLevel = update.asset.name.substring(
    0,
    update.asset.name.length - '.zip'.length,
  );
  if (!RegExp(r'^mdslens-windows-(x64|arm64)$').hasMatch(expectedTopLevel)) {
    return UpdateInstallResult(
      status: UpdateLaunchStatus.unsupported,
      message: 'The Windows portable update name is invalid.',
      downloaded: update,
    );
  }

  final work = await Directory.systemTemp.createTemp(
    'mdslens-windows-portable-update-',
  );
  final extracted = Directory(
    '${work.path}${Platform.pathSeparator}extracted',
  );
  final candidate = Directory(
    '${extracted.path}${Platform.pathSeparator}$expectedTopLevel',
  );
  final nonceBase =
      nonceOverride ?? '$currentPid-${DateTime.now().microsecondsSinceEpoch}';
  Directory? staged;
  Directory? backup;
  for (var attempt = 0; attempt < 100; attempt++) {
    final nonce = attempt == 0 ? nonceBase : '$nonceBase-$attempt';
    final proposedStage =
        Directory('${currentRoot.path}.mdslens-update-$nonce');
    final proposedBackup =
        Directory('${currentRoot.path}.mdslens-backup-$nonce');
    if (!await _fileSystemEntryExists(proposedStage.path) &&
        !await _fileSystemEntryExists(proposedBackup.path)) {
      staged = proposedStage;
      backup = proposedBackup;
      break;
    }
  }
  if (staged == null || backup == null) {
    await work.delete(recursive: true);
    return UpdateInstallResult(
      status: UpdateLaunchStatus.unsupported,
      message: 'No safe staging path was available for the update.',
      downloaded: update,
    );
  }

  var scheduled = false;
  try {
    final unpack = await commandRunner(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'& { param($archive, $destination); Expand-Archive -LiteralPath $archive -DestinationPath $destination -Force }',
      update.path,
      extracted.path,
    ]);
    final marker = File(
      '${candidate.path}${Platform.pathSeparator}.mdslens-portable.json',
    );
    final executable = File(
      '${candidate.path}${Platform.pathSeparator}mdslens.exe',
    );
    if (unpack.exitCode != 0 ||
        !await executable.exists() ||
        !await _validWindowsPortableMarker(
          marker,
          architecture: update.asset.architecture,
        )) {
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message: 'The verified Windows portable archive is not valid.',
        downloaded: update,
      );
    }
    final parentWritable = parentWritableOverride ??
        await _directoryIsWritable(currentRoot.parent);
    if (!parentWritable) {
      final result = await _prepareProtectedWindowsPortableUpdate(
        update,
        currentRoot: currentRoot,
        staged: staged,
        backup: backup,
        work: work,
        currentPid: currentPid,
        commandLauncher: commandLauncher,
        commandRunner: commandRunner,
        helperReadyAttempts: authorizationReadyAttempts,
      );
      scheduled = result.closeApplication;
      return result;
    }
    final stage = await commandRunner(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'& { param($source, $destination); Copy-Item -LiteralPath $source -Destination $destination -Recurse }',
      candidate.path,
      staged.path,
    ]);
    if (stage.exitCode != 0 || !await Directory(staged.path).exists()) {
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message: 'The Windows portable update could not be staged.',
        downloaded: update,
      );
    }
    final helper = File(
      '${work.path}${Platform.pathSeparator}apply-update.ps1',
    );
    final ready = File(
      '${work.path}${Platform.pathSeparator}helper-ready',
    );
    final handshake = _createUpdateHandshake(
      work,
      commitMarker: '${currentRoot.path}.mdslens-update-committed',
    );
    await helper.writeAsString(_windowsPortableApplyUpdateScript);
    final helperArguments = <String>[
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      helper.path,
      '$currentPid',
      currentRoot.path,
      staged.path,
      backup.path,
      update.path,
      work.path,
      handshake.healthFile.path,
      handshake.token,
      handshake.commitMarker,
      ready.path,
    ];

    // Launch through `cmd start` first.  A few Windows desktop launchers put
    // Flutter in a process job that is torn down with the UI process; a direct
    // PowerShell child can therefore disappear at the exact moment the app
    // exits. `start` creates a second, independent process before we hand the
    // update over. The helper writes its ready marker before it waits for the
    // current process, so the caller can safely close after this handoff.
    var helperLaunched = false;
    var directFallbackLaunched = false;
    try {
      await commandLauncher(
        'cmd.exe',
        _windowsDetachedStartArguments(powershell, helperArguments),
      );
      helperLaunched = true;
    } catch (_) {
      // The direct PowerShell call below is retained for unusual shells where
      // `cmd start` cannot be invoked.
      try {
        await commandLauncher(powershell, helperArguments);
        helperLaunched = true;
        directFallbackLaunched = true;
      } catch (_) {}
    }
    final initialAttempts = min(helperReadyAttempts, 20);
    var helperReady =
        helperLaunched && await _waitForFile(ready, attempts: initialAttempts);
    if (!helperReady && helperLaunched && !directFallbackLaunched) {
      try {
        await commandLauncher(powershell, helperArguments);
      } catch (_) {}
      helperReady = await _waitForFile(
        ready,
        attempts: max(0, helperReadyAttempts - initialAttempts),
      );
    } else if (!helperReady) {
      helperReady = await _waitForFile(
        ready,
        attempts: max(0, helperReadyAttempts - initialAttempts),
      );
    }
    if (!helperReady) {
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message:
            'Windows did not start the portable update helper, so MDSLens stayed open.',
        downloaded: update,
      );
    }
    scheduled = true;
    return UpdateInstallResult(
      status: UpdateLaunchStatus.installed,
      message:
          'The portable update is ready. MDSLens will restart automatically.',
      downloaded: update,
      closeApplication: true,
    );
  } finally {
    if (!scheduled) {
      try {
        if (await staged.exists()) await staged.delete(recursive: true);
      } catch (_) {}
      try {
        if (await work.exists()) await work.delete(recursive: true);
      } catch (_) {}
    }
  }
}

Future<UpdateInstallResult> _prepareProtectedWindowsPortableUpdate(
  DownloadedUpdate update, {
  required Directory currentRoot,
  required Directory staged,
  required Directory backup,
  required Directory work,
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
  required CommandRunner commandRunner,
  required int helperReadyAttempts,
}) async {
  final powershell = _windowsPowerShellExecutable();
  final privilegedHelper = File(
    '${work.path}${Platform.pathSeparator}apply-update-elevated.ps1',
  );
  final userHelper = File(
    '${work.path}${Platform.pathSeparator}relaunch-update.ps1',
  );
  final bootstrap = File(
    '${work.path}${Platform.pathSeparator}request-elevation.ps1',
  );
  final prepared = File('${work.path}${Platform.pathSeparator}prepared');
  final swapReady = File('${work.path}${Platform.pathSeparator}swap-ready');
  final healthy = File('${work.path}${Platform.pathSeparator}healthy');
  final failed = File('${work.path}${Platform.pathSeparator}failed');
  final rollbackReady =
      File('${work.path}${Platform.pathSeparator}rollback-ready');
  final handshake = _createUpdateHandshake(
    work,
    // The replacement runs as the current user even when the swap helper is
    // elevated, so the commit marker must live in the user-writable
    // transaction directory rather than beside a protected installation.
    commitMarker: '${work.path}${Platform.pathSeparator}committed',
  );
  final newPid = File('${work.path}${Platform.pathSeparator}new-pid');
  await privilegedHelper.writeAsString(_windowsPortablePrivilegedUpdateScript);
  await userHelper.writeAsString(_windowsPortableUserRelaunchScript);
  await bootstrap.writeAsString(r'''
$ErrorActionPreference = 'Stop'
try {
  $quoted = $args | ForEach-Object { '"' + $_ + '"' }
  $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File') + $quoted
  $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments
  exit 0
} catch {
  exit 1223
}
''');

  final elevatedArguments = <String>[
    privilegedHelper.path,
    '$currentPid',
    update.path,
    update.asset.name.substring(0, update.asset.name.length - 4),
    update.asset.sha256,
    currentRoot.path,
    staged.path,
    backup.path,
    prepared.path,
    swapReady.path,
    healthy.path,
    failed.path,
    rollbackReady.path,
    handshake.healthFile.path,
    handshake.token,
    handshake.commitMarker,
    newPid.path,
  ];
  final elevation = await commandRunner(powershell, [
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    bootstrap.path,
    ...elevatedArguments,
  ]);
  if (elevation.exitCode != 0) {
    return UpdateInstallResult(
      status: UpdateLaunchStatus.permissionRequired,
      message:
          'Administrator permission was not granted, so MDSLens stayed open.',
      downloaded: update,
    );
  }
  if (!await _waitForFile(prepared, attempts: helperReadyAttempts)) {
    return UpdateInstallResult(
      status: UpdateLaunchStatus.permissionRequired,
      message:
          'Windows did not authorize the protected portable update, so MDSLens stayed open.',
      downloaded: update,
    );
  }

  final userHelperArguments = <String>[
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    userHelper.path,
    currentRoot.path,
    swapReady.path,
    healthy.path,
    failed.path,
    rollbackReady.path,
    update.path,
    work.path,
    handshake.healthFile.path,
    handshake.token,
    handshake.commitMarker,
    newPid.path,
  ];
  // The relaunch helper must outlive the Flutter process just like the
  // ordinary portable helper.  Start it through an independent Windows shell
  // process so UAC work can finish after the current app closes.
  try {
    await commandLauncher(
      'cmd.exe',
      _windowsDetachedStartArguments(userHelper.path, userHelperArguments),
    );
  } catch (_) {
    await commandLauncher(powershell, userHelperArguments);
  }
  return UpdateInstallResult(
    status: UpdateLaunchStatus.installed,
    message:
        'The protected portable update is authorized. MDSLens will restart as the current user.',
    downloaded: update,
    closeApplication: true,
  );
}

Future<bool> _validWindowsPortableMarker(
  File marker, {
  String? architecture,
}) async {
  try {
    final metadata = jsonDecode(await marker.readAsString());
    return metadata is Map &&
        metadata['schema_version'] == 1 &&
        metadata['product'] == 'com.mdslens.app' &&
        metadata['platform'] == 'windows' &&
        metadata['executable'] == 'mdslens.exe' &&
        (architecture == null || metadata['architecture'] == architecture);
  } catch (_) {
    return false;
  }
}

Future<bool> _waitForFile(
  File file, {
  int attempts = _updateHealthTimeoutAttempts,
  Duration interval = const Duration(milliseconds: 100),
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (await file.exists()) return true;
    await Future<void>.delayed(interval);
  }
  return false;
}

Future<UpdateInstallResult?> prepareLinuxSystemPackageUpdate(
  DownloadedUpdate update, {
  required String currentExecutable,
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
  required CommandRunner commandRunner,
  String? packageManagerPathOverride,
  String? pkexecPathOverride,
}) async {
  final format = update.asset.format.toLowerCase();
  if (!const {'rpm', 'deb', 'pkg.tar.zst', 'pkg.tar.xz'}.contains(format)) {
    return null;
  }

  final pkexec = pkexecPathOverride ??
      _firstExistingExecutable(const ['/usr/bin/pkexec', '/bin/pkexec']);
  final packageManager = packageManagerPathOverride ??
      _firstExistingExecutable(
        format == 'rpm'
            ? const [
                '/usr/bin/dnf5',
                '/usr/bin/dnf',
                '/usr/bin/zypper',
              ]
            : format == 'deb'
                ? const ['/usr/bin/apt-get']
                : const ['/usr/bin/pacman'],
      );
  if (pkexec == null || packageManager == null) return null;

  final managerName =
      packageManager.substring(packageManager.lastIndexOf('/') + 1);
  final arguments = switch (managerName) {
    'dnf5' || 'dnf' => [
        'install',
        '-y',
        '--nogpgcheck',
        update.path,
      ],
    'zypper' => [
        '--non-interactive',
        '--no-gpg-checks',
        'install',
        '--allow-unsigned-rpm',
        update.path,
      ],
    'apt-get' => [
        'install',
        '-y',
        update.path,
      ],
    'pacman' => [
        '-U',
        '--noconfirm',
        update.path,
      ],
    _ => null,
  };
  if (arguments == null) return null;

  // The release manifest's size and SHA-256 have already been verified before
  // this point. PolicyKit keeps the privilege boundary in the operating
  // system, while invoking the package manager directly avoids GUI software
  // centers refreshing unrelated repositories before installing a local file.
  final installation = await commandRunner(
    pkexec,
    [packageManager, ...arguments],
  );
  if (installation.exitCode != 0) {
    final authorizationDismissed =
        installation.exitCode == 126 || installation.exitCode == 127;
    return UpdateInstallResult(
      status: authorizationDismissed
          ? UpdateLaunchStatus.permissionRequired
          : UpdateLaunchStatus.unsupported,
      message: authorizationDismissed
          ? 'Administrator authorization was not granted. The installed application was left unchanged.'
          : 'The system package manager could not install the verified update. The installed application was left unchanged.',
      downloaded: update,
    );
  }

  await scheduleApplicationRelaunch(
    currentExecutable,
    currentPid: currentPid,
    commandLauncher: commandLauncher,
  );
  return UpdateInstallResult(
    status: UpdateLaunchStatus.installed,
    message: 'The update was installed. MDSLens will restart now.',
    downloaded: update,
    closeApplication: true,
  );
}

String? _firstExistingExecutable(List<String> candidates) {
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

String windowsInstallDirectoryFromExecutable(String executablePath) {
  final separator = [
    executablePath.lastIndexOf('/'),
    executablePath.lastIndexOf(r'\'),
  ].reduce((left, right) => left > right ? left : right);
  if (separator <= 0) return Directory.current.path;
  return executablePath.substring(0, separator);
}

String? windowsPortableRootFromExecutable(String executablePath) {
  if (executablePath.trim().isEmpty) return null;
  final directory = File(executablePath).parent;
  final marker = File(
    '${directory.path}${Platform.pathSeparator}.mdslens-portable.json',
  );
  try {
    if (!marker.existsSync()) return null;
    final metadata = jsonDecode(marker.readAsStringSync());
    if (metadata is Map &&
        metadata['schema_version'] == 1 &&
        metadata['product'] == 'com.mdslens.app' &&
        metadata['platform'] == 'windows' &&
        metadata['executable'] == 'mdslens.exe' &&
        File(
          '${directory.path}${Platform.pathSeparator}mdslens.exe',
        ).existsSync()) {
      return directory.path;
    }
  } catch (_) {}
  return null;
}

String _preferredWindowsPackageFormat() {
  return windowsPortableRootFromExecutable(Platform.resolvedExecutable) != null
      ? 'zip'
      : 'exe';
}

String? linuxPortableRootFromExecutable(String executablePath) {
  if (executablePath.trim().isEmpty) return null;
  Directory directory = File(executablePath).parent;
  for (var depth = 0; depth < 6; depth++) {
    final marker = File(
      '${directory.path}${Platform.pathSeparator}.mdslens-portable.json',
    );
    try {
      if (marker.existsSync()) {
        final metadata = jsonDecode(marker.readAsStringSync());
        if (metadata is Map &&
            metadata['product'] == 'com.mdslens.app' &&
            metadata['schema_version'] == 1 &&
            File(
              '${directory.path}${Platform.pathSeparator}mdslens',
            ).existsSync()) {
          return directory.path;
        }
        return null;
      }
    } catch (_) {
      return null;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}

Future<UpdateInstallResult?> prepareLinuxPortableUpdate(
  DownloadedUpdate update, {
  required String portableRoot,
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
  required CommandRunner commandRunner,
  String? pkexecPathOverride,
  bool? parentWritableOverride,
  String? nonceOverride,
}) async {
  if (update.asset.format != 'tar.gz') return null;
  Directory currentRoot;
  try {
    currentRoot = Directory(
      await Directory(portableRoot).resolveSymbolicLinks(),
    );
  } catch (_) {
    return null;
  }
  if (!await currentRoot.exists()) return null;
  final rootParent = currentRoot.parent;
  if (currentRoot.path == rootParent.path ||
      currentRoot.path == Platform.pathSeparator ||
      !currentRoot.path
          .startsWith('${rootParent.path}${Platform.pathSeparator}')) {
    return null;
  }
  final marker = File(
    '${currentRoot.path}${Platform.pathSeparator}.mdslens-portable.json',
  );
  if (!await _validLinuxPortableMarker(marker)) return null;
  final tar = _firstExistingExecutable(const ['/bin/tar', '/usr/bin/tar']);
  if (tar == null) return null;

  final expectedTopLevel = update.asset.name
      .substring(0, update.asset.name.length - '.tar.gz'.length);
  if (!RegExp(r'^mdslens-linux-(x64|arm64)$').hasMatch(expectedTopLevel)) {
    return null;
  }
  final listing = await commandRunner(tar, ['-tzf', update.path]);
  if (listing.exitCode != 0) return null;
  final entries = listing.stdout.toString().split('\n').where(
        (entry) => entry.isNotEmpty,
      );
  for (final entry in entries) {
    if (entry.startsWith('/') ||
        entry.contains(r'\') ||
        entry.split('/').contains('..') ||
        (entry != expectedTopLevel &&
            !entry.startsWith('$expectedTopLevel/'))) {
      return null;
    }
  }
  final detailed = await commandRunner(tar, ['-tvzf', update.path]);
  if (detailed.exitCode != 0) return null;
  for (final line in detailed.stdout
      .toString()
      .split('\n')
      .where((line) => line.isNotEmpty)) {
    if (line.startsWith('l') || line.startsWith('h')) return null;
  }

  final nonceBase =
      nonceOverride ?? '$currentPid-${DateTime.now().microsecondsSinceEpoch}';
  Directory? stagedRootCandidate;
  Directory? backupRootCandidate;
  for (var attempt = 0; attempt < 100; attempt++) {
    final nonce = attempt == 0 ? nonceBase : '$nonceBase-$attempt';
    final staged = Directory('${currentRoot.path}.mdslens-update-$nonce');
    final backup = Directory('${currentRoot.path}.mdslens-backup-$nonce');
    if (!await _fileSystemEntryExists(staged.path) &&
        !await _fileSystemEntryExists(backup.path)) {
      stagedRootCandidate = staged;
      backupRootCandidate = backup;
      break;
    }
  }
  if (stagedRootCandidate == null || backupRootCandidate == null) return null;
  final stagedRoot = stagedRootCandidate;
  final backupRoot = backupRootCandidate;
  final work = await Directory.systemTemp.createTemp(
    'mdslens-linux-portable-update-',
  );
  final extracted = Directory(
    '${work.path}${Platform.pathSeparator}extracted',
  );
  final candidate = Directory(
    '${extracted.path}${Platform.pathSeparator}$expectedTopLevel',
  );
  final parentWritable =
      parentWritableOverride ?? await _directoryIsWritable(currentRoot.parent);
  final handshake = _createUpdateHandshake(
    work,
    commitMarker: parentWritable
        ? '${currentRoot.path}.mdslens-update-committed'
        : '${work.path}${Platform.pathSeparator}committed',
  );
  var scheduled = false;
  try {
    await extracted.create();
    final unpack = await commandRunner(tar, [
      '-xzf',
      update.path,
      '-C',
      extracted.path,
      '--no-same-owner',
      '--no-same-permissions',
    ]);
    if (unpack.exitCode != 0 ||
        !await File(
          '${candidate.path}${Platform.pathSeparator}mdslens',
        ).exists() ||
        !await _validLinuxPortableMarker(
          File(
            '${candidate.path}${Platform.pathSeparator}.mdslens-portable.json',
          ),
          architecture: update.asset.architecture,
        )) {
      return null;
    }

    final applyArguments = [
      '$currentPid',
      currentRoot.path,
      stagedRoot.path,
      backupRoot.path,
      update.path,
      work.path,
      handshake.healthFile.path,
      handshake.token,
      handshake.commitMarker,
    ];
    if (parentWritable) {
      await stagedRoot.create();
      final copy = await commandRunner('/bin/cp', [
        '-a',
        '${candidate.path}/.',
        '${stagedRoot.path}/',
      ]);
      if (copy.exitCode != 0 ||
          !await File(
            '${stagedRoot.path}${Platform.pathSeparator}mdslens',
          ).exists()) {
        return null;
      }
      final chmod = await commandRunner('/bin/chmod', [
        '+x',
        '${stagedRoot.path}${Platform.pathSeparator}mdslens',
      ]);
      if (chmod.exitCode != 0) return null;
      await commandLauncher('/bin/sh', [
        '-c',
        _linuxPortableApplyUpdateScript,
        'mdslens-portable-updater',
        ...applyArguments,
      ]);
    } else {
      final pkexec = pkexecPathOverride ??
          _firstExistingExecutable(const ['/usr/bin/pkexec', '/bin/pkexec']);
      if (pkexec == null) return null;
      final readyFile = '${work.path}${Platform.pathSeparator}ready';
      final healthyFile = '${work.path}${Platform.pathSeparator}healthy';
      final failedFile = '${work.path}${Platform.pathSeparator}failed';
      final cancelFile = '${work.path}${Platform.pathSeparator}cancel';
      final pidFile = '${work.path}${Platform.pathSeparator}new-pid';
      await commandLauncher('/bin/sh', [
        '-c',
        _linuxPortableUserRelaunchScript,
        'mdslens-portable-relauncher',
        currentRoot.path,
        readyFile,
        healthyFile,
        failedFile,
        cancelFile,
        pidFile,
        handshake.healthFile.path,
        handshake.token,
        handshake.commitMarker,
      ]);
      final authorization = await commandRunner(pkexec, [
        '/bin/sh',
        '-c',
        _linuxPortableAuthorizeScript,
        'mdslens-portable-authorizer',
        candidate.path,
        stagedRoot.path,
        _linuxPortablePrivilegedApplyScript,
        ...applyArguments,
        readyFile,
        healthyFile,
        failedFile,
        pidFile,
        cancelFile,
      ]);
      if (authorization.exitCode != 0) {
        try {
          await File(cancelFile).writeAsString('cancelled\n');
        } catch (_) {}
        return UpdateInstallResult(
          status: UpdateLaunchStatus.permissionRequired,
          message:
              'Administrator authorization was not granted. The portable application was left unchanged.',
          downloaded: update,
        );
      }
    }
    scheduled = true;
    return UpdateInstallResult(
      status: UpdateLaunchStatus.installed,
      message:
          'The portable application update is ready. MDSLens will restart automatically.',
      downloaded: update,
      closeApplication: true,
    );
  } finally {
    if (!scheduled) {
      try {
        if (await stagedRoot.exists()) {
          await stagedRoot.delete(recursive: true);
        }
      } catch (_) {}
      try {
        if (await work.exists()) await work.delete(recursive: true);
      } catch (_) {}
    }
  }
}

Future<bool> _fileSystemEntryExists(String path) async {
  return await FileSystemEntity.type(
        path,
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;
}

Future<bool> _validLinuxPortableMarker(
  File marker, {
  String? architecture,
}) async {
  try {
    final metadata = jsonDecode(await marker.readAsString());
    return metadata is Map &&
        metadata['schema_version'] == 1 &&
        metadata['product'] == 'com.mdslens.app' &&
        metadata['executable'] == 'mdslens' &&
        (architecture == null || metadata['architecture'] == architecture);
  } catch (_) {
    return false;
  }
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
    if (bundlePath != null && await Directory(bundlePath).exists()) {
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
  bool? parentWritableOverride,
  String? nonceOverride,
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
  if (!await currentBundle.exists()) return null;
  final parentWritable = parentWritableOverride ??
      await _directoryIsWritable(currentBundle.parent);

  final nonceBase =
      nonceOverride ?? '$currentPid-${DateTime.now().microsecondsSinceEpoch}';
  Directory? stagedCandidate;
  Directory? backupCandidate;
  for (var attempt = 0; attempt < 100; attempt++) {
    final nonce = attempt == 0 ? nonceBase : '$nonceBase-$attempt';
    final staged = Directory('$bundlePath.mdslens-update-$nonce');
    final backup = Directory('$bundlePath.mdslens-backup-$nonce');
    if (!await _fileSystemEntryExists(staged.path) &&
        !await _fileSystemEntryExists(backup.path)) {
      stagedCandidate = staged;
      backupCandidate = backup;
      break;
    }
  }
  if (stagedCandidate == null || backupCandidate == null) return null;
  final stagedBundle = stagedCandidate;
  final backupBundle = backupCandidate;
  final work = await Directory.systemTemp.createTemp('mdslens-macos-update-');
  final ready = File('${work.path}${Platform.pathSeparator}helper-ready');
  final handshake = _createUpdateHandshake(
    work,
    commitMarker: '$bundlePath.mdslens-update-committed',
  );
  final extracted = Directory(
    '${work.path}${Platform.pathSeparator}extracted',
  );
  final candidate = Directory(
    '${extracted.path}${Platform.pathSeparator}MDSLens.app',
  );
  var updateScheduled = false;
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

    final applyArguments = [
      '$currentPid',
      currentBundle.path,
      stagedBundle.path,
      backupBundle.path,
      update.path,
      work.path,
      handshake.healthFile.path,
      handshake.token,
      handshake.commitMarker,
      ready.path,
    ];
    if (parentWritable) {
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
      await commandLauncher('/bin/sh', [
        '-c',
        _macOSApplyUpdateScript,
        'mdslens-updater',
        ...applyArguments,
      ]);
    } else {
      final privilegedCommand = [
        '/usr/bin/ditto',
        _shellQuote(candidate.path),
        _shellQuote(stagedBundle.path),
        '&&',
        '/usr/bin/codesign',
        '--verify',
        '--deep',
        '--strict',
        _shellQuote(stagedBundle.path),
        '&&',
        '(',
        '/bin/sh',
        '-c',
        _shellQuote(_macOSApplyUpdateScript),
        _shellQuote('mdslens-updater'),
        ...applyArguments.map(_shellQuote),
        '>/dev/null',
        '2>&1',
        '&',
        ')',
      ].join(' ');
      final authorization = await commandRunner('/usr/bin/osascript', [
        '-e',
        'do shell script "${_appleScriptQuote(privilegedCommand)}" '
            'with administrator privileges',
      ]);
      if (authorization.exitCode != 0) {
        return UpdateInstallResult(
          status: UpdateLaunchStatus.permissionRequired,
          message:
              'Administrator authorization was not granted. The current installation was left unchanged.',
          downloaded: update,
        );
      }
    }
    if (!await _waitForFile(ready)) {
      return UpdateInstallResult(
        status: UpdateLaunchStatus.unsupported,
        message:
            'macOS did not start the update helper, so MDSLens stayed open and the installed version was left unchanged.',
        downloaded: update,
      );
    }
    updateScheduled = true;
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
    if (!updateScheduled) {
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

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _appleScriptQuote(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

Future<void> scheduleApplicationRelaunch(
  String executablePath, {
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
}) async {
  final work = await Directory.systemTemp.createTemp('mdslens-relaunch-');
  final helper = File('${work.path}${Platform.pathSeparator}relaunch.sh');
  final handshake = _createUpdateHandshake(
    work,
    commitMarker: '${work.path}${Platform.pathSeparator}committed',
  );
  await helper.writeAsString(r'''#!/bin/sh
set -u
parent_pid="$1"
executable="$2"
health_file="$3"
health_token="$4"
commit_marker="$5"
work_dir="$6"
attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ "$attempt" -ge 3000 ]; then
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
"$executable" \
  "--mdslens-update-health=$health_file" \
  "--mdslens-update-token=$health_token" \
  "--mdslens-update-commit=$commit_marker" >/dev/null 2>&1 &
new_pid=$!
health_attempt=0
healthy=0
while [ "$health_attempt" -lt 1200 ]; do
  if ! kill -0 "$new_pid" 2>/dev/null; then
    /bin/rm -rf "$work_dir"
    exit 1
  fi
  if [ -f "$health_file" ] &&
     [ "$(/bin/cat "$health_file" 2>/dev/null || true)" = "$health_token" ]; then
    healthy=1
    break
  fi
  health_attempt=$((health_attempt + 1))
  sleep 0.1
done
if [ "$healthy" -ne 1 ]; then
  /bin/rm -rf "$work_dir"
  exit 1
fi
commit_attempt=0
while [ "$commit_attempt" -lt 1200 ]; do
  if [ -f "$commit_marker" ] &&
     [ "$(/bin/cat "$commit_marker" 2>/dev/null || true)" = "$health_token" ]; then
    /bin/rm -rf "$work_dir"
    exit 0
  fi
  if ! kill -0 "$new_pid" 2>/dev/null; then
    break
  fi
  commit_attempt=$((commit_attempt + 1))
  sleep 0.1
done
/bin/rm -rf "$work_dir"
exit 1
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
    handshake.healthFile.path,
    handshake.token,
    handshake.commitMarker,
    work.path,
  ]);
}

Future<UpdateInstallResult?> prepareAppImageUpdate(
  DownloadedUpdate update,
  String currentPath, {
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
  String? nonceOverride,
}) async {
  String resolvedCurrent;
  try {
    resolvedCurrent = await File(currentPath).resolveSymbolicLinks();
  } catch (_) {
    return null;
  }
  final current = File(resolvedCurrent);
  if (await FileSystemEntity.type(
        current.path,
        followLinks: false,
      ) !=
      FileSystemEntityType.file) {
    return null;
  }
  if (!await _directoryIsWritable(current.parent)) return null;

  final nonceBase =
      nonceOverride ?? '$currentPid-${DateTime.now().microsecondsSinceEpoch}';
  File? stagedCandidate;
  File? backupCandidate;
  for (var attempt = 0; attempt < 100; attempt++) {
    final nonce = attempt == 0 ? nonceBase : '$nonceBase-$attempt';
    final staged = File('${current.path}.mdslens-update-$nonce');
    final backup = File('${current.path}.mdslens-backup-$nonce');
    if (!await _fileSystemEntryExists(staged.path) &&
        !await _fileSystemEntryExists(backup.path)) {
      stagedCandidate = staged;
      backupCandidate = backup;
      break;
    }
  }
  if (stagedCandidate == null || backupCandidate == null) return null;
  final staged = stagedCandidate;
  final backup = backupCandidate;
  final work = await Directory.systemTemp.createTemp(
    'mdslens-appimage-update-',
  );
  final handshake = _createUpdateHandshake(
    work,
    commitMarker: '${current.path}.mdslens-update-committed',
  );
  var scheduled = false;
  try {
    await File(update.path).copy(staged.path);
    final chmod = await Process.run('/bin/chmod', ['+x', staged.path]);
    if (chmod.exitCode != 0) return null;
    await commandLauncher('/bin/sh', [
      '-c',
      _linuxAppImageApplyUpdateScript,
      'mdslens-appimage-updater',
      '$currentPid',
      current.path,
      staged.path,
      backup.path,
      update.path,
      handshake.healthFile.path,
      handshake.token,
      handshake.commitMarker,
    ]);
    scheduled = true;
    return UpdateInstallResult(
      status: UpdateLaunchStatus.installed,
      message:
          'The AppImage update is ready. MDSLens will restart automatically.',
      downloaded: update,
      closeApplication: true,
    );
  } catch (_) {
    return null;
  } finally {
    if (!scheduled) {
      try {
        if (await staged.exists()) await staged.delete();
      } catch (_) {}
      try {
        if (await work.exists()) await work.delete(recursive: true);
      } catch (_) {}
    }
  }
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

Future<UpdateInstallResult?> prepareElevatedAppImageUpdate(
  DownloadedUpdate update,
  String currentPath, {
  required int currentPid,
  required DetachedCommandLauncher commandLauncher,
  required CommandRunner commandRunner,
  String? pkexecPathOverride,
}) async {
  String resolvedCurrent;
  try {
    resolvedCurrent = await File(currentPath).resolveSymbolicLinks();
  } catch (_) {
    return null;
  }
  if (FileSystemEntity.typeSync(resolvedCurrent) != FileSystemEntityType.file) {
    return null;
  }
  final pkexec = pkexecPathOverride ??
      (File('/usr/bin/pkexec').existsSync()
          ? '/usr/bin/pkexec'
          : File('/bin/pkexec').existsSync()
              ? '/bin/pkexec'
              : null);
  if (pkexec == null) return null;

  final nonce = '$currentPid-${DateTime.now().microsecondsSinceEpoch}';
  final staged = '$resolvedCurrent.mdslens-update-$nonce';
  final backup = '$resolvedCurrent.mdslens-backup-$nonce';
  if (await _fileSystemEntryExists(staged) ||
      await _fileSystemEntryExists(backup)) {
    return null;
  }
  final work = await Directory.systemTemp.createTemp(
    'mdslens-appimage-privileged-update-',
  );
  final ready = '${work.path}${Platform.pathSeparator}ready';
  final healthy = '${work.path}${Platform.pathSeparator}healthy';
  final failed = '${work.path}${Platform.pathSeparator}failed';
  final rollback = '${work.path}${Platform.pathSeparator}rollback';
  final cancel = '${work.path}${Platform.pathSeparator}cancel';
  final handshake = _createUpdateHandshake(
    work,
    // The replacement is launched as the current user; the privileged helper
    // observes this marker from the user-writable transaction directory.
    commitMarker: '${work.path}${Platform.pathSeparator}committed',
  );
  final pidFile = '${work.path}${Platform.pathSeparator}new-pid';
  await commandLauncher('/bin/sh', [
    '-c',
    _linuxAppImageUserRelaunchScript,
    'mdslens-appimage-relauncher',
    resolvedCurrent,
    ready,
    healthy,
    failed,
    rollback,
    cancel,
    handshake.healthFile.path,
    handshake.token,
    pidFile,
    handshake.commitMarker,
  ]);
  final authorization = await commandRunner(pkexec, [
    '/bin/sh',
    '-c',
    _linuxAuthorizeUpdateScript,
    'mdslens-authorizer',
    _linuxAppImagePrivilegedApplyScript,
    update.path,
    staged,
    '$currentPid',
    resolvedCurrent,
    staged,
    backup,
    update.path,
    handshake.healthFile.path,
    handshake.token,
    handshake.commitMarker,
    ready,
    healthy,
    failed,
    rollback,
    pidFile,
  ]);
  if (authorization.exitCode != 0) {
    try {
      await File(cancel).writeAsString('cancelled\n');
    } catch (_) {}
    return UpdateInstallResult(
      status: UpdateLaunchStatus.permissionRequired,
      message:
          'Administrator authorization was not granted. The current AppImage was left unchanged.',
      downloaded: update,
    );
  }
  return UpdateInstallResult(
    status: UpdateLaunchStatus.installed,
    message: 'The AppImage update is ready. MDSLens will restart now.',
    downloaded: update,
    closeApplication: true,
  );
}

Future<String> _preferredLinuxPackageFormat() async {
  final executable = resolvedExecutableForUpdate();
  final source = _linuxOsReleaseSync();
  return linuxPreferredPackageFormatForInstallation(
    executablePath: executable,
    environment: Platform.environment,
    linuxOsRelease: source,
    linuxPortableRootExists:
        linuxPortableRootFromExecutable(executable) != null,
  );
}

/// Returns the package format that belongs to the currently running Linux
/// installation channel.  This deliberately prefers a marked portable bundle
/// over the host distribution's package format.  Otherwise launching a
/// portable copy through a symlink or desktop entry could install a second
/// copy under /usr and leave the original directory unchanged.
String linuxPreferredPackageFormatForInstallation({
  required String executablePath,
  required Map<String, String> environment,
  required String linuxOsRelease,
  bool linuxPortableRootExists = false,
}) {
  if ((environment['APPIMAGE'] ?? '').trim().isNotEmpty) {
    return 'AppImage';
  }
  if (linuxPortableRootExists) return 'tar.gz';

  final source = linuxOsRelease.toLowerCase();
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
  if (RegExp(
    r'(?:^|\s)(?:id|id_like)=[^\n]*(?:arch|manjaro)',
  ).hasMatch(source)) {
    return 'pkg.tar.zst';
  }
  return 'AppImage';
}

String _linuxOsReleaseSync() {
  if (!Platform.isLinux) return '';
  try {
    return File('/etc/os-release').readAsStringSync();
  } catch (_) {
    return '';
  }
}
