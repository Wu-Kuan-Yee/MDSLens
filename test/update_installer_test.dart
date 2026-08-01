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
          await File(arguments[12]).create(recursive: true);
        },
      );

      expect(commands, hasLength(1));
      expect(commands.single.$1, 'cmd.exe');
      expect(
        commands.single.$2,
        containsAll(<String>[
          '/d',
          '/s',
          '/c',
          'call',
          '12345',
          update.path,
          '/CURRENTUSER',
          installDirectory.path,
        ]),
      );
      final helper = File(commands.single.$2[4]);
      final script = await helper.readAsString();
      expect(script, contains(':wait_for_parent'));
      expect(script, contains('Installer exit code'));
      expect(script, contains('start "" "%TargetExecutable%"'));
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
          await File(arguments[12]).create(recursive: true);
        },
      );

      expect(commands.single.$1, 'cmd.exe');
      expect(
        commands.single.$2,
        containsAll(<String>[
          update.path,
          'msi',
          r'C:\Program Files\MDSLens\mdslens.exe',
        ]),
      );
      final helper = File(commands.single.$2[4]);
      final script = await helper.readAsString();
      expect(script, contains(':install_msi'));
      expect(script, contains('start "" /wait msiexec.exe'));
      expect(script, contains('start "" "%TargetExecutable%"'));
      addTearDown(() async {
        if (await helper.parent.exists()) {
          await helper.parent.delete(recursive: true);
        }
      });
      expect(result.closeApplication, isTrue);
    },
  );

  test(
    'Windows stays open when the update helper does not take ownership',
    () async {
      final update = DownloadedUpdate(
        asset: assetFor(utf8.encode('installer')),
        path: r'C:\Temp\mdslens-update.exe',
      );

      final result = await launchVerifiedUpdateAsset(
        update,
        platformOverride: 'windows',
        currentPidOverride: 12345,
        currentExecutableOverride: r'C:\Program Files\MDSLens\mdslens.exe',
        windowsHelperReadyAttempts: 1,
        commandLauncher: (executable, arguments) async {},
      );

      expect(result.status, UpdateLaunchStatus.unsupported);
      expect(result.closeApplication, isFalse);
      expect(result.message, contains('stayed open'));
    },
  );

  test('Windows portable updates stage a complete bundle and wait for handoff',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'mdslens-windows-portable-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final current = Directory('${root.path}/mdslens-windows-x64');
    await current.create();
    await File('${current.path}/mdslens.exe').writeAsString('old');
    await File('${current.path}/.mdslens-portable.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'product': 'com.mdslens.app',
        'platform': 'windows',
        'version': '0.3.1',
        'architecture': 'x64',
        'executable': 'mdslens.exe',
      }),
    );
    final archive = File('${root.path}/mdslens-windows-x64.zip');
    await archive.writeAsString('archive');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-windows-x64.zip',
        url: 'https://example.invalid/windows.zip',
        platform: 'windows',
        architecture: 'x64',
        format: 'zip',
        strategy: 'self-replace',
        size: await archive.length(),
        sha256: sha256.convert(await archive.readAsBytes()).toString(),
      ),
      path: archive.path,
    );
    List<String>? launchedArguments;

    final result = await prepareWindowsPortableUpdate(
      update,
      portableRoot: current.path,
      currentPid: 12345,
      nonceOverride: 'test',
      parentWritableOverride: true,
      commandRunner: (executable, arguments) async {
        final script = arguments[3];
        if (script.contains('Expand-Archive')) {
          expect(script, contains(r'param($archive, $destination)'));
          final candidate = Directory(
            '${arguments.last}/mdslens-windows-x64',
          );
          await candidate.create(recursive: true);
          await File('${candidate.path}/mdslens.exe').writeAsString('new');
          await File('${candidate.path}/.mdslens-portable.json').writeAsString(
            jsonEncode({
              'schema_version': 1,
              'product': 'com.mdslens.app',
              'platform': 'windows',
              'version': '0.3.2',
              'architecture': 'x64',
              'executable': 'mdslens.exe',
            }),
          );
        } else if (script.contains('Copy-Item')) {
          expect(script, contains(r'param($source, $destination)'));
          final source = Directory(arguments[4]);
          final destination = Directory(arguments[5]);
          await destination.create();
          for (final entity in source.listSync()) {
            if (entity is File) {
              await entity.copy(
                '${destination.path}/${entity.uri.pathSegments.last}',
              );
            }
          }
        }
        return ProcessResult(0, 0, '', '');
      },
      commandLauncher: (executable, arguments) async {
        launchedArguments = arguments;
        await File(arguments.last).create(recursive: true);
      },
    );

    expect(result.closeApplication, isTrue);
    expect(launchedArguments?[5], endsWith('apply-update.ps1'));
    final helper = File(launchedArguments![5]);
    final script = await helper.readAsString();
    expect(script, contains('The replacement exited during startup.'));
    expect(script, contains('Move-Item -LiteralPath \$backupRoot'));
  });

  test('protected Windows portable updates request UAC and relaunch as user',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'mdslens-windows-protected-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final current = Directory('${root.path}/mdslens-windows-x64');
    await current.create();
    await File('${current.path}/mdslens.exe').writeAsString('old');
    await File('${current.path}/.mdslens-portable.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'product': 'com.mdslens.app',
        'platform': 'windows',
        'version': '0.3.1',
        'architecture': 'x64',
        'executable': 'mdslens.exe',
      }),
    );
    final archive = File('${root.path}/mdslens-windows-x64.zip');
    await archive.writeAsString('archive');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-windows-x64.zip',
        url: 'https://example.invalid/windows.zip',
        platform: 'windows',
        architecture: 'x64',
        format: 'zip',
        strategy: 'self-replace',
        size: await archive.length(),
        sha256: sha256.convert(await archive.readAsBytes()).toString(),
      ),
      path: archive.path,
    );
    List<String>? userHelperArguments;
    String? bootstrapScript;
    String? privilegedScript;

    final result = await prepareWindowsPortableUpdate(
      update,
      portableRoot: current.path,
      currentPid: 12345,
      nonceOverride: 'protected',
      parentWritableOverride: false,
      commandRunner: (executable, arguments) async {
        if (arguments[3].contains('Expand-Archive')) {
          final candidate = Directory(
            '${arguments.last}/mdslens-windows-x64',
          );
          await candidate.create(recursive: true);
          await File('${candidate.path}/mdslens.exe').writeAsString('new');
          await File('${candidate.path}/.mdslens-portable.json').writeAsString(
            jsonEncode({
              'schema_version': 1,
              'product': 'com.mdslens.app',
              'platform': 'windows',
              'version': '0.3.2',
              'architecture': 'x64',
              'executable': 'mdslens.exe',
            }),
          );
        } else if (arguments.contains('-File')) {
          bootstrapScript = await File(arguments[5]).readAsString();
          privilegedScript = await File(arguments[6]).readAsString();
          await File(arguments[14]).create(recursive: true);
        }
        return ProcessResult(0, 0, '', '');
      },
      commandLauncher: (executable, arguments) async {
        userHelperArguments = arguments;
      },
    );

    expect(result.closeApplication, isTrue);
    expect(bootstrapScript, contains('-Verb RunAs'));
    expect(privilegedScript, contains('Replacement health check timed out.'));
    expect(privilegedScript, contains('rollbackReadyFile'));
    expect(userHelperArguments?[5], endsWith('relaunch-update.ps1'));
    final userScript = await File(userHelperArguments![5]).readAsString();
    expect(userScript, contains("Start-Process -FilePath \$target"));
    expect(userScript, isNot(contains('-Verb RunAs')));
  });

  test('declining Windows portable UAC keeps the current app open', () async {
    final root = await Directory.systemTemp.createTemp(
      'mdslens-windows-uac-declined-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final current = Directory('${root.path}/mdslens-windows-x64');
    await current.create();
    await File('${current.path}/mdslens.exe').writeAsString('old');
    await File('${current.path}/.mdslens-portable.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'product': 'com.mdslens.app',
        'platform': 'windows',
        'version': '0.3.1',
        'architecture': 'x64',
        'executable': 'mdslens.exe',
      }),
    );
    final archive = File('${root.path}/mdslens-windows-x64.zip');
    await archive.writeAsString('archive');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-windows-x64.zip',
        url: 'https://example.invalid/windows.zip',
        platform: 'windows',
        architecture: 'x64',
        format: 'zip',
        strategy: 'self-replace',
        size: await archive.length(),
        sha256: sha256.convert(await archive.readAsBytes()).toString(),
      ),
      path: archive.path,
    );

    final result = await prepareWindowsPortableUpdate(
      update,
      portableRoot: current.path,
      currentPid: 12345,
      parentWritableOverride: false,
      commandRunner: (executable, arguments) async {
        if (arguments[3].contains('Expand-Archive')) {
          final candidate = Directory(
            '${arguments.last}/mdslens-windows-x64',
          );
          await candidate.create(recursive: true);
          await File('${candidate.path}/mdslens.exe').writeAsString('new');
          await File('${candidate.path}/.mdslens-portable.json').writeAsString(
            jsonEncode({
              'schema_version': 1,
              'product': 'com.mdslens.app',
              'platform': 'windows',
              'version': '0.3.2',
              'architecture': 'x64',
              'executable': 'mdslens.exe',
            }),
          );
          return ProcessResult(0, 0, '', '');
        }
        return ProcessResult(0, 1223, '', 'cancelled');
      },
      commandLauncher: (executable, arguments) async {
        fail('The relaunch helper must not start after UAC is declined.');
      },
    );

    expect(result.status, UpdateLaunchStatus.permissionRequired);
    expect(result.closeApplication, isFalse);
    expect(await File('${current.path}/mdslens.exe').readAsString(), 'old');
  });

  test('macOS bundle paths are derived only from application executables', () {
    expect(
      macOSBundlePathFromExecutable(
        '/Applications/MDSLens.app/Contents/MacOS/MDSLens',
      ),
      '/Applications/MDSLens.app',
    );
    expect(macOSBundlePathFromExecutable('/usr/local/bin/mdslens'), isNull);
  });

  test('macOS update helper takes ownership and skips path collisions',
      () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-macos-update-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final executable = File(
      '${directory.path}/MDSLens.app/Contents/MacOS/MDSLens',
    );
    await executable.create(recursive: true);
    final archive = File('${directory.path}/update.zip');
    await archive.writeAsString('archive');
    final collidingStage = Directory(
      '${directory.path}/MDSLens.app.mdslens-update-collision',
    );
    final collidingBackup = Directory(
      '${directory.path}/MDSLens.app.mdslens-backup-collision',
    );
    await collidingStage.create();
    await collidingBackup.create();
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-macos-arm64-unsigned.zip',
        url: 'https://example.invalid/update.zip',
        platform: 'macos',
        architecture: 'arm64',
        format: 'zip',
        strategy: 'self-replace',
        size: 7,
        sha256: List.filled(64, 'a').join(),
      ),
      path: archive.path,
    );
    List<String>? launchedArguments;

    final result = await prepareMacOSApplicationUpdate(
      update,
      currentExecutable: executable.path,
      currentPid: 12345,
      parentWritableOverride: true,
      nonceOverride: 'collision',
      commandLauncher: (command, arguments) async {
        launchedArguments = arguments;
        await File(arguments.last).create(recursive: true);
      },
      commandRunner: (command, arguments) async {
        if (command == '/usr/bin/ditto' && arguments.first == '-x') {
          await Directory('${arguments.last}/MDSLens.app').create(
            recursive: true,
          );
        } else if (command == '/usr/bin/ditto') {
          await Directory(arguments.last).create(recursive: true);
        }
        if (command == '/usr/bin/plutil') {
          return ProcessResult(0, 0, 'com.mdslens.app\n', '');
        }
        return ProcessResult(0, 0, '', '');
      },
    );

    expect(result?.closeApplication, isTrue);
    expect(
      launchedArguments?.any(
        (argument) => argument.endsWith(
          '/MDSLens.app.mdslens-update-collision-1',
        ),
      ),
      isTrue,
    );
    expect(launchedArguments?[1], contains('/usr/bin/open -n -W'));
    expect(launchedArguments?[1], contains(r'kill -0 "$open_pid"'));
    expect(launchedArguments?[1], contains('/usr/libexec/PlistBuddy'));
    expect(await collidingStage.exists(), isTrue);
    expect(await collidingBackup.exists(), isTrue);
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
    'AppImage update swaps after exit, confirms launch, and keeps a backup',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'mdslens-appimage-relaunch-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final current = File('${directory.path}/MDSLens.AppImage');
      final downloaded = File('${directory.path}/downloaded.AppImage');
      await current.writeAsString('#!/bin/sh\nexit 0\n');
      final launched = File('${directory.path}/launched');
      final launchedPid = File('${directory.path}/launched.pid');
      await downloaded.writeAsString(
        '#!/bin/sh\necho launched > "${launched.path}"\n'
        'echo \$\$ > "${launchedPid.path}"\nsleep 10\n',
      );
      final update = DownloadedUpdate(
        asset: UpdateManifestAsset(
          name: 'mdslens-linux-x64.AppImage',
          url: 'https://example.invalid/AppImage',
          platform: 'linux',
          architecture: 'x64',
          format: 'AppImage',
          strategy: 'open-package',
          size: await downloaded.length(),
          sha256: sha256.convert(await downloaded.readAsBytes()).toString(),
        ),
        path: downloaded.path,
      );

      final result = await launchVerifiedUpdateAsset(
        update,
        platformOverride: 'linux',
        currentAppImageOverride: current.path,
        currentPidOverride: 2147483646,
        commandLauncher: (executable, arguments) async {
          final compatibleArguments = List<String>.of(arguments);
          if (Platform.isMacOS) {
            compatibleArguments[1] = compatibleArguments[1].replaceAll(
              '/bin/mv -T --',
              '/bin/mv',
            );
          }
          final applied = await Process.run(executable, compatibleArguments);
          expect(
            applied.exitCode,
            0,
            reason: '${applied.stdout}\n${applied.stderr}',
          );
        },
      );

      expect(result.status, UpdateLaunchStatus.installed);
      expect(result.closeApplication, isTrue);
      expect(await launched.readAsString(), 'launched\n');
      expect(
        await File('${current.path}.mdslens-previous').readAsString(),
        '#!/bin/sh\nexit 0\n',
      );
      expect(
        await File('${current.path}.mdslens-previous.owner').readAsString(),
        'com.mdslens.app\n',
      );
      Process.killPid(int.parse(await launchedPid.readAsString()));
    },
  );

  test('AppImage update rolls back when the replacement exits early', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mdslens-appimage-rollback-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final current = File('${directory.path}/MDSLens.AppImage');
    final downloaded = File('${directory.path}/downloaded.AppImage');
    final rollbackMarker = File('${directory.path}/rollback-launched');
    await current.writeAsString(
      '#!/bin/sh\necho rollback > "${rollbackMarker.path}"\nsleep 10\n',
    );
    await Process.run('/bin/chmod', ['+x', current.path]);
    await downloaded.writeAsString('#!/bin/sh\nexit 1\n');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.AppImage',
        url: 'https://example.invalid/AppImage',
        platform: 'linux',
        architecture: 'x64',
        format: 'AppImage',
        strategy: 'self-replace',
        size: await downloaded.length(),
        sha256: sha256.convert(await downloaded.readAsBytes()).toString(),
      ),
      path: downloaded.path,
    );

    final result = await prepareAppImageUpdate(
      update,
      current.path,
      currentPid: 2147483646,
      commandLauncher: (executable, arguments) async {
        final compatibleArguments = List<String>.of(arguments);
        if (Platform.isMacOS) {
          compatibleArguments[1] = compatibleArguments[1].replaceAll(
            '/bin/mv -T --',
            '/bin/mv',
          );
        }
        final applied = await Process.run(executable, compatibleArguments);
        expect(applied.exitCode, 1);
      },
    );

    expect(result?.closeApplication, isTrue);
    expect(await current.readAsString(), contains('rollback-launched'));
    for (var attempt = 0;
        attempt < 30 && !rollbackMarker.existsSync();
        attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(rollbackMarker.existsSync(), isTrue);
  });

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
      commandLauncher: (command, arguments) async {
        commands.add((command, arguments));
      },
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

  test('Linux package selection follows the running installation channel', () {
    expect(
      linuxPreferredPackageFormatForInstallation(
        executablePath: '/home/user/Applications/mdslens/mdslens',
        environment: const {},
        linuxOsRelease: 'ID=ubuntu',
        linuxPortableRootExists: true,
      ),
      'tar.gz',
      reason: 'portable bundles must never be redirected into /usr',
    );
    expect(
      linuxPreferredPackageFormatForInstallation(
        executablePath: '/usr/lib/mdslens/mdslens',
        environment: const {},
        linuxOsRelease: 'ID=ubuntu',
      ),
      'deb',
    );
    expect(
      linuxPreferredPackageFormatForInstallation(
        executablePath: '/home/user/MDSLens.AppImage',
        environment: const {'APPIMAGE': '/home/user/MDSLens.AppImage'},
        linuxOsRelease: 'ID=fedora',
      ),
      'AppImage',
    );
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
        linuxPortableRootExists: true,
      ),
      isTrue,
      reason: 'marked portable archives support directory replacement',
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
    expect(
      nativeDirectUpdateSupported(
        platform: 'macos',
        resolvedExecutable:
            '/Volumes/MDSLens/MDSLens.app/Contents/MacOS/MDSLens',
        environment: const {},
      ),
      isFalse,
      reason: 'a read-only mounted disk image must not self-replace',
    );
  });

  test('Linux portable updates reject a package from another channel',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'mdslens-linux-channel-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/mdslens').writeAsString('old');
    await File('${root.path}/.mdslens-portable.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'product': 'com.mdslens.app',
        'architecture': 'x64',
        'executable': 'mdslens',
      }),
    );
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.deb',
        url: 'https://example.invalid/mdslens.deb',
        platform: 'linux',
        architecture: 'x64',
        format: 'deb',
        strategy: 'open-package',
        size: 1,
        sha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ),
      path: '/tmp/mdslens-linux-x64.deb',
    );
    final commands = <(String, List<String>)>[];

    final result = await launchVerifiedUpdateAsset(
      update,
      platformOverride: 'linux',
      currentExecutableOverride: '${root.path}/mdslens',
      currentAppImageOverride: '',
      commandLauncher: (executable, arguments) async {
        commands.add((executable, arguments));
      },
      commandRunner: (executable, arguments) async {
        commands.add((executable, arguments));
        return ProcessResult(0, 0, '', '');
      },
    );

    expect(result.status, UpdateLaunchStatus.unsupported);
    expect(result.message, contains('running portable installation'));
    expect(commands, isEmpty);
  });

  test('marked Linux portable bundles prepare an in-place directory update',
      () async {
    final root = await Directory.systemTemp.createTemp(
      'mdslens-portable-update-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final current = Directory('${root.path}/MDSLens');
    await current.create();
    await File('${current.path}/mdslens').writeAsString('old');
    await File('${current.path}/.mdslens-portable.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'product': 'com.mdslens.app',
        'version': '0.2.6',
        'architecture': 'x64',
        'executable': 'mdslens',
      }),
    );
    expect(
      linuxPortableRootFromExecutable('${current.path}/mdslens'),
      current.path,
    );

    final payload = Directory('${root.path}/payload/mdslens-linux-x64');
    await payload.create(recursive: true);
    await File('${payload.path}/mdslens').writeAsString('new');
    await File('${payload.path}/.mdslens-portable.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'product': 'com.mdslens.app',
        'version': '0.2.7',
        'architecture': 'x64',
        'executable': 'mdslens',
      }),
    );
    final archive = File('${root.path}/mdslens-linux-x64.tar.gz');
    final packed = await Process.run('/usr/bin/tar', [
      '-czf',
      archive.path,
      '-C',
      '${root.path}/payload',
      'mdslens-linux-x64',
    ]);
    expect(packed.exitCode, 0);
    final launches = <(String, List<String>)>[];
    final collidingStaged = Directory(
      '${current.path}.mdslens-update-collision',
    );
    final collidingBackup = Directory(
      '${current.path}.mdslens-backup-collision',
    );
    await collidingStaged.create();
    await collidingBackup.create();
    await File('${collidingStaged.path}/keep').writeAsString('staged');
    await File('${collidingBackup.path}/keep').writeAsString('backup');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.tar.gz',
        url: 'https://example.invalid/mdslens-linux-x64.tar.gz',
        platform: 'linux',
        architecture: 'x64',
        format: 'tar.gz',
        strategy: 'self-replace',
        size: await archive.length(),
        sha256: sha256.convert(await archive.readAsBytes()).toString(),
      ),
      path: archive.path,
    );

    final result = await prepareLinuxPortableUpdate(
      update,
      portableRoot: current.path,
      currentPid: 12345,
      parentWritableOverride: true,
      nonceOverride: 'collision',
      commandLauncher: (executable, arguments) async {
        launches.add((executable, arguments));
      },
      commandRunner: Process.run,
    );

    expect(result?.status, UpdateLaunchStatus.installed);
    expect(result?.closeApplication, isTrue);
    expect(launches.single.$1, '/bin/sh');
    final stagedPath = launches.single.$2.lastWhere(
      (argument) => argument.contains('.mdslens-update-'),
    );
    expect(stagedPath, endsWith('.mdslens-update-collision-1'));
    expect(await File('$stagedPath/mdslens').readAsString(), 'new');
    expect(await File('${collidingStaged.path}/keep').readAsString(), 'staged');
    expect(await File('${collidingBackup.path}/keep').readAsString(), 'backup');
    final script = launches.single.$2[1];
    expect(script, contains('/bin/mv -T --'));
    expect(script, contains(r'[ -L "$backup_root" ] && exit 1'));
  });

  test(
    'Linux portable update restarts inside the replacement directory and keeps one backup',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'mdslens-portable-swap-test-',
      );
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final current = Directory('${root.path}/MDSLens');
      await current.create();
      await File('${current.path}/mdslens')
          .writeAsString('#!/bin/sh\nexit 0\n');
      await File('${current.path}/.mdslens-portable.json').writeAsString(
        jsonEncode({
          'schema_version': 1,
          'product': 'com.mdslens.app',
          'version': '0.3.0',
          'architecture': 'x64',
          'executable': 'mdslens',
        }),
      );

      final observedWorkingDirectory = File('${root.path}/new-process.cwd');
      final observedProcessId = File('${root.path}/new-process.pid');
      final payload = Directory('${root.path}/payload/mdslens-linux-x64');
      await payload.create(recursive: true);
      await File('${payload.path}/mdslens').writeAsString(
        '#!/bin/sh\npwd > "${observedWorkingDirectory.path}"\n'
        'echo \$\$ > "${observedProcessId.path}"\nsleep 10\n',
      );
      await File('${payload.path}/.mdslens-portable.json').writeAsString(
        jsonEncode({
          'schema_version': 1,
          'product': 'com.mdslens.app',
          'version': '0.3.1',
          'architecture': 'x64',
          'executable': 'mdslens',
        }),
      );
      final archive = File('${root.path}/mdslens-linux-x64.tar.gz');
      final packed = await Process.run('/usr/bin/tar', [
        '-czf',
        archive.path,
        '-C',
        '${root.path}/payload',
        'mdslens-linux-x64',
      ]);
      expect(packed.exitCode, 0);
      final update = DownloadedUpdate(
        asset: UpdateManifestAsset(
          name: 'mdslens-linux-x64.tar.gz',
          url: 'https://example.invalid/mdslens-linux-x64.tar.gz',
          platform: 'linux',
          architecture: 'x64',
          format: 'tar.gz',
          strategy: 'self-replace',
          size: await archive.length(),
          sha256: sha256.convert(await archive.readAsBytes()).toString(),
        ),
        path: archive.path,
      );

      final result = await prepareLinuxPortableUpdate(
        update,
        portableRoot: current.path,
        currentPid: 2147483646,
        parentWritableOverride: true,
        commandLauncher: (executable, arguments) async {
          final compatibleArguments = List<String>.of(arguments);
          if (Platform.isMacOS) {
            // The production path is Linux-only and deliberately uses GNU
            // mv's exact-target flag. BSD mv lacks -T, so retain the
            // end-to-end working-directory test while the separate script
            // assertion above verifies that production keeps -T.
            compatibleArguments[1] = compatibleArguments[1].replaceAll(
              '/bin/mv -T --',
              '/bin/mv',
            );
            compatibleArguments[1] = compatibleArguments[1].replaceFirst(
              'set -u',
              'set -ux',
            );
          }
          final applied = await Process.run(
            executable,
            compatibleArguments,
          );
          expect(
            applied.exitCode,
            0,
            reason: '${applied.stdout}\n${applied.stderr}',
          );
        },
        commandRunner: Process.run,
      );

      expect(result?.closeApplication, isTrue);
      final resolvedCurrent = await current.resolveSymbolicLinks();
      for (var attempt = 0;
          attempt < 60 && !observedWorkingDirectory.existsSync();
          attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
          await observedWorkingDirectory.readAsString(), '$resolvedCurrent\n');
      final previous = Directory('$resolvedCurrent.mdslens-previous');
      expect(await File('$resolvedCurrent/mdslens').exists(), isTrue);
      expect(await File('${previous.path}/mdslens').exists(), isTrue);
      final launchedPid = int.parse(await observedProcessId.readAsString());
      Process.killPid(launchedPid);
    },
  );

  test('Linux portable updates reject archive path traversal', () async {
    final root = await Directory.systemTemp.createTemp(
      'mdslens-portable-traversal-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    final current = Directory('${root.path}/MDSLens');
    await current.create();
    await File('${current.path}/mdslens').writeAsString('old');
    await File('${current.path}/.mdslens-portable.json').writeAsString(
      jsonEncode({
        'schema_version': 1,
        'product': 'com.mdslens.app',
        'architecture': 'x64',
        'executable': 'mdslens',
      }),
    );
    final archive = File('${root.path}/mdslens-linux-x64.tar.gz');
    await archive.writeAsString('not used');
    final update = DownloadedUpdate(
      asset: UpdateManifestAsset(
        name: 'mdslens-linux-x64.tar.gz',
        url: 'https://example.invalid/mdslens-linux-x64.tar.gz',
        platform: 'linux',
        architecture: 'x64',
        format: 'tar.gz',
        strategy: 'self-replace',
        size: 8,
        sha256: List.filled(64, '0').join(),
      ),
      path: archive.path,
    );

    final result = await prepareLinuxPortableUpdate(
      update,
      portableRoot: current.path,
      currentPid: 12345,
      commandLauncher: (executable, arguments) async {},
      commandRunner: (executable, arguments) async {
        if (arguments.contains('-tzf')) {
          return ProcessResult(0, 0, '../outside\n', '');
        }
        return ProcessResult(0, 1, '', 'unexpected command');
      },
    );

    expect(result, isNull);
    expect(File('${root.path}/outside').existsSync(), isFalse);
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
