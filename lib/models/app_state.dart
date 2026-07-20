import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../services/rust_bridge.dart';

class AppState extends ChangeNotifier {
  // Config
  List<List<Map<String, dynamic>>> _columns = [];
  List<List<Map<String, dynamic>>> get columns => _columns;

  // Plots
  final List<PlotData> _plots = [];
  List<PlotData> get plots => _plots;
  int selectedCol = -1, selectedRow = -1;
  double? crosshairX;
  final List<({String name, double y})> crosshairReadout = [];

  void setCrosshair(double x) { crosshairX = x; notifyListeners(); }
  void clearCrosshair() { crosshairX = null; crosshairReadout.clear(); notifyListeners(); }

  // Shot
  String _shotText = '';
  String get shotText => _shotText;
  final _shotCtrl = TextEditingController();
  TextEditingController get shotCtrl => _shotCtrl;
  set shotText(String v) { _shotText = v; _shotCtrl.text = v; notifyListeners(); }

  // Shot history (last 20)
  final List<String> _shotHistory = [];
  List<String> get shotHistory => _shotHistory;
  void _addToHistory(String shot) {
    if (shot.isEmpty) return;
    _shotHistory.remove(shot);
    _shotHistory.insert(0, shot);
    if (_shotHistory.length > 20) _shotHistory.removeLast();
  }

  AppState() {
    _shotCtrl.addListener(() {
      if (_shotCtrl.text != _shotText) { _shotText = _shotCtrl.text; notifyListeners(); }
    });
    loadDefaultConfig();
  }

  void setShotFromApi(String v) {
    _shotText = v;
    _shotCtrl.text = v;
    // Move cursor to end
    _shotCtrl.selection = TextSelection.collapsed(offset: v.length);
    notifyListeners();
  }

  String _shotInfoIp = '', _shotInfoPulse = '', _shotInfoIt = '', _shotInfoTime = '';
  String get shotInfoIp => _shotInfoIp; String get shotInfoPulse => _shotInfoPulse;
  String get shotInfoIt => _shotInfoIt; String get shotInfoTime => _shotInfoTime;

  // Mode
  int _dataMode = 0;
  int get dataMode => _dataMode;
  set dataMode(int v) { _dataMode = v; notifyListeners(); }

  int _interactionMode = 0;
  int get interactionMode => _interactionMode;
  set interactionMode(int v) {
    _interactionMode = v;
    if (v != 1) clearCrosshair(); // Auto-clear when leaving Point mode
    notifyListeners();
  }

  // Theme
  int _themeMode = 2;
  int get themeMode => _themeMode;
  set themeMode(int v) { _themeMode = v; notifyListeners(); }

  // Auth
  bool _loggedIn = false; bool get loggedIn => _loggedIn;
  String _authToken = ''; String get authToken => _authToken;
  String _loginApiUrl = 'http://202.127.204.26:80/api'; String get loginApiUrl => _loginApiUrl;
  String _loginUser = ''; String get loginUser => _loginUser;
  String _loginPass = ''; String get loginPass => _loginPass;

  // SSH
  String _sshHost = ''; String get sshHost => _sshHost;
  int _sshMode = 1; int get sshMode => _sshMode; set sshMode(int v) { _sshMode = v; notifyListeners(); }
  int _sshPort = 22; int get sshPort => _sshPort;
  String _sshUser = ''; String get sshUser => _sshUser;
  String _sshPass = ''; String get sshPass => _sshPass;
  String _sshIdentity = ''; String get sshIdentity => _sshIdentity;
  bool _sshConnected = false; bool get sshConnected => _sshConnected;

  // View reset — incremented on each Refresh/Apply to reset zoom/pan
  int _viewResetId = 0;
  int get viewResetId => _viewResetId;

  // Fetch
  bool _fetching = false; bool get fetching => _fetching;
  String _status = 'Ready'; String get status => _status;

  // Dialogs
  bool _showLogin = false; bool get showLogin => _showLogin;
  bool _showSsh = false; bool get showSsh => _showSsh;

  // AppState() constructor is above with _shotCtrl initialization

  void setLoginApiUrl(String v) { _loginApiUrl = v; }
  void setLoginUser(String v) { _loginUser = v; }
  void setLoginPass(String v) { _loginPass = v; }
  void setSshHost(String v) { _sshHost = v; notifyListeners(); }
  void setSshPort(int v) { _sshPort = v; notifyListeners(); }
  void setSshUser(String v) { _sshUser = v; notifyListeners(); }
  void setSshPass(String v) { _sshPass = v; notifyListeners(); }
  void setSshIdentity(String v) { _sshIdentity = v; notifyListeners(); }
  void openLogin() { _showLogin = true; notifyListeners(); }
  void openSsh() { _showSsh = true; notifyListeners(); }
  void setLoggedIn(bool v, String token) { _loggedIn = v; _authToken = token; notifyListeners(); }
  void logout() { _loggedIn = false; _authToken = ''; setStatus('Logged out'); }
  void setStatus(String s) { _status = s; notifyListeners(); }
  void setSshConnected(bool v) { _sshConnected = v; notifyListeners(); }

