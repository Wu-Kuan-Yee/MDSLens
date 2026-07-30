import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mdslens/services/update_installer.dart';
import 'package:mdslens/services/update_service.dart';

void main() {
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
    'Windows EXE updates run silently and request application shutdown',
    () async {
      final commands = <(String, List<String>)>[];
      final update = DownloadedUpdate(
        asset: assetFor(utf8.encode('installer')),
        path: r'C:\Temp\mdslens-update.exe',
      );

      final result = await launchVerifiedUpdateAsset(
        update,
        platformOverride: 'windows',
        commandLauncher: (executable, arguments) async {
          commands.add((executable, arguments));
        },
      );

      expect(commands, hasLength(1));
      expect(commands.single.$1, update.path);
      expect(
        commands.single.$2,
        containsAll(<String>[
          '/VERYSILENT',
          '/SUPPRESSMSGBOXES',
          '/NORESTART',
          '/CLOSEAPPLICATIONS',
          '/RESTARTAPPLICATIONS',
        ]),
      );
      expect(result.status, UpdateLaunchStatus.launched);
      expect(result.closeApplication, isTrue);
    },
  );

  test(
    'Windows MSI fallback uses the non-interactive Windows Installer mode',
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
        commandLauncher: (executable, arguments) async {
          commands.add((executable, arguments));
        },
      );

      expect(commands.single.$1, 'msiexec.exe');
      expect(commands.single.$2, containsAll(<String>['/qn', '/norestart']));
      expect(result.closeApplication, isTrue);
    },
  );
}
