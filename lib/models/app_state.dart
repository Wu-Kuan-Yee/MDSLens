import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/platform_file_dialog.dart';
import '../services/rust_bridge.dart';

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
  final android = Platform.isAndroid;
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: 'Open MdsScope configuration',
    type: android ? FileType.any : FileType.custom,
    allowedExtensions: android ? null : const ['toml', 'webscp'],
    withData: mobile,
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
    path: mobile ? null : file.path,
    bytes: file.bytes,
  );
}

Future<String?> _saveConfigurationFile(
  String suggestedName,
  Uint8List bytes,
) {
  return saveBytesWithFilePicker(
    dialogTitle: 'Save MdsScope configuration',
    fileName: suggestedName,
    allowedExtensions: const ['toml'],
    bytes: bytes,
  );
}

String _parseConfiguration(String path) => RustBridge.instance.parseEnv(path);

Future<Uint8List> _encodeConfiguration(String configJson) async {
  final directory = await Directory.systemTemp.createTemp('mdsscope-save-');
  final path = '${directory.path}${Platform.pathSeparator}config.toml';
  try {
    final result = RustBridge.instance.writeEnv(configJson, path);
    final decoded = jsonDecode(result);
    if (decoded is! Map || decoded['ok'] != true) {
      throw decoded is Map ? decoded['error'] ?? result : result;
    }
    return File(path).readAsBytes();
  } finally {
    try {
      await directory.delete(recursive: true);
    } catch (_) {}
  }
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
    final request = await client.postUrl(Uri.parse('$base/login'));
    request.headers.set('Content-Type', 'application/json');
    request.write(jsonEncode({'userName': user, 'password': password}));
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw 'Unexpected login response';
    if (decoded['code'] != '20000' && decoded['code'] != 20000) {
      throw decoded['msg']?.toString() ?? 'Login failed';
    }
    final token = decoded['data']?['token']?.toString();
    if (token == null || token.isEmpty) throw 'Login returned no token';
    return (token: token, usedSsh: prepared.usedSsh);
  } finally {
    client.close();
  }
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
    final request = await client.postUrl(Uri.parse('$base/treeShot'));
    request.headers.set('Content-Type', 'application/json');
    request.headers.set('Authorization', 'Bearer $token');
    request.write('{}');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map) throw 'Unexpected latest-shot response';
    if (decoded['code'] != '20000' && decoded['code'] != 20000) {
      throw decoded['msg']?.toString() ?? 'Latest-shot request failed';
    }
    return decoded['data'];
  } finally {
    client.close();
  }
}

class AppState extends ChangeNotifier {
  final SignalFetchWorker _signalFetchWorker;
  final ShotInfoFetchWorker _shotInfoFetchWorker;
  final LoginWorker _loginWorker;
  final LatestShotWorker _latestShotWorker;
  final ConfigOpenPicker _configOpenPicker;
  final ConfigSavePicker _configSavePicker;
  final ConfigParser _configParser;
  final ConfigEncoder _configEncoder;
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
  final _shotCtrl = TextEditingController();
  TextEditingController get shotCtrl => _shotCtrl;
  set shotText(String v) {
    _invalidateFetchForSettingsChange();
    _shotText = v;
    _shotCtrl.text = v;
    savePreferences();
    notifyListeners();
  }

  // Shot history (last 20)
  final List<String> _shotHistory = [];
  List<String> get shotHistory => _shotHistory;
  void _addToHistory(String shot) {
    if (shot.isEmpty) return;
    _shotHistory.remove(shot);
    _shotHistory.insert(0, shot);
    if (_shotHistory.length > 20) _shotHistory.removeLast();
  }

  late final Future<void> preferencesReady;

