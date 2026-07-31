import 'dart:convert';

import 'package:http/http.dart' as http;

const mdsLensRepositoryUrl = 'https://github.com/Wu-Kuan-Yee/MDSLens';
const mdsLensSourceUrl = 'https://github.com/Wu-Kuan-Yee/MDSLens';
const mdsLensMaintainerUrl = 'https://github.com/Wu-Kuan-Yee';
const originalMdsScopeRepositoryUrl = 'https://github.com/wwktz/MdsScope';
const mdsLensReleasesUrl = 'https://github.com/Wu-Kuan-Yee/MDSLens/releases';
const mdsLensReleasesApiUrl =
    'https://api.github.com/repos/Wu-Kuan-Yee/MDSLens/releases?per_page=100';

class ReleaseUpdate {
  final String latestVersion;
  final String releaseUrl;
  final bool updateAvailable;
  final List<ReleaseAssetLocation> assets;

  const ReleaseUpdate({
    required this.latestVersion,
    required this.releaseUrl,
    required this.updateAvailable,
    this.assets = const [],
  });

  ReleaseAssetLocation? assetNamed(String name) {
    for (final asset in assets) {
      if (asset.name == name) return asset;
    }
    return null;
  }
}

class ReleaseAssetLocation {
  const ReleaseAssetLocation({
    required this.name,
    required this.url,
    required this.size,
  });

  final String name;
  final String url;
  final int size;
}

class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.releaseUrl,
    required this.assets,
  });

  final String version;
  final String releaseUrl;
  final List<UpdateManifestAsset> assets;
}

class UpdateManifestAsset {
  const UpdateManifestAsset({
    required this.name,
    required this.url,
    required this.platform,
    required this.architecture,
    required this.format,
    required this.strategy,
    required this.size,
    required this.sha256,
  });

  final String name;
  final String url;
  final String platform;
  final String architecture;
  final String format;
  final String strategy;
  final int size;
  final String sha256;
}

Future<ReleaseUpdate> checkLatestMDSLensRelease(
  String currentVersion, {
  http.Client? client,
}) async {
  final ownedClient = client == null;
  final activeClient = client ?? http.Client();
  try {
    final response = await activeClient.get(
      Uri.parse(mdsLensReleasesApiUrl),
      headers: const {
        'Accept': 'application/vnd.github+json',
      },
    ).timeout(const Duration(seconds: 10));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('GitHub returned HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) {
      throw const FormatException('Invalid release response');
    }
    Map<dynamic, dynamic>? selected;
    for (final candidate in decoded) {
      if (candidate is! Map ||
          candidate['draft'] == true ||
          candidate['prerelease'] == true) {
        continue;
      }
      final tag = candidate['tag_name']?.toString().trim() ?? '';
      if (!_parseVersion(tag).isValid) continue;
      final selectedTag = selected?['tag_name']?.toString().trim();
      if (selectedTag == null || compareVersions(tag, selectedTag) > 0) {
        selected = candidate;
      }
    }
    if (selected == null) {
      throw const FormatException('No stable release version was found');
    }
    return _releaseUpdateFromGitHub(
      selected,
      currentVersion: currentVersion,
    );
  } finally {
    if (ownedClient) activeClient.close();
  }
}

ReleaseUpdate _releaseUpdateFromGitHub(
  Map<dynamic, dynamic> decoded, {
  required String currentVersion,
}) {
  final latest = decoded['tag_name']?.toString().trim() ?? '';
  if (!_parseVersion(latest).isValid) {
    throw const FormatException('Invalid release version');
  }
  final releaseUrl = decoded['html_url']?.toString().trim();
  final assets = <ReleaseAssetLocation>[];
  final rawAssets = decoded['assets'];
  if (rawAssets is List) {
    for (final rawAsset in rawAssets) {
      if (rawAsset is! Map) continue;
      final name = rawAsset['name']?.toString().trim() ?? '';
      final url = rawAsset['browser_download_url']?.toString().trim() ?? '';
      final size = _integer(rawAsset['size']);
      if (name.isEmpty ||
          !_isTrustedGitHubDownload(url) ||
          size == null ||
          size < 0) {
        continue;
      }
      assets.add(ReleaseAssetLocation(name: name, url: url, size: size));
    }
  }
  return ReleaseUpdate(
    latestVersion: latest,
    releaseUrl: releaseUrl == null || releaseUrl.isEmpty
        ? mdsLensReleasesUrl
        : releaseUrl,
    updateAvailable: compareVersions(latest, currentVersion) > 0,
    assets: List.unmodifiable(assets),
  );
}

Future<UpdateManifest> fetchUpdateManifest(
  ReleaseUpdate release, {
  http.Client? client,
}) async {
  final location = release.assetNamed('update-manifest.json');
  if (location == null) {
    throw const FormatException('This release has no update manifest');
  }
  final ownedClient = client == null;
  final activeClient = client ?? http.Client();
  try {
    final response = await activeClient.get(
      Uri.parse(location.url),
      headers: const {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'GitHub returned HTTP ${response.statusCode} for the update manifest',
      );
    }
    return parseUpdateManifest(
      utf8.decode(response.bodyBytes),
      release: release,
    );
  } finally {
    if (ownedClient) activeClient.close();
  }
}

