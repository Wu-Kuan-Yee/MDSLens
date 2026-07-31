import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mdslens/services/update_service.dart';

void main() {
  const releaseUrl =
      'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.2.3';

  ReleaseAssetLocation location(String name, int size) {
    return ReleaseAssetLocation(
      name: name,
      url:
          'https://github.com/Wu-Kuan-Yee/MDSLens/releases/download/v1.2.3/$name',
      size: size,
    );
  }

  test('update manifests require matching GitHub release assets', () {
    final release = ReleaseUpdate(
      latestVersion: 'v1.2.3',
      releaseUrl: releaseUrl,
      updateAvailable: true,
      assets: [
        location('update-manifest.json', 10),
        location('mdslens-windows-x64-setup.exe', 7),
      ],
    );
    final manifest = parseUpdateManifest(
      jsonEncode({
        'schema_version': 1,
        'version': '1.2.3',
        'release_url': releaseUrl,
        'assets': [
          {
            'name': 'mdslens-windows-x64-setup.exe',
            'platform': 'windows',
            'architecture': 'x64',
            'format': 'exe',
            'strategy': 'launch-installer',
            'size': 7,
            'sha256':
                'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          },
          {
            'name': 'not-on-the-release.exe',
            'platform': 'windows',
            'architecture': 'x64',
            'format': 'exe',
            'strategy': 'launch-installer',
            'size': 7,
            'sha256':
                'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          },
        ],
      }),
      release: release,
    );

    expect(manifest.assets, hasLength(1));
    expect(manifest.assets.single.name, 'mdslens-windows-x64-setup.exe');
  });

  test('asset selection follows platform, architecture, and package channel',
      () {
    const manifest = UpdateManifest(
      version: '1.2.3',
      releaseUrl: releaseUrl,
      assets: [
        UpdateManifestAsset(
          name: 'linux-x64.AppImage',
          url: 'https://example.invalid/appimage',
          platform: 'linux',
          architecture: 'x64',
          format: 'AppImage',
          strategy: 'open-package',
          size: 1,
          sha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        UpdateManifestAsset(
          name: 'linux-x64.deb',
          url: 'https://example.invalid/deb',
          platform: 'linux',
          architecture: 'x64',
          format: 'deb',
          strategy: 'open-package',
          size: 1,
          sha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
        UpdateManifestAsset(
          name: 'linux-x64.tar.gz',
          url: 'https://example.invalid/portable.tar.gz',
          platform: 'linux',
          architecture: 'x64',
          format: 'tar.gz',
          strategy: 'self-replace',
          size: 1,
          sha256:
              'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
        ),
        UpdateManifestAsset(
          name: 'windows-x64.exe',
          url: 'https://example.invalid/windows.exe',
          platform: 'windows',
          architecture: 'x64',
          format: 'exe',
          strategy: 'launch-installer',
          size: 1,
          sha256:
              '1111111111111111111111111111111111111111111111111111111111111111',
        ),
        UpdateManifestAsset(
          name: 'windows-x64.zip',
          url: 'https://example.invalid/windows.zip',
          platform: 'windows',
          architecture: 'x64',
          format: 'zip',
          strategy: 'self-replace',
          size: 1,
          sha256:
              '2222222222222222222222222222222222222222222222222222222222222222',
        ),
        UpdateManifestAsset(
          name: 'android-universal.apk',
          url: 'https://example.invalid/apk',
          platform: 'android',
          architecture: 'universal',
          format: 'apk',
          strategy: 'system-installer',
          size: 1,
          sha256:
              'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
        ),
        UpdateManifestAsset(
          name: 'macos-universal.zip',
          url: 'https://example.invalid/macos.zip',
          platform: 'macos',
          architecture: 'universal',
          format: 'zip',
          strategy: 'self-replace',
          size: 1,
          sha256:
              'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        ),
        UpdateManifestAsset(
          name: 'macos-universal.dmg',
          url: 'https://example.invalid/macos.dmg',
          platform: 'macos',
          architecture: 'universal',
          format: 'dmg',
          strategy: 'open-package',
          size: 1,
          sha256:
              'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
        ),
      ],
    );

    expect(
      selectUpdateAsset(
        manifest,
        platform: 'linux',
        architecture: 'x86_64',
        preferredLinuxFormat: 'deb',
      )?.format,
      'deb',
    );
    expect(
      selectUpdateAsset(
        manifest,
        platform: 'linux',
        architecture: 'x86_64',
        preferredLinuxFormat: 'tar.gz',
      )?.format,
      'tar.gz',
    );
    expect(
      selectUpdateAsset(
        manifest,
        platform: 'android',
        architecture: 'arm64-v8a',
      )?.name,
      'android-universal.apk',
    );
    expect(
      selectUpdateAsset(
        manifest,
        platform: 'windows',
        architecture: 'x64',
        preferredWindowsFormat: 'exe',
      )?.format,
      'exe',
    );
    expect(
      selectUpdateAsset(
        manifest,
        platform: 'windows',
        architecture: 'x64',
        preferredWindowsFormat: 'zip',
      )?.format,
      'zip',
    );
    expect(
      selectUpdateAsset(
        manifest,
        platform: 'macos',
        architecture: 'arm64',
        preferredMacOSFormat: 'zip',
      )?.format,
      'zip',
    );
    expect(
      selectUpdateAsset(
        manifest,
        platform: 'macos',
        architecture: 'arm64',
        preferredMacOSFormat: 'dmg',
      )?.format,
      'dmg',
    );
  });

  test('manifest rejects mismatched versions and untrusted release URLs', () {
    final release = ReleaseUpdate(
      latestVersion: 'v1.2.3',
      releaseUrl: releaseUrl,
      updateAvailable: true,
      assets: [location('asset.exe', 1)],
    );
    for (final values in [
      ('9.0.0', releaseUrl),
      ('1.2.3', 'https://example.invalid/release'),
    ]) {
      expect(
        () => parseUpdateManifest(
          jsonEncode({
            'schema_version': 1,
            'version': values.$1,
            'release_url': values.$2,
            'assets': const [],
          }),
          release: release,
        ),
        throwsFormatException,
      );
    }
  });

  test('automatic checks choose the highest stable semantic release', () async {
    final response = jsonEncode([
      {
        'tag_name': 'v1.5.0',
        'html_url':
            'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.5.0',
        'draft': false,
        'prerelease': false,
        'assets': const [],
      },
      {
        'tag_name': 'v1.4.9',
        'html_url':
            'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.4.9',
        'draft': false,
        'prerelease': false,
        'assets': const [],
      },
      {
        'tag_name': 'v2.0.0-beta',
        'draft': false,
        'prerelease': true,
        'assets': const [],
      },
      {
        'tag_name': 'v1.6.0',
        'draft': true,
        'prerelease': false,
        'assets': const [],
      },
    ]);
    final client = MockClient((request) async {
      expect(request.url.toString(), mdsLensReleasesApiUrl);
      return http.Response(response, 200);
    });

    final update = await checkLatestMDSLensRelease(
      '1.4.0',
      client: client,
    );

    expect(update.latestVersion, 'v1.5.0');
    expect(update.updateAvailable, isTrue);
  });
}
