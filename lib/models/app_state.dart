import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/credential_store.dart';
import '../services/platform_file_dialog.dart';
import '../services/network_permission_service.dart';
import '../services/rust_bridge.dart';
import '../services/source_index.dart';
import '../services/user_data_store.dart';

const _configurationSignalColors = [
  '#2364aa',
  '#c44e52',
  '#2f855a',
  '#805ad5',
  '#d97706',
  '#0f766e',
  '#9f1239',
  '#4a5568',
  '#db2777',
  '#16a34a',
  '#ea580c',
  '#0891b2',
];

const signalHideModeVisible = 0;
const signalHideModeTemporary = 1;
const signalHideModePersistent = 2;

const _filePreferenceKeys = <String>[
  'rememberLogin',
  'explicitlyLoggedOut',
  'loginApiUrl',
  'loginUser',
  'sshHost',
  'sshPort',
  'sshUser',
  'sshIdentity',
  'sshMode',
  'dataMode',
  'interactionMode',
  'themeMode',
  'toolbarCollapsed',
  'fontFamily',
  'fontLegendSize',
  'fontAxisSize',
  'fontUnitSize',
  'fontUiSize',
  'limitShotHistory',
  'shotHistoryLimit',
  'webBookmarks',
  'shotHistory',
  'sourceIndexMemory',
  'lastConfigJson',
  'loggedIn',
];

const _loginPasswordCredential = 'mdsscope.login.password';
const _authTokenCredential = 'mdsscope.login.token';
const _sshPasswordCredential = 'mdsscope.ssh.password';
const _plaintextCredentialKeys = <String>[
  'loginPass',
  'authToken',
  'sshPass',
];

int signalHideModeOf(Map<dynamic, dynamic> signal) {
  final raw = signal['hide_mode'];
  final parsed = raw is num
      ? raw.toInt()
      : switch (raw?.toString().trim().toLowerCase()) {
          'temporary' || 'current_shot' || 'current-shot' => 1,
          'persistent' || 'always' => 2,
          'visible' || 'none' || 'not_hidden' || 'not-hidden' => 0,
          final value => int.tryParse(value ?? ''),
        };
  if (parsed != null && parsed >= 0 && parsed <= 2) return parsed;
  // Configurations produced before the three-state control used a single
  // boolean. Preserve a previously hidden curve as persistently hidden.
  return signal['hidden'] == true
      ? signalHideModePersistent
      : signalHideModeVisible;
}

bool signalIsHidden(Map<dynamic, dynamic> signal) =>
    signalHideModeOf(signal) != signalHideModeVisible;

void normalizeSignalHideSettings(Map<dynamic, dynamic> signal) {
  final mode = signalHideModeOf(signal);
  signal['hide_mode'] = mode;
  signal['hidden'] = mode != signalHideModeVisible;
}

class ConfigOpenSelection {
  const ConfigOpenSelection({
    required this.name,
    this.path,
    this.bytes,
  });

  final String name;
  final String? path;
  final Uint8List? bytes;
}

typedef ConfigOpenPicker = Future<ConfigOpenSelection?> Function();
typedef ConfigSavePicker = Future<String?> Function(
  String suggestedName,
  Uint8List bytes,
);
typedef ConfigParser = String Function(String path);
typedef ConfigEncoder = Future<Uint8List> Function(String configJson);
typedef ImportedShotDecision = Future<bool> Function(String importedShot);
typedef SshTestWorker = Future<String> Function(String settingsJson);
typedef SshDisconnect = void Function();

/// The Qt-era application used this shared user directory.  Keeping imports
/// out of it prevents an old installation from silently becoming a source of
/// state for this application as well.
bool isLegacyMdsScopeConfigurationPath(String path) {
  final normalized =
      path.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/').toLowerCase();
  return normalized.endsWith('/.config/mdsscope') ||
      normalized.contains('/.config/mdsscope/');
}

typedef SignalFetchWorker = Future<String> Function(
  String configJson,
  String dataMode,
  String sshSettingsJson,
);

typedef ShotInfoFetchWorker = Future<String> Function(
  String apiUrl,
  String token,
  String shot,
);

typedef LoginWorker = Future<({String token, bool usedSsh})> Function(
  String apiUrl,
  String user,
  String password,
  String sshSettingsJson,
);

typedef LatestShotWorker = Future<dynamic> Function(
  String apiUrl,
  String token,
  String sshSettingsJson,
);

Future<ConfigOpenSelection?> _pickConfigurationFile() async {
  final mobile = Platform.isAndroid || Platform.isIOS;
  final privateDirectory =
      mobile ? null : await UserDataStore().configurationDirectory();
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Open MdsScope configuration',
    // iOS/iPadOS document providers do not consistently map the non-standard
    // TOML extension to a UTI, which makes valid files appear disabled.
    // Validate the selected filename ourselves on mobile instead.
    type: mobile ? FileType.any : FileType.custom,
    allowedExtensions: mobile ? null : const ['toml', 'webscp'],
    withData: mobile,
    initialDirectory: privateDirectory?.path,
    lockParentWindow: !mobile,
  );
  if (result == null || result.files.isEmpty) return null;
  final file = result.files.single;
  final lowerName = file.name.toLowerCase();
  if (!lowerName.endsWith('.toml') && !lowerName.endsWith('.webscp')) {
    throw const FormatException(
      'Please choose an MdsScope .toml or .webscp configuration file.',
    );
  }
  return ConfigOpenSelection(
    name: file.name,
    // file_picker commonly provides a readable cached path on mobile. Keep it
    // and use the in-memory bytes only as a fallback.
    path: file.path,
    bytes: file.bytes,
  );
}

Future<String?> _saveConfigurationFile(
  String suggestedName,
  Uint8List bytes,
) async {
  final mobile = Platform.isAndroid || Platform.isIOS;
  final privateDirectory =
      mobile ? null : await UserDataStore().configurationDirectory();
  return saveBytesWithFilePicker(
    dialogTitle: 'Save MdsScope configuration',
    fileName: suggestedName,
    allowedExtensions: const ['toml'],
    bytes: bytes,
    initialDirectory: privateDirectory?.path,
  );
}

String _parseConfiguration(String path) => RustBridge.instance.parseEnv(path);

Future<Uint8List> _encodeConfiguration(String configJson) async {
  final toml = RustBridge.instance.encodeEnv(configJson);
  return Uint8List.fromList(utf8.encode(toml));
}

Future<String> _testSshInBackground(String settingsJson) {
  return Isolate.run(() => RustBridge.instance.sshT(settingsJson));
}

Future<String> _fetchSignalsInBackground(
  String configJson,
  String dataMode,
  String sshSettingsJson,
) {
  return Isolate.run(
    () => RustBridge.instance.fetchSigSsh(
      configJson,
      dataMode,
      sshSettingsJson,
    ),
  );
}

Future<String> _fetchShotInfoInBackground(
  String apiUrl,
  String token,
  String shot,
) {
  return Isolate.run(
    () => RustBridge.instance.fetchSInfo(apiUrl, token, shot),
  );
}

Future<({String url, bool usedSsh})> _prepareApiUrl(
  String apiUrl,
  String sshSettingsJson,
) async {
  if (sshSettingsJson.isEmpty) return (url: apiUrl, usedSsh: false);
  final prepared = await Isolate.run(
    () => RustBridge.instance.prepareUrl(apiUrl, sshSettingsJson),
  );
  if (!prepared.startsWith('http') || prepared.contains('"error"')) {
    throw 'SSH prepare failed: $prepared';
  }
  await Future<void>.delayed(const Duration(milliseconds: 200));
  return (url: prepared, usedSsh: true);
}

Future<({String token, bool usedSsh})> _loginToApi(
  String apiUrl,
  String user,
  String password,
  String sshSettingsJson,
) async {
  final prepared = await _prepareApiUrl(apiUrl, sshSettingsJson);
  final base = prepared.url.replaceAll(RegExp(r'/$'), '');
  final client = HttpClient();
  try {
    client.connectionTimeout = const Duration(seconds: 10);
    final request = await client.postUrl(Uri.parse('$base/login'));
    final payload = utf8.encode(
      jsonEncode({'userName': user, 'password': password}),
    );
    request.headers
      ..set('Content-Type', 'application/json; charset=utf-8')
      ..set('User-Agent', 'MdsScope/7.0');
    request.contentLength = payload.length;
    request.add(payload);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    try {
      final token = decodeLoginToken(body, httpStatus: response.statusCode);
      return (token: token, usedSsh: prepared.usedSsh);
    } on EmptyApiResponseException {
      // The EAST nginx/API combination has occasionally closed a successful
      // Dart HttpClient response without delivering its chunked body on
      // desktop. Retry through the bundled native transport, which uses an
      // explicit HTTP/1.1 connection and Content-Length.
      final nativeBody = await Isolate.run(
        () => RustBridge.instance.reqLogin(base, user, password),
      );
      final token = decodeLoginToken(nativeBody, nativeResponse: true);
      return (token: token, usedSsh: prepared.usedSsh);
    }
  } finally {
    client.close();
  }
}

class EmptyApiResponseException implements Exception {
  const EmptyApiResponseException(this.operation, this.httpStatus);

  final String operation;
  final int? httpStatus;

  @override
  String toString() {
    final status = httpStatus == null ? '' : ' (HTTP $httpStatus)';
    return '$operation returned an empty response$status.';
  }
}

String decodeLoginToken(
  String body, {
  int? httpStatus,
  bool nativeResponse = false,
}) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) {
    throw EmptyApiResponseException('Login server', httpStatus);
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    final preview =
        trimmed.length > 160 ? '${trimmed.substring(0, 160)}...' : trimmed;
    final status = httpStatus == null ? '' : ' (HTTP $httpStatus)';
    throw 'Login server returned invalid JSON$status: $preview';
  }
  if (decoded is! Map) {
    throw 'Login server returned an unexpected response.';
  }

  if (nativeResponse) {
    final error = decoded['error']?.toString().trim() ?? '';
    if (error.isNotEmpty) throw error;
    final token = decoded['token']?.toString().trim() ?? '';
    if (decoded['ok'] == true && token.isNotEmpty) return token;
    throw 'Native login returned no token.';
  }

  if (httpStatus != null && (httpStatus < 200 || httpStatus >= 300)) {
    throw 'Login request failed with HTTP $httpStatus.';
  }
  if (decoded['code'] != '20000' && decoded['code'] != 20000) {
    throw decoded['msg']?.toString() ??
        decoded['message']?.toString() ??
        'Login failed.';
  }
  final data = decoded['data'];
  final token = data is Map ? data['token']?.toString().trim() ?? '' : '';
  if (token.isEmpty) throw 'Login returned no token.';
  return token;
}

