import 'dart:convert';
import 'dart:io';

const currentMdsScopeVersion = '7.0';
const mdsScopeRepositoryUrl = 'https://github.com/Wu-Kuan-Yee/MdsScope';
const mdsScopeSourceUrl =
    'https://github.com/Wu-Kuan-Yee/MdsScope/tree/flutter-rewrite';
const mdsScopeReleasesUrl = 'https://github.com/Wu-Kuan-Yee/MdsScope/releases';
const mdsScopeLatestReleaseApiUrl =
    'https://api.github.com/repos/Wu-Kuan-Yee/MdsScope/releases/latest';

class ReleaseUpdate {
  final String latestVersion;
  final String releaseUrl;
  final bool updateAvailable;

  const ReleaseUpdate({
    required this.latestVersion,
    required this.releaseUrl,
    required this.updateAvailable,
  });
}

Future<ReleaseUpdate> checkLatestMdsScopeRelease() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final request = await client.getUrl(
      Uri.parse(mdsScopeLatestReleaseApiUrl),
    );
    request.headers.set(HttpHeaders.userAgentHeader, 'MdsScope');
    request.headers
        .set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'GitHub returned HTTP ${response.statusCode}',
        uri: request.uri,
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      throw const FormatException('Invalid release response');
    }
    final latest = decoded['tag_name']?.toString().trim() ?? '';
    if (!_parseVersion(latest).isValid) {
      throw const FormatException('Invalid release version');
    }
    final releaseUrl = decoded['html_url']?.toString().trim();
    return ReleaseUpdate(
      latestVersion: latest,
      releaseUrl: releaseUrl == null || releaseUrl.isEmpty
          ? mdsScopeReleasesUrl
          : releaseUrl,
      updateAvailable: compareVersions(latest, currentMdsScopeVersion) > 0,
    );
  } finally {
    client.close(force: true);
  }
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