UpdateManifest parseUpdateManifest(
  String source, {
  required ReleaseUpdate release,
}) {
  final decoded = jsonDecode(source);
  if (decoded is! Map || _integer(decoded['schema_version']) != 1) {
    throw const FormatException('Unsupported update manifest');
  }
  final version = decoded['version']?.toString().trim() ?? '';
  if (!_parseVersion(version).isValid ||
      compareVersions(version, release.latestVersion) != 0) {
    throw const FormatException(
        'Update manifest version does not match release');
  }
  final releaseUrl = decoded['release_url']?.toString().trim() ?? '';
  if (!_isTrustedRepositoryUrl(releaseUrl)) {
    throw const FormatException('Update manifest has an untrusted release URL');
  }
  final rawAssets = decoded['assets'];
  if (rawAssets is! List) {
    throw const FormatException('Update manifest has no asset list');
  }
  final assets = <UpdateManifestAsset>[];
  for (final rawAsset in rawAssets) {
    if (rawAsset is! Map) continue;
    final name = rawAsset['name']?.toString().trim() ?? '';
    final location = release.assetNamed(name);
    final platform =
        rawAsset['platform']?.toString().trim().toLowerCase() ?? '';
    final architecture =
        rawAsset['architecture']?.toString().trim().toLowerCase() ?? '';
    final format = rawAsset['format']?.toString().trim() ?? '';
    final strategy = rawAsset['strategy']?.toString().trim() ?? '';
    final size = _integer(rawAsset['size']);
    final sha256 = rawAsset['sha256']?.toString().trim().toLowerCase() ?? '';
    if (location == null ||
        size == null ||
        size <= 0 ||
        location.size != size ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
        !const {
          'windows',
          'macos',
          'linux',
          'android',
          'ios',
          'ipados',
        }.contains(platform) ||
        !const {'x64', 'arm64', 'armv7', 'universal'}.contains(architecture) ||
        !const {
          'launch-installer',
          'open-package',
          'self-replace',
          'system-installer',
          'manual',
        }.contains(strategy)) {
      continue;
    }
    assets.add(
      UpdateManifestAsset(
        name: name,
        url: location.url,
        platform: platform,
        architecture: architecture,
        format: format,
        strategy: strategy,
        size: size,
        sha256: sha256,
      ),
    );
  }
  if (assets.isEmpty) {
    throw const FormatException('Update manifest has no usable assets');
  }
  return UpdateManifest(
    version: version,
    releaseUrl: releaseUrl,
    assets: List.unmodifiable(assets),
  );
}

UpdateManifestAsset? selectUpdateAsset(
  UpdateManifest manifest, {
  required String platform,
  required String architecture,
  String? preferredLinuxFormat,
  String? preferredMacOSFormat,
  String? preferredWindowsFormat,
}) {
  final normalizedPlatform =
      platform.toLowerCase() == 'ipados' ? 'ipados' : platform.toLowerCase();
  final normalizedArchitecture = switch (architecture.toLowerCase()) {
    'x86_64' || 'amd64' => 'x64',
    'aarch64' || 'arm64-v8a' => 'arm64',
    'armeabi-v7a' => 'armv7',
    final value => value,
  };
  final candidates = manifest.assets
      .where((asset) => asset.platform == normalizedPlatform)
      .toList();
  if (candidates.isEmpty) return null;

  int rank(UpdateManifestAsset asset) {
    final architectureRank = asset.architecture == normalizedArchitecture
        ? 0
        : asset.architecture == 'universal'
            ? 1
            : 100;
    if (architectureRank == 100) return 1000;
    final formatRank = switch (normalizedPlatform) {
      'windows' => asset.format == preferredWindowsFormat
          ? 0
          : asset.format == 'exe'
              ? 1
              : asset.format == 'msi'
                  ? 2
                  : 10,
      'macos' => asset.format == preferredMacOSFormat
          ? 0
          : asset.format == 'zip'
              ? 1
              : asset.format == 'dmg'
                  ? 2
                  : 10,
      'android' => asset.architecture == 'universal' ? 0 : architectureRank,
      'linux' => asset.format == preferredLinuxFormat
          ? 0
          : preferredLinuxFormat == 'tar.gz' && asset.format == 'tar.gz'
              ? 0
              : asset.format == 'AppImage'
                  ? 1
                  : 5,
      _ => 0,
    };
    return architectureRank * 10 + formatRank;
  }

  candidates.sort((left, right) => rank(left).compareTo(rank(right)));
  return rank(candidates.first) >= 1000 ? null : candidates.first;
}

int compareVersions(String left, String right) {
  final a = _parseVersion(left);
  final b = _parseVersion(right);
  if (!a.isValid || !b.isValid) {
    throw const FormatException('Invalid semantic version');
  }
  for (var index = 0; index < 3; index++) {
    final comparison = a.parts[index].compareTo(b.parts[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

({bool isValid, List<int> parts}) _parseVersion(String value) {
  final match = RegExp(
    r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return (isValid: false, parts: const [0, 0, 0]);
  return (
    isValid: true,
    parts: List.generate(
      3,
      (index) => int.parse(match.group(index + 1) ?? '0'),
    ),
  );
}

int? _integer(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value == value.roundToDouble()) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '');
}

bool _isTrustedGitHubDownload(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.path.startsWith('/Wu-Kuan-Yee/MDSLens/releases/download/');
}

bool _isTrustedRepositoryUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.toLowerCase() == 'github.com' &&
      uri.path.startsWith('/Wu-Kuan-Yee/MDSLens/releases/');
}