Future<dynamic> _fetchLatestShotFromApi(
  String apiUrl,
  String token,
  String sshSettingsJson,
) async {
  final prepared = await _prepareApiUrl(apiUrl, sshSettingsJson);
  final base = prepared.url.replaceAll(RegExp(r'/$'), '');
  final client = HttpClient();
  try {
    client.connectionTimeout = const Duration(seconds: 10);
    final request = await client.postUrl(Uri.parse('$base/treeShot'));
    final payload = utf8.encode('{}');
    request.headers
      ..set('Content-Type', 'application/json; charset=utf-8')
      ..set('Authorization', 'Bearer $token')
      ..set('User-Agent', 'MdsScope/7.0');
    request.contentLength = payload.length;
    request.add(payload);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    try {
      return decodeLatestShotResponse(body, httpStatus: response.statusCode);
    } on EmptyApiResponseException {
      final nativeBody = await Isolate.run(
        () => RustBridge.instance.fetchS(base, token),
      );
      return decodeLatestShotResponse(nativeBody, nativeResponse: true);
    }
  } finally {
    client.close();
  }
}

dynamic decodeLatestShotResponse(
  String body, {
  int? httpStatus,
  bool nativeResponse = false,
}) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) {
    throw EmptyApiResponseException('Latest-shot server', httpStatus);
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException {
    final preview =
        trimmed.length > 160 ? '${trimmed.substring(0, 160)}...' : trimmed;
    final status = httpStatus == null ? '' : ' (HTTP $httpStatus)';
    throw 'Latest-shot server returned invalid JSON$status: $preview';
  }
  if (decoded is! Map) {
    throw 'Latest-shot server returned an unexpected response.';
  }

  if (nativeResponse) {
    final error = decoded['error']?.toString().trim() ?? '';
    if (error.isNotEmpty) throw error;
    if (decoded['shot'] == null) {
      throw 'Native latest-shot response has no shot.';
    }
    return decoded;
  }

  if (httpStatus != null && (httpStatus < 200 || httpStatus >= 300)) {
    throw 'Latest-shot request failed with HTTP $httpStatus.';
  }
  if (decoded['code'] != '20000' && decoded['code'] != 20000) {
    throw decoded['msg']?.toString() ??
        decoded['message']?.toString() ??
        'Latest-shot request failed.';
  }
  return decoded['data'];
}

class AppState extends ChangeNotifier {
  static const int defaultShotHistoryLimit = 50;
  static const int maximumShotHistoryLimit = 10000;

  final SignalFetchWorker _signalFetchWorker;
  final SshDisconnect _sshDisconnect;
  final ShotInfoFetchWorker _shotInfoFetchWorker;
  final LoginWorker _loginWorker;
  final LatestShotWorker _latestShotWorker;
  final ConfigOpenPicker _configOpenPicker;
  final ConfigSavePicker _configSavePicker;
  final ConfigParser _configParser;
  final ConfigEncoder _configEncoder;
  final SshTestWorker _sshTestWorker;
  bool _disposed = false;

  // Config
  List<List<Map<String, dynamic>>> _columns = [];
  List<List<Map<String, dynamic>>> get columns => _columns;

  // Plots
  final List<PlotData> _plots = [];
  List<PlotData> get plots => _plots;
  int selectedCol = -1, selectedRow = -1;
  void selectPanel(int col, int row) {
    if (selectedCol != col || selectedRow != row) {
      selectedCol = col;
      selectedRow = row;
      notifyListeners();
    }
  }

  void clearSelectedPanel() {
    if (selectedCol != -1 || selectedRow != -1) {
      selectedCol = -1;
      selectedRow = -1;
      notifyListeners();
    }
  }

  double? crosshairX;
  int? crosshairSourcePlot;
  int crosshairSourceSeries = 0;
  final List<({String name, double y})> crosshairReadout = [];

  void setCrosshair(double x, {int? sourcePlot, int sourceSeries = 0}) {
    crosshairX = x;
    if (sourcePlot != null) {
      crosshairSourcePlot = sourcePlot;
      crosshairSourceSeries = sourceSeries;
    }
    notifyListeners();
  }

  void clearCrosshair() {
    crosshairX = null;
    crosshairSourcePlot = null;
    crosshairSourceSeries = 0;
    crosshairReadout.clear();
    notifyListeners();
  }

  // Shot
  String _shotText = '';
  String get shotText => _shotText;
  String _displayedShot = '';
  String get displayedShot => _displayedShot;
  String? _pendingImportedShot;
  final _shotCtrl = TextEditingController();
  TextEditingController get shotCtrl => _shotCtrl;
  set shotText(String v) {
    _invalidateFetchForSettingsChange();
    _pendingImportedShot = null;
    _shotText = v;
    _shotCtrl.text = v;
    savePreferences();
    notifyListeners();
  }

  // Shot history
  final List<String> _shotHistory = [];
  List<String> get shotHistory => _shotHistory;
  bool _limitShotHistory = true;
  bool get limitShotHistory => _limitShotHistory;
  int _shotHistoryLimit = defaultShotHistoryLimit;
  int get shotHistoryLimit => _shotHistoryLimit;

  void _addToHistory(String shot) {
    if (shot.isEmpty) return;
    _shotHistory.remove(shot);
    _shotHistory.insert(0, shot);
    _trimShotHistory();
  }

  void _trimShotHistory() {
    if (!_limitShotHistory || _shotHistory.length <= _shotHistoryLimit) return;
    _shotHistory.removeRange(_shotHistoryLimit, _shotHistory.length);
  }

  void setShotHistoryRetentionEnabled(bool enabled) {
    if (_limitShotHistory == enabled) return;
    _limitShotHistory = enabled;
    _trimShotHistory();
    savePreferences();
    notifyListeners();
  }

  void setShotHistoryLimit(int value) {
    final normalized = value.clamp(1, maximumShotHistoryLimit);
    if (_shotHistoryLimit == normalized) return;
    _shotHistoryLimit = normalized;
    _trimShotHistory();
    savePreferences();
    notifyListeners();
  }

  void restoreDefaultShotHistoryLimit() {
    setShotHistoryLimit(defaultShotHistoryLimit);
  }

  Future<void> clearShotHistory() async {
    if (_shotHistory.isEmpty) return;
    _shotHistory.clear();
    notifyListeners();
    await savePreferences();
  }

  Future<void> removeShotHistory(Iterable<String> shots) async {
    final selected = shots.toSet();
    if (selected.isEmpty) return;
    final previousLength = _shotHistory.length;
    _shotHistory.removeWhere(selected.contains);
    if (_shotHistory.length == previousLength) return;
    notifyListeners();
    await savePreferences();
  }

  late final Future<void> preferencesReady;
  final UserDataStore _userDataStore;
  final CredentialStore _credentialStore;

  AppState({
    SignalFetchWorker? signalFetchWorker,
    SshDisconnect? sshDisconnect,
    ShotInfoFetchWorker? shotInfoFetchWorker,
    LoginWorker? loginWorker,
    LatestShotWorker? latestShotWorker,
    ConfigOpenPicker? configOpenPicker,
    ConfigSavePicker? configSavePicker,
    ConfigParser? configParser,
    ConfigEncoder? configEncoder,
    SshTestWorker? sshTestWorker,
    UserDataStore? userDataStore,
    CredentialStore? credentialStore,
  })  : _signalFetchWorker = signalFetchWorker ?? _fetchSignalsInBackground,
        _sshDisconnect =
            sshDisconnect ?? (() => RustBridge.instance.disconnectSsh()),
        _shotInfoFetchWorker =
            shotInfoFetchWorker ?? _fetchShotInfoInBackground,
        _loginWorker = loginWorker ?? _loginToApi,
        _latestShotWorker = latestShotWorker ?? _fetchLatestShotFromApi,
        _configOpenPicker = configOpenPicker ?? _pickConfigurationFile,
        _configSavePicker = configSavePicker ?? _saveConfigurationFile,
        _configParser = configParser ?? _parseConfiguration,
        _configEncoder = configEncoder ?? _encodeConfiguration,
        _sshTestWorker = sshTestWorker ?? _testSshInBackground,
        _userDataStore = userDataStore ?? UserDataStore(),
        _credentialStore = credentialStore ?? PlatformCredentialStore() {
    _shotCtrl.addListener(() {
      if (_shotCtrl.text != _shotText) {
        _invalidateFetchForSettingsChange();
        _pendingImportedShot = null;
        _shotText = _shotCtrl.text;
        savePreferences();
        notifyListeners();
      }
    });
    loadDefaultConfig();
    preferencesReady = initPreferences();
  }

  void setShotFromApi(String v) {
    _invalidateFetchForSettingsChange();
    _pendingImportedShot = null;
    _shotText = v;
    _shotCtrl.text = v;
    // Move cursor to end
    _shotCtrl.selection = TextSelection.collapsed(offset: v.length);
    savePreferences();
    notifyListeners();
  }

  String _shotInfoIp = '',
      _shotInfoPulse = '',
      _shotInfoIt = '',
      _shotInfoTime = '';
  String get shotInfoIp => _shotInfoIp;
  String get shotInfoPulse => _shotInfoPulse;
  String get shotInfoIt => _shotInfoIt;
  String get shotInfoTime => _shotInfoTime;

  // Mode
  int _dataMode = 0;
  int get dataMode => _dataMode;
  set dataMode(int v) {
    if (v == _dataMode) return;
    _invalidateFetchForSettingsChange();
    _dataMode = v;
    savePreferences();
    notifyListeners();
  }

  // Point mode: Esc locks crosshair in place; next click unlocks
  bool _pointLocked = false;
  bool get pointLocked => _pointLocked;
  set pointLocked(bool v) {
    _pointLocked = v;
    notifyListeners();
  }

  // Shift key state for Shift+drag pan
  bool shiftHeld = false;

  int _interactionMode = 0;
  int get interactionMode => _interactionMode;
  set interactionMode(int v) {
    _interactionMode = v;
    if (v != 1) {
      pointLocked = false;
      clearCrosshair();
    }
    savePreferences();
    notifyListeners();
  }

