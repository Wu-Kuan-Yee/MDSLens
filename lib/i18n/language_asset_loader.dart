import 'language_asset_loader_stub.dart'
    if (dart.library.io) 'language_asset_loader_io.dart' as backend;

/// Loads a bundled language catalog.
///
/// The IO test backend can read the checked-out asset directly. This avoids a
/// Flutter testWidgets fake-async limitation in the platform asset channel;
/// production builds continue to use the normal asset bundle.
Future<String> loadLanguageAsset(
  String path, {
  bool preferFileSystem = false,
}) =>
    backend.loadLanguageAsset(path, preferFileSystem: preferFileSystem);