  void loadDefaultConfig() {
    // Match the original MdsScope init.toml — 2 columns × 3 rows
    final panels = [
      // Column 1
      ('Ip',     r'\pcrl01'),  ('R',   r'\lmsr'),  ('Z',           r'\lmsz'),
      // Column 2
      ('Vloop',  r'\pcvloop'), ('Ne', r'\dfsdev'), ('Pf1 current', r'\pcpf1'),
    ];
    _columns = [[], []];
    _plots.clear();
    for (var i = 0; i < 6; i++) {
      final col = i < 3 ? 0 : 1;
      final (title, y) = panels[i];
      _columns[col].add({
        'title': title, 'x_label': 's', 'y_label': 'a.u.',
        'signal_specs': [{'y_expr': y, 'experiment': 'pcs_east', 'server_ip': '202.127.204.12'}],
      });
    }
    for (final col in _columns) { for (final panel in col) {
      _plots.add(PlotData(title: panel['title']?.toString()??'', xLabel: 's', yLabel: 'a.u.', series: List.filled(1, null)));
    }}
    _status = 'Default config loaded. Login + Refresh to fetch data.';
    notifyListeners();
  }

  void openFile() async {
    try {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['toml','webscp']);
      if (r == null || r.files.single.path == null) return;
      final path = r.files.single.path!;
      _status = 'Loading $path...'; notifyListeners();
      final raw = RustBridge.instance.parseEnv(path);
      if (raw.isEmpty) { _status = 'Empty result from parser'; notifyListeners(); return; }
      final json = jsonDecode(raw);
      if (json is! Map || json['columns'] is! List) {
        _status = 'Invalid config format'; notifyListeners(); return;
      }
      final cols = (json['columns'] as List).map((col) {
        return (col as List).map((panel) {
          final m = Map<String, dynamic>.from(panel as Map);
          m['extraction_points'] ??= 2000;
          m['grid'] ??= true;
          // Keep signal_specs as-is (List<Map>)
          return m;
        }).toList();
      }).toList();
      if (cols.isEmpty || cols.every((c) => c.isEmpty)) {
        _status = 'No panels found in config'; notifyListeners(); return;
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
      _status = 'Loaded: ${path.split('/').last} (${_columns.length} cols, ${_plots.length} panels)'; notifyListeners();
      // Auto-refresh if logged in
      if (_shotText.isNotEmpty && _loggedIn) startRefresh();
    } catch (e) { _status = 'Open error: $e'; notifyListeners(); }
  }

  void saveFile() async {
    try {
      final r = await FilePicker.platform.saveFile(fileName: 'config.toml', type: FileType.custom, allowedExtensions: ['toml']);
      if (r == null) return;
      // Serialize _columns to FrbLayoutConfig JSON
      final cols = _columns.map((col) => col.map((panel) {
        final m = Map<String, dynamic>.from(panel);
        // Remove internal keys not part of FrbPlotSpec
        m.remove('shot');
        return m;
      }).toList()).toList();
      final configJson = jsonEncode({'columns': cols});
      final result = RustBridge.instance.writeEnv(configJson, r);
      final resMap = jsonDecode(result);
      if (resMap is Map && resMap['ok'] == true) {
        _status = 'Saved to ${r.split('/').last}'; notifyListeners();
      } else {
        _status = 'Save error: ${resMap is Map ? resMap['error'] ?? result : result}'; notifyListeners();
      }
    } catch (e) { _status = 'Save error: $e'; notifyListeners(); }
  }

