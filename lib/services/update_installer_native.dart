import 'dart:convert';
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

bool get directUpdateSupported => nativeDirectUpdateSupported(
      platform: Platform.operatingSystem,
      resolvedExecutable: Platform.resolvedExecutable,
      environment: Platform.environment,
      flatpakInfoExists: File('/.flatpak-info').existsSync(),
      linuxOsRelease: _linuxOsReleaseSync(),
      linuxPortableRootExists:
          linuxPortableRootFromExecutable(Platform.resolvedExecutable) != null,
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

const _macOSApplyUpdateScript = r'''
set -u
parent_pid="$1"
current_bundle="$2"
staged_bundle="$3"
backup_bundle="$4"
archive="$5"
work_dir="$6"
ready_file="$7"
previous_bundle="${current_bundle}.mdslens-previous"

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
  /usr/bin/open -n -W "$current_bundle" >/dev/null 2>&1 &
  open_pid=$!
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if ! kill -0 "$open_pid" 2>/dev/null; then
      /bin/rm -rf "$current_bundle"
      /bin/mv "$backup_bundle" "$current_bundle"
      /usr/bin/open "$current_bundle"
      /bin/rm -rf "$work_dir"
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
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
  /bin/rm -f "$archive"
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
''';

const _linuxAppImageApplyUpdateScript = r'''
set -u
parent_pid="$1"
current_image="$2"
staged_image="$3"
backup_image="$4"
downloaded_image="$5"
previous_image="${current_image}.mdslens-previous"
previous_owner="${previous_image}.owner"

case "$current_image" in ""|"/") exit 1 ;; esac
case "$staged_image" in "${current_image}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_image" in "${current_image}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ -e "$backup_image" ] && exit 1
[ -L "$backup_image" ] && exit 1

attempt=0
while kill -0 "$parent_pid" 2>/dev/null; do
  if [ "$attempt" -ge 3000 ]; then
    /bin/rm -f "$staged_image"
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done

if /bin/mv -T -- "$current_image" "$backup_image" &&
   /bin/mv -T -- "$staged_image" "$current_image"; then
  /bin/chmod +x "$current_image"
  "$current_image" >/dev/null 2>&1 &
  new_pid=$!
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if ! kill -0 "$new_pid" 2>/dev/null; then
      /bin/rm -f "$current_image"
      /bin/mv -T -- "$backup_image" "$current_image"
      "$current_image" >/dev/null 2>&1 &
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
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
  /bin/rm -f "$downloaded_image"
  exit 0
fi

if [ ! -e "$current_image" ] && [ -e "$backup_image" ]; then
  /bin/mv -T -- "$backup_image" "$current_image"
fi
/bin/rm -f "$staged_image"
if [ -x "$current_image" ]; then
  "$current_image" >/dev/null 2>&1 &
fi
exit 1
''';

const _linuxAppImagePrivilegedApplyScript = r'''
set -u
parent_pid="$1"
current_image="$2"
staged_image="$3"
backup_image="$4"
downloaded_image="$5"
ready_file="$6"
healthy_file="$7"
failed_file="$8"
rollback_file="$9"
previous_image="${current_image}.mdslens-previous"
previous_owner="${previous_image}.owner"
work_dir=$(/usr/bin/dirname "$ready_file")

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
  while [ "$attempt" -lt 300 ]; do
    if [ -e "$healthy_file" ]; then
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
      /bin/rm -f "$downloaded_image"
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

attempt=0
while [ "$attempt" -lt 300 ]; do
  [ -e "$cancel_file" ] && exit 1
  if [ -e "$ready_file" ]; then
    "$current_image" >/dev/null 2>&1 &
    new_pid=$!
    health_attempt=0
    while [ "$health_attempt" -lt 30 ]; do
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
      health_attempt=$((health_attempt + 1))
      sleep 0.1
    done
    : > "$healthy_file"
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
previous_root="${current_root}.mdslens-previous"

case "$current_root" in ""|"/") exit 1 ;; esac
case "$staged_root" in "${current_root}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_root" in "${current_root}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ -e "$backup_root" ] && exit 1
[ -L "$backup_root" ] && exit 1

launch_from_root() {
  root="$1"
  (cd "$root" && exec ./mdslens) >/dev/null 2>&1 &
  launched_pid=$!
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
  launch_from_root "$current_root"
  new_pid=$launched_pid
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if ! kill -0 "$new_pid" 2>/dev/null; then
      /bin/rm -rf "$current_root"
      /bin/mv -T -- "$backup_root" "$current_root"
      launch_from_root "$current_root"
      /bin/rm -rf "$work_dir"
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  /bin/rm -rf "$previous_root"
  /bin/mv -T -- "$backup_root" "$previous_root"
  /bin/rm -f "$downloaded_archive"
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
ready_file="$7"
healthy_file="$8"
previous_root="${current_root}.mdslens-previous"

case "$current_root" in ""|"/") exit 1 ;; esac
case "$staged_root" in "${current_root}.mdslens-update-"*) ;; *) exit 1 ;; esac
case "$backup_root" in "${current_root}.mdslens-backup-"*) ;; *) exit 1 ;; esac
[ -e "$backup_root" ] && exit 1
[ -L "$backup_root" ] && exit 1

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
  : > "$ready_file"
  attempt=0
  while [ "$attempt" -lt 300 ]; do
    if [ -e "$healthy_file" ]; then
      /bin/rm -rf "$previous_root"
      /bin/mv -T -- "$backup_root" "$previous_root"
      /bin/rm -f "$downloaded_archive"
      /bin/rm -rf "$work_dir"
      exit 0
    fi
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
cancel_file="$4"

attempt=0
while [ "$attempt" -lt 300 ]; do
  if [ -e "$cancel_file" ]; then
    exit 1
  fi
  if [ -e "$ready_file" ]; then
    (cd "$current_root" && exec ./mdslens) >/dev/null 2>&1 &
    new_pid=$!
    health_attempt=0
    while [ "$health_attempt" -lt 30 ]; do
      if ! kill -0 "$new_pid" 2>/dev/null; then
        exit 1
      fi
      health_attempt=$((health_attempt + 1))
      sleep 0.1
    done
    : > "$healthy_file"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
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

:relaunch
if exist "%TargetExecutable%" (
  >>"%LogFile%" echo [%date% %time%] Relaunching "%TargetExecutable%".
  start "" "%TargetExecutable%"
) else (
  >>"%LogFile%" echo [%date% %time%] Target executable is missing after update.
)
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
$readyFile = $args[6]
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
if (Get-Process -Id $parentPid -ErrorAction SilentlyContinue) { exit 1 }

try {
  Move-Item -LiteralPath $currentRoot -Destination $backupRoot
  Move-Item -LiteralPath $stagedRoot -Destination $currentRoot
  $target = Join-Path $currentRoot 'mdslens.exe'
  $process = Start-Process -FilePath $target -WorkingDirectory $currentRoot -PassThru
  Start-Sleep -Seconds 3
  $process.Refresh()
  if ($process.HasExited) { throw 'The replacement exited during startup.' }

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
  exit 1
}
''';

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
  String? currentPortableRootOverride,
  int? currentPidOverride,
  int windowsHelperReadyAttempts = 50,
  String? linuxPackageManagerPathOverride,
  String? linuxPkexecPathOverride,
}) async {
  final platform = platformOverride ?? Platform.operatingSystem;
  final launch = commandLauncher ?? _startDetached;
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
    await launch('cmd.exe', [
      '/d',
      '/s',
      '/c',
      'call',
      helper.path,
      '${currentPidOverride ?? pid}',
      update.path,
      installDirectory.path,
      currentExecutable,
      update.asset.format,
      scopeArgument,
      work.path,
      ready.path,
      log.path,
    ]);
    final helperReady = await _waitForFile(
      ready,
      attempts: windowsHelperReadyAttempts,
    );
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
    final currentAppImage = currentAppImageOverride ??
        (Platform.environment['APPIMAGE'] ?? '').trim();
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
    final portableRoot = currentPortableRootOverride ??
        linuxPortableRootFromExecutable(
          currentExecutableOverride ?? Platform.resolvedExecutable,
        );
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
        currentExecutable:
            currentExecutableOverride ?? Platform.resolvedExecutable,
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
  int helperReadyAttempts = 50,
}) async {
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
    final unpack = await commandRunner('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'Expand-Archive -LiteralPath $args[0] -DestinationPath $args[1] -Force',
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
    final stage = await commandRunner('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'Copy-Item -LiteralPath $args[0] -Destination $args[1] -Recurse',
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
    await helper.writeAsString(_windowsPortableApplyUpdateScript);
    await commandLauncher('powershell.exe', [
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
      ready.path,
    ]);
    if (!await _waitForFile(ready, attempts: helperReadyAttempts)) {
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
  int attempts = 50,
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

    final parentWritable = parentWritableOverride ??
        await _directoryIsWritable(currentRoot.parent);
    final applyArguments = [
      '$currentPid',
      currentRoot.path,
      stagedRoot.path,
      backupRoot.path,
      update.path,
      work.path,
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
      final cancelFile = '${work.path}${Platform.pathSeparator}cancel';
      await commandLauncher('/bin/sh', [
        '-c',
        _linuxPortableUserRelaunchScript,
        'mdslens-portable-relauncher',
        currentRoot.path,
        readyFile,
        healthyFile,
        cancelFile,
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
    ready,
    healthy,
    failed,
    rollback,
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
  if ((Platform.environment['APPIMAGE'] ?? '').trim().isNotEmpty) {
    return 'AppImage';
  }
  if (linuxPortableRootFromExecutable(Platform.resolvedExecutable) != null) {
    return 'tar.gz';
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
    if (RegExp(
      r'(?:^|\s)(?:id|id_like)=[^\n]*(?:arch|manjaro)',
    ).hasMatch(source)) {
      return 'pkg.tar.zst';
    }
  } catch (_) {}
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
