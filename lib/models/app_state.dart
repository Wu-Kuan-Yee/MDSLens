import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/rust_bridge.dart';

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

class AppState extends ChangeNotifier {
  final SignalFetchWorker _signalFetchWorker;
  final ShotInfoFetchWorker _shotInfoFetchWorker;
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
  })  : _signalFetchWorker = signalFetchWorker ?? _fetchSignalsInBackground,
        _shotInfoFetchWorker =
            shotInfoFetchWorker ?? _fetchShotInfoInBackground {
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
    _rememberLogin = v;
    savePreferences();
    notifyListeners();
  }

  bool _loggedIn = false;
  bool get loggedIn => _loggedIn;
  String _authToken = '';
  String get authToken => _authToken;
  String _loginApiUrl = 'http://202.127.204.26:80/api';
  String get loginApiUrl => _loginApiUrl;
  String _loginUser = '';
  String get loginUser => _loginUser;
  String _loginPass = '';
  String get loginPass => _loginPass;

  // SSH
  String _sshHost = '';
  String get sshHost => _sshHost;
  int _sshMode = 1;
  int get sshMode => _sshMode;
  set sshMode(int v) {
    if (v == _sshMode) return;
    _invalidateFetchForSettingsChange();
    _sshMode = v;
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
  bool _sshConnected = false;
  bool get sshConnected => _sshConnected;

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

  // Dialogs
  bool _showLogin = false;
  bool get showLogin => _showLogin;
  bool _showSsh = false;
  bool get showSsh => _showSsh;

  void setLoginApiUrl(String v) {
    if (v == _loginApiUrl) return;
    _invalidateFetchForSettingsChange();
    _loginApiUrl = v;
    savePreferences();
  }

  void setLoginUser(String v) {
    _loginUser = v;
    savePreferences();
  }

  void setLoginPass(String v) {
    _loginPass = v;
    savePreferences();
  }

  void setSshHost(String v) {
    if (v == _sshHost) return;
    _invalidateFetchForSettingsChange();
    _sshHost = v;
    savePreferences();
    notifyListeners();
  }

  void setSshPort(int v) {
    if (v == _sshPort) return;
    _invalidateFetchForSettingsChange();
    _sshPort = v;
    savePreferences();
  }

  void setSshUser(String v) {
    if (v == _sshUser) return;
    _invalidateFetchForSettingsChange();
    _sshUser = v;
    savePreferences();
  }

  void setSshPass(String v) {
    if (v == _sshPass) return;
    _invalidateFetchForSettingsChange();
    _sshPass = v;
    savePreferences();
  }

  void setSshIdentity(String v) {
    if (v == _sshIdentity) return;
    _invalidateFetchForSettingsChange();
    _sshIdentity = v;
    savePreferences();
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
    _invalidateFetchForSettingsChange();
    _loggedIn = v;
    _authToken = token;
    savePreferences();
    notifyListeners();
  }

  void logout() {
    _loggedIn = false;
    _authToken = '';
    savePreferences();
    setStatus('Logged out');
  }

  void setStatus(String s) {
    _status = s;
    notifyListeners();
  }

  void setSshConnected(bool v) {
    _sshConnected = v;
    notifyListeners();
  }

  Future<void> initPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _invalidateFetchForSettingsChange();
      _rememberLogin = prefs.getBool('rememberLogin') ?? true;
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

  void openFile() async {
    try {
      final r = await FilePicker.platform.pickFiles(
          type: FileType.custom, allowedExtensions: ['toml', 'webscp']);
      if (r == null || r.files.isEmpty || r.files.single.path == null) return;
      final path = r.files.single.path!;
      _status = 'Loading $path...';
      notifyListeners();
      final raw = RustBridge.instance.parseEnv(path);
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
          'Loaded: ${path.split('/').last} (${_columns.length} cols, ${_plots.length} panels)';
      savePreferences();
      notifyListeners();
      if (_shotText.isNotEmpty) startRefresh();
    } catch (e) {
      _status = 'Open error: $e';
      notifyListeners();
    }
  }

  void saveFile() async {
    try {
      var r = await FilePicker.platform.saveFile(
          fileName: 'config.toml',
          type: FileType.custom,
          allowedExtensions: ['toml']);
      if (r == null || r.trim().isEmpty) return;
      if (!r.endsWith('.toml') && !r.endsWith('.webscp')) {
        r = '$r.toml';
      }
      final cols = _columns
          .map((col) => col.map((panel) {
                final m = Map<String, dynamic>.from(panel);
                m.remove('shot');
                return m;
              }).toList())
          .toList();
      final configJson = jsonEncode({'columns': cols});
      final result = RustBridge.instance.writeEnv(configJson, r);
      final resMap = jsonDecode(result);
      if (resMap is Map && resMap['ok'] == true) {
        _status = 'Saved to ${r.split('/').last}';
        notifyListeners();
      } else {
        _status =
            'Save error: ${resMap is Map ? resMap['error'] ?? result : result}';
        notifyListeners();
      }
    } catch (e) {
      _status = 'Save error: $e';
      notifyListeners();
    }
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

  void startRefresh() {
    if (_columns.isEmpty) return;
    _clearCustomReadModes();
    if (_shotCtrl.text.trim().isNotEmpty) {
      _shotText = _shotCtrl.text.trim();
    }
    _addToHistory(_shotText);
    savePreferences();
    _viewResetId++;
    _doFetch();
  }

  void startRefreshPreserveView() {
    if (_columns.isEmpty) return;
    _clearCustomReadModes();
    if (_shotCtrl.text.trim().isNotEmpty) {
      _shotText = _shotCtrl.text.trim();
    }
    _addToHistory(_shotText);
    savePreferences();
    _doFetch();
  }

  String _buildSignalConfigJson() {
    final cols = _columns
        .map((col) => col.map((p) {
              final panel = Map<String, dynamic>.from(p);
              panel['shot'] = _shotText;
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

  String _buildSshSettingsJson() {
    if (_sshMode <= 0 || _sshHost.isEmpty) return '';
    return jsonEncode({
      'host': _sshHost,
      'port': _sshPort,
      'user': _sshUser,
      'password': _sshPass,
      'identity_file': _sshIdentity,
      'mode': _sshMode,
    });
  }

  Future<void> _doFetch() async {
    final generation = ++_fetchGeneration;
    final requestShot = _shotText;
    final configJson = _buildSignalConfigJson();
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
    final configJson = _buildSignalConfigJson();
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
    final generation = ++_fetchGeneration;
    _fetching = true;
    _status = 'Fetching latest shot...';
    notifyListeners();
    try {
      String apiUrl = _loginApiUrl;
      // Route through SSH if configured
      if (_sshMode > 0 && _sshHost.isNotEmpty) {
        try {
          final settings = jsonEncode({
            'host': _sshHost,
            'port': _sshPort,
            'user': _sshUser,
            'password': _sshPass,
            'identity_file': _sshIdentity,
            'mode': 2
          });
          final resp = RustBridge.instance.prepareUrl(_loginApiUrl, settings);
          if (resp.startsWith('http') && !resp.contains('"error"'))
            apiUrl = resp;
        } catch (_) {}
      }
      final base = apiUrl.replaceAll(RegExp(r'/$'), '');
      final uri = Uri.parse('$base/treeShot');
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('Content-Type', 'application/json');
        req.headers.set('Authorization', 'Bearer $_authToken');
        req.write('{}');
        final resp = await req.close();
        final body = await resp.transform(utf8.decoder).join();
        if (!_isCurrentFetch(generation)) return;
        final json = jsonDecode(body);
        if (json is! Map) throw 'unexpected: $body';
        if (json['code'] != '20000' && json['code'] != 20000)
          throw json['msg'] ?? 'failed';
        final data = json['data'];
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
      } finally {
        client.close();
      }
    } catch (e) {
      if (!_isCurrentFetch(generation)) return;
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