  void startRefresh() {
    if (_columns.isEmpty) return;
    _addToHistory(_shotText);
    _viewResetId++; // Signal all panels to reset zoom/pan
    _fetching = true; _status = 'Fetching...'; notifyListeners();
    Future.microtask(() {
      try {
        final cols = _columns.map((col) => col.map((p) {
          final m = Map<String, dynamic>.from(p);
          m['shot'] = _shotText;
          m['extraction_points'] ??= 2000;
          m['grid'] ??= true;
          return m;
        }).toList()).toList();
        final sshSettings = _sshMode > 0 && _sshHost.isNotEmpty
            ? jsonEncode({'host': _sshHost, 'port': _sshPort, 'user': _sshUser, 'password': _sshPass, 'identity_file': _sshIdentity, 'mode': _sshMode})
            : '';
        final raw = RustBridge.instance.fetchSigSsh(jsonEncode({'columns': cols}), _dataMode.toString(), sshSettings);
        if (raw.isEmpty) { _fetching = false; _status = 'Empty raw from Rust'; notifyListeners(); return; }
        final json = jsonDecode(raw);
        if (json is! List) { _fetching = false; _status = 'Type: ${json.runtimeType} — ${raw.length > 300 ? raw.substring(0,300) : raw}'; notifyListeners(); return; }
        if (json.isEmpty) { _fetching = false; _status = 'Empty list'; notifyListeners(); return; }
        String? firstErr;
        for (final sig in json) {
          if (sig is Map) {
            final ser = sig['series'];
            final err = ser?['error']?.toString();
            if (err != null && err.isNotEmpty) firstErr ??= err;
            final pts = (ser?['points'] as List?)?.map((p) => [(p[0] as num).toDouble(), (p[1] as num).toDouble()]).toList();
            updatePlotSeriesByColRow(sig['column'] as int, sig['row'] as int, sig['signal'] as int, pts, err);
          }
        }
        _fetching = false;
        final loaded = _plots.where((p) => p.series.any((s) => s?.points != null && s!.points!.isNotEmpty)).length;
        // Debug: show timebase and X range
        var xInfo = '';
        for (final sig in json) {
          if (sig is Map) {
            final s = sig['series'];
            if (s is Map && s['points'] is List && (s['points'] as List).isNotEmpty) {
              final pts = s['points'] as List;
              xInfo = ' [X:${(pts.first as List)[0]}-${(pts.last as List)[0]} tb:start=${s['uniform_start']} step=${s['uniform_step']}]';
              break;
            }
          }
        }
        _status = 'Shot $_shotText: ${firstErr ?? "$loaded panels with data"}$xInfo';
      } catch (e) { _fetching = false; _status = 'Error: $e'; }
      notifyListeners();
    });
  }

  void stopFetch() { _fetching = false; _status = 'Stopped'; notifyListeners(); }

  Future<void> fetchLatestShot() async {
    _status = 'Fetching latest shot...'; notifyListeners();
    try {
      String apiUrl = _loginApiUrl;
      // Route through SSH if configured
      if (_sshMode > 0 && _sshHost.isNotEmpty) {
        try {
          final settings = jsonEncode({'host': _sshHost, 'port': _sshPort, 'user': _sshUser, 'password': _sshPass, 'identity_file': _sshIdentity, 'mode': 2});
          final resp = RustBridge.instance.prepareUrl(_loginApiUrl, settings);
          if (resp.startsWith('http') && !resp.contains('"error"')) apiUrl = resp;
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
        final json = jsonDecode(body);
        if (json is! Map) throw 'unexpected: $body';
        if (json['code'] != '20000' && json['code'] != 20000) throw json['msg'] ?? 'failed';
        final data = json['data'];
        final shot = data is Map ? (data['shot'] ?? _findShot(data)) : _findShot(data);
        if (shot != null) {
          setShotFromApi(shot.toString());
          if (data is Map) {
            _shotInfoIp = data['ip']?.toString() ?? '';
            _shotInfoPulse = data['pulseLength'] != null ? '${data['pulseLength']}s' : '';
            _shotInfoIt = data['it'] != null ? '${data['it']}kA' : '';
            _shotInfoTime = data['currentTime']?.toString() ?? '';
          }
          _status = 'Shot $shot'; notifyListeners();
          startRefresh();
        } else { _status = 'No shot found'; notifyListeners(); }
      } finally { client.close(); }
    } catch (e) { _status = 'Shot fetch: $e'; notifyListeners(); }
  }

  dynamic _findShot(dynamic d) {
    if (d is Map) { for (final k in ['shot','shotNo','treeShot']) { var v = d[k]; if (v is int && v >= 1000) return v; if (v is String) { var p = int.tryParse(v); if (p != null && p >= 1000) return p; }} for (final v in d.values) { var r = _findShot(v); if (r != null) return r; }}
    else if (d is List) { for (final v in d) { var r = _findShot(v); if (r != null) return r; }}
    else if (d is int && d >= 1000) { return d; }
    else if (d is String) { var p = int.tryParse(d); if (p != null && p >= 1000) return p; }
    return null;
  }

  void updatePlotSeriesByColRow(int col, int row, int sigIdx, List<List<double>>? pts, String? err) {
    var pi = 0;
    for (var c = 0; c < _columns.length; c++) { if (c == col) break; pi += _columns[c].length; }
    pi += row;
    if (pi < _plots.length) {
      while (_plots[pi].series.length <= sigIdx) { _plots[pi].series.add(null); }
      _plots[pi].series[sigIdx] = SeriesData(points: pts, error: err);
    }
  }
}

class PlotData {
  final String title, xLabel, yLabel;
  double? crosshairX;
  List<SeriesData?> series;
  PlotData({required this.title, required this.xLabel, required this.yLabel, required this.series, this.crosshairX});
}

class SeriesData {
  final List<List<double>>? points;
  final String? error;
  SeriesData({this.points, this.error});
}