  // A normal stylus starts in write mode (pan). Platforms that expose a
  // write/erase toggle, such as Apple Pencil double-tap, update this transient
  // session state. An inverted stylus is still treated as an eraser directly
  // from its PointerDeviceKind.
  bool _stylusEraserMode = false;
  bool get stylusEraserMode => _stylusEraserMode;
  void setStylusEraserMode(bool enabled) {
    if (_stylusEraserMode == enabled) return;
    _stylusEraserMode = enabled;
    setStatus(
      enabled
          ? 'Stylus erase mode: drag a rubber-band to zoom.'
          : 'Stylus write mode: drag to pan.',
    );
  }

  // Theme
  int _themeMode = 2;
  int get themeMode => _themeMode;
  set themeMode(int v) {
    _themeMode = v;
    savePreferences();
    notifyListeners();
  }

  bool _toolbarCollapsed = false;
  bool get toolbarCollapsed => _toolbarCollapsed;
  set toolbarCollapsed(bool value) {
    if (value == _toolbarCollapsed) return;
    _toolbarCollapsed = value;
    savePreferences();
    notifyListeners();
  }

  // Font settings (Customize Fonts dialog)
  String _fontFamily = 'System';
  int _fontLegendSize = 11,
      _fontAxisSize = 8,
      _fontUnitSize = 9,
      _fontUiSize = 12;
  String get fontFamily => _fontFamily;
  String? get effectiveFontFamily =>
      _fontFamily == 'System' ? null : _fontFamily;
  int get fontLegendSize => _fontLegendSize;
  int get fontAxisSize => _fontAxisSize;
  int get fontUnitSize => _fontUnitSize;
  int get fontUiSize => _fontUiSize;
  void applyFontSettings(
      String family, int legend, int axis, int unit, int ui) {
    _fontFamily = family;
    _fontLegendSize = legend;
    _fontAxisSize = axis;
    _fontUnitSize = unit;
    _fontUiSize = ui;
    savePreferences();
    notifyListeners();
  }

  // Web bookmarks
  final List<Map<String, String>> _webBookmarks = [];
  List<Map<String, String>> get webBookmarks => _webBookmarks;
  void addWebBookmark(String alias, String url) {
    _webBookmarks.add({alias: url});
    savePreferences();
    notifyListeners();
  }

  Future<void> updateWebBookmark(int index, String alias, String url) async {
    if (index < 0 || index >= _webBookmarks.length) return;
    final normalizedAlias = alias.trim();
    final normalizedUrl = url.trim();
    if (normalizedAlias.isEmpty || normalizedUrl.isEmpty) return;
    _webBookmarks[index] = {normalizedAlias: normalizedUrl};
    notifyListeners();
    await savePreferences();
  }

  void removeWebBookmark(int i) {
    if (i >= 0 && i < _webBookmarks.length) {
      _webBookmarks.removeAt(i);
      savePreferences();
      notifyListeners();
    }
  }

  Future<void> removeWebBookmarks(Iterable<int> indexes) async {
    final valid = indexes
        .where((index) => index >= 0 && index < _webBookmarks.length)
        .toSet()
        .toList()
      ..sort((a, b) => b.compareTo(a));
    if (valid.isEmpty) return;
    for (final index in valid) {
      _webBookmarks.removeAt(index);
    }
    notifyListeners();
    await savePreferences();
  }

  // Layout
  void applyLayout(int cols, int rows) {
    applyLayoutList(List.filled(cols, rows));
  }

  void applyLayoutList(List<int> colSizes) {
    final newCols = <List<Map<String, dynamic>>>[];
    for (var c = 0; c < colSizes.length; c++) {
      final col = <Map<String, dynamic>>[];
      for (var r = 0; r < colSizes[c]; r++) {
        if (c < _columns.length && r < _columns[c].length) {
          col.add(_columns[c][r]);
        } else {
          col.add({
            'title': '',
            'x_label': 's',
            'y_label': 'a.u.',
            'grid': true,
            'signal_specs': []
          });
        }
      }
      newCols.add(col);
    }
    applyLayoutColumns(newCols);
  }

  void applyLayoutColumns(List<List<Map<String, dynamic>>> columns) {
    if (columns.isEmpty || columns.every((column) => column.isEmpty)) return;
    _invalidateFetchForSettingsChange();
    _columns = columns
        .where((column) => column.isNotEmpty)
        .map(
          (column) =>
              column.map((panel) => Map<String, dynamic>.from(panel)).toList(),
        )
        .toList();
    _rebuildPlotsFromColumns();
    savePreferences();
    notifyListeners();
  }

  void _rebuildPlotsFromColumns() {
    _plots.clear();
    for (final col in _columns) {
      for (final p in col) {
        final sc = (p['signal_specs'] as List?)?.length ?? 1;
        _plots.add(PlotData(
            title: p['title']?.toString() ?? '',
            xLabel: p['x_label']?.toString() ?? 's',
            yLabel: p['y_label']?.toString() ?? 'a.u.',
            series: List.filled(sc > 0 ? sc : 1, null, growable: true)));
      }
    }
  }

  // Auth
  bool _rememberLogin = true;
  bool get rememberLogin => _rememberLogin;
  set rememberLogin(bool v) {
    _sessionGeneration++;
    _rememberLogin = v;
    savePreferences();
    notifyListeners();
  }

  bool _loggedIn = false;
  bool get loggedIn => _loggedIn;
  String _authToken = '';
  String get authToken => _authToken;
  bool get hasActiveSession => _loggedIn && _authToken.trim().isNotEmpty;
  bool _explicitlyLoggedOut = false;
  String _loginApiUrl = 'http://202.127.204.26:80/api';
  String get loginApiUrl => _loginApiUrl;
  String _loginUser = '';
  String get loginUser => _loginUser;
  String _loginPass = '';
  String get loginPass => _loginPass;
  int _sessionGeneration = 0;
  final SourceIndexMemory sourceIndexMemory = SourceIndexMemory();

