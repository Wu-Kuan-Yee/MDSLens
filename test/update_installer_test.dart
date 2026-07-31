import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mdslens/services/update_installer.dart';
import 'package:mdslens/services/update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  UpdateManifestAsset assetFor(List<int> bytes) {
    return UpdateManifestAsset(
      name: 'mdslens-windows-x64-setup.exe',
      url:
          'https://github.com/Wu-Kuan-Yee/MDSLens/releases/download/v1.0.0/mdslens-windows-x64-setup.exe',
      platform: 'windows',
      architecture: 'x64',
      format: 'exe',
      strategy: 'launch-installer',
      size: bytes.length,
      sha256: sha256.convert(bytes).toString(),
    );
  }

  test(
    'verified update downloads stream to a file and report progress',
    () async {
      final bytes = utf8.encode('verified update');
      final progress = <UpdateDownloadProgress>[];
      final controller = UpdateDownloadController();
      final client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.fromIterable([bytes.sublist(0, 4), bytes.sublist(4)]),
          200,
          contentLength: bytes.length,
        );
      });
      final directory = await Directory.systemTemp.createTemp(
        'mdslens-update-test-',
      );
      addTearDown(() => directory.delete(recursive: true));

      final downloaded = await downloadVerifiedUpdateAsset(
        assetFor(bytes),
        controller: controller,
        client: client,
        downloadDirectory: directory,
        onProgress: progress.add,
      );

      expect(await File(downloaded.path).readAsBytes(), bytes);
      expect(progress.first.received, 0);
      expect(progress.last.received, bytes.length);
      expect(progress.last.fraction, 1);
    },
  );

  test('a corrupt update is deleted before it can be launched', () async {
    final expected = utf8.encode('expected');
    final received = utf8.encode('corrupt!');
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      downloadVerifiedUpdateAsset(
        assetFor(expected),
        controller: UpdateDownloadController(),
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.value(received),
            200,
            contentLength: received.length,
          );
        }),
        downloadDirectory: directory,
      ),
      throwsFormatException,
    );
    expect(directory.listSync(), isEmpty);
  });

  test('cancelled downloads remove partial files', () async {
    final bytes = utf8.encode('cancel this update');
    final controller = UpdateDownloadController();
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));

    await expectLater(
      downloadVerifiedUpdateAsset(
        assetFor(bytes),
        controller: controller,
        client: MockClient.streaming((request, bodyStream) async {
          return http.StreamedResponse(
            Stream.fromIterable([bytes.sublist(0, 4), bytes.sublist(4)]),
            200,
            contentLength: bytes.length,
          );
        }),
        downloadDirectory: directory,
        onProgress: (progress) {
          if (progress.received >= 4) controller.cancel();
        },
      ),
      throwsA(isA<UpdateCancelledException>()),
    );
    expect(directory.listSync(), isEmpty);
  });

  test('Android updater explains a signing-key mismatch', () async {
    const channel = MethodChannel('mdslens/updater');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'installApk');
      expect(call.arguments, '/cache/mdslens-updates/update.apk');
      return 'signature_mismatch';
    });
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-android-arm64.apk',
        url: 'https://example.invalid/update.apk',
        platform: 'android',
        architecture: 'arm64',
        format: 'apk',
        strategy: 'system-installer',
        size: 1,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      path: '/cache/mdslens-updates/update.apk',
    );

    final result = await launchVerifiedUpdateAsset(
      update,
      platformOverride: 'android',
    );

    expect(result.status, UpdateLaunchStatus.unsupported);
    expect(result.message, contains('different Android signing keys'));
  });

  test('verified AppImages atomically replace the running image', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-appimage-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final current = File('${directory.path}/MDSLens.AppImage');
    final downloaded = File('${directory.path}/downloaded.AppImage');
    await current.writeAsString('old');
    await downloaded.writeAsString('new');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.AppImage',
        url: 'https://example.invalid/AppImage',
        platform: 'linux',
        architecture: 'x64',
        format: 'AppImage',
        strategy: 'open-package',
        size: 3,
        sha256: sha256.convert(utf8.encode('new')).toString(),
      ),
      path: downloaded.path,
    );

    expect(await replaceAppImageForUpdate(update, current.path), isTrue);
    expect(await current.readAsString(), 'new');
    expect(downloaded.existsSync(), isFalse);
    expect(File('${current.path}.mdslens-backup').existsSync(), isFalse);
  });

  test(
    'Windows EXE updates wait for shutdown, install, and relaunch',
    () async {
      final installDirectory = await Directory.systemTemp.createTemp(
        'mdslens-windows-install-test-',
      );
      addTearDown(() => installDirectory.delete(recursive: true));
      final commands = <(String, List<String>)>[];
      final update = DownloadedUpdate(
        asset: assetFor(utf8.encode('installer')),
        path: r'C:\Temp\mdslens-update.exe',
      );

      final result = await launchVerifiedUpdateAsset(
        update,
        platformOverride: 'windows',
        currentPidOverride: 12345,
        currentExecutableOverride:
            '${installDirectory.path}${Platform.pathSeparator}mdslens.exe',
        commandLauncher: (executable, arguments) async {
          commands.add((executable, arguments));
        },
      );

      expect(commands, hasLength(1));
      expect(commands.single.$1, 'powershell.exe');
      expect(
        commands.single.$2,
        containsAll(<String>[
          '-File',
          '-ParentPid',
          '12345',
          '-Installer',
          update.path,
          '/CURRENTUSER',
          installDirectory.path,
        ]),
      );
      final helper = File(
        commands.single.$2[commands.single.$2.indexOf('-File') + 1],
      );
      final script = await helper.readAsString();
      expect(script, contains('Wait-Process'));
      expect(script, contains(r'$TargetExecutable'));
      addTearDown(() async {
        if (await helper.parent.exists()) {
          await helper.parent.delete(recursive: true);
        }
      });
      expect(result.status, UpdateLaunchStatus.installed);
      expect(result.closeApplication, isTrue);
    },
  );

  test(
    'Windows MSI fallback uses the detached relaunch helper',
    () async {
      final commands = <(String, List<String>)>[];
      final update = DownloadedUpdate(
        asset: UpdateManifestAsset(
          name: 'mdslens-windows-x64.msi',
          url: 'https://example.invalid/mdslens.msi',
          platform: 'windows',
          architecture: 'x64',
          format: 'msi',
          strategy: 'launch-installer',
          size: 1,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        path: r'C:\Temp\mdslens-update.msi',
      );

      final result = await launchVerifiedUpdateAsset(
        update,
        platformOverride: 'windows',
        currentPidOverride: 12345,
        currentExecutableOverride: r'C:\Program Files\MDSLens\mdslens.exe',
        commandLauncher: (executable, arguments) async {
          commands.add((executable, arguments));
        },
      );

      expect(commands.single.$1, 'powershell.exe');
      expect(commands.single.$2, contains('-NonInteractive'));
      expect(
        commands.single.$2,
        containsAll(<String>[
          '-Installer',
          update.path,
          '-Format',
          'msi',
          '-TargetExecutable',
          r'C:\Program Files\MDSLens\mdslens.exe',
        ]),
      );
      final helper = File(
        commands.single.$2[commands.single.$2.indexOf('-File') + 1],
      );
      final script = await helper.readAsString();
      expect(script, contains("if (\$Format -eq 'msi')"));
      expect(script, contains(r'Start-Process -FilePath $TargetExecutable'));
      addTearDown(() async {
        if (await helper.parent.exists()) {
          await helper.parent.delete(recursive: true);
        }
      });
      expect(result.closeApplication, isTrue);
    },
  );

  test('macOS bundle paths are derived only from application executables', () {
    expect(
      macOSBundlePathFromExecutable(
        '/Applications/MDSLens.app/Contents/MacOS/MDSLens',
      ),
      '/Applications/MDSLens.app',
    );
    expect(macOSBundlePathFromExecutable('/usr/local/bin/mdslens'), isNull);
  });

  test('macOS protected installs request administrator authorization',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-macos-authorization-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = File(
      '${directory.path}/MDSLens.app/Contents/MacOS/MDSLens',
    );
    await executable.create(recursive: true);
    final archive = File('${directory.path}/update.zip');
    await archive.writeAsString('archive');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-macos-arm64-unsigned.zip',
        url: 'https://example.invalid/update.zip',
        platform: 'macos',
        architecture: 'arm64',
        format: 'zip',
        strategy: 'self-replace',
        size: 7,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      path: archive.path,
    );
    final commands = <(String, List<String>)>[];

    final result = await prepareMacOSApplicationUpdate(
      update,
      currentExecutable: executable.path,
      currentPid: 12345,
      parentWritableOverride: false,
      commandLauncher: (executable, arguments) async {},
      commandRunner: (command, arguments) async {
        commands.add((command, arguments));
        if (command == '/usr/bin/ditto' && arguments.first == '-x') {
          await Directory('${arguments.last}/MDSLens.app').create(
            recursive: true,
          );
        }
        if (command == '/usr/bin/plutil') {
          return ProcessResult(0, 0, 'com.mdslens.app\n', '');
        }
        if (command == '/usr/bin/osascript') {
          return ProcessResult(0, 1, '', 'User canceled.');
        }
        return ProcessResult(0, 0, '', '');
      },
    );

    expect(
        commands.map((command) => command.$1), contains('/usr/bin/osascript'));
    expect(result?.status, UpdateLaunchStatus.permissionRequired);
    expect(result?.closeApplication, isFalse);
  });

  test(
    'AppImage update schedules a relaunch and closes the old process',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mdslens-appimage-relaunch-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final current = File('${directory.path}/MDSLens.AppImage');
      final downloaded = File('${directory.path}/downloaded.AppImage');
      await current.writeAsString('old');
      await downloaded.writeAsString('new');
      final commands = <(String, List<String>)>[];
      final update = DownloadedUpdate(
        asset: UpdateManifestAsset(
          name: 'mdslens-linux-x64.AppImage',
          url: 'https://example.invalid/AppImage',
          platform: 'linux',
          architecture: 'x64',
          format: 'AppImage',
          strategy: 'open-package',
          size: 3,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        path: downloaded.path,
      );

      final result = await launchVerifiedUpdateAsset(
        update,
        platformOverride: 'linux',
        currentAppImageOverride: current.path,
        currentPidOverride: 12345,
        commandLauncher: (executable, arguments) async {
          commands.add((executable, arguments));
        },
      );

      expect(await current.readAsString(), 'new');
      expect(commands.single.$1, '/bin/sh');
      expect(commands.single.$2, containsAll(<String>['12345', current.path]));
      final helperWork = Directory(commands.single.$2.last);
      addTearDown(() async {
        if (await helperWork.exists()) {
          await helperWork.delete(recursive: true);
        }
      });
      expect(result.status, UpdateLaunchStatus.installed);
      expect(result.closeApplication, isTrue);
    },
  );

  test('protected AppImages request PolicyKit authorization', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-appimage-authorization-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final current = File('${directory.path}/MDSLens.AppImage');
    final downloaded = File('${directory.path}/downloaded.AppImage');
    await current.writeAsString('old');
    await downloaded.writeAsString('new');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.AppImage',
        url: 'https://example.invalid/AppImage',
        platform: 'linux',
        architecture: 'x64',
        format: 'AppImage',
        strategy: 'self-replace',
        size: 3,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      path: downloaded.path,
    );
    final commands = <(String, List<String>)>[];

    final result = await prepareElevatedAppImageUpdate(
      update,
      current.path,
      currentPid: 12345,
      pkexecPathOverride: '/usr/bin/pkexec',
      commandRunner: (command, arguments) async {
        commands.add((command, arguments));
        if (command == '/usr/bin/pkexec') {
          return ProcessResult(0, 126, '', 'Authorization dismissed.');
        }
        return ProcessResult(0, 0, '', '');
      },
    );

    expect(commands.map((command) => command.$1), contains('/usr/bin/pkexec'));
    expect(result?.status, UpdateLaunchStatus.permissionRequired);
    expect(await current.readAsString(), 'old');
  });

  test('Fedora RPM updates install through PolicyKit and restart', () async {
    final commands = <(String, List<String>)>[];
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.rpm',
        url: 'https://example.invalid/mdslens.rpm',
        platform: 'linux',
        architecture: 'x64',
        format: 'rpm',
        strategy: 'open-package',
        size: 1,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      path: '/tmp/mdslens-linux-x64.rpm',
    );

    final result = await launchVerifiedUpdateAsset(
      update,
      platformOverride: 'linux',
      currentExecutableOverride: '/usr/bin/mdslens',
      currentPidOverride: 12345,
      linuxPackageManagerPathOverride: '/usr/bin/dnf5',
      linuxPkexecPathOverride: '/usr/bin/pkexec',
      commandRunner: (executable, arguments) async {
        commands.add((executable, arguments));
        return ProcessResult(0, 0, '', '');
      },
      commandLauncher: (executable, arguments) async {
        commands.add((executable, arguments));
      },
    );

    expect(commands.first.$1, '/usr/bin/pkexec');
    expect(
      commands.first.$2,
      containsAllInOrder(<String>[
        '/usr/bin/dnf5',
        'install',
        '-y',
        '--nogpgcheck',
        update.path,
      ]),
    );
    expect(commands.last.$1, '/bin/sh');
    expect(
        commands.last.$2, containsAll(<String>['12345', '/usr/bin/mdslens']));
    final helperWork = Directory(commands.last.$2.last);
    addTearDown(() async {
      if (await helperWork.exists()) {
        await helperWork.delete(recursive: true);
      }
    });
    expect(result.status, UpdateLaunchStatus.installed);
    expect(result.closeApplication, isTrue);
  });

  test('cancelled Linux package authorization does not close the app',
      () async {
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.rpm',
        url: 'https://example.invalid/mdslens.rpm',
        platform: 'linux',
        architecture: 'x64',
        format: 'rpm',
        strategy: 'open-package',
        size: 1,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      path: '/tmp/mdslens-linux-x64.rpm',
    );

    final result = await prepareLinuxSystemPackageUpdate(
      update,
      currentExecutable: '/usr/bin/mdslens',
      currentPid: 12345,
      packageManagerPathOverride: '/usr/bin/dnf',
      pkexecPathOverride: '/usr/bin/pkexec',
      commandLauncher: (executable, arguments) async {},
      commandRunner: (executable, arguments) async {
        return ProcessResult(0, 126, '', 'Authorization dismissed.');
      },
    );

    expect(result?.status, UpdateLaunchStatus.permissionRequired);
    expect(result?.closeApplication, isFalse);
  });

  test('direct update support follows the native installation channel', () {
    expect(
      nativeDirectUpdateSupported(
        platform: 'windows',
        resolvedExecutable: r'C:\Program Files\MDSLens\mdslens.exe',
        environment: const {},
      ),
      isTrue,
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'windows',
        resolvedExecutable:
            r'C:\Program Files\WindowsApps\MDSLens_0.2.6_x64\mdslens.exe',
        environment: const {},
      ),
      isFalse,
      reason: 'unsigned EXE updates must not duplicate an MSIX install',
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'linux',
        resolvedExecutable: '/usr/lib/mdslens/mdslens',
        environment: const {},
        linuxOsRelease: 'ID=fedora\nID_LIKE="rhel centos"',
      ),
      isTrue,
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'linux',
        resolvedExecutable: '/home/user/Downloads/mdslens/mdslens',
        environment: const {},
        linuxOsRelease: 'ID=fedora',
      ),
      isFalse,
      reason: 'portable archives require a different replacement strategy',
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'linux',
        resolvedExecutable: '/app/lib/mdslens/mdslens',
        environment: const {'FLATPAK_ID': 'com.mdslens.app'},
        linuxOsRelease: 'ID=fedora',
      ),
      isFalse,
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'linux',
        resolvedExecutable: '/snap/mdslens/current/mdslens',
        environment: const {'SNAP': '/snap/mdslens/current'},
        linuxOsRelease: 'ID=ubuntu',
      ),
      isFalse,
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'linux',
        resolvedExecutable: '/tmp/.mount_MDSLens/mdslens',
        environment: const {'APPIMAGE': '/home/user/MDSLens.AppImage'},
        linuxOsRelease: 'ID=unknown',
      ),
      isTrue,
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'ios',
        resolvedExecutable: '/private/var/containers/MDSLens',
        environment: const {},
      ),
      isFalse,
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'linux',
        resolvedExecutable: '/usr/lib/mdslens/mdslens',
        environment: const {},
        linuxOsRelease: 'ID=alpine',
      ),
      isFalse,
      reason: 'unknown native package managers must not receive a fake update',
    );
    expect(
      nativeDirectUpdateSupported(
        platform: 'macos',
        resolvedExecutable:
            '/private/var/folders/AppTranslocation/MDSLens.app/Contents/MacOS/MDSLens',
        environment: const {},
      ),
      isFalse,
    );
  });

  test('Arch packages install through PolicyKit and pacman', () async {
    final commands = <(String, List<String>)>[];
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.pkg.tar.zst',
        url: 'https://example.invalid/mdslens.pkg.tar.zst',
        platform: 'linux',
        architecture: 'x64',
        format: 'pkg.tar.zst',
        strategy: 'open-package',
        size: 1,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      path: '/tmp/mdslens-linux-x64.pkg.tar.zst',
    );

    final result = await prepareLinuxSystemPackageUpdate(
      update,
      currentExecutable: '/usr/bin/mdslens',
      currentPid: 12345,
      packageManagerPathOverride: '/usr/bin/pacman',
      pkexecPathOverride: '/usr/bin/pkexec',
      commandLauncher: (executable, arguments) async {
        commands.add((executable, arguments));
      },
      commandRunner: (executable, arguments) async {
        commands.add((executable, arguments));
        return ProcessResult(0, 0, '', '');
      },
    );

    expect(commands.first.$1, '/usr/bin/pkexec');
    expect(
      commands.first.$2,
      containsAllInOrder(<String>[
        '/usr/bin/pacman',
        '-U',
        '--noconfirm',
        update.path,
      ]),
    );
    expect(result?.status, UpdateLaunchStatus.installed);
    expect(result?.closeApplication, isTrue);
    final helperWork = Directory(commands.last.$2.last);
    addTearDown(() async {
      if (await helperWork.exists()) {
        await helperWork.delete(recursive: true);
      }
    });
  });
}
