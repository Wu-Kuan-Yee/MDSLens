import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mdslens/services/toml_codec.dart';
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
        location('update-manifest.toml', 10),
        location('mdslens-windows-x64-setup.exe', 7),
      ],
    );
    final manifest = parseUpdateManifest(
      encodeTomlDocument({
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
          encodeTomlDocument({
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

  test('automatic checks use the lightweight release index first', () async {
    final requests = <http.BaseRequest>[];
    final client = MockClient((request) async {
      requests.add(request);
      expect(request.url.toString(), mdsLensLatestIndexUrl);
      expect(request.headers['user-agent'], 'MDSLens/1.4.0');
      expect(request.headers['x-github-api-version'], '2022-11-28');
      return http.Response(
        encodeTomlDocument({
          'schema_version': 1,
          'version': '1.5.0',
          'tag': 'v1.5.0',
          'release_url':
              'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.5.0',
          'assets': [
            {
              'name': 'update-manifest.toml',
              'url':
                  'https://github.com/Wu-Kuan-Yee/MDSLens/releases/download/v1.5.0/update-manifest.toml',
              'size': 10,
            },
            {
              'name': 'mdslens-windows-x64.zip',
              'url':
                  'https://github.com/Wu-Kuan-Yee/MDSLens/releases/download/v1.5.0/mdslens-windows-x64.zip',
              'size': 20,
            },
          ],
        }),
        200,
        headers: const {'content-type': 'application/toml'},
      );
    });

    final update = await checkLatestMDSLensRelease(
      '1.4.0',
      client: client,
    );

    expect(update.latestVersion, 'v1.5.0');
    expect(update.updateAvailable, isTrue);
    expect(update.assets, hasLength(2));
    expect(requests, hasLength(1));
  });

  test('automatic checks fall back to tags and one release lookup', () async {
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      if (request.url.toString() == mdsLensLatestIndexUrl) {
        return http.Response('temporarily unavailable', 503);
      }
      if (request.url.path == '/repos/Wu-Kuan-Yee/MDSLens/tags') {
        return http.Response(
          jsonEncode([
            {'name': 'v1.5.0'},
            {'name': 'v1.4.9'},
            {'name': 'v2.0.0-beta'},
          ]),
          200,
        );
      }
      expect(
        request.url.toString(),
        '$mdsLensGitHubApiBaseUrl/releases/tags/v1.5.0',
      );
      return http.Response(
        jsonEncode({
          'tag_name': 'v1.5.0',
          'html_url':
              'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.5.0',
          'draft': false,
          'prerelease': false,
          'assets': [
            {
              'name': 'update-manifest.toml',
              'browser_download_url':
                  'https://github.com/Wu-Kuan-Yee/MDSLens/releases/download/v1.5.0/update-manifest.toml',
              'size': 10,
            },
          ],
        }),
        200,
      );
    });

    final update = await checkLatestMDSLensRelease(
      '1.4.0',
      client: client,
    );

    expect(update.latestVersion, 'v1.5.0');
    expect(update.updateAvailable, isTrue);
    expect(requests.map((uri) => uri.toString()), [
      mdsLensLatestIndexUrl,
      mdsLensTagsApiUrl,
      '$mdsLensGitHubApiBaseUrl/releases/tags/v1.5.0',
    ]);
  });
}
