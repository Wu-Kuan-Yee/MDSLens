import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Private persistence owned by this application.
///
/// Desktop builds use ~/.mdslens and never read the legacy ~/.mdsscope
/// or ~/.config/mdsscope trees. Sandboxed mobile platforms use an equally isolated
/// .mdslens directory below their application-support container.
class UserDataStore {
  UserDataStore({Directory? rootOverride}) : _rootOverride = rootOverride;

  static bool disableFileStorageForTests = false;
  static const _directoryChannel = MethodChannel('mdslens/user_data');

  final Directory? _rootOverride;
  Future<void> _writeTail = Future<void>.value();

  Future<Directory?> rootDirectory() async {
    if (_rootOverride != null) return _rootOverride;
    if (disableFileStorageForTests) return null;
    try {
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        final home = Platform.isWindows
            ? Platform.environment['USERPROFILE']
            : Platform.environment['HOME'];
        if (home == null || home.trim().isEmpty) return null;
        return Directory(_join(home, '.mdslens'));
      }
      final support = await _directoryChannel.invokeMethod<String>(
        'supportDirectory',
      );
      if (support == null || support.trim().isEmpty) return null;
      return Directory(_join(support, '.mdslens'));
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> readSettings() async {
    final root = await rootDirectory();
    if (root == null) return null;
    try {
      await _prepareDirectories(root);
      final file = File(_join(root.path, 'settings.json'));
      if (!await file.exists()) return <String, dynamic>{};
      final decoded = jsonDecode(await file.readAsString());
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<Directory?> configurationDirectory() async {
    final root = await rootDirectory();
    if (root == null) return null;
    try {
      await _prepareDirectories(root);
      return Directory(_join(root.path, 'configurations'));
    } catch (_) {
      return null;
    }
  }

  Future<bool> writeSettings(Map<String, dynamic> settings) {
    final completer = Completer<bool>();
    _writeTail = _writeTail.then((_) async {
      final root = await rootDirectory();
      if (root == null) {
        completer.complete(false);
        return;
      }
      try {
        await _prepareDirectories(root);
        final file = File(_join(root.path, 'settings.json'));
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(
          const JsonEncoder.withIndent('  ').convert(settings),
          flush: true,
        );
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
        completer.complete(true);
      } catch (_) {
        completer.complete(false);
      }
    });
    return completer.future;
  }

  Future<void> _prepareDirectories(Directory root) async {
    await root.create(recursive: true);
    await Directory(_join(root.path, 'configurations')).create(recursive: true);
    await Directory(_join(root.path, 'cache')).create(recursive: true);
  }

  static String _join(String parent, String child) {
    final separator = Platform.pathSeparator;
    return parent.endsWith(separator)
        ? '$parent$child'
        : '$parent$separator$child';
  }
}