  AppState({
    SignalFetchWorker? signalFetchWorker,
    ShotInfoFetchWorker? shotInfoFetchWorker,
    LoginWorker? loginWorker,
    LatestShotWorker? latestShotWorker,
    ConfigOpenPicker? configOpenPicker,
    ConfigSavePicker? configSavePicker,
    ConfigParser? configParser,
    ConfigEncoder? configEncoder,
  })  : _signalFetchWorker = signalFetchWorker ?? _fetchSignalsInBackground,
        _shotInfoFetchWorker =
            shotInfoFetchWorker ?? _fetchShotInfoInBackground,
        _loginWorker = loginWorker ?? _loginToApi,
        _latestShotWorker = latestShotWorker ?? _fetchLatestShotFromApi,
        _configOpenPicker = configOpenPicker ?? _pickConfigurationFile,
        _configSavePicker = configSavePicker ?? _saveConfigurationFile,
        _configParser = configParser ?? _parseConfiguration,
        _configEncoder = configEncoder ?? _encodeConfiguration {
    _shotCtrl.addListener(() {
      if (_shotCtrl.text != _shotText) {
        _invalidateFetchForSettingsChange();
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

  void removeWebBookmark(int i) {
    if (i >= 0 && i < _webBookmarks.length) {
      _webBookmarks.removeAt(i);
      savePreferences();
      notifyListeners();
    }
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
            series: List.filled(sc > 0 ? sc : 1, null)));
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
  String _status = 'Ready';
  String get status => _status;
  int _fetchGeneration = 0;

  bool _isCurrentFetch(int generation) {
    return !_disposed && generation == _fetchGeneration;
  }

  void _invalidateFetchForSettingsChange() {
    _fetchGeneration++;
    if (_fetching) {
      _fetching = false;
      _status = 'Settings changed. Previous load discarded.';
    }
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
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshPort(int v) {
    if (v == _sshPort) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshPort = v;
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshUser(String v) {
    if (v == _sshUser) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshUser = v;
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshPass(String v) {
    if (v == _sshPass) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshPass = v;
    _resetSshConnectionState();
    savePreferences();
    notifyListeners();
  }

  void setSshIdentity(String v) {
    if (v == _sshIdentity) return;
    _sessionGeneration++;
    _invalidateFetchForSettingsChange();
    _sshIdentity = v;
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

  void setSshTestResult(bool reachable) {
    _sshTunnelReachable = reachable;
    if (!reachable) _sshInUse = false;
    notifyListeners();
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
  }) async {
    final generation = ++_sessionGeneration;
    _status = automatic ? 'Signing in automatically...' : 'Signing in...';
    notifyListeners();
    try {
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
      await fetchLatestShot();
    } catch (error) {
      if (_disposed || generation != _sessionGeneration) return;
      _loggedIn = false;
      _authToken = '';
      _status =
          automatic ? 'Automatic login failed: $error' : 'Login failed: $error';
      await savePreferences();
      if (!_disposed) notifyListeners();
      rethrow;
    }
  }

  Future<void> initializeStartupSession() async {
    await preferencesReady;
    if (_disposed || !_rememberLogin || _explicitlyLoggedOut) return;
    if (_loginUser.trim().isNotEmpty) {
      try {
        await loginAndLoadLatest(
          apiUrl: _loginApiUrl,
          user: _loginUser,
          password: _loginPass,
          automatic: true,
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
      _invalidateFetchForSettingsChange();
      _rememberLogin = prefs.getBool('rememberLogin') ?? true;
      _explicitlyLoggedOut =
          prefs.getBool('explicitlyLoggedOut') ?? _explicitlyLoggedOut;
      _loginApiUrl = prefs.getString('loginApiUrl') ?? _loginApiUrl;
      _loginUser = prefs.getString('loginUser') ?? _loginUser;
      if (_rememberLogin) {
        _loginPass = prefs.getString('loginPass') ?? _loginPass;
        _authToken = prefs.getString('authToken') ?? _authToken;
        _loggedIn = prefs.getBool('loggedIn') ?? _loggedIn;
      }
      _sshHost = prefs.getString('sshHost') ?? _sshHost;
      _sshPort = prefs.getInt('sshPort') ?? _sshPort;
      _sshUser = prefs.getString('sshUser') ?? _sshUser;
      _sshPass = prefs.getString('sshPass') ?? _sshPass;
      _sshIdentity = prefs.getString('sshIdentity') ?? _sshIdentity;
      _sshMode = prefs.getInt('sshMode') ?? _sshMode;
      _dataMode = (prefs.getInt('dataMode') ?? _dataMode).clamp(0, 2);
      _interactionMode =
          (prefs.getInt('interactionMode') ?? _interactionMode).clamp(0, 1);
      _themeMode = (prefs.getInt('themeMode') ?? _themeMode).clamp(0, 2);
      _toolbarCollapsed =
          prefs.getBool('toolbarCollapsed') ?? _toolbarCollapsed;
      _fontFamily = prefs.getString('fontFamily') ?? _fontFamily;
      _fontLegendSize = prefs.getInt('fontLegendSize') ?? _fontLegendSize;
      _fontAxisSize = prefs.getInt('fontAxisSize') ?? _fontAxisSize;
      _fontUnitSize = prefs.getInt('fontUnitSize') ?? _fontUnitSize;
      _fontUiSize = prefs.getInt('fontUiSize') ?? _fontUiSize;

      final bookmarksJson = prefs.getString('webBookmarks');
      if (bookmarksJson != null) {
        final list = jsonDecode(bookmarksJson);
        if (list is List) {
          _webBookmarks.clear();
          for (final item in list) {
            if (item is Map) _webBookmarks.add(Map<String, String>.from(item));
          }
        }
      }

      final shotHistoryJson = prefs.getString('shotHistory');
      if (shotHistoryJson != null) {
        final list = jsonDecode(shotHistoryJson);
        if (list is List) {
          _shotHistory
            ..clear()
            ..addAll(list.map((item) => item.toString()).where(
                  (item) => item.isNotEmpty,
                ));
          if (_shotHistory.length > 20) {
            _shotHistory.removeRange(20, _shotHistory.length);
          }
        }
      }

      final lastConfig = prefs.getString('lastConfigJson');
      if (lastConfig != null && lastConfig.isNotEmpty) {
        _applyConfigJsonString(lastConfig);
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> savePreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('rememberLogin', _rememberLogin);
      await prefs.setBool('explicitlyLoggedOut', _explicitlyLoggedOut);
      await prefs.setString('loginApiUrl', _loginApiUrl);
      await prefs.setString('loginUser', _loginUser);
      if (_rememberLogin) {
        await prefs.setString('loginPass', _loginPass);
        await prefs.setString('authToken', _authToken);
        await prefs.setBool('loggedIn', _loggedIn);
      } else {
        await prefs.remove('loginPass');
        await prefs.remove('authToken');
        await prefs.setBool('loggedIn', false);
      }
      await prefs.setString('sshHost', _sshHost);
      await prefs.setInt('sshPort', _sshPort);
      await prefs.setString('sshUser', _sshUser);
      await prefs.setString('sshPass', _sshPass);
      await prefs.setString('sshIdentity', _sshIdentity);
      await prefs.setInt('sshMode', _sshMode);
      await prefs.setInt('dataMode', _dataMode);
      await prefs.setInt('interactionMode', _interactionMode);
      await prefs.setInt('themeMode', _themeMode);
      await prefs.setBool('toolbarCollapsed', _toolbarCollapsed);
      await prefs.setString('fontFamily', _fontFamily);
      await prefs.setInt('fontLegendSize', _fontLegendSize);
      await prefs.setInt('fontAxisSize', _fontAxisSize);
      await prefs.setInt('fontUnitSize', _fontUnitSize);
      await prefs.setInt('fontUiSize', _fontUiSize);
      await prefs.setString('webBookmarks', jsonEncode(_webBookmarks));
      await prefs.setString('shotHistory', jsonEncode(_shotHistory));

      final configJson = jsonEncode({
        'columns': _jsonSafeValue(_columns),
        'shot': _shotText,
      });
      await prefs.setString('lastConfigJson', configJson);
    } catch (_) {}
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

  void _applyConfigJsonString(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map || json['columns'] is! List) return;
      final cols = (json['columns'] as List).map((col) {
        return (col as List).map((panel) {
          final m = Map<String, dynamic>.from(panel as Map);
          m['extraction_points'] ??= 2000;
          m['grid'] ??= true;
          return m;
        }).toList();
      }).toList();
      if (cols.isEmpty || cols.every((c) => c.isEmpty)) return;
      _columns = cols;
      _plots.clear();
      for (final col in _columns) {
        for (final panel in col) {
          final sigCount = (panel['signal_specs'] as List?)?.length ?? 1;
          _plots.add(PlotData(
            title: panel['title']?.toString() ?? '',
            xLabel: panel['x_label']?.toString() ?? 's',
            yLabel: panel['y_label']?.toString() ?? 'a.u.',
            series: List.filled(sigCount > 0 ? sigCount : 1, null),
          ));
        }
      }
      if (json['shot'] != null) {
        final s = json['shot'].toString().trim();
        if (s.isNotEmpty) {
          _shotText = s;
          _shotCtrl.text = s;
        }
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
            series: List.filled(1, null)));
      }
    }
    _status = 'Default config loaded. Login + Refresh to fetch data.';
    notifyListeners();
  }

  Future<void> openFile() async {
    Directory? temporaryDirectory;
    try {
      _status = 'Choose a .toml or .webscp configuration file...';
      notifyListeners();
      final selection = await _configOpenPicker();
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
          m['extraction_points'] ??= 2000;
          m['grid'] ??= true;
          return m;
        }).toList();
      }).toList();
      if (cols.isEmpty || cols.every((c) => c.isEmpty)) {
        _status = 'No panels found in config';
        notifyListeners();
        return;
      }
      _invalidateFetchForSettingsChange();
      final fileShot =
          json['shot'] ?? json['default_shot'] ?? json['global_shot'];
      if (fileShot != null && fileShot.toString().trim().isNotEmpty) {
        _shotText = fileShot.toString().trim();
        _shotCtrl.text = _shotText;
      }
      _columns = cols;
      _plots.clear();
      for (final col in _columns) {
        for (final panel in col) {
          final sigCount = (panel['signal_specs'] as List?)?.length ?? 1;
          _plots.add(PlotData(
            title: panel['title']?.toString() ?? '',
            xLabel: panel['x_label']?.toString() ?? 's',
            yLabel: panel['y_label']?.toString() ?? 'a.u.',
            series: List.filled(sigCount > 0 ? sigCount : 1, null),
          ));
        }
      }
      _status =
          'Loaded: ${selection.name} (${_columns.length} cols, ${_plots.length} panels)';
      savePreferences();
      notifyListeners();
      if (_shotText.isNotEmpty) startRefresh();
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

  Future<void> saveFile() async {
    try {
      _status = 'Preparing configuration...';
      notifyListeners();
      final cols = _columns
          .map((col) => col.map((panel) {
                final m = Map<String, dynamic>.from(panel);
                m.remove('shot');
                return m;
              }).toList())
          .toList();
      final configJson = jsonEncode(_jsonSafeValue({'columns': cols}));
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

  void _clearCustomReadModes() {
    for (final col in _columns) {
      for (final p in col) {
        final sigs = p['signal_specs'] as List?;
        if (sigs != null) {
          for (final s in sigs) {
            if (s is Map) {
              s.remove('read_mode');
            }
          }
        }
      }
    }
  }

  bool _requireActiveSession(String action) {
    if (hasActiveSession) return true;
    _fetchGeneration++;
    _fetching = false;
    _status = 'Login required to $action.';
    notifyListeners();
    return false;
  }

  void startRefresh() {
    if (!_requireActiveSession('load a shot')) return;
    if (_columns.isEmpty) return;
    _clearCustomReadModes();
    if (_shotCtrl.text.trim().isNotEmpty) {
      _shotText = _shotCtrl.text.trim();
    }
    _addToHistory(_shotText);
    savePreferences();
    _viewResetId++;
    _doFetch(shot: _shotText);
  }

  void refreshDisplayedShot() {
    if (!_requireActiveSession('refresh waveforms')) return;
    if (_columns.isEmpty) return;
    _clearCustomReadModes();
    final shot = _displayedShot.trim().isNotEmpty
        ? _displayedShot.trim()
        : _shotText.trim();
    if (shot.isEmpty) return;
    _addToHistory(shot);
    savePreferences();
    _viewResetId++;
    _doFetch(shot: shot);
  }

  void startRefreshPreserveView() {
    if (!_requireActiveSession('load a shot')) return;
    if (_columns.isEmpty) return;
    _clearCustomReadModes();
    if (_shotCtrl.text.trim().isNotEmpty) {
      _shotText = _shotCtrl.text.trim();
    }
    _addToHistory(_shotText);
    savePreferences();
    _doFetch(shot: _shotText);
  }

  String _buildSignalConfigJson(String shot) {
    final cols = _columns
        .map((col) => col.map((p) {
              final panel = Map<String, dynamic>.from(p);
              panel['shot'] = shot;
              panel['extraction_points'] ??= 2000;
              panel['grid'] ??= true;
              return panel;
            }).toList())
        .toList();
    return jsonEncode({'columns': cols});
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
    final generation = ++_fetchGeneration;
    final requestShot = shot;
    final configJson = _buildSignalConfigJson(requestShot);
    final dataMode = _dataMode.toString();
    final sshSettings = _buildSshSettingsJson();
    _fetching = true;
    _status = 'Fetching...';
    notifyListeners();

    try {
      final raw = await _signalFetchWorker(configJson, dataMode, sshSettings);
      if (!_isCurrentFetch(generation)) return;
      if (raw.isEmpty) {
        _fetching = false;
        _status = 'Empty raw from Rust';
        notifyListeners();
        return;
      }
      final json = jsonDecode(raw);
      if (json is! List) {
        _fetching = false;
        _status =
            'Type: ${json.runtimeType} — ${raw.length > 300 ? raw.substring(0, 300) : raw}';
        notifyListeners();
        return;
      }
      if (json.isEmpty) {
        _fetching = false;
        _status = 'Empty list';
        notifyListeners();
        return;
      }
      _clearAllSeriesPoints();
      String? firstErr;
      for (final sig in json) {
        if (sig is Map) {
          final ser = sig['series'];
          final err = ser?['error']?.toString();
          if (err != null && err.isNotEmpty) firstErr ??= err;
          final pts = (ser?['points'] as List?)
              ?.map((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()])
              .toList();
          updatePlotSeriesByColRow(sig['column'] as int, sig['row'] as int,
              sig['signal'] as int, pts, err);
        }
      }
      _displayedShot = requestShot;
      _fetching = false;
      final loaded = _plots
          .where((p) =>
              p.series.any((s) => s?.points != null && s!.points!.isNotEmpty))
          .length;
      _status = 'Shot $requestShot: ${firstErr ?? "$loaded panels with data"}';
      unawaited(_fetchTopInfo(requestShot, generation));
    } catch (e) {
      if (!_isCurrentFetch(generation)) return;
      _fetching = false;
      _status = 'Error: $e';
    }
    if (_isCurrentFetch(generation)) notifyListeners();
  }

  void stopFetch() {
    _fetchGeneration++;
    _fetching = false;
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

    final generation = ++_fetchGeneration;
    final shot = _displayedShot.trim().isNotEmpty
        ? _displayedShot.trim()
        : _shotText.trim();
    final configJson = _buildSignalConfigJson(shot);
    final dataMode = _dataMode.toString();
    final sshSettings = _buildSshSettingsJson();
    _fetching = true;
    _status = 'Fetching panel ($targetCol, $targetRow)...';
    notifyListeners();

    try {
      final raw = await _signalFetchWorker(configJson, dataMode, sshSettings);
      if (!_isCurrentFetch(generation)) return;
      if (raw.isNotEmpty) {
        final json = jsonDecode(raw);
        if (json is List) {
          _clearPanelSeries(plotIdx);
          String? firstErr;
          for (final sig in json) {
            if (sig is Map) {
              final c = sig['column'] as int?;
              final r = sig['row'] as int?;
              if (c == targetCol && r == targetRow) {
                final ser = sig['series'];
                final err = ser?['error']?.toString();
                if (err != null && err.isNotEmpty) firstErr ??= err;
                final pts = (ser?['points'] as List?)
                    ?.map((p) =>
                        [(p[0] as num).toDouble(), (p[1] as num).toDouble()])
                    .toList();
                updatePlotSeriesByColRow(
                    targetCol, targetRow, sig['signal'] as int, pts, err);
              }
            }
          }
        }
      }
      _fetching = false;
      _status = 'Updated panel ($targetCol, $targetRow)';
    } catch (e) {
      if (!_isCurrentFetch(generation)) return;
      _fetching = false;
      _status = 'Error: $e';
    }
    if (_isCurrentFetch(generation)) notifyListeners();
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
          _shotInfoPulse =
              data['pulseLength'] != null ? '${data['pulseLength']}s' : '';
          _shotInfoIt = data['it'] != null ? '${data['it']}kA' : '';
          _shotInfoTime = data['currentTime']?.toString() ?? '';
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
      int col, int row, int sigIdx, List<List<double>>? pts, String? err) {
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
      _plots[pi].series[sigIdx] = SeriesData(points: pts, error: err);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _sessionGeneration++;
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
  SeriesData({this.points, this.error});
}
