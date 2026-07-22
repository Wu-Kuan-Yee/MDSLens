import 'package:url_launcher/url_launcher.dart' as url_launcher;

typedef ExternalUriOpener = Future<bool> Function(Uri uri);

Uri? normalizeExternalWebUrl(String value) {
  var normalized = value.trim();
  if (normalized.isEmpty) return null;
  final schemeMatch = RegExp(
    r'^([a-z][a-z0-9+.-]*):',
    caseSensitive: false,
  ).firstMatch(normalized);
  if (schemeMatch != null &&
      schemeMatch.group(1)?.toLowerCase() != 'http' &&
      schemeMatch.group(1)?.toLowerCase() != 'https') {
    return null;
  }
  if (schemeMatch == null) {
    normalized = 'http://$normalized';
  }
  final uri = Uri.tryParse(normalized);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

Future<bool> openExternalWebUrl(
  String value, {
  ExternalUriOpener? opener,
}) async {
  final uri = normalizeExternalWebUrl(value);
  if (uri == null) return false;
  try {
    return await (opener ?? _launch)(uri);
  } catch (_) {
    return false;
  }
}

Future<bool> _launch(Uri uri) {
  return url_launcher.launchUrl(
    uri,
    mode: url_launcher.LaunchMode.externalApplication,
  );
}