  // SSH
  String _sshHost = '';
  String get sshHost => _sshHost;
  int _sshMode = 1;
  int get sshMode => _sshMode;
  set sshMode(int v) {
    if (v == _sshMode) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshMode = v;
    _disconnectSshTunnels();
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  int _sshPort = 22;
  int get sshPort => _sshPort;
  String _sshUser = '';
  String get sshUser => _sshUser;
  String _sshPass = '';
  String get sshPass => _sshPass;
  String _sshIdentity = '';
  String get sshIdentity => _sshIdentity;
  bool _sshTunnelReachable = false;
  bool get sshTunnelReachable => _sshTunnelReachable;
  bool _sshInUse = false;
  bool get sshConnected => _sshTunnelReachable && _sshInUse;

  // View reset — incremented on each Refresh/Apply to reset zoom/pan
  int _viewResetId = 0;
  int get viewResetId => _viewResetId;
  int _rateViewResetId = 0;
  int get rateViewResetId => _rateViewResetId;
  void resetAllViews() {
    for (final plot in _plots) {
      plot.clearViewRange();
    }
    _viewResetId++;
    notifyListeners();
  }

  void rebuild() {
    _invalidateFetchForSettingsChange();
    savePreferences();
    notifyListeners();
  }

  // Shared scale (All Same X/Y Scale context menu)
  double? sharedXMin, sharedXMax, sharedYMin, sharedYMax;
  void applySharedXScale(double min, double max) {
    sharedXMin = min;
    sharedXMax = max;
    sharedYMin = null;
    sharedYMax = null;
    resetAllViews();
  }

  void applySharedYScale(double min, double max) {
    sharedYMin = min;
    sharedYMax = max;
    sharedXMin = null;
    sharedXMax = null;
    resetAllViews();
  }

  // Fetch
  bool _fetching = false;
  bool get fetching => _fetching;
  int? _fetchingPlotIndex;
  bool isPlotFetching(int plotIdx) =>
      _fetching &&
      (_fetchingPlotIndex == null || _fetchingPlotIndex == plotIdx);
  String _status = 'Ready';
  String get status => _status;
  int _fetchGeneration = 0;
  int? _activeNativeFetchId;
  Timer? _fullShotDebounceTimer;
  DateTime? _lastFullShotScheduleAt;
  int _rapidFullShotChanges = 0;
  int _networkPermissionFailureRevision = 0;
  int get networkPermissionFailureRevision => _networkPermissionFailureRevision;
  String _networkPermissionFailureDetails = '';
  String get networkPermissionFailureDetails =>
      _networkPermissionFailureDetails;
  Future<void> Function()? _lastNetworkRetry;
  bool get canRetryNetworkOperation => _lastNetworkRetry != null;

  void reportNetworkPermissionFailure(
    Object error, {
    Future<void> Function()? retry,
  }) {
    if (_disposed) return;
    if (!NetworkPermissionService.isLikelyPermissionFailure(error)) return;
    _networkPermissionFailureDetails = error.toString();
    _lastNetworkRetry = retry;
    _networkPermissionFailureRevision++;
    notifyListeners();
  }

  Future<void> retryLastNetworkOperation() async {
    final retry = _lastNetworkRetry;
    if (retry != null) await retry();
  }

  bool _isCurrentFetch(int generation) {
    return !_disposed && generation == _fetchGeneration;
  }

  void _invalidateFetchForSettingsChange() {
    _cancelPendingFullShotRefresh();
    _cancelActiveNativeFetch();
    _fetchGeneration++;
    _fetchingPlotIndex = null;
    if (_fetching) {
      _fetching = false;
      _status = 'Settings changed. Previous load discarded.';
    }
  }

  void _cancelActiveNativeFetch() {
    final requestId = _activeNativeFetchId;
    _activeNativeFetchId = null;
    if (requestId == null) return;
    try {
      RustBridge.instance.cancelFetch(requestId);
    } catch (_) {
      // The result-generation guard below still prevents stale data from
      // reaching the UI when a development build has an older native bridge.
    }
  }

  void _cancelPendingFullShotRefresh({bool resetCadence = false}) {
    _fullShotDebounceTimer?.cancel();
    _fullShotDebounceTimer = null;
    if (resetCadence) {
      _lastFullShotScheduleAt = null;
      _rapidFullShotChanges = 0;
    }
  }

  Duration _nextFullShotDebounceDelay() {
    final now = DateTime.now();
    final previous = _lastFullShotScheduleAt;
    final isRapid = previous != null &&
        now.difference(previous) <= const Duration(milliseconds: 450);
    _lastFullShotScheduleAt = now;
    if (!isRapid) {
      _rapidFullShotChanges = 0;
      return const Duration(milliseconds: 120);
    }
    if (_rapidFullShotChanges < 4) _rapidFullShotChanges++;
    final milliseconds = 220 + (_rapidFullShotChanges * 40);
    return Duration(milliseconds: milliseconds > 380 ? 380 : milliseconds);
  }

  void _scheduleFullShotFetch(String shot) {
    _cancelPendingFullShotRefresh();
    _cancelActiveNativeFetch();
    _fetchGeneration++;
    final delay = _nextFullShotDebounceDelay();
    _fetchingPlotIndex = null;
    _fetching = true;
    _status = 'Shot selected; loading in ${delay.inMilliseconds} ms...';
    notifyListeners();
    _fullShotDebounceTimer = Timer(delay, () {
      _fullShotDebounceTimer = null;
      if (_disposed) return;
      unawaited(_doFetch(shot: shot));
    });
  }

  // Max panel (null = show all)
  int? _maximizedPlot;
  int? get maximizedPlot => _maximizedPlot;
  void maximizePlot(int idx) {
    _maximizedPlot = idx;
    notifyListeners();
  }

  void showAllPanels() {
    _maximizedPlot = null;
    notifyListeners();
  }

  bool handleEscapeKey() {
    if (_maximizedPlot != null) {
      showAllPanels();
      return true;
    }
    if (_interactionMode == 1 && crosshairX != null) {
      pointLocked = true;
      return true;
    }
    return false;
  }

  // Dialogs
  bool _showLogin = false;
  bool get showLogin => _showLogin;
  bool _showSsh = false;
  bool get showSsh => _showSsh;

  void setLoginApiUrl(String v) {
    if (v == _loginApiUrl) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _loginApiUrl = v;
    savePreferences();
  }

  void setLoginUser(String v) {
    if (v == _loginUser) return;
    _sessionGeneration++;
    _loginUser = v;
    savePreferences();
  }

  void setLoginPass(String v) {
    if (v == _loginPass) return;
    _sessionGeneration++;
    _loginPass = v;
    savePreferences();
  }

  void setSshHost(String v) {
    if (v == _sshHost) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshHost = v;
    _disconnectSshTunnels();
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshPort(int v) {
    if (v == _sshPort) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshPort = v;
    _disconnectSshTunnels();
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshUser(String v) {
    if (v == _sshUser) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshUser = v;
    _disconnectSshTunnels();
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshPass(String v) {
    if (v == _sshPass) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshPass = v;
    _disconnectSshTunnels();
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshIdentity(String v) {
    if (v == _sshIdentity) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshIdentity = v;
    _disconnectSshTunnels();
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void openLogin() {
    _showLogin = true;
    notifyListeners();
  }

  void openSsh() {
    _showSsh = true;
    notifyListeners();
  }

  void setLoggedIn(bool v, String token) {
    if (v == _loggedIn && token == _authToken) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _loggedIn = v;
    _authToken = token;
    _explicitlyLoggedOut = !v;
    savePreferences();
    notifyListeners();
  }

  void logout() {
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _loggedIn = false;
    _authToken = '';
    _explicitlyLoggedOut = true;
    _disconnectSshTunnels();
    _resetSshConnectionState();
    savePreferences();
    setStatus('Logged out');
  }

  void setStatus(String s) {
    _status = s;
    notifyListeners();
  }

  void _resetSshConnectionState() {
    _sshTunnelReachable = false;
    _sshInUse = false;
  }

  void _disconnectSshTunnels() {
    try {
      _sshDisconnect();
    } catch (_) {
      // Fetch cancellation and the next settings snapshot still prevent an
      // obsolete tunnel from being selected by the application.
    }
  }

  void setSshTestResult(bool reachable) {
    _sshTunnelReachable = reachable;
    if (!reachable) _sshInUse = false;
    notifyListeners();
  }

  Future<String> testSshConnection(String settingsJson) {
    return _sshTestWorker(settingsJson);
  }

  void recordSshUsage(bool used) {
    _sshInUse = used;
    if (used) _sshTunnelReachable = true;
    notifyListeners();
  }

  Future<void> loginAndLoadLatest({
    required String apiUrl,
    required String user,
    required String password,
    bool automatic = false,
    NetworkAccessPreparation? preparedNetworkAccess,
  }) async {
    final generation = ++_sessionGeneration;
    var networkAccess =
        preparedNetworkAccess ?? NetworkAccessPreparation.unknown;
    _status = automatic ? 'Signing in automatically...' : 'Signing in...';
    notifyListeners();
    try {
      if (preparedNetworkAccess == null) {
        networkAccess =
            await NetworkPermissionService.prepareNetworkAccess(apiUrl);
      }
      if (_disposed || generation != _sessionGeneration) return;
      if (networkAccess == NetworkAccessPreparation.deniedDuringRequest ||
          networkAccess == NetworkAccessPreparation.deniedPreviously) {
        throw 'Cellular data access was denied for MdsScope.';
      }
      late ({String token, bool usedSsh}) result;
      if (_sshMode == 1 && _sshHost.trim().isNotEmpty) {
        try {
          result = await _loginWorker(apiUrl, user, password, '');
        } catch (directError) {
          if (_disposed || generation != _sessionGeneration) return;
          _status = automatic
              ? 'Direct automatic login failed; trying SSH tunnel...'
              : 'Direct login failed; trying SSH tunnel...';
          notifyListeners();
          try {
            result = await _loginWorker(
              apiUrl,
              user,
              password,
              _buildSshSettingsJson(forceTunnel: true),
            );
          } catch (sshError) {
            throw 'Direct login failed: $directError; '
                'SSH fallback failed: $sshError';
          }
        }
      } else {
        result = await _loginWorker(
          apiUrl,
          user,
          password,
          _buildSshSettingsJson(),
        );
      }
      if (_disposed || generation != _sessionGeneration) return;
      _loginApiUrl = apiUrl;
      _loginUser = user;
      _loginPass = password;
      _loggedIn = true;
      _authToken = result.token;
      _explicitlyLoggedOut = false;
      recordSshUsage(result.usedSsh);
      _status = 'Logged in as $user';
      await savePreferences();
      if (_disposed || generation != _sessionGeneration) return;
      notifyListeners();
      if (_pendingImportedShot != null) {
        await _loadPendingImportedConfiguration();
      } else if (!automatic && _shotText.trim().isNotEmpty) {
        final shot = _shotText.trim();
        _shotText = shot;
        _shotCtrl.text = shot;
        _synchronizeSignalRuntimeSettings(shot);
        _addToHistory(shot);
        await savePreferences();
        _viewResetId++;
        await _doFetch(shot: shot);
      } else {
        await fetchLatestShot();
      }
    } catch (error) {
      if (_disposed || generation != _sessionGeneration) return;
      _loggedIn = false;
      _authToken = '';
      _status =
          automatic ? 'Automatic login failed: $error' : 'Login failed: $error';
      await savePreferences();
      if (!_disposed) notifyListeners();
      final shouldOfferSettings =
          networkAccess == NetworkAccessPreparation.deniedPreviously ||
              NetworkPermissionService.isConfirmedPermissionFailure(error);
      if (shouldOfferSettings &&
          networkAccess != NetworkAccessPreparation.deniedDuringRequest) {
        reportNetworkPermissionFailure(
          error,
          retry: () => loginAndLoadLatest(
            apiUrl: apiUrl,
            user: user,
            password: password,
            automatic: automatic,
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> initializeStartupSession({
    NetworkAccessPreparation? preparedNetworkAccess,
  }) async {
    await preferencesReady;
    if (_disposed || !_rememberLogin || _explicitlyLoggedOut) return;
    if (_loginUser.trim().isNotEmpty) {
      try {
        await loginAndLoadLatest(
          apiUrl: _loginApiUrl,
          user: _loginUser,
          password: _loginPass,
          automatic: true,
          preparedNetworkAccess: preparedNetworkAccess,
        );
      } catch (_) {}
      return;
    }
    if (_loggedIn && _authToken.isNotEmpty) {
      _status = 'Restoring saved session...';
      notifyListeners();
      await fetchLatestShot();
    }
  }

  Future<void> initPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final fileSettings = await _userDataStore.readSettings();
      final migrateLegacySettings =
          fileSettings != null && fileSettings.isEmpty;
      dynamic setting(String key) {
        if (fileSettings != null && fileSettings.containsKey(key)) {
          return fileSettings[key];
        }
        return prefs.get(key);
      }

      _invalidateFetchForSettingsChange();
      _rememberLogin = setting('rememberLogin') is bool
          ? setting('rememberLogin') as bool
          : true;
      _explicitlyLoggedOut = setting('explicitlyLoggedOut') is bool
          ? setting('explicitlyLoggedOut') as bool
          : _explicitlyLoggedOut;
      _loginApiUrl = setting('loginApiUrl')?.toString() ?? _loginApiUrl;
      _loginUser = setting('loginUser')?.toString() ?? _loginUser;
      if (_rememberLogin) {
        _loginPass = await _readCredentialWithPlaintextMigration(
              prefs,
              secureKey: _loginPasswordCredential,
              plaintextKey: 'loginPass',
            ) ??
            _loginPass;
        _authToken = await _readCredentialWithPlaintextMigration(
              prefs,
              secureKey: _authTokenCredential,
              plaintextKey: 'authToken',
            ) ??
            _authToken;
      }
      _loggedIn =
          setting('loggedIn') is bool ? setting('loggedIn') as bool : _loggedIn;
      if (_authToken.isEmpty) _loggedIn = false;
      _sshHost = setting('sshHost')?.toString() ?? _sshHost;
      _sshPort = setting('sshPort') is num
          ? (setting('sshPort') as num).toInt()
          : _sshPort;
      _sshUser = setting('sshUser')?.toString() ?? _sshUser;
      _sshPass = await _readCredentialWithPlaintextMigration(
            prefs,
            secureKey: _sshPasswordCredential,
            plaintextKey: 'sshPass',
          ) ??
          _sshPass;
      _sshIdentity = setting('sshIdentity')?.toString() ?? _sshIdentity;
      _sshMode = setting('sshMode') is num
          ? (setting('sshMode') as num).toInt()
          : _sshMode;
      _dataMode = (setting('dataMode') is num
              ? (setting('dataMode') as num).toInt()
              : _dataMode)
          .clamp(0, 2);
      _interactionMode = (setting('interactionMode') is num
              ? (setting('interactionMode') as num).toInt()
              : _interactionMode)
          .clamp(0, 1);
      _themeMode = (setting('themeMode') is num
              ? (setting('themeMode') as num).toInt()
              : _themeMode)
          .clamp(0, 2);
      _toolbarCollapsed = setting('toolbarCollapsed') is bool
          ? setting('toolbarCollapsed') as bool
          : _toolbarCollapsed;
      _fontFamily = setting('fontFamily')?.toString() ?? _fontFamily;
      _fontLegendSize = setting('fontLegendSize') is num
          ? (setting('fontLegendSize') as num).toInt()
          : _fontLegendSize;
      _fontAxisSize = setting('fontAxisSize') is num
          ? (setting('fontAxisSize') as num).toInt()
          : _fontAxisSize;
      _fontUnitSize = setting('fontUnitSize') is num
          ? (setting('fontUnitSize') as num).toInt()
          : _fontUnitSize;
      _fontUiSize = setting('fontUiSize') is num
          ? (setting('fontUiSize') as num).toInt()
          : _fontUiSize;
      _limitShotHistory = setting('limitShotHistory') is bool
          ? setting('limitShotHistory') as bool
          : _limitShotHistory;
      _shotHistoryLimit = (setting('shotHistoryLimit') is num
              ? (setting('shotHistoryLimit') as num).toInt()
              : defaultShotHistoryLimit)
          .clamp(1, maximumShotHistoryLimit);

      final bookmarksJson = setting('webBookmarks')?.toString();
      if (bookmarksJson != null) {
        final list = jsonDecode(bookmarksJson);
        if (list is List) {
          _webBookmarks.clear();
          for (final item in list) {
            if (item is Map) _webBookmarks.add(Map<String, String>.from(item));
          }
        }
      }

      final shotHistoryJson = setting('shotHistory')?.toString();
      if (shotHistoryJson != null) {
        final list = jsonDecode(shotHistoryJson);
        if (list is List) {
          _shotHistory
            ..clear()
            ..addAll(list.map((item) => item.toString()).where(
                  (item) => item.isNotEmpty,
                ));
          _trimShotHistory();
        }
      }

      final sourceIndexJson = setting('sourceIndexMemory')?.toString();
      if (sourceIndexJson != null && sourceIndexJson.isNotEmpty) {
        sourceIndexMemory.restore(jsonDecode(sourceIndexJson));
      }

      final lastConfig = setting('lastConfigJson')?.toString();
      if (lastConfig != null && lastConfig.isNotEmpty) {
        _applyConfigJsonString(lastConfig);
      }
      notifyListeners();
      if (migrateLegacySettings && _filePreferenceKeys.any(prefs.containsKey)) {
        await savePreferences();
      }
      await _removePlaintextCredentials(prefs);
    } catch (_) {}
  }

  Future<void> savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_rememberLogin) {
        await _writeOrDeleteCredential(
          _loginPasswordCredential,
          _loginPass,
        );
        await _writeOrDeleteCredential(_authTokenCredential, _authToken);
      } else {
        await _writeOrDeleteCredential(_loginPasswordCredential, '');
        await _writeOrDeleteCredential(_authTokenCredential, '');
      }
      await _writeOrDeleteCredential(_sshPasswordCredential, _sshPass);
      await _removePlaintextCredentials(prefs);

      final configJson = jsonEncode({
        'columns': _jsonSafeValue(_columns),
        'shot': _shotText,
      });
      final fileSettings = <String, dynamic>{
        'rememberLogin': _rememberLogin,
        'explicitlyLoggedOut': _explicitlyLoggedOut,
        'loggedIn': _rememberLogin && _loggedIn,
        'loginApiUrl': _loginApiUrl,
        'loginUser': _loginUser,
        'sshHost': _sshHost,
        'sshPort': _sshPort,
        'sshUser': _sshUser,
        'sshIdentity': _sshIdentity,
        'sshMode': _sshMode,
        'dataMode': _dataMode,
        'interactionMode': _interactionMode,
        'themeMode': _themeMode,
        'toolbarCollapsed': _toolbarCollapsed,
        'fontFamily': _fontFamily,
        'fontLegendSize': _fontLegendSize,
        'fontAxisSize': _fontAxisSize,
        'fontUnitSize': _fontUnitSize,
        'fontUiSize': _fontUiSize,
        'limitShotHistory': _limitShotHistory,
        'shotHistoryLimit': _shotHistoryLimit,
        'webBookmarks': jsonEncode(_webBookmarks),
        'shotHistory': jsonEncode(_shotHistory),
        'sourceIndexMemory': jsonEncode(sourceIndexMemory.toJson()),
        'lastConfigJson': configJson,
      };
      final storedInPrivateDirectory =
          await _userDataStore.writeSettings(fileSettings);
      if (storedInPrivateDirectory) {
        for (final key in _filePreferenceKeys) {
          await prefs.remove(key);
        }
      }
    } catch (_) {}
  }

  Future<String?> _readCredentialWithPlaintextMigration(
    SharedPreferences prefs, {
    required String secureKey,
    required String plaintextKey,
  }) async {
    String? secureValue;
    try {
      secureValue = await _credentialStore.read(secureKey);
    } catch (_) {}
    final plaintextValue = prefs.getString(plaintextKey);
    if (secureValue != null) return secureValue;
    if (plaintextValue == null) return null;
    try {
      await _credentialStore.write(secureKey, plaintextValue);
    } catch (_) {
      // Keep the value only for this process. It must not remain persisted in
      // an insecure store when the platform vault is unavailable.
    }
    return plaintextValue;
  }

  Future<void> _writeOrDeleteCredential(String key, String value) async {
    try {
      if (value.isEmpty) {
        await _credentialStore.delete(key);
      } else {
        await _credentialStore.write(key, value);
      }
    } catch (_) {
      // Platforms without an available secure vault deliberately do not fall
      // back to plaintext persistence.
    }
  }

  Future<void> _removePlaintextCredentials(SharedPreferences prefs) async {
    for (final key in _plaintextCredentialKeys) {
      await prefs.remove(key);
    }
  }

  dynamic _jsonSafeValue(dynamic value) {
    if (value is double && !value.isFinite) return null;
    if (value is List) return value.map(_jsonSafeValue).toList();
    if (value is Map) {
      return value.map(
        (key, item) => MapEntry(key.toString(), _jsonSafeValue(item)),
      );
    }
    return value;
  }

  void _normalizePanelDefaults(Map<String, dynamic> panel) {
    final rawPoints = panel['extraction_points'];
    final points = rawPoints is num
        ? rawPoints.toInt()
        : int.tryParse(rawPoints?.toString() ?? '');
    panel['extraction_points'] = points != null && points >= 2 ? points : 2000;
    panel['grid'] ??= true;
    final signals = panel['signal_specs'];
    if (signals is List) {
      panel['signal_specs'] = <Map<String, dynamic>>[
        for (final rawSignal in signals)
          if (rawSignal is Map)
            () {
              final signal = Map<String, dynamic>.from(rawSignal);
              normalizeSignalHideSettings(signal);
              return signal;
            }(),
      ];
    }
  }

  String _configurationInitialShot(
    Map<dynamic, dynamic> json,
    List<List<Map<String, dynamic>>> columns,
  ) {
    for (final key in const ['shot', 'default_shot', 'global_shot']) {
      final value = json[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    for (final column in columns) {
      for (final panel in column) {
        final panelShot = panel['shot']?.toString().trim() ?? '';
        if (panelShot.isNotEmpty) return panelShot;
        final signals = panel['signal_specs'];
        if (signals is! List) continue;
        for (final rawSignal in signals) {
          if (rawSignal is! Map) continue;
          final signalShot = rawSignal['shot']?.toString().trim() ?? '';
          if (signalShot.isNotEmpty) return signalShot;
        }
      }
    }
    return '';
  }

  void _makeConfigurationShotInheritable(
    List<List<Map<String, dynamic>>> columns,
    String initialShot,
  ) {
    if (initialShot.isEmpty) return;
    for (final column in columns) {
      for (final panel in column) {
        if (panel['shot']?.toString().trim() == initialShot) {
          panel.remove('shot');
        }
        final signals = panel['signal_specs'];
        if (signals is! List) continue;
        for (final rawSignal in signals) {
          if (rawSignal is Map &&
              rawSignal['shot']?.toString().trim() == initialShot) {
            rawSignal.remove('shot');
          }
        }
      }
    }
  }

  void _removeConfigurationShots(
    List<List<Map<String, dynamic>>> columns,
  ) {
    for (final column in columns) {
      for (final panel in column) {
        panel.remove('shot');
        final signals = panel['signal_specs'];
        if (signals is! List) continue;
        for (final rawSignal in signals) {
          if (rawSignal is Map) rawSignal.remove('shot');
        }
      }
    }
  }

  List<Map<String, dynamic>> _configurationSignalsFor(
    Map<String, dynamic> panel,
  ) {
    final panelShot = panel['shot']?.toString().trim() ?? '';
    final inheritedShot = panelShot.isNotEmpty ? panelShot : _shotText.trim();
    final rawSignals = panel['signal_specs'];
    if (rawSignals is! List) return [];

    return [
      for (var index = 0; index < rawSignals.length; index++)
        if (rawSignals[index] is Map)
          () {
            final signal = Map<String, dynamic>.from(rawSignals[index] as Map);
            final shot = signal['shot']?.toString().trim() ?? '';
            final color = signal['color_name']?.toString().trim() ?? '';
            final rawMode = signal['read_mode'];
            final parsedMode = rawMode is num
                ? rawMode.toInt()
                : int.tryParse(rawMode?.toString() ?? '');
            final mode =
                parsedMode != null && parsedMode >= 0 && parsedMode <= 2
                    ? parsedMode
                    : _dataMode;
            final hideMode = signalHideModeOf(signal);
            return <String, dynamic>{
              ...signal,
              'shot': shot.isNotEmpty ? shot : inheritedShot,
              'y_expr': signal['y_expr']?.toString() ?? '',
              'x_expr': signal['x_expr']?.toString() ?? '',
              'legend': signal['legend']?.toString() ?? '',
              'experiment': signal['experiment']?.toString() ?? '',
              'server_ip': signal['server_ip']?.toString() ?? '',
              'color_name': color.isNotEmpty
                  ? color
                  : _configurationSignalColors[
                      index % _configurationSignalColors.length],
              'manual_color': signal['manual_color'] == true ||
                  (color.isNotEmpty && signal['manual_color'] != false),
              'hide_mode': hideMode,
              'hidden': hideMode != signalHideModeVisible,
              'read_mode': mode,
            };
          }(),
    ];
  }

  void _applyConfigJsonString(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['columns'] is! List) return;
      final cols = (json['columns'] as List).map((col) {
        return (col as List).map((panel) {
          final m = Map<String, dynamic>.from(panel as Map);
          _normalizePanelDefaults(m);
          return m;
        }).toList();
      }).toList();
      if (cols.isEmpty || cols.every((c) => c.isEmpty)) return;
      final initialShot = _configurationInitialShot(json, cols);
      _makeConfigurationShotInheritable(cols, initialShot);
      _columns = cols;
      _plots.clear();
      for (final col in _columns) {
        for (final panel in col) {
          final sigCount = (panel['signal_specs'] as List?)?.length ?? 1;
          _plots.add(PlotData(
            title: panel['title']?.toString() ?? '',
            xLabel: panel['x_label']?.toString() ?? 's',
            yLabel: panel['y_label']?.toString() ?? 'a.u.',
            series:
                List.filled(sigCount > 0 ? sigCount : 1, null, growable: true),
          ));
        }
      }
      if (initialShot.isNotEmpty) {
        _shotText = initialShot;
        _shotCtrl.text = initialShot;
      }
    } catch (_) {}
  }

  void loadDefaultConfig() {
    // Match the original MdsScope init.toml — 2 columns × 3 rows
    final panels = [
      // Column 1
      ('Ip', r'\pcrl01'), ('R', r'\lmsr'), ('Z', r'\lmsz'),
      // Column 2
      ('Vloop', r'\pcvloop'), ('Ne', r'\dfsdev'), ('Pf1 current', r'\pcpf1'),
    ];
    _columns = [[], []];
    _plots.clear();
    for (var i = 0; i < 6; i++) {
      final col = i < 3 ? 0 : 1;
      final (title, y) = panels[i];
      _columns[col].add({
        'title': title,
        'x_label': 's',
        'y_label': 'a.u.',
        'extraction_points': 2000,
        'grid': true,
        'signal_specs': [
          {'y_expr': y, 'experiment': 'pcs_east', 'server_ip': '202.127.204.12'}
        ],
      });
    }
    for (final col in _columns) {
      for (final panel in col) {
        _plots.add(PlotData(
            title: panel['title']?.toString() ?? '',
            xLabel: 's',
            yLabel: 'a.u.',
            series: List.filled(1, null, growable: true)));
      }
    }
    _status = 'Default config loaded. Login + Refresh to fetch data.';
    notifyListeners();
  }

  Future<void> restoreDefaultConfig() async {
    _invalidateFetchForSettingsChange();
    _pendingImportedShot = null;
    selectedCol = -1;
    selectedRow = -1;
    _maximizedPlot = null;
    crosshairX = null;
    crosshairSourcePlot = null;
    crosshairSourceSeries = 0;
    crosshairReadout.clear();
    _pointLocked = false;
    _viewResetId++;
    loadDefaultConfig();
    await savePreferences();

    final shot = _displayedShot.trim().isNotEmpty
        ? _displayedShot.trim()
        : _shotText.trim();
    if (hasActiveSession && shot.isNotEmpty) {
      refreshDisplayedShot();
    }
  }

  Future<void> openFile({
    ImportedShotDecision? importedShotDecision,
    ConfigOpenSelection? selectionOverride,
  }) async {
    Directory? temporaryDirectory;
    try {
      _status = 'Choose a .toml or .webscp configuration file...';
      notifyListeners();
      final selection = selectionOverride ?? await _configOpenPicker();
      if (selection == null) {
        _status = 'Open cancelled';
        notifyListeners();
        return;
      }

      var path = selection.path;
      if ((path == null || path.isEmpty) && selection.bytes != null) {
        temporaryDirectory =
            await Directory.systemTemp.createTemp('mdsscope-open-');
        final safeName = selection.name.replaceAll(
          RegExp(r'[^A-Za-z0-9._-]'),
          '_',
        );
        path = '${temporaryDirectory.path}${Platform.pathSeparator}'
            '${safeName.isEmpty ? "config.toml" : safeName}';
        await File(path).writeAsBytes(selection.bytes!, flush: true);
      }
      if (path == null || path.isEmpty) {
        throw 'The selected file did not provide a readable path or bytes.';
      }
      if (isLegacyMdsScopeConfigurationPath(path)) {
        throw 'Configurations in ~/.config/mdsscope belong to the legacy '
            'application and are intentionally not imported. Use a copy '
            'outside that directory instead.';
      }

      _status = 'Opening ${selection.name}...';
      notifyListeners();
      final raw = _configParser(path);
      if (raw.isEmpty) {
        _status = 'Empty result from parser';
        notifyListeners();
        return;
      }
      final json = jsonDecode(raw);
      if (json is! Map || json['columns'] is! List) {
        _status = 'Invalid config format';
        notifyListeners();
        return;
      }
      final cols = (json['columns'] as List).map((col) {
        return (col as List).map((panel) {
          final m = Map<String, dynamic>.from(panel as Map);
          _normalizePanelDefaults(m);
          return m;
        }).toList();
      }).toList();
      if (cols.isEmpty || cols.every((c) => c.isEmpty)) {
        _status = 'No panels found in config';
        notifyListeners();
        return;
      }
      _invalidateFetchForSettingsChange();
      final fileShot = _configurationInitialShot(json, cols);
      final useFileShot = fileShot.isNotEmpty &&
          (await importedShotDecision?.call(fileShot) ?? false);
      if (useFileShot) {
        _makeConfigurationShotInheritable(cols, fileShot);
        _shotText = fileShot;
        _shotCtrl.text = _shotText;
      } else {
        _removeConfigurationShots(cols);
      }
      _columns = cols;
      _plots.clear();
      _displayedShot = '';
      for (final col in _columns) {
        for (final panel in col) {
          final sigCount = (panel['signal_specs'] as List?)?.length ?? 1;
          _plots.add(PlotData(
            title: panel['title']?.toString() ?? '',
            xLabel: panel['x_label']?.toString() ?? 's',
            yLabel: panel['y_label']?.toString() ?? 'a.u.',
            series:
                List.filled(sigCount > 0 ? sigCount : 1, null, growable: true),
          ));
        }
      }
      _status =
          'Loaded: ${selection.name} (${_columns.length} cols, ${_plots.length} panels)';
      _pendingImportedShot = _shotText.trim().isEmpty ? null : _shotText.trim();
      await savePreferences();
      notifyListeners();
      if (_pendingImportedShot != null) {
        if (hasActiveSession) {
          await _loadPendingImportedConfiguration();
        } else {
          _status =
              'Loaded: ${selection.name} (${_columns.length} cols, ${_plots.length} panels). '
              'Sign in to load shot $_pendingImportedShot.';
          notifyListeners();
        }
      }
    } catch (e) {
      _status = 'Open error: $e';
      notifyListeners();
    } finally {
      if (temporaryDirectory != null) {
        try {
          await temporaryDirectory.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<void> openConfigurationPath(String path) {
    final normalizedPath = path.trim();
    if (normalizedPath.isEmpty) return Future<void>.value();
    return openFile(
      selectionOverride: ConfigOpenSelection(
        name: File(normalizedPath).uri.pathSegments.last,
        path: normalizedPath,
      ),
    );
  }

  Future<void> saveFile() async {
    try {
      _status = 'Preparing configuration...';
      notifyListeners();
      final cols = _columns
          .map((col) => col.map((panel) {
                final m = Map<String, dynamic>.from(panel);
                m['signal_specs'] = _configurationSignalsFor(m);
                m.remove('shot');
                _normalizePanelDefaults(m);
                if (m['custom_x_range'] != true) {
                  m
                    ..remove('xmin')
                    ..remove('xmax');
                }
                if (m['custom_y_range'] != true) {
                  m
                    ..remove('ymin')
                    ..remove('ymax');
                }
                return m;
              }).toList())
          .toList();
      final configJson = jsonEncode(_jsonSafeValue({
        'shot': _shotText.trim(),
        'columns': cols,
      }));
      final bytes = await _configEncoder(configJson);
      _status = 'Choose where to save the configuration...';
      notifyListeners();
      final destination = await _configSavePicker('config.toml', bytes);
      if (destination == null || destination.trim().isEmpty) {
        _status = 'Save cancelled';
        notifyListeners();
        return;
      }
      _status = 'Saved to ${_displayFileName(destination)}';
      notifyListeners();
    } catch (e) {
      _status = 'Save error: $e';
      notifyListeners();
    }
  }

  String _displayFileName(String value) {
    final decoded = Uri.decodeComponent(value);
    final parts = decoded.split(RegExp(r'[/\\]'));
    for (var index = parts.length - 1; index >= 0; index--) {
      if (parts[index].isNotEmpty) return parts[index];
    }
    return value;
  }

  void _synchronizeSignalRuntimeSettings(
    String shot, {
    bool resetTemporaryHides = true,
  }) {
    for (final col in _columns) {
      for (final p in col) {
        final sigs = p['signal_specs'] as List?;
        if (sigs != null) {
          p['signal_specs'] = <Map<String, dynamic>>[
            for (final rawSignal in sigs)
              if (rawSignal is Map)
                () {
                  final signal = Map<String, dynamic>.from(rawSignal);
                  var hideMode = signalHideModeOf(signal);
                  if (resetTemporaryHides &&
                      hideMode == signalHideModeTemporary) {
                    hideMode = signalHideModeVisible;
                  }
                  signal['shot'] = shot;
                  signal['read_mode'] = _dataMode;
                  signal['hide_mode'] = hideMode;
                  signal['hidden'] = hideMode != signalHideModeVisible;
                  return signal;
                }(),
          ];
        }
      }
    }
  }

  bool _requireActiveSession(String action) {
    if (hasActiveSession) return true;
    _fetchGeneration++;
    _fetching = false;
    _fetchingPlotIndex = null;
    _status = 'Login required to $action.';
    notifyListeners();
    return false;
  }

  void startRefresh() {
    _pendingImportedShot = null;
    if (!_requireActiveSession('load a shot')) return;
    if (_columns.isEmpty) return;
    if (_shotCtrl.text.trim().isNotEmpty) {
      _shotText = _shotCtrl.text.trim();
    }
    _synchronizeSignalRuntimeSettings(_shotText);
    _addToHistory(_shotText);
    savePreferences();
    _viewResetId++;
    if (_dataMode == 2) {
      _scheduleFullShotFetch(_shotText);
    } else {
      _doFetch(shot: _shotText);
    }
  }

  Future<void> _loadPendingImportedConfiguration() async {
    final shot = _pendingImportedShot;
    if (shot == null || shot.isEmpty) return;
    if (!_requireActiveSession('load the imported configuration')) return;
    if (_columns.isEmpty) return;
    _shotText = shot;
    _shotCtrl.text = shot;
    _synchronizeSignalRuntimeSettings(shot);
    _addToHistory(shot);
    await savePreferences();
    _viewResetId++;
    await _doFetch(shot: shot);
    if (_displayedShot == shot &&
        _plots.any((plot) => plot.series.any(
              (series) => series?.points != null && series!.points!.isNotEmpty,
            ))) {
      _pendingImportedShot = null;
    }
  }

  void refreshDisplayedShot() {
    if (!_requireActiveSession('refresh waveforms')) return;
    if (_columns.isEmpty) return;
    final shot = _displayedShot.trim().isNotEmpty
        ? _displayedShot.trim()
        : _shotText.trim();
    if (shot.isEmpty) return;
    _synchronizeSignalRuntimeSettings(shot);
    _addToHistory(shot);
    savePreferences();
    _viewResetId++;
    _doFetch(shot: shot);
  }

  void startRefreshPreserveView() {
    _pendingImportedShot = null;
    if (!_requireActiveSession('load a shot')) return;
    if (_columns.isEmpty) return;
    if (_shotCtrl.text.trim().isNotEmpty) {
      _shotText = _shotCtrl.text.trim();
    }
    _synchronizeSignalRuntimeSettings(_shotText);
    _addToHistory(_shotText);
    savePreferences();
    _doFetch(shot: _shotText);
  }

  void startRateRefresh() {
    _pendingImportedShot = null;
    if (!_requireActiveSession('change waveform rate')) return;
    if (_columns.isEmpty) return;
    if (_shotCtrl.text.trim().isNotEmpty) {
      _shotText = _shotCtrl.text.trim();
    }
    _synchronizeSignalRuntimeSettings(_shotText);
    _addToHistory(_shotText);
    for (final plot in _plots) {
      plot.viewMinY = null;
      plot.viewMaxY = null;
    }
    _rateViewResetId++;
    savePreferences();
    _doFetch(shot: _shotText);
  }

  String _buildSignalConfigJson(String shot, int requestId) {
    final cols = _columns
        .map((col) => col.map((p) {
              final panel = Map<String, dynamic>.from(p);
              panel['shot'] = shot;
              final signals = p['signal_specs'];
              if (signals is List) {
                panel['signal_specs'] = [
                  for (final rawSignal in signals)
                    if (rawSignal is Map)
                      () {
                        final signal = Map<String, dynamic>.from(rawSignal);
                        final hideMode = signalHideModeOf(signal);
                        signal['shot'] = shot;
                        signal['read_mode'] = _dataMode;
                        signal['hide_mode'] = hideMode;
                        signal['hidden'] = hideMode != signalHideModeVisible;
                        return signal;
                      }(),
                ];
              }
              _normalizePanelDefaults(panel);
              return panel;
            }).toList())
        .toList();
    return jsonEncode({'request_id': requestId, 'columns': cols});
  }

  String _buildSinglePanelSignalConfigJson(
    String shot,
    int targetCol,
    int targetRow,
    int requestId,
  ) {
    final cols = <List<Map<String, dynamic>>>[];
    for (var col = 0; col < _columns.length; col++) {
      final panels = <Map<String, dynamic>>[];
      for (var row = 0; row < _columns[col].length; row++) {
        final panel = Map<String, dynamic>.from(_columns[col][row]);
        panel['shot'] = shot;
        _normalizePanelDefaults(panel);
        if (col != targetCol || row != targetRow) {
          panel['signal_specs'] = <Map<String, dynamic>>[];
        }
        panels.add(panel);
      }
      cols.add(panels);
    }
    return jsonEncode({'request_id': requestId, 'columns': cols});
  }

  void _clearAllSeriesPoints() {
    for (final plot in _plots) {
      for (final series in plot.series) {
        if (series != null) {
          series.points = null;
          series.error = null;
        }
      }
    }
  }

  void _markUnresolvedSeries(String message) {
    for (final plot in _plots) {
      for (var index = 0; index < plot.series.length; index++) {
        final series = plot.series[index];
        if (series == null) {
          plot.series[index] = SeriesData(error: message);
        } else if ((series.points == null || series.points!.isEmpty) &&
            (series.error == null || series.error!.isEmpty)) {
          series.error = message;
        }
      }
    }
  }

  ({
    List<List<double>>? points,
    String? error,
    String unit,
    String xName,
    String xUnit,
  }) _decodeLoadedSeries(dynamic rawSeries) {
    if (rawSeries is! Map) {
      return (
        points: null,
        error: 'The server returned an invalid signal payload.',
        unit: '',
        xName: '',
        xUnit: '',
      );
    }
    final rawError = rawSeries['error']?.toString().trim() ?? '';
    final unit = rawSeries['unit']?.toString().trim() ?? '';
    final xName = rawSeries['x_name']?.toString().trim() ?? '';
    final xUnit = rawSeries['x_unit']?.toString().trim() ?? '';
    final rawPoints = rawSeries['points'];
    final rawUniform = rawSeries['uniform_y'];
    if (rawPoints == null) {
      return (
        points: null,
        error: rawError.isEmpty ? null : rawError,
        unit: unit,
        xName: xName,
        xUnit: xUnit,
      );
    }
    if (rawPoints is! List) {
      return (
        points: null,
        error: rawError.isEmpty
            ? 'The server returned an invalid point list.'
            : rawError,
        unit: unit,
        xName: xName,
        xUnit: xUnit,
      );
    }

    final points = <List<double>>[];
    for (final rawPoint in rawPoints) {
      if (rawPoint is! List || rawPoint.length < 2) continue;
      final rawX = rawPoint[0];
      final rawY = rawPoint[1];
      if (rawX is! num || rawY is! num) continue;
      final x = rawX.toDouble();
      final y = rawY.toDouble();
      if (!x.isFinite || !y.isFinite) continue;
      points.add([x, y]);
    }
    if (points.isEmpty && rawUniform is List) {
      final rawStart = rawSeries['uniform_start'];
      final rawStep = rawSeries['uniform_step'];
      if (rawStart is num && rawStep is num) {
        final start = rawStart.toDouble();
        final step = rawStep.toDouble();
        if (start.isFinite && step.isFinite && step != 0) {
          for (var index = 0; index < rawUniform.length; index++) {
            final rawY = rawUniform[index];
            if (rawY is! num) continue;
            final x = start + index * step;
            final y = rawY.toDouble();
            if (x.isFinite && y.isFinite) points.add([x, y]);
          }
        }
      }
    }

    String? error = rawError.isEmpty ? null : rawError;
    if (points.isEmpty && error == null) {
      error = rawPoints.isEmpty && (rawUniform is! List || rawUniform.isEmpty)
          ? 'The signal returned no samples for this tree and shot.'
          : 'The signal returned no finite numeric samples for this tree and shot.';
    }
    return (
      points: points,
      error: error,
      unit: unit,
      xName: xName,
      xUnit: xUnit,
    );
  }

  int? _decodeSignalIndex(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  void _clearPanelSeries(int plotIdx) {
    if (plotIdx < 0 || plotIdx >= _plots.length) return;
    for (final series in _plots[plotIdx].series) {
      if (series != null) {
        series.points = null;
        series.error = null;
      }
    }
  }

  String _buildSshSettingsJson({bool forceTunnel = false}) {
    if (_sshMode <= 0 || _sshHost.isEmpty) return '';
    return jsonEncode({
      'host': _sshHost,
      'port': _sshPort,
      'user': _sshUser,
      'password': _sshPass,
      'identity_file': _sshIdentity,
      'mode': forceTunnel || (_sshMode == 1 && _sshInUse) ? 2 : _sshMode,
    });
  }

  Future<void> _doFetch({required String shot}) async {
    if (!_requireActiveSession('load waveforms')) return;
    _cancelActiveNativeFetch();
    final generation = ++_fetchGeneration;
    final requestShot = shot;
    final configJson = _buildSignalConfigJson(requestShot, generation);
    final dataMode = _dataMode.toString();
    final sshSettings = _buildSshSettingsJson();
    _fetchingPlotIndex = null;
    _fetching = true;
    _activeNativeFetchId = generation;
    _status = 'Fetching...';
    notifyListeners();

    try {
      final raw = await _signalFetchWorker(configJson, dataMode, sshSettings);
      if (_activeNativeFetchId == generation) _activeNativeFetchId = null;
      if (!_isCurrentFetch(generation)) return;
      if (raw.isEmpty) {
        _fetching = false;
        _status = 'Empty raw from Rust';
        _markUnresolvedSeries(
          'The native data loader returned no response for this signal.',
        );
        notifyListeners();
        return;
      }
      final json = jsonDecode(raw);
      if (json is! List) {
        _fetching = false;
        _status =
            'Type: ${json.runtimeType} — ${raw.length > 300 ? raw.substring(0, 300) : raw}';
        _markUnresolvedSeries(
          'The native data loader returned an invalid response.',
        );
        notifyListeners();
        return;
      }
      if (json.isEmpty) {
        _fetching = false;
        _status = 'Empty list';
        _markUnresolvedSeries(
          'No result was returned for the configured signal.',
        );
        notifyListeners();
        return;
      }
      _clearAllSeriesPoints();
      String? firstErr;
      for (final sig in json) {
        if (sig is Map) {
          final col = _decodeSignalIndex(sig['column']);
          final row = _decodeSignalIndex(sig['row']);
          final signal = _decodeSignalIndex(sig['signal']);
          if (col == null || row == null || signal == null) {
            firstErr ??= 'The server returned an invalid signal location.';
            continue;
          }
          final decoded = _decodeLoadedSeries(sig['series']);
          final err = decoded.error;
          if (err != null && err.isNotEmpty) firstErr ??= err;
          _rememberLoadedSource(col, row, signal, decoded.points);
          updatePlotSeriesByColRow(
            col,
            row,
            signal,
            decoded.points,
            err,
            unit: decoded.unit,
            xName: decoded.xName,
            xUnit: decoded.xUnit,
          );
        }
      }
      _markUnresolvedSeries(
        'No result was returned for this configured signal.',
      );
      _displayedShot = requestShot;
      _fetching = false;
      final loaded = _plots
          .where((p) =>
              p.series.any((s) => s?.points != null && s!.points!.isNotEmpty))
          .length;
      _status = 'Shot $requestShot: ${firstErr ?? "$loaded panels with data"}';
      if (firstErr != null) {
        reportNetworkPermissionFailure(
          firstErr,
          retry: () => _doFetch(shot: requestShot),
        );
      }
      unawaited(_fetchTopInfo(requestShot, generation));
    } catch (e) {
      if (_activeNativeFetchId == generation) _activeNativeFetchId = null;
      if (!_isCurrentFetch(generation)) return;
      _fetching = false;
      _status = 'Error: $e';
      _markUnresolvedSeries('Loading this signal failed: $e');
      reportNetworkPermissionFailure(
        e,
        retry: () => _doFetch(shot: requestShot),
      );
    }
    if (_isCurrentFetch(generation)) notifyListeners();
  }

  void stopFetch() {
    _cancelPendingFullShotRefresh(resetCadence: true);
    _cancelActiveNativeFetch();
    _fetchGeneration++;
    _fetching = false;
    _fetchingPlotIndex = null;
    _status = 'Stopped';
    notifyListeners();
  }

  Future<void> fetchSinglePanel(int plotIdx) async {
    if (!_requireActiveSession('reload a panel')) return;
    if (_columns.isEmpty) return;
    var targetCol = -1, targetRow = -1;
    var pIdx = 0;
    for (var c = 0; c < _columns.length; c++) {
      for (var r = 0; r < _columns[c].length; r++) {
        if (pIdx == plotIdx) {
          targetCol = c;
          targetRow = r;
          break;
        }
        pIdx++;
      }
      if (targetCol >= 0) break;
    }
    if (targetCol < 0) return;

    _cancelActiveNativeFetch();
    final generation = ++_fetchGeneration;
    final shot = _displayedShot.trim().isNotEmpty
        ? _displayedShot.trim()
        : _shotText.trim();
    final configJson = _buildSinglePanelSignalConfigJson(
        shot, targetCol, targetRow, generation);
    final dataMode = _dataMode.toString();
    final sshSettings = _buildSshSettingsJson();
    _fetchingPlotIndex = plotIdx;
    _fetching = true;
    _activeNativeFetchId = generation;
    _status = 'Fetching panel ($targetCol, $targetRow)...';
    notifyListeners();

    try {
      final raw = await _signalFetchWorker(configJson, dataMode, sshSettings);
      if (_activeNativeFetchId == generation) _activeNativeFetchId = null;
      if (!_isCurrentFetch(generation)) return;
      if (raw.isNotEmpty) {
        final json = jsonDecode(raw);
        if (json is List) {
          _clearPanelSeries(plotIdx);
          String? firstErr;
          for (final sig in json) {
            if (sig is Map) {
              final c = _decodeSignalIndex(sig['column']);
              final r = _decodeSignalIndex(sig['row']);
              if (c == targetCol && r == targetRow) {
                final signal = _decodeSignalIndex(sig['signal']);
                if (signal == null) {
                  firstErr ??= 'The server returned an invalid signal index.';
                  continue;
                }
                final decoded = _decodeLoadedSeries(sig['series']);
                final err = decoded.error;
                if (err != null && err.isNotEmpty) firstErr ??= err;
                _rememberLoadedSource(
                  targetCol,
                  targetRow,
                  signal,
                  decoded.points,
                );
                updatePlotSeriesByColRow(
                  targetCol,
                  targetRow,
                  signal,
                  decoded.points,
                  err,
                  unit: decoded.unit,
                  xName: decoded.xName,
                  xUnit: decoded.xUnit,
                );
              }
            }
          }
        }
      }
      _fetching = false;
      _fetchingPlotIndex = null;
      _status = 'Updated panel ($targetCol, $targetRow)';
    } catch (e) {
      if (_activeNativeFetchId == generation) _activeNativeFetchId = null;
      if (!_isCurrentFetch(generation)) return;
      _fetching = false;
      _fetchingPlotIndex = null;
      _status = 'Error: $e';
      reportNetworkPermissionFailure(
        e,
        retry: () => fetchSinglePanel(plotIdx),
      );
    }
    if (_isCurrentFetch(generation)) notifyListeners();
  }

  void _rememberLoadedSource(
    int column,
    int row,
    int signal,
    List<List<double>>? points,
  ) {
    if (points?.isNotEmpty != true ||
        column < 0 ||
        column >= _columns.length ||
        row < 0 ||
        row >= _columns[column].length) {
      return;
    }
    final configuredSignals = _columns[column][row]['signal_specs'] as List?;
    if (configuredSignals == null ||
        signal < 0 ||
        signal >= configuredSignals.length ||
        configuredSignals[signal] is! Map) {
      return;
    }
    final configured = configuredSignals[signal] as Map;
    final changed = sourceIndexMemory.remember(
      configured['experiment']?.toString() ?? '',
      configured['y_expr']?.toString() ?? '',
    );
    if (changed) unawaited(savePreferences());
  }

  Future<void> _fetchTopInfo(String shot, int generation) async {
    if (_loginApiUrl.isEmpty || shot.isEmpty || _authToken.isEmpty) return;
    final apiUrl = _loginApiUrl;
    final token = _authToken;
    try {
      final raw = await _shotInfoFetchWorker(apiUrl, token, shot);
      if (!_isCurrentFetch(generation)) return;
      if (raw.isNotEmpty && !raw.contains('"error"')) {
        final json = jsonDecode(raw);
        if (json is Map) {
          _shotInfoIp = json['ip']?.toString() ?? '';
          _shotInfoPulse = json['pulse']?.toString() ?? '';
          _shotInfoIt = json['it']?.toString() ?? '';
          _shotInfoTime = json['time']?.toString() ?? '';
          notifyListeners();
        }
      }
    } catch (_) {}
  }

  Future<void> fetchLatestShot() async {
    if (!_requireActiveSession('load the latest shot')) return;
    final generation = ++_fetchGeneration;
    final apiUrl = _loginApiUrl;
    final token = _authToken;
    final sshSettings = _buildSshSettingsJson();
    _fetchingPlotIndex = null;
    _fetching = true;
    _status = 'Fetching latest shot...';
    notifyListeners();
    try {
      final data = await _latestShotWorker(apiUrl, token, sshSettings);
      if (!_isCurrentFetch(generation)) return;
      recordSshUsage(sshSettings.isNotEmpty);
      final shot =
          data is Map ? (data['shot'] ?? _findShot(data)) : _findShot(data);
      if (shot != null) {
        setShotFromApi(shot.toString());
        if (data is Map) {
          _shotInfoIp = data['ip']?.toString() ?? '';
          _shotInfoPulse = data['pulseLength'] != null
              ? '${data['pulseLength']}s'
              : data['pulse']?.toString() ?? '';
          if (data['it'] != null) {
            final it = data['it'].toString();
            _shotInfoIt = RegExp(r'[A-Za-z]').hasMatch(it) ? it : '${it}kA';
          } else {
            _shotInfoIt = '';
          }
          _shotInfoTime =
              data['currentTime']?.toString() ?? data['time']?.toString() ?? '';
        }
        _status = 'Shot $shot';
        notifyListeners();
        startRefresh();
      } else {
        _fetching = false;
        _status = 'No shot found';
        notifyListeners();
      }
    } catch (e) {
      if (!_isCurrentFetch(generation)) return;
      recordSshUsage(false);
      _fetching = false;
      _status = 'Shot fetch: $e';
      notifyListeners();
      reportNetworkPermissionFailure(e, retry: fetchLatestShot);
    }
  }

  dynamic _findShot(dynamic d) {
    if (d is Map) {
      for (final k in ['shot', 'shotNo', 'treeShot']) {
        var v = d[k];
        if (v is int && v >= 1000) return v;
        if (v is String) {
          var p = int.tryParse(v);
          if (p != null && p >= 1000) return p;
        }
      }
      for (final v in d.values) {
        var r = _findShot(v);
        if (r != null) return r;
      }
    } else if (d is List) {
      for (final v in d) {
        var r = _findShot(v);
        if (r != null) return r;
      }
    } else if (d is int && d >= 1000) {
      return d;
    } else if (d is String) {
      var p = int.tryParse(d);
      if (p != null && p >= 1000) return p;
    }
    return null;
  }

  void updatePlotSeriesByColRow(
      int col, int row, int sigIdx, List<List<double>>? pts, String? err,
      {String unit = '', String xName = '', String xUnit = ''}) {
    var pi = 0;
    for (var c = 0; c < _columns.length; c++) {
      if (c == col) break;
      pi += _columns[c].length;
    }
    pi += row;
    if (pi < _plots.length) {
      while (_plots[pi].series.length <= sigIdx) {
        _plots[pi].series.add(null);
      }
      _plots[pi].series[sigIdx] = SeriesData(
        points: pts,
        error: err,
        unit: unit,
        xName: xName,
        xUnit: xUnit,
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration++;
    _cancelPendingFullShotRefresh(resetCadence: true);
    _cancelActiveNativeFetch();
    _disconnectSshTunnels();
    _fetchGeneration++;
    _shotCtrl.dispose();
    super.dispose();
  }
}

class PlotData {
  final String title, xLabel, yLabel;
  double? crosshairX;
  double? viewMinX, viewMaxX, viewMinY, viewMaxY;
  List<SeriesData?> series;
  PlotData(
      {required this.title,
      required this.xLabel,
      required this.yLabel,
      required this.series,
      this.crosshairX,
      this.viewMinX,
      this.viewMaxX,
      this.viewMinY,
      this.viewMaxY});

  void setViewRange(double minX, double maxX, double minY, double maxY) {
    viewMinX = minX.isFinite ? minX : null;
    viewMaxX = maxX.isFinite ? maxX : null;
    viewMinY = minY.isFinite ? minY : null;
    viewMaxY = maxY.isFinite ? maxY : null;
  }

  void clearViewRange() {
    viewMinX = null;
    viewMaxX = null;
    viewMinY = null;
    viewMaxY = null;
  }
}

class SeriesData {
  List<List<double>>? points;
  String? error;
  String unit;
  String xName;
  String xUnit;
  SeriesData({
    this.points,
    this.error,
    this.unit = '',
    this.xName = '',
    this.xUnit = '',
  });
}
