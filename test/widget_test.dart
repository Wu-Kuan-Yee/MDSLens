import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:mdsscope/app.dart';
import 'package:mdsscope/pages/main_page.dart';
import 'package:mdsscope/models/app_state.dart';
import 'package:mdsscope/services/external_url_launcher.dart';
import 'package:mdsscope/services/identity_file_access.dart';
import 'package:mdsscope/services/platform_file_dialog.dart';
import 'package:mdsscope/services/runtime_build_info.dart';
import 'package:mdsscope/services/source_index.dart';
import 'package:mdsscope/services/update_service.dart';
import 'package:mdsscope/theme/mdsscope_theme.dart';
import 'package:mdsscope/widgets/dialogs/about.dart';
import 'package:mdsscope/widgets/dialogs/login.dart';
import 'package:mdsscope/widgets/plot_panel.dart';
import 'package:mdsscope/widgets/plot_grid.dart';
import 'package:mdsscope/widgets/plot_render_cache.dart';
import 'package:mdsscope/widgets/responsive_plot_layout.dart';
import 'package:mdsscope/widgets/toolbar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Point readout interpolates ascending and descending waveforms', () {
    expect(
      interpolateWaveformY(
        [
          [0, 10],
          [2, 20],
        ],
        0.5,
      ),
      12.5,
    );
    expect(
      interpolateWaveformY(
        [
          [2, 20],
          [0, 10],
        ],
        0.5,
      ),
      12.5,
    );
    expect(
      interpolateWaveformY(
        [
          [0, 10],
          [2, 20],
        ],
        -1,
      ),
      10,
    );
  });

  test('Source index extracts MDS nodes from expressions and remembers them',
      () {
    expect(
      sourceIndexSignalNames(r'build_signal(\PCRL01 / 1000, \TIMEBASE)'),
      [r'\PCRL01', r'\TIMEBASE'],
    );
    expect(sourceIndexSignalNames('PCRL02'), [r'\PCRL02']);
    expect(sourceIndexSignalKey(r'\PCRL01 / 1000'), 'pcrl01');

    final memory = SourceIndexMemory();
    memory.remember(
      'test_tree_for_source_index',
      r'\NEW_SIGNAL * 2',
    );
    expect(
      memory.signalsForTree('TEST_TREE_FOR_SOURCE_INDEX'),
      contains(r'\NEW_SIGNAL'),
    );
    final restored = SourceIndexMemory()
      ..restore(jsonDecode(jsonEncode(memory.toJson())));
    expect(
      restored.signalsForTree('TEST_TREE_FOR_SOURCE_INDEX'),
      contains(r'\NEW_SIGNAL'),
    );
  });

  test('Learned source index survives application restart', () async {
    SharedPreferences.setMockInitialValues({
      'sourceIndexMemory': jsonEncode({
        'diagnostic_tree': [r'\LEARNED_SIGNAL'],
      }),
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);

    expect(
      app.sourceIndexMemory.signalsForTree('DIAGNOSTIC_TREE'),
      contains(r'\LEARNED_SIGNAL'),
    );
  });

  test('Waveform render geometry is reused until series data changes', () {
    final points = List<List<double>>.generate(
      12000,
      (index) => [index / 1000, math.sin(index / 80)],
    );
    final series = SeriesData(points: points);
    final cache = PlotRenderCache();

    final first = cache.render(series);
    final second = cache.render(series);
    expect(identical(first, second), isTrue);
    expect(first.spots.length, lessThanOrEqualTo(2000));

    series.points = List<List<double>>.from(points);
    final replaced = cache.render(series);
    expect(identical(first, replaced), isFalse);

    series.points!.add([12.0, 0.0]);
    final extended = cache.render(series);
    expect(identical(replaced, extended), isFalse);

    final zoomed = cache.render(series, minX: 4, maxX: 4.1);
    expect(zoomed.spots.first.x, lessThanOrEqualTo(4));
    expect(zoomed.spots.last.x, greaterThanOrEqualTo(4.1));
    expect(zoomed.spots.length, lessThan(points.length ~/ 10));
  });

  test('Release versions are compared semantically', () {
    expect(currentMdsScopeVersion, '7.0');
    expect(compareVersions('v7.1.0', '7.0.9'), greaterThan(0));
    expect(compareVersions('7.0', '7.0.0'), 0);
    expect(compareVersions('6.9.9', '7.0.0'), lessThan(0));
  });

  test('Runtime system information normalizes versions and architectures', () {
    expect(
      normalizedOperatingSystemVersion(
        'Version 15.5 (Build 24F74)',
      ),
      '15.5',
    );
    expect(normalizedArchitecture('androidArm64'), 'arm64');
    expect(normalizedArchitecture('arm64-v8a'), 'arm64');
    expect(normalizedArchitecture('windowsX64'), 'x86_64');
    expect(
      runtimeSystemInfoForValues(
        operatingSystem: 'windows',
        operatingSystemVersion: 'Windows 10 Pro 10.0.26200.8875',
        architecture: 'windowsX64',
      ).displayText,
      'Windows 11 (25H2, build 26200.8875) (x86_64)',
    );
    expect(
      linuxRuntimeSystemInfo(
        osRelease: 'NAME=Fedora\nPRETTY_NAME="Fedora Linux 44"\n',
        kernelVersion: 'Linux 7.0.11-200.fc44.x86_64 #1 SMP PREEMPT_DYNAMIC',
        architecture: 'linuxX64',
      ).displayText,
      'Fedora Linux 44 (kernel 7.0.11-200.fc44.x86_64) (x86_64)',
    );
    expect(
      const RuntimeSystemInfo(
        name: 'Android',
        version: '15',
        architecture: 'arm64',
      ).displayText,
      'Android (15) (arm64)',
    );
  });

  test('Runtime system information prefers the native platform channel',
      () async {
    const channel = MethodChannel('mdsscope/system_info');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'get');
      return {
        'name': 'Windows 11 Pro',
        'version': '25H2, build 26200.8875',
        'architecture': 'AMD64',
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final info = await loadRuntimeSystemInfo(useLinuxReleaseInfo: false);

    expect(
      info.displayText,
      'Windows 11 Pro (25H2, build 26200.8875) (x86_64)',
    );
  });

  test('Customize Fonts values are applied to the application theme', () {
    final theme = MdsScopeTheme.light(
      fontFamily: 'Courier New',
      uiFontSize: 18,
    );

    expect(theme.textTheme.bodyMedium?.fontFamily, 'Courier New');
    expect(theme.textTheme.bodyMedium?.fontSize, 18);
    expect(theme.textTheme.labelLarge?.fontSize, 18);
    expect(theme.inputDecorationTheme.filled, isTrue);
    final popupShape = theme.popupMenuTheme.shape as RoundedRectangleBorder;
    expect(popupShape.borderRadius, BorderRadius.circular(12));
  });

  testWidgets('Auto theme follows live platform brightness changes',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    app.themeMode = 2;
    addTearDown(
        tester.binding.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MdsScopeApp(),
      ),
    );
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light);

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    await tester.pump();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark);

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    await tester.pump();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light);
  });

  testWidgets('Auto theme keeps the authoritative startup brightness',
      (tester) async {
    const channel = MethodChannel('mdsscope/theme');
    var nativeBrightnessQueries = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'isDark') {
        nativeBrightnessQueries++;
        return nativeBrightnessQueries == 1 ? false : true;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue();
    });
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;

    final app = AppState();
    await app.preferencesReady;
    app.themeMode = 2;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MdsScopeApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark);
    expect(nativeBrightnessQueries, 2);
  });

  testWidgets('Auto theme corrects a stale light startup value on macOS',
      (tester) async {
    const channel = MethodChannel('mdsscope/theme');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return call.method == 'isDark' ? true : null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue();
    });
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;

    final app = AppState();
    await app.preferencesReady;
    app.themeMode = 2;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MdsScopeApp(),
      ),
    );
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.light);

    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark);

    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark);
  });

  testWidgets('Tapping empty main-page space dismisses the Shot keyboard',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: MainPage()),
      ),
    );

    final shotField = find.descendant(
      of: find.byKey(const ValueKey('toolbar-shot-entry')),
      matching: find.byType(TextField),
    );
    final shotEditable = find.descendant(
      of: shotField,
      matching: find.byType(EditableText),
    );
    await tester.tap(shotField);
    await tester.pump();
    expect(
      tester.widget<EditableText>(shotEditable).focusNode.hasFocus,
      isTrue,
    );
    expect(tester.testTextInput.isVisible, isTrue);

    final toolbarDivider = find.descendant(
      of: find.byKey(const ValueKey('toolbar-root')),
      matching: find.byType(Divider),
    );
    await tester.tap(toolbarDivider.first);
    await tester.pump();

    expect(
      tester.widget<EditableText>(shotEditable).focusNode.hasFocus,
      isFalse,
    );
    expect(tester.testTextInput.isVisible, isFalse);
  });

  test('Manual application settings survive an application restart', () async {
    SharedPreferences.setMockInitialValues({
      'shotHistory': '["163700","163699"]',
    });

    final first = AppState();
    await first.preferencesReady;
    first.dataMode = 2;
    first.interactionMode = 1;
    first.themeMode = 0;
    first.toolbarCollapsed = true;
    first.shotText = '163701';
    first.applyFontSettings('Courier New', 17, 14, 13, 16);
    first.addWebBookmark('Status', 'http://10.0.0.8/status');
    first.applyLayoutList([1, 2]);
    first.columns[0][0]['title'] = 'Saved panel';
    first.columns[0][0]['custom_x_range'] = true;
    first.columns[0][0]['xmin'] = double.nan;
    first.rebuild();
    await first.savePreferences();

    final second = AppState();
    await second.preferencesReady;

    expect(second.dataMode, 2);
    expect(second.interactionMode, 1);
    expect(second.themeMode, 0);
    expect(second.toolbarCollapsed, isTrue);
    expect(second.shotText, '163701');
    expect(second.fontFamily, 'Courier New');
    expect(second.fontLegendSize, 17);
    expect(second.webBookmarks, [
      {'Status': 'http://10.0.0.8/status'}
    ]);
    expect(second.shotHistory, ['163700', '163699']);
    expect(second.columns.map((column) => column.length), [1, 2]);
    expect(second.columns[0][0]['title'], 'Saved panel');
    expect(second.columns[0][0]['xmin'], isNull);
  });

  test('Shot history retention is bounded, optional, and persisted', () async {
    final history = List<String>.generate(55, (index) => '${170000 - index}');
    SharedPreferences.setMockInitialValues({
      'shotHistory': jsonEncode(history),
    });

    final first = AppState();
    await first.preferencesReady;
    addTearDown(first.dispose);

    expect(first.limitShotHistory, isTrue);
    expect(first.shotHistoryLimit, AppState.defaultShotHistoryLimit);
    expect(first.shotHistory, history.take(50));

    first.setShotHistoryLimit(3);
    expect(first.shotHistory, history.take(3));

    first.setShotHistoryRetentionEnabled(false);
    first.setShotHistoryLimit(1);
    expect(first.shotHistory, history.take(3));
    await first.savePreferences();

    final second = AppState();
    await second.preferencesReady;
    addTearDown(second.dispose);
    expect(second.limitShotHistory, isFalse);
    expect(second.shotHistoryLimit, 1);
    expect(second.shotHistory, history.take(3));

    second.setShotHistoryRetentionEnabled(true);
    expect(second.shotHistory, history.take(1));
    second.restoreDefaultShotHistoryLimit();
    expect(second.shotHistoryLimit, AppState.defaultShotHistoryLimit);
    expect(second.shotHistory, history.take(1));
  });

  test('Configuration open accepts desktop paths and mobile file bytes',
      () async {
    const parsedConfig = '{"columns":[[{"title":"Opened panel","x_label":"s",'
        '"y_label":"A","signal_specs":[{"y_expr":"\\\\ip"}]}]]}';
    String? desktopParsedPath;
    final desktop = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'desktop.toml',
        path: '/chosen/desktop.toml',
      ),
      configParser: (path) {
        desktopParsedPath = path;
        return parsedConfig;
      },
    );
    await desktop.preferencesReady;
    await desktop.openFile();
    expect(desktopParsedPath, '/chosen/desktop.toml');
    expect(desktop.columns[0][0]['title'], 'Opened panel');
    expect(desktop.status, contains('Loaded: desktop.toml'));

    final originalBytes = Uint8List.fromList(utf8.encode('mobile config'));
    String? temporaryPath;
    final mobile = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'mobile.toml',
        bytes: originalBytes,
      ),
      configParser: (path) {
        temporaryPath = path;
        expect(File(path).readAsBytesSync(), originalBytes);
        return parsedConfig;
      },
    );
    await mobile.preferencesReady;
    await mobile.openFile();
    expect(mobile.columns[0][0]['title'], 'Opened panel');
    expect(temporaryPath, isNotNull);
    expect(File(temporaryPath!).existsSync(), isFalse);
  });

  test('Configuration save hands complete TOML bytes to the file dialog',
      () async {
    String? encodedJson;
    String? suggestedName;
    Uint8List? savedBytes;
    final expectedBytes = Uint8List.fromList(utf8.encode('title = "Saved"'));
    final app = AppState(
      configEncoder: (configJson) async {
        encodedJson = configJson;
        return expectedBytes;
      },
      configSavePicker: (name, bytes) async {
        suggestedName = name;
        savedBytes = bytes;
        return 'content://documents/config.toml';
      },
    );
    await app.preferencesReady;
    app.shotText = '143850';

    await app.saveFile();

    expect(suggestedName, 'config.toml');
    expect(savedBytes, expectedBytes);
    expect(jsonDecode(encodedJson!)['columns'], isNotEmpty);
    expect(jsonDecode(encodedJson!)['shot'], '143850');
    expect(app.status, 'Saved to config.toml');
  });

  test('Configuration save materializes every per-curve data source field',
      () async {
    String? encodedJson;
    final app = AppState(
      configEncoder: (configJson) async {
        encodedJson = configJson;
        return Uint8List.fromList(utf8.encode('version = 1'));
      },
      configSavePicker: (_, __) async => '/saved/complete.toml',
    );
    await app.preferencesReady;
    app.shotText = '163900';
    app.dataMode = 1;
    app.columns[0][0]['signal_specs'] = [
      {
        'shot': '163899',
        'y_expr': r'\FIRST',
        'x_expr': 'dim_of(\\FIRST)',
        'experiment': 'tree_a',
        'server_ip': '10.0.0.1',
        'color_name': '#123456',
        'manual_color': true,
        'hidden': true,
        'hide_mode': signalHideModePersistent,
        'read_mode': 2,
      },
      {
        'y_expr': r'\SECOND',
        'experiment': 'tree_b',
        'server_ip': '10.0.0.2',
      },
    ];

    await app.saveFile();

    final signals = (jsonDecode(encodedJson!)['columns'][0][0]['signal_specs'])
        as List<dynamic>;
    expect(signals, hasLength(2));
    expect(signals[0], {
      'shot': '163899',
      'y_expr': r'\FIRST',
      'x_expr': 'dim_of(\\FIRST)',
      'legend': '',
      'experiment': 'tree_a',
      'server_ip': '10.0.0.1',
      'color_name': '#123456',
      'manual_color': true,
      'hidden': true,
      'hide_mode': signalHideModePersistent,
      'read_mode': 2,
    });
    expect(signals[1], {
      'shot': '163900',
      'y_expr': r'\SECOND',
      'x_expr': '',
      'legend': '',
      'experiment': 'tree_b',
      'server_ip': '10.0.0.2',
      'color_name': '#c44e52',
      'manual_color': false,
      'hidden': false,
      'hide_mode': signalHideModeVisible,
      'read_mode': 1,
    });
  });

  test('Opening a portable configuration restores its shot and fetches data',
      () async {
    String? requestedConfig;
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'portable.toml',
        bytes: Uint8List(0),
      ),
      configParser: (_) => '{"shot":"143850","columns":[[{"title":"Ip",'
          '"signal_specs":[{"y_expr":"\\\\pcrl01","experiment":"pcs_east",'
          '"server_ip":"202.127.204.12"}]}]]}',
      signalFetchWorker: (configJson, _, __) async {
        requestedConfig = configJson;
        return '[{"column":0,"row":0,"signal":0,"shot":"143850",'
            '"series":{"error":"","points":[[0.0,1.0]]}}]';
      },
    );
    await app.preferencesReady;
    app.setLoggedIn(true, 'test-token');

    await app.openFile(importedShotDecision: (_) async => true);
    await Future<void>.delayed(Duration.zero);

    expect(app.shotText, '143850');
    expect(jsonDecode(requestedConfig!)['columns'][0][0]['shot'], '143850');
    expect(app.plots.single.series.single?.points, [
      [0.0, 1.0]
    ]);
  });

  test('Imported shots are ignored by default at every configuration level',
      () async {
    String? requestedConfig;
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'layout-only.toml',
        bytes: Uint8List(0),
      ),
      configParser: (_) =>
          '{"shot":"143850","columns":[[{"title":"Signals","shot":"143851",'
          '"signal_specs":['
          '{"shot":"143852","y_expr":"\\\\first","experiment":"pcs_east"},'
          '{"shot":"143853","y_expr":"\\\\second","experiment":"pcs_east"}'
          ']}]]}',
      signalFetchWorker: (configJson, _, __) async {
        requestedConfig = configJson;
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163999';

    await app.openFile();

    expect(app.shotText, '163999');
    expect(app.columns.single.single.containsKey('shot'), isFalse);
    final storedSignals =
        app.columns.single.single['signal_specs'] as List<dynamic>;
    expect(
      storedSignals.every((signal) => (signal as Map)['shot'] == '163999'),
      isTrue,
    );

    final requestedPanel =
        jsonDecode(requestedConfig!)['columns'][0][0] as Map<String, dynamic>;
    expect(requestedPanel['shot'], '163999');
    final requestedSignals = requestedPanel['signal_specs'] as List<dynamic>;
    expect(
      requestedSignals.every((signal) => (signal as Map)['shot'] == '163999'),
      isTrue,
    );
  });

  test('A newly loaded shot overrides every imported per-signal shot',
      () async {
    final requestedConfigs = <Map<String, dynamic>>[];
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'switchable.toml',
        bytes: Uint8List(0),
      ),
      configParser: (_) =>
          '{"shot":"143850","columns":[[{"title":"Signals","shot":"143850",'
          '"signal_specs":['
          '{"shot":"143850","y_expr":"\\\\inherit","experiment":"pcs_east",'
          '"server_ip":"202.127.204.12"},'
          '{"shot":"143849","y_expr":"\\\\fixed","experiment":"pcs_east",'
          '"server_ip":"202.127.204.12"}]}]]}',
      signalFetchWorker: (configJson, _, __) async {
        final config = Map<String, dynamic>.from(jsonDecode(configJson) as Map);
        requestedConfigs.add(config);
        final panel = (config['columns'] as List).first.first as Map;
        final panelShot = panel['shot'].toString();
        final signals = panel['signal_specs'] as List;
        final fixedShot = (signals[1] as Map)['shot']?.toString() ?? panelShot;
        return jsonEncode([
          {
            'column': 0,
            'row': 0,
            'signal': 0,
            'shot': panelShot,
            'series': {
              'error': '',
              'points': [
                [0.0, 1.0]
              ]
            }
          },
          {
            'column': 0,
            'row': 0,
            'signal': 1,
            'shot': fixedShot,
            'series': {
              'error': '',
              'points': [
                [0.0, 2.0]
              ]
            }
          }
        ]);
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');

    await app.openFile(importedShotDecision: (_) async => true);
    expect(app.displayedShot, '143850');
    var requestedPanel =
        (requestedConfigs.single['columns'] as List).first.first as Map;
    expect(requestedPanel['shot'], '143850');
    var requestedSignals = requestedPanel['signal_specs'] as List;
    expect((requestedSignals[0] as Map)['shot'], '143850');
    expect((requestedSignals[1] as Map)['shot'], '143850');

    app.shotText = '163999';
    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    expect(app.displayedShot, '163999');
    expect(requestedConfigs, hasLength(2));
    requestedPanel =
        (requestedConfigs.last['columns'] as List).first.first as Map;
    expect(requestedPanel['shot'], '163999');
    requestedSignals = requestedPanel['signal_specs'] as List;
    expect((requestedSignals[0] as Map)['shot'], '163999');
    expect((requestedSignals[1] as Map)['shot'], '163999');
  });

  test(
      'Full shot loads override signal Shot and Data and reset temporary hiding',
      () async {
    String? requestedConfig;
    String? requestedDataMode;
    final app = AppState(
      signalFetchWorker: (configJson, dataMode, _) async {
        requestedConfig = configJson;
        requestedDataMode = dataMode;
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.columns[0][0]['signal_specs'] = [
      {
        'shot': '100001',
        'read_mode': 2,
        'hide_mode': signalHideModeTemporary,
        'hidden': true,
        'experiment': 'tree_a',
        'y_expr': r'\FIRST',
        'legend': 'First',
        'server_ip': '10.0.0.1',
        'color_name': '#123456',
      },
      {
        'shot': '100002',
        'read_mode': 0,
        'hide_mode': signalHideModePersistent,
        'hidden': true,
        'experiment': 'tree_b',
        'y_expr': r'\SECOND',
        'legend': 'Second',
        'server_ip': '10.0.0.2',
        'color_name': '#654321',
      },
    ];
    app.dataMode = 1;
    app.shotText = '170001';

    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    expect(requestedDataMode, '1');
    final signals =
        jsonDecode(requestedConfig!)['columns'][0][0]['signal_specs'] as List;
    expect(signals.map((signal) => (signal as Map)['shot']),
        everyElement('170001'));
    expect(
        signals.map((signal) => (signal as Map)['read_mode']), everyElement(1));
    expect((signals[0] as Map)['hide_mode'], signalHideModeVisible);
    expect((signals[0] as Map)['hidden'], isFalse);
    expect((signals[1] as Map)['hide_mode'], signalHideModePersistent);
    expect((signals[1] as Map)['hidden'], isTrue);
    expect((signals[0] as Map)['experiment'], 'tree_a');
    expect((signals[0] as Map)['y_expr'], r'\FIRST');
    expect((signals[0] as Map)['legend'], 'First');
    expect((signals[0] as Map)['server_ip'], '10.0.0.1');
    expect((signals[0] as Map)['color_name'], '#123456');

    final stored = app.columns[0][0]['signal_specs'] as List;
    expect((stored[0] as Map)['shot'], '170001');
    expect((stored[0] as Map)['read_mode'], 1);
    expect((stored[0] as Map)['hide_mode'], signalHideModeVisible);
    expect((stored[1] as Map)['hide_mode'], signalHideModePersistent);
  });

  test('Rate refresh preserves X range and resets Y range', () async {
    final app = AppState(
      signalFetchWorker: (_, __, ___) async => '[]',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '170001';
    app.plots.first.setViewRange(0.25, 0.75, -4, 8);
    final fullReset = app.viewResetId;
    final rateReset = app.rateViewResetId;

    app.dataMode = 1;
    app.startRateRefresh();
    await Future<void>.delayed(Duration.zero);

    expect(app.viewResetId, fullReset);
    expect(app.rateViewResetId, rateReset + 1);
    expect(app.plots.first.viewMinX, 0.25);
    expect(app.plots.first.viewMaxX, 0.75);
    expect(app.plots.first.viewMinY, isNull);
    expect(app.plots.first.viewMaxY, isNull);
  });

  test(
      'A configuration imported before login keeps its shot and loads after login',
      () async {
    var latestShotRequests = 0;
    String? requestedConfig;
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'before-login.toml',
        bytes: Uint8List(0),
      ),
      configParser: (_) => '{"shot":"163807","columns":[[{"title":"Ip",'
          '"signal_specs":[{"y_expr":"\\\\pcrl01","experiment":"pcs_east",'
          '"server_ip":"202.127.204.12"}]}]]}',
      loginWorker: (_, __, ___, ____) async =>
          (token: 'test-token', usedSsh: false),
      latestShotWorker: (_, __, ___) async {
        latestShotRequests++;
        return {'shot': 999999};
      },
      signalFetchWorker: (configJson, _, __) async {
        requestedConfig = configJson;
        return '[{"column":0,"row":0,"signal":0,"shot":"163807",'
            '"series":{"error":"","points":[[0.0,7.0]]}}]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);

    await app.openFile(importedShotDecision: (_) async => true);
    expect(app.loggedIn, isFalse);
    expect(app.status, contains('Sign in to load shot 163807'));

    await app.loginAndLoadLatest(
      apiUrl: 'http://east.example/api',
      user: 'user',
      password: 'password',
    );

    expect(latestShotRequests, 0);
    expect(app.shotText, '163807');
    expect(app.displayedShot, '163807');
    expect(jsonDecode(requestedConfig!)['columns'][0][0]['shot'], '163807');
    expect(app.plots.single.series.single?.points, [
      [0.0, 7.0]
    ]);
  });

  test(
      'Manual login reloads the entered shot instead of replacing it with latest',
      () async {
    var latestShotRequests = 0;
    String? requestedConfig;
    final app = AppState(
      loginWorker: (_, __, ___, ____) async =>
          (token: 'test-token', usedSsh: false),
      latestShotWorker: (_, __, ___) async {
        latestShotRequests++;
        return {'shot': 999999};
      },
      signalFetchWorker: (configJson, _, __) async {
        requestedConfig = configJson;
        return '[{"column":0,"row":0,"signal":0,"shot":"170123",'
            '"series":{"error":"","points":[[0.0,7.0]]}}]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.shotText = '170123';

    await app.loginAndLoadLatest(
      apiUrl: 'http://east.example/api',
      user: 'user',
      password: 'password',
    );

    expect(latestShotRequests, 0);
    expect(app.shotText, '170123');
    expect(app.displayedShot, '170123');
    expect(jsonDecode(requestedConfig!)['columns'][0][0]['shot'], '170123');
  });

  test('Imported zero-point panels are repaired before waveform loading',
      () async {
    String? requestedConfig;
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'iphone-config.toml',
        bytes: Uint8List(0),
      ),
      configParser: (_) => '{"shot":"163870","columns":[[{"title":"Ip",'
          '"extraction_points":0,"grid":false,'
          '"signal_specs":[{"y_expr":"\\\\pcrl01","experiment":"pcs_east",'
          '"server_ip":"202.127.204.12"}]}]]}',
      signalFetchWorker: (configJson, _, __) async {
        requestedConfig = configJson;
        return '[{"column":0,"row":0,"signal":0,"shot":"163870",'
            '"series":{"error":"","points":[[0.0,1.0],[1.0,2.0]]}}]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');

    await app.openFile(importedShotDecision: (_) async => true);

    final requestedPanel =
        jsonDecode(requestedConfig!)['columns'][0][0] as Map<String, dynamic>;
    expect(requestedPanel['extraction_points'], 2000);
    expect(requestedPanel['grid'], isFalse);
    expect(app.plots.single.series.single?.points, hasLength(2));
  });

  test('Waveform decoding keeps finite samples and skips null coordinates',
      () async {
    final app = AppState(
      signalFetchWorker: (_, __, ___) async =>
          '[{"column":0,"row":0,"signal":0,"series":{"error":"","points":'
          '[[null,1.0],[0.0,null],["bad",2.0],[1.0,3.0],[2.0,4.0]]}}]',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163870';

    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    expect(app.plots.first.series.first?.points, [
      [1.0, 3.0],
      [2.0, 4.0],
    ]);
    expect(app.status, isNot(contains("type 'Null'")));
  });

  test('Uniform high-resolution payloads preserve samples and axis metadata',
      () async {
    final app = AppState(
      signalFetchWorker: (_, __, ___) async =>
          '[{"column":0,"row":0,"signal":0,"series":{"error":"","points":[],'
          '"uniform_y":[1.0,2.0,3.0],"uniform_start":-0.1,'
          '"uniform_step":0.0001,"unit":"kA","x_name":"time",'
          '"x_unit":"s"}}]',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163870';

    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    final series = app.plots.first.series.first;
    expect(series?.points, [
      [-0.1, 1.0],
      [-0.0999, 2.0],
      [-0.0998, 3.0],
    ]);
    expect(series?.unit, 'kA');
    expect(series?.xName, 'time');
    expect(series?.xUnit, 's');
  });

  test('A signal with no finite samples reports a meaningful data error',
      () async {
    final app = AppState(
      signalFetchWorker: (_, __, ___) async =>
          '[{"column":0,"row":0,"signal":0,"series":{"error":"","points":'
          '[[null,1.0],[0.0,null]]}}]',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163870';

    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    expect(
      app.plots.first.series.first?.error,
      contains('no finite numeric samples'),
    );
    expect(app.status, contains('no finite numeric samples'));
  });

  test('Imported layouts load every panel beyond the built-in six', () async {
    final columns = List.generate(
      3,
      (column) => List.generate(
        3,
        (row) => {
          'title': 'Panel ${column * 3 + row + 1}',
          'signal_specs': [
            {
              'y_expr': '\\signal_${column}_$row',
              'experiment': 'pcs_east',
              'server_ip': '202.127.204.12',
            },
          ],
        },
      ),
    );
    final loadedSignals = [
      for (var column = 0; column < columns.length; column++)
        for (var row = 0; row < columns[column].length; row++)
          {
            'column': column,
            'row': row,
            'signal': 0,
            'shot': '163807',
            'series': {
              'error': '',
              'points': [
                [0.0, (column * 3 + row + 1).toDouble()],
              ],
            },
          },
    ];
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'nine-panels.toml',
        bytes: Uint8List(0),
      ),
      configParser: (_) => jsonEncode({
        'shot': '163807',
        'columns': columns,
      }),
      signalFetchWorker: (_, __, ___) async => jsonEncode(loadedSignals),
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');

    await app.openFile(importedShotDecision: (_) async => true);
    await Future<void>.delayed(Duration.zero);

    expect(app.plots, hasLength(9));
    expect(
      app.plots.map((plot) => plot.series.single?.points?.single.last).toList(),
      [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0],
    );
    expect(app.status, contains('9 panels with data'));
  });

  test('Cross-platform saver writes desktop paths and supplies mobile bytes',
      () async {
    final directory = await Directory.systemTemp.createTemp('mdsscope-test-');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    Uint8List? desktopDialogBytes;
    final desktopPath = await saveBytesWithFilePicker(
      dialogTitle: 'Save',
      fileName: 'config.toml',
      allowedExtensions: const ['toml'],
      bytes: bytes,
      mobileOverride: false,
      saveDialog: (payload) async {
        desktopDialogBytes = payload;
        return '${directory.path}/desktop-config';
      },
    );
    expect(desktopDialogBytes, isNull);
    expect(desktopPath, endsWith('.toml'));
    expect(await File(desktopPath!).readAsBytes(), bytes);

    Uint8List? mobileDialogBytes;
    final mobilePath = await saveBytesWithFilePicker(
      dialogTitle: 'Save',
      fileName: 'config.toml',
      allowedExtensions: const ['toml'],
      bytes: bytes,
      mobileOverride: true,
      saveDialog: (payload) async {
        mobileDialogBytes = payload;
        return 'content://documents/mobile-config.toml';
      },
    );
    expect(mobileDialogBytes, bytes);
    expect(mobilePath, 'content://documents/mobile-config.toml');
  });

  testWidgets('Open and Save toolbar buttons invoke working file flows',
      (tester) async {
    var openCalls = 0;
    var saveCalls = 0;
    final app = AppState(
      configOpenPicker: () async {
        openCalls++;
        return const ConfigOpenSelection(name: 'toolbar.toml', path: '/x');
      },
      configParser: (_) =>
          '{"columns":[[{"title":"Toolbar open","signal_specs":[]}]]}',
      configEncoder: (_) async => Uint8List.fromList([10, 20]),
      configSavePicker: (_, bytes) async {
        saveCalls++;
        expect(bytes, [10, 20]);
        return '/saved/config.toml';
      },
    );
    await app.preferencesReady;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Open configuration'));
    await tester.pumpAndSettle();
    expect(openCalls, 1);
    expect(app.columns[0][0]['title'], 'Toolbar open');

    await tester.tap(find.byTooltip('Save configuration'));
    await tester.pumpAndSettle();
    expect(saveCalls, 1);
    expect(app.status, 'Saved to config.toml');
  });

  testWidgets('Configuration import asks before applying its shot',
      (tester) async {
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'with-shot.toml',
        path: '/with-shot.toml',
      ),
      configParser: (_) =>
          '{"shot":"143850","columns":[[{"title":"Imported layout",'
          '"signal_specs":[]}]]}',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.shotText = '163999';
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Open configuration'));
    await tester.pumpAndSettle();

    expect(find.text('Use the configuration shot?'), findsOneWidget);
    expect(find.textContaining('143850'), findsWidgets);
    final ignoreButton = find.byKey(
      const ValueKey('ignore-imported-configuration-shot'),
    );
    expect(tester.widget<FilledButton>(ignoreButton).autofocus, isTrue);

    await tester.tap(ignoreButton);
    await tester.pumpAndSettle();

    expect(app.shotText, '163999');
    expect(app.columns.single.single['title'], 'Imported layout');
  });

  testWidgets('Toolbar restores and persists the default waveform layout',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    app.applyLayout(1, 1);
    expect(app.columns, hasLength(1));

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );
    await tester.tap(find.byTooltip('Restore default configuration'));
    await tester.pumpAndSettle();

    expect(find.text('Restore default configuration?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('restore-default-cancel')));
    await tester.pumpAndSettle();
    expect(app.columns, hasLength(1));

    await tester.tap(find.byTooltip('Restore default configuration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('restore-default-confirm')));
    await tester.pumpAndSettle();

    expect(app.columns, hasLength(2));
    expect(app.columns.map((column) => column.length), [3, 3]);
    expect(app.plots.map((plot) => plot.title),
        ['Ip', 'R', 'Z', 'Vloop', 'Ne', 'Pf1 current']);

    final restored = AppState();
    await restored.preferencesReady;
    expect(restored.columns, hasLength(2));
    expect(restored.columns.map((column) => column.length), [3, 3]);
  });

  test('Waveform loading stays interactive and discards stale results',
      () async {
    final pending = <Completer<String>>[];
    final requestedConfigs = <String>[];
    final app = AppState(
      signalFetchWorker: (configJson, dataMode, sshSettings) {
        requestedConfigs.add(configJson);
        final result = Completer<String>();
        pending.add(result);
        return result.future;
      },
    );
    await app.preferencesReady;
    app.setLoggedIn(true, 'test-token');
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 10],
          [1, 11]
        ],
        null);

    app.shotText = '163701';
    app.startRefresh();
    expect(app.fetching, isTrue);
    expect(pending, hasLength(1));
    expect(requestedConfigs.single, contains('163701'));

    app.interactionMode = 1;
    expect(app.interactionMode, 1);
    expect(app.fetching, isTrue);
    expect(app.plots[0].series[0]!.points![0][1], 10);

    app.shotText = '163702';
    expect(app.fetching, isFalse);
    app.startRefresh();
    expect(app.fetching, isTrue);
    expect(pending, hasLength(2));
    expect(requestedConfigs.last, contains('163702'));

    pending[0].complete(
      '[{"column":0,"row":0,"signal":0,'
      '"series":{"points":[[0,111],[1,112]],"error":""}}]',
    );
    await Future<void>.delayed(Duration.zero);
    expect(app.fetching, isTrue);
    expect(app.plots[0].series[0]!.points![0][1], 10);

    pending[1].complete(
      '[{"column":0,"row":0,"signal":0,'
      '"series":{"points":[[0,222],[1,223]],"error":""}}]',
    );
    await Future<void>.delayed(Duration.zero);
    expect(app.fetching, isFalse);
    expect(app.plots[0].series[0]!.points![0][1], 222);
    expect(app.status, contains('163702'));
  });

  test('Refresh reloads the displayed shot instead of the shot input',
      () async {
    final requestedConfigs = <String>[];
    final app = AppState(
      signalFetchWorker: (configJson, dataMode, sshSettings) async {
        requestedConfigs.add(configJson);
        return '[{"column":0,"row":0,"signal":0,'
            '"series":{"points":[[0,1],[1,2]],"error":""}}]';
      },
    );
    await app.preferencesReady;
    app.setLoggedIn(true, 'test-token');

    app.shotText = '163701';
    app.startRefresh();
    await Future<void>.delayed(Duration.zero);
    expect(app.displayedShot, '163701');

    app.shotText = '999999';
    app.refreshDisplayedShot();
    await Future<void>.delayed(Duration.zero);

    expect(requestedConfigs, hasLength(2));
    expect(requestedConfigs.last, contains('163701'));
    expect(requestedConfigs.last, isNot(contains('999999')));
    expect(app.shotText, '999999');
    expect(app.displayedShot, '163701');
    expect(app.status, contains('163701'));
  });

  testWidgets('Waveform panels show Loading while keeping existing curves',
      (tester) async {
    final pending = Completer<String>();
    final app = AppState(
      signalFetchWorker: (configJson, dataMode, sshSettings) => pending.future,
    );
    await app.preferencesReady;
    app.setLoggedIn(true, 'test-token');
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 10],
          [1, 11],
        ],
        null);
    app.shotText = '163701';
    app.startRefresh();

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
              body: SizedBox(
                  width: 320, height: 240, child: PlotPanel(plotIdx: 0))),
        ),
      ),
    );

    expect(find.byType(LineChart), findsOneWidget);
    expect(find.byKey(const ValueKey('plot-loading-0')), findsOneWidget);
    expect(find.text('Loading...'), findsOneWidget);

    pending.complete(
      '[{"column":0,"row":0,"signal":0,'
      '"series":{"points":[[0,20],[1,21]],"error":""}}]',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plot-loading-0')), findsNothing);
    expect(find.byType(LineChart), findsOneWidget);
  });

  testWidgets('Single panel reload loads only its target panel',
      (tester) async {
    final pending = Completer<String>();
    String? requestedConfig;
    final app = AppState(
      signalFetchWorker: (configJson, dataMode, sshSettings) {
        requestedConfig = configJson;
        return pending.future;
      },
    );
    await app.preferencesReady;
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163701';

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                Expanded(child: PlotPanel(plotIdx: 0)),
                Expanded(child: PlotPanel(plotIdx: 1)),
              ],
            ),
          ),
        ),
      ),
    );

    unawaited(app.fetchSinglePanel(1));
    await tester.pump();

    expect(find.byKey(const ValueKey('plot-loading-0')), findsNothing);
    expect(find.byKey(const ValueKey('plot-loading-1')), findsOneWidget);
    final config = jsonDecode(requestedConfig!) as Map<String, dynamic>;
    final columns = config['columns'] as List;
    expect(
      ((columns[0] as List)[0] as Map)['signal_specs'],
      isEmpty,
    );
    expect(
      ((columns[0] as List)[1] as Map)['signal_specs'],
      isNotEmpty,
    );
    expect(
      ((columns[1] as List)[0] as Map)['signal_specs'],
      isEmpty,
    );

    pending.complete(
      '[{"column":0,"row":1,"signal":0,'
      '"series":{"points":[[0,20],[1,21]],"error":""}}]',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plot-loading-1')), findsNothing);
    expect(app.plots[1].series[0]?.points, [
      [0, 20],
      [1, 21],
    ]);
  });

  test('Logout preserves loaded data and blocks authenticated operations',
      () async {
    var signalRequests = 0;
    var latestRequests = 0;
    final app = AppState(
      signalFetchWorker: (configJson, dataMode, sshSettings) async {
        signalRequests++;
        return '[]';
      },
      latestShotWorker: (apiUrl, token, sshSettings) async {
        latestRequests++;
        return {'shot': 170100};
      },
    );
    await app.preferencesReady;
    app.setLoggedIn(true, 'valid-token');
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 12],
          [1, 13],
        ],
        null);

    app.logout();
    app.startRefresh();
    await app.fetchLatestShot();

    expect(app.hasActiveSession, isFalse);
    expect(signalRequests, 0);
    expect(latestRequests, 0);
    expect(app.plots[0].series[0]!.points, [
      [0, 12],
      [1, 13],
    ]);
    expect(app.status, contains('Login required'));
  });

  test('Explicit logout suppresses automatic sign-in after restart', () async {
    SharedPreferences.setMockInitialValues({
      'rememberLogin': true,
      'explicitlyLoggedOut': true,
      'loginApiUrl': 'http://east.example/api',
      'loginUser': 'saved-user',
      'loginPass': 'saved-password',
      'loggedIn': false,
    });
    var loginRequests = 0;
    final app = AppState(
      loginWorker: (apiUrl, user, password, sshSettings) async {
        loginRequests++;
        return (token: 'unexpected-token', usedSsh: false);
      },
    );

    await app.initializeStartupSession();

    expect(loginRequests, 0);
    expect(app.hasActiveSession, isFalse);
  });

  testWidgets('Signed-in account button opens a login panel with real logout',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    app.setLoggedIn(true, 'valid-token');
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    expect(find.byTooltip('Account — signed in'), findsOneWidget);
    await tester.tap(find.byTooltip('Account — signed in'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('login-api-url')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-username')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-dialog-login')), findsOneWidget);
    expect(find.byKey(const ValueKey('login-dialog-logout')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('login-dialog-logout')));
    await tester.pump();
    expect(app.hasActiveSession, isFalse);
    final logout = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('login-dialog-logout')),
    );
    expect(logout.onPressed, isNull);
    expect(find.text('Signed out'), findsOneWidget);
  });

  testWidgets('Login and SSH dialogs scroll above a virtual keyboard',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 700);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Login'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();

    final loginScroll = find.descendant(
      of: find.byKey(const ValueKey('keyboard-safe-dialog-scroll')),
      matching: find.byType(Scrollable),
    );
    expect(loginScroll, findsWidgets);
    expect(
      tester.state<ScrollableState>(loginScroll.first).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(tester.getSize(find.byKey(const ValueKey('login-password'))).height,
        greaterThanOrEqualTo(48));
    expect(
      tester
          .getBottomRight(find.byKey(const ValueKey('login-dialog-login')))
          .dy,
      lessThanOrEqualTo(340),
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('SSH tunnel'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();

    final sshScroll = find.descendant(
      of: find.byKey(const ValueKey('keyboard-safe-dialog-scroll')),
      matching: find.byType(Scrollable),
    );
    expect(sshScroll, findsWidgets);
    expect(
      tester.state<ScrollableState>(sshScroll.first).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(tester.getSize(find.byKey(const ValueKey('ssh-host'))).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byKey(const ValueKey('ssh-password'))).height,
        greaterThanOrEqualTo(48));
    expect(tester.getBottomRight(find.text('Save')).dy, lessThanOrEqualTo(340));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Credential fields keep the secure keyboard focus transition',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Login'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('login-username')));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump(const Duration(milliseconds: 100));

    final loginPassword = tester.widget<TextField>(
      find.byKey(const ValueKey('login-password')),
    );
    expect(loginPassword.focusNode?.hasFocus, isTrue);
    expect(loginPassword.keyboardType, TextInputType.visiblePassword);
    expect(loginPassword.enableSuggestions, isFalse);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('SSH tunnel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ssh-user')));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump(const Duration(milliseconds: 100));

    final sshPassword = tester.widget<TextField>(
      find.byKey(const ValueKey('ssh-password')),
    );
    expect(sshPassword.focusNode?.hasFocus, isTrue);
    expect(sshPassword.keyboardType, TextInputType.visiblePassword);
    expect(sshPassword.enableSuggestions, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Credential form labels have room without keyboard compression',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Login'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('login-username'))).dy -
          tester.getBottomLeft(find.byKey(const ValueKey('login-api-url'))).dy,
      greaterThanOrEqualTo(12),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('login-password'))).dy -
          tester.getBottomLeft(find.byKey(const ValueKey('login-username'))).dy,
      greaterThanOrEqualTo(12),
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('login-password'))).height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = FakeViewPadding.zero;

    await tester.tap(find.byTooltip('SSH tunnel'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('ssh-user'))).dy -
          tester.getBottomLeft(find.byKey(const ValueKey('ssh-host'))).dy,
      greaterThanOrEqualTo(12),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('ssh-password'))).dy -
          tester.getBottomLeft(find.byKey(const ValueKey('ssh-user'))).dy,
      greaterThanOrEqualTo(12),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('ssh-identity'))).dy -
          tester.getBottomLeft(find.byKey(const ValueKey('ssh-password'))).dy,
      greaterThanOrEqualTo(12),
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 360);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byKey(const ValueKey('ssh-password'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('SSH dialog preserves a manually entered identity file path',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('SSH tunnel'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ssh-identity')),
      '  ~/.ssh/id_ed25519  ',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(app.sshIdentity, '~/.ssh/id_ed25519');
  });

  test('Identity file authorization returns the platform-authorized path',
      () async {
    const channel = MethodChannel('mdsscope/identity_file_access');
    MethodCall? receivedCall;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      receivedCall = call;
      return '/authorized/id_ed25519';
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final path = await IdentityFileAccess.authorize(
      '  ~/.ssh/id_ed25519  ',
    );

    expect(path, '/authorized/id_ed25519');
    expect(receivedCall?.method, 'authorizeIdentityFile');
    expect(receivedCall?.arguments, {
      'path': '~/.ssh/id_ed25519',
      'promptIfNeeded': true,
    });
  });

  testWidgets('SSH button lights only while a reachable tunnel is in use',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    expect(find.byTooltip('SSH tunnel'), findsOneWidget);
    app.setSshTestResult(true);
    await tester.pump();
    expect(app.sshTunnelReachable, isTrue);
    expect(app.sshConnected, isFalse);
    expect(
        find.byTooltip('SSH tunnel — reachable, not in use'), findsOneWidget);

    app.recordSshUsage(true);
    await tester.pump();
    expect(app.sshConnected, isTrue);
    expect(find.byTooltip('SSH tunnel — in use'), findsOneWidget);

    app.recordSshUsage(false);
    await tester.pump();
    expect(app.sshConnected, isFalse);
    expect(
        find.byTooltip('SSH tunnel — reachable, not in use'), findsOneWidget);

    app.setSshTestResult(false);
    await tester.pump();
    expect(find.byTooltip('SSH tunnel'), findsOneWidget);
  });

  testWidgets('SSH Test runs in the background and keeps the dialog responsive',
      (tester) async {
    final result = Completer<String>();
    String? testedSettings;
    final app = AppState(
      sshTestWorker: (settingsJson) {
        testedSettings = settingsJson;
        return result.future;
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('SSH tunnel'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ssh-host')),
      'ssh.example.com',
    );
    await tester.tap(find.byKey(const ValueKey('ssh-dialog-test')));
    await tester.pump();

    expect(find.text('Connecting...'), findsNWidgets(2));
    expect(find.byIcon(Icons.vpn_lock_rounded), findsWidgets);
    expect(testedSettings, isNotNull);

    await tester.enterText(
      find.byKey(const ValueKey('ssh-user')),
      'still-responsive',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ssh-user')))
          .controller
          ?.text,
      'still-responsive',
    );

    result.complete('{"ok":true}');
    await tester.pumpAndSettle();
    expect(find.text('Connection OK'), findsOneWidget);
    expect(find.text('Connecting...'), findsNothing);
  });

  test('Startup signs in, fetches the latest shot, and loads its waveforms',
      () async {
    SharedPreferences.setMockInitialValues({
      'rememberLogin': true,
      'loginApiUrl': 'http://east.example/api',
      'loginUser': 'saved-user',
      'loginPass': 'saved-password',
      'loggedIn': false,
    });
    final loginRequests = <String>[];
    final latestRequests = <String>[];
    final signalRequests = <String>[];
    final app = AppState(
      loginWorker: (apiUrl, user, password, sshSettings) async {
        loginRequests.add('$apiUrl|$user|$password|$sshSettings');
        return (token: 'fresh-token', usedSsh: false);
      },
      latestShotWorker: (apiUrl, token, sshSettings) async {
        latestRequests.add('$apiUrl|$token|$sshSettings');
        return {
          'shot': 170001,
          'ip': 502.13,
          'pulseLength': 5.66,
          'it': 10995,
          'currentTime': '2026-07-23 08:00:00',
        };
      },
      signalFetchWorker: (configJson, dataMode, sshSettings) async {
        signalRequests.add(configJson);
        return '[{"column":0,"row":0,"signal":0,'
            '"series":{"points":[[0,12],[1,13]],"error":""}}]';
      },
    );

    await app.initializeStartupSession();
    await Future<void>.delayed(Duration.zero);

    expect(loginRequests, [
      'http://east.example/api|saved-user|saved-password|',
    ]);
    expect(latestRequests, [
      'http://east.example/api|fresh-token|',
    ]);
    expect(signalRequests.single, contains('170001'));
    expect(app.loggedIn, isTrue);
    expect(app.authToken, 'fresh-token');
    expect(app.shotText, '170001');
    expect(app.shotInfoIp, '502.13');
    expect(app.plots[0].series[0]!.points![0], [0, 12]);
    expect(app.status, contains('170001'));
  });

  test('Automatic login falls back from direct access to an SSH tunnel',
      () async {
    SharedPreferences.setMockInitialValues({
      'rememberLogin': true,
      'loginApiUrl': 'http://east.example/api',
      'loginUser': 'saved-user',
      'loginPass': 'saved-password',
      'loggedIn': false,
      'sshMode': 1,
      'sshHost': 'gateway.example',
      'sshUser': 'ssh-user',
    });
    final loginSettings = <String>[];
    final laterSettings = <String>[];
    final app = AppState(
      loginWorker: (apiUrl, user, password, sshSettings) async {
        loginSettings.add(sshSettings);
        if (sshSettings.isEmpty) throw 'direct route unavailable';
        final settings = jsonDecode(sshSettings) as Map<String, dynamic>;
        expect(settings['mode'], 2);
        return (token: 'ssh-token', usedSsh: true);
      },
      latestShotWorker: (apiUrl, token, sshSettings) async {
        laterSettings.add(sshSettings);
        return {'shot': 170002};
      },
      signalFetchWorker: (configJson, dataMode, sshSettings) async {
        laterSettings.add(sshSettings);
        return '[{"column":0,"row":0,"signal":0,'
            '"series":{"points":[[0,1],[1,2]],"error":""}}]';
      },
    );

    await app.initializeStartupSession();
    await Future<void>.delayed(Duration.zero);

    expect(loginSettings, hasLength(2));
    expect(loginSettings.first, isEmpty);
    expect(jsonDecode(loginSettings.last)['mode'], 2);
    expect(laterSettings, hasLength(2));
    expect(
        laterSettings.every((value) => jsonDecode(value)['mode'] == 2), isTrue);
    expect(app.hasActiveSession, isTrue);
    expect(app.sshConnected, isTrue);
    expect(app.authToken, 'ssh-token');
    expect(app.displayedShot, '170002');
  });

  test('Responsive plot columns preserve order across screen sizes', () {
    final phone = buildResponsivePlotColumns([2, 1, 2], 390);
    expect(phone, hasLength(3));
    expect(phone.map((column) => column.length), [2, 1, 2]);
    expect(phone.map((column) => column.map((cell) => cell.plotIndex)), [
      [0, 1],
      [2],
      [3, 4],
    ]);

    final tablet = buildResponsivePlotColumns([2, 1, 2], 700);
    expect(tablet, hasLength(3));
    expect(tablet.map((column) => column.length), [2, 1, 2]);

    final desktop = buildResponsivePlotColumns([2, 1, 2], 1200);
    expect(desktop, hasLength(3));
    expect(desktop.map((column) => column.length), [2, 1, 2]);
  });

  test('External web URLs are normalized before cross-platform launch',
      () async {
    Uri? launchedUri;
    final opened = await openExternalWebUrl(
      '10.0.0.8/internal/status',
      opener: (uri) async {
        launchedUri = uri;
        return true;
      },
    );

    expect(opened, isTrue);
    expect(launchedUri, Uri.parse('http://10.0.0.8/internal/status'));
    expect(normalizeExternalWebUrl('ftp://10.0.0.8/file'), isNull);
  });

  testWidgets(
      'Point mode draws a synchronized horizontal crosshair in every plot',
      (tester) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 10],
          [1, 12],
          [2, 14]
        ],
        null);
    app.updatePlotSeriesByColRow(
        0,
        1,
        0,
        [
          [0, 20],
          [1, 22],
          [2, 24]
        ],
        null);
    app.interactionMode = 1;
    app.setCrosshair(1, sourcePlot: 0, sourceSeries: 0);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
              body: SizedBox(width: 900, height: 700, child: PlotGrid())),
        ),
      ),
    );

    final charts =
        tester.widgetList<LineChart>(find.byType(LineChart)).toList();
    expect(charts, hasLength(2));
    expect(charts[0].data.extraLinesData.horizontalLines.single.y, 12);
    expect(charts[1].data.extraLinesData.horizontalLines.single.y, 22);
    expect(find.byKey(const ValueKey('plot-point-marker-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('plot-point-marker-1')), findsOneWidget);
  });

  testWidgets('Plot legend uses signal names and supports custom labels',
      (tester) async {
    expect(signalLegendLabel({'y_expr': r'\PCRL01'}), 'PCRL01');
    expect(
      signalLegendLabel({'y_expr': r'\DFSDEV', 'legend': 'Density'}),
      'Density',
    );

    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.columns[0][0]['signal_specs'] = [
      {
        'y_expr': r'\PCRL01',
        'color_name': '#123456',
      },
      {
        'y_expr': r'\DFSDEV',
        'legend': 'Density',
        'color_name': '#654321',
      },
    ];
    app.updatePlotSeriesByColRow(
      0,
      0,
      0,
      [
        [0, 1],
        [1, 2],
      ],
      null,
    );
    app.updatePlotSeriesByColRow(
      0,
      0,
      1,
      [
        [0, 2],
        [1, 3],
      ],
      null,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('plot-legend-0-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('plot-legend-0-1')), findsOneWidget);
    expect(find.text('PCRL01'), findsOneWidget);
    expect(find.text('Density'), findsOneWidget);
    expect(find.text(r'\PCRL01'), findsNothing);
  });

  testWidgets('Point mode continuously follows a held touch drag',
      (tester) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);
    app.interactionMode = 1;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    final drag = await tester.startGesture(const Offset(180, 180));
    await tester.pump();
    final initialX = app.crosshairX;
    expect(initialX, isNotNull);

    await drag.moveTo(const Offset(360, 180));
    await tester.pump();
    expect(app.crosshairX, isNotNull);
    expect(app.crosshairX!, greaterThan(initialX!));

    await drag.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Escape locks Point mode globally and a plot click unlocks it',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [1, 1],
          [2, 2],
        ],
        null);
    app.interactionMode = 1;
    app.setCrosshair(0.5, sourcePlot: 0);
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MdsScopeApp(),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(app.pointLocked, isTrue);

    await tester.tap(find.byKey(const ValueKey('plot-panel-0')));
    await tester.pump();
    expect(app.pointLocked, isFalse);
    expect(app.crosshairX, isNotNull);
  });

  testWidgets('Plot title, axes, and units use customized fonts',
      (tester) async {
    final app = AppState();
    app.applyFontSettings('Courier New', 17, 14, 13, 16);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 10],
          [1, 12],
          [2, 14]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: MdsScopeTheme.light(
            fontFamily: app.effectiveFontFamily,
            uiFontSize: app.fontUiSize.toDouble(),
          ),
          home: const Scaffold(
            body:
                SizedBox(width: 500, height: 400, child: PlotPanel(plotIdx: 0)),
          ),
        ),
      ),
    );

    final title = tester.widget<Text>(find.text('Ip'));
    final xUnit = tester.widget<Text>(find.text('s'));
    final plotTexts = tester.widgetList<Text>(
      find.descendant(of: find.byType(PlotPanel), matching: find.byType(Text)),
    );
    expect(title.style?.fontFamily, 'Courier New');
    expect(title.style?.fontSize, 17);
    expect(xUnit.style?.fontSize, 13);
    expect(plotTexts.any((text) => text.style?.fontSize == 14), isTrue);
  });

  testWidgets('Two-finger gestures pan and zoom a plot in Zoom/Move mode',
      (tester) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                  width: 500, height: 400, child: PlotPanel(plotIdx: 0)),
            ),
          ),
        ),
      ),
    );

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final initialWidth = chart().data.maxX - chart().data.minX;
    final initialCenter = (chart().data.minX + chart().data.maxX) / 2;

    final first = await tester.startGesture(const Offset(220, 200), pointer: 1);
    final second =
        await tester.startGesture(const Offset(280, 200), pointer: 2);
    await tester.pump();
    await first.moveTo(const Offset(200, 200));
    await second.moveTo(const Offset(340, 200));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    final zoomedWidth = chart().data.maxX - chart().data.minX;
    final zoomedCenter = (chart().data.minX + chart().data.maxX) / 2;
    expect(zoomedWidth, lessThan(initialWidth));
    expect((zoomedCenter - initialCenter).abs(), greaterThan(0.01));

    final centerBeforePan = (chart().data.minX + chart().data.maxX) / 2;
    final panFirst =
        await tester.startGesture(const Offset(220, 200), pointer: 3);
    final panSecond =
        await tester.startGesture(const Offset(280, 200), pointer: 4);
    await tester.pump();
    await panFirst.moveBy(const Offset(40, 0));
    await panSecond.moveBy(const Offset(40, 0));
    await tester.pump();
    await panFirst.up();
    await panSecond.up();
    await tester.pump();

    final centerAfterPan = (chart().data.minX + chart().data.maxX) / 2;
    expect(centerAfterPan, lessThan(centerBeforePan));
  });

  testWidgets('Trackpad pan/zoom events pan and zoom a plot together',
      (tester) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final initialWidth = chart().data.maxX - chart().data.minX;
    final initialCenter = (chart().data.minX + chart().data.maxX) / 2;
    final trackpadListener = find.byWidgetPredicate(
      (widget) => widget is Listener && widget.onPointerPanZoomUpdate != null,
    );
    final position = tester.getCenter(trackpadListener);

    await tester.sendEventToBinding(
      PointerPanZoomStartEvent(pointer: 41, position: position),
    );
    await tester.sendEventToBinding(
      PointerPanZoomUpdateEvent(
        pointer: 41,
        position: position,
        pan: const Offset(55, -20),
        panDelta: const Offset(55, -20),
        scale: 1.5,
      ),
    );
    await tester.pump();
    await tester.sendEventToBinding(
      PointerPanZoomEndEvent(pointer: 41, position: position),
    );
    await tester.pump();

    final transformedWidth = chart().data.maxX - chart().data.minX;
    final transformedCenter = (chart().data.minX + chart().data.maxX) / 2;
    expect(transformedWidth, lessThan(initialWidth));
    expect((transformedCenter - initialCenter).abs(), greaterThan(0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('One-finger touch drag pans a plot in Zoom/Move mode',
      (tester) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final centerBefore = (chart().data.minX + chart().data.maxX) / 2;
    final widthBefore = chart().data.maxX - chart().data.minX;

    final drag = await tester.startGesture(const Offset(240, 200));
    await drag.moveBy(const Offset(80, -30));
    await tester.pump();
    await drag.up();
    await tester.pump();

    final centerAfter = (chart().data.minX + chart().data.maxX) / 2;
    final widthAfter = chart().data.maxX - chart().data.minX;
    expect(centerAfter, lessThan(centerBefore));
    expect(widthAfter, closeTo(widthBefore, 0.0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stylus write tip pans in Zoom/Move mode', (tester) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final centerBefore = (chart().data.minX + chart().data.maxX) / 2;
    final widthBefore = chart().data.maxX - chart().data.minX;
    final stylus = await tester.startGesture(
      const Offset(150, 100),
      kind: PointerDeviceKind.stylus,
    );
    await stylus.moveTo(const Offset(390, 300));
    await tester.pump();
    expect(find.byKey(const ValueKey('plot-rubber-band-0')), findsNothing);
    expect(find.byType(PopupMenuItem<String>), findsNothing);

    await stylus.up();
    await tester.pumpAndSettle();
    final widthAfter = chart().data.maxX - chart().data.minX;
    final centerAfter = (chart().data.minX + chart().data.maxX) / 2;
    expect(centerAfter, lessThan(centerBefore));
    expect(widthAfter, closeTo(widthBefore, 0.0001));
    expect(
      find.byKey(const ValueKey('plot-rubber-band-0')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stylus erase mode draws rubber-band and inverted tip points',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final widthBefore = chart().data.maxX - chart().data.minX;
    app.setStylusEraserMode(true);
    final eraser = await tester.startGesture(
      const Offset(150, 100),
      kind: PointerDeviceKind.stylus,
    );
    await eraser.moveTo(const Offset(390, 300));
    await tester.pump();
    expect(find.byKey(const ValueKey('plot-rubber-band-0')), findsOneWidget);
    await eraser.up();
    await tester.pumpAndSettle();
    final widthAfter = chart().data.maxX - chart().data.minX;
    expect(widthAfter, lessThan(widthBefore));
    expect(find.byType(PopupMenuItem<String>), findsNothing);

    app.interactionMode = 1;
    final pointPen = await tester.startGesture(
      const Offset(180, 180),
      kind: PointerDeviceKind.invertedStylus,
    );
    await tester.pump();
    final firstX = app.crosshairX;
    expect(firstX, isNotNull);
    await pointPen.moveTo(const Offset(360, 180));
    await tester.pump();
    expect(app.crosshairX, greaterThan(firstX!));
    await pointPen.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('A standard stylus button temporarily selects rubber-band zoom',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    final eraser = await tester.startGesture(
      const Offset(150, 100),
      kind: PointerDeviceKind.stylus,
      buttons: kPrimaryStylusButton,
    );
    await eraser.moveTo(const Offset(390, 300));
    await tester.pump();

    expect(find.byKey(const ValueKey('plot-rubber-band-0')), findsOneWidget);
    await eraser.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stylus long press tolerates jitter and opens context menu',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    final stylus = await tester.startGesture(
      const Offset(240, 200),
      kind: PointerDeviceKind.stylus,
    );
    await stylus.moveBy(const Offset(4, 3));
    await tester.pump(const Duration(milliseconds: 550));

    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('plot-rubber-band-0')), findsNothing);

    await stylus.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Closing a stylus context menu releases the plot for finger gestures',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
        ),
      ),
    );

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final stylus = await tester.startGesture(
      const Offset(240, 200),
      pointer: 41,
      kind: PointerDeviceKind.stylus,
    );
    await stylus.moveBy(const Offset(4, 3));
    await tester.pump(const Duration(milliseconds: 550));
    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsOneWidget,
    );

    // Reproduce iPadOS consuming the Pencil-up event: dismiss the popup while
    // the original test pointer is still down.
    await tester.tapAt(const Offset(5, 5), pointer: 42);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsNothing,
    );

    final centerBefore = (chart().data.minX + chart().data.maxX) / 2;
    final finger = await tester.startGesture(
      const Offset(180, 180),
      pointer: 43,
      kind: PointerDeviceKind.touch,
    );
    await finger.moveTo(const Offset(330, 250));
    await tester.pump();
    await finger.up();
    await tester.pumpAndSettle();
    final centerAfter = (chart().data.minX + chart().data.maxX) / 2;

    expect(centerAfter, lessThan(centerBefore));

    final widthBeforePinch = chart().data.maxX - chart().data.minX;
    final firstFinger = await tester.startGesture(
      const Offset(220, 200),
      pointer: 44,
      kind: PointerDeviceKind.touch,
    );
    final secondFinger = await tester.startGesture(
      const Offset(280, 200),
      pointer: 45,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await firstFinger.moveTo(const Offset(190, 200));
    await secondFinger.moveTo(const Offset(340, 200));
    await tester.pump();
    await firstFinger.up();
    await secondFinger.up();
    await tester.pump();
    final widthAfterPinch = chart().data.maxX - chart().data.minX;
    expect(widthAfterPinch, lessThan(widthBeforePinch));

    final longPressFinger = await tester.startGesture(
      const Offset(220, 180),
      pointer: 46,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 550));
    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsOneWidget,
    );
    await tester.tapAt(const Offset(5, 5), pointer: 47);
    await tester.pumpAndSettle();
    await longPressFinger.up();
    await stylus.up();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Plot view survives panel disposal and reconstruction',
      (tester) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10]
        ],
        null);

    Widget panelApp(Widget child) => ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(width: 500, height: 400, child: child),
              ),
            ),
          ),
        );

    await tester.pumpWidget(panelApp(const PlotPanel(plotIdx: 0)));
    final first = await tester.startGesture(const Offset(220, 200), pointer: 1);
    final second =
        await tester.startGesture(const Offset(280, 200), pointer: 2);
    await tester.pump();
    await first.moveTo(const Offset(180, 200));
    await second.moveTo(const Offset(320, 200));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final savedRange = (
      minX: chart().data.minX,
      maxX: chart().data.maxX,
      minY: chart().data.minY,
      maxY: chart().data.maxY,
    );

    await tester.pumpWidget(panelApp(const SizedBox()));
    await tester.pumpWidget(panelApp(const PlotPanel(plotIdx: 0)));

    expect(chart().data.minX, savedRange.minX);
    expect(chart().data.maxX, savedRange.maxX);
    expect(chart().data.minY, savedRange.minY);
    expect(chart().data.maxY, savedRange.maxY);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Phone overview keeps every plot visible without scrolling',
      (tester) async {
    final app = AppState();
    app.applyLayoutList([2, 2]);
    for (var column = 0; column < 2; column++) {
      for (var row = 0; row < 2; row++) {
        app.updatePlotSeriesByColRow(
            column,
            row,
            0,
            [
              [0, column * 20 + row * 10],
              [5, column * 20 + row * 10 + 5],
              [10, column * 20 + row * 10 + 10]
            ],
            null);
      }
    }
    app.interactionMode = 1;
    app.setCrosshair(5, sourcePlot: 0, sourceSeries: 0);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 600);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: PlotGrid())),
      ),
    );

    expect(find.byType(Scrollable), findsNothing);
    for (var plot = 0; plot < 4; plot++) {
      expect(find.byKey(ValueKey('plot-panel-$plot')), findsOneWidget);
      final rect = tester.getRect(find.byKey(ValueKey('plot-panel-$plot')));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(390));
      expect(rect.bottom, lessThanOrEqualTo(600));
    }
    final charts =
        tester.widgetList<LineChart>(find.byType(LineChart)).toList();
    expect(charts, hasLength(4));
    expect(
      charts.map((chart) => chart.data.extraLinesData.horizontalLines.single.y),
      [5, 15, 25, 35],
    );

    app.interactionMode = 0;
    await tester.pump();
    LineChart firstChart() =>
        tester.widgetList<LineChart>(find.byType(LineChart)).first;
    final initialWidth = firstChart().data.maxX - firstChart().data.minX;
    final center = tester.getCenter(find.byKey(const ValueKey('plot-panel-0')));
    final first = await tester.startGesture(
      center.translate(-20, 10),
      pointer: 12,
    );
    final second = await tester.startGesture(
      center.translate(20, 10),
      pointer: 13,
    );
    await tester.pump();
    await first.moveBy(const Offset(-15, 0));
    await second.moveBy(const Offset(15, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(firstChart().data.maxX - firstChart().data.minX,
        lessThan(initialWidth));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Toolbar keeps ordered groups across responsive screen widths',
      (tester) async {
    final app = AppState();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final width in [
      280.0,
      320.0,
      390.0,
      600.0,
      768.0,
      1024.0,
      1440.0,
      1920.0,
    ]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
        ),
      );

      final toolbar = find.byKey(const ValueKey('toolbar-root'));
      expect(tester.getSize(toolbar).width, width);
      expect(
        find.descendant(
            of: toolbar, matching: find.byType(SingleChildScrollView)),
        findsNothing,
      );
      final themeCenter = tester
          .getCenter(find.byKey(const ValueKey('toolbar-theme-actions')))
          .dy;
      final appCenter = tester
          .getCenter(find.byKey(const ValueKey('toolbar-app-actions')))
          .dy;
      final fileTop = tester
          .getTopLeft(find.byKey(const ValueKey('toolbar-file-actions')))
          .dy;
      expect(themeCenter, closeTo(appCenter, 0.01));
      expect(themeCenter, lessThanOrEqualTo(fileTop + 22.01));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Phone toolbar button groups are aligned and equally sized',
      (tester) async {
    final app = AppState();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    void expectEqualRow(
        Finder group, Finder Function(Finder) buttonFinder, int count) {
      final buttons = buttonFinder(group);
      expect(buttons, findsNWidgets(count));
      final rects = [
        for (var i = 0; i < count; i++) tester.getRect(buttons.at(i))
      ];
      for (final rect in rects.skip(1)) {
        expect(rect.top, closeTo(rects.first.top, 0.01));
        expect(rect.height, closeTo(rects.first.height, 0.01));
        expect(rect.width, closeTo(rects.first.width, 0.01));
      }
    }

    Finder outlinedButtons(Finder group) =>
        find.descendant(of: group, matching: find.byType(OutlinedButton));

    final fileActions = find.byKey(const ValueKey('toolbar-file-actions'));
    final navigation = find.byKey(const ValueKey('toolbar-shot-navigation'));
    final modes = find.byKey(const ValueKey('toolbar-mode-actions'));
    final themes = find.byKey(const ValueKey('toolbar-theme-actions'));
    final appActions = find.byKey(const ValueKey('toolbar-app-actions'));
    expectEqualRow(fileActions, outlinedButtons, 4);
    expectEqualRow(navigation, outlinedButtons, 3);
    expectEqualRow(modes, outlinedButtons, 2);
    expect(
      find.descendant(of: themes, matching: find.byType(OutlinedButton)),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('theme-mode-switch')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('theme-mode-switch')),
        matching: find.byType(CustomPaint),
      ),
      findsNWidgets(3),
    );
    expect(find.byTooltip('Open configuration'), findsOneWidget);
    expect(find.byTooltip('Save configuration'), findsOneWidget);
    expect(find.byTooltip('Restore default configuration'), findsOneWidget);
    expect(find.byTooltip('Refresh waveforms'), findsOneWidget);
    expect(find.byTooltip('Previous shot'), findsOneWidget);
    expect(find.byTooltip('Next shot'), findsOneWidget);
    expect(find.byTooltip('Latest shot'), findsOneWidget);
    expect(find.byTooltip('Zoom and move mode'), findsOneWidget);
    expect(find.byTooltip('Point mode'), findsOneWidget);
    expect(tester.getSize(find.byTooltip('Open configuration')).height,
        greaterThanOrEqualTo(44));

    final autoTheme = tester.widget<Semantics>(
      find.byKey(const ValueKey('theme-mode-auto')),
    );
    expect(autoTheme.properties.selected, isTrue);
    await tester.tap(find.byKey(const ValueKey('theme-mode-dark')));
    await tester.pumpAndSettle();
    expect(app.themeMode, 1);
    final darkTheme = tester.widget<Semantics>(
      find.byKey(const ValueKey('theme-mode-dark')),
    );
    expect(darkTheme.properties.selected, isTrue);

    for (final key in const [
      'theme-mode-light',
      'theme-mode-auto',
      'theme-mode-dark',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      final segmentCenter = tester.getCenter(find.byKey(ValueKey(key)));
      final glyphCenter = tester.getCenter(
        find.descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(CustomPaint),
        ),
      );
      final thumbCenter =
          tester.getCenter(find.byKey(const ValueKey('theme-mode-thumb')));
      expect(glyphCenter.dx, closeTo(segmentCenter.dx, 0.01));
      expect(glyphCenter.dy, closeTo(segmentCenter.dy, 0.01));
      expect(thumbCenter.dx, closeTo(glyphCenter.dx, 0.01));
      expect(thumbCenter.dy, closeTo(glyphCenter.dy, 0.01));
    }

    final orderedGroups = [
      themes,
      fileActions,
      find.byKey(const ValueKey('toolbar-shot-entry')),
      navigation,
      find.byKey(const ValueKey('toolbar-shot-info')),
    ];
    final tops = orderedGroups.map(tester.getTopLeft).map((p) => p.dy).toList();
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]));
    }
    expect(tester.getCenter(appActions).dy,
        closeTo(tester.getCenter(themes).dy, 0.01));
    expect(tester.getTopLeft(modes).dy,
        closeTo(tester.getTopLeft(navigation).dy, 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dropdown and popup menu choices have visible separators',
      (tester) async {
    final app = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('toolbar-rate-dropdown')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('toolbar-rate-divider-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('toolbar-rate-divider-2')),
      findsOneWidget,
    );
    final anchor = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('toolbar-rate-anchor')),
    );
    final decoration = anchor.decoration as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(12));
    expect(decoration.boxShadow, isNotEmpty);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('toolbar-rate-option-1')));
    await tester.pumpAndSettle();
    expect(app.dataMode, 1);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuDivider), findsNWidgets(3));
  });

  testWidgets('Shot history uses the polished compact dropdown',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'shotHistory': '["163702","163701"]',
      'shot': '163703',
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    expect(
      find.byKey(const ValueKey('toolbar-shot-history-dropdown')),
      findsOneWidget,
    );
    expect(find.byTooltip('Shot history'), findsOneWidget);
    final shotLabel = find.descendant(
      of: find.byKey(const ValueKey('toolbar-shot-entry')),
      matching: find.text('Shot:'),
    );
    final history = find.byKey(const ValueKey('toolbar-shot-history-dropdown'));
    expect(
      tester.getTopLeft(history).dx - tester.getTopRight(shotLabel).dx,
      closeTo(6, 0.01),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('toolbar-shot-entry')),
        matching: find.byType(PopupMenuButton<String>),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('toolbar-shot-history-dropdown')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('toolbar-shot-history-divider-1')),
      findsOneWidget,
    );
    expect(find.text('163702'), findsOneWidget);
    expect(find.text('163701'), findsOneWidget);
  });

  testWidgets('Shot history uses one selectable list with nested confirmation',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'shotHistory': '["163703","163702","163701"]',
      'shot': '163704',
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('toolbar-shot-history-dropdown')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('toolbar-shot-history-menu-action'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey('toolbar-shot-history-action-divider'),
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(
        const ValueKey('toolbar-shot-history-menu-action'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Manage Shot History'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('shot-history-selection-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('shot-history-select-all')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('shot-history-retention-enabled')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('shot-history-retention-limit')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('shot-history-retention-restore-default')),
      findsOneWidget,
    );

    final retentionToggle =
        find.byKey(const ValueKey('shot-history-retention-enabled'));
    await tester.tap(retentionToggle);
    await tester.pump();
    expect(app.limitShotHistory, isFalse);
    await tester.tap(retentionToggle);
    await tester.pump();
    expect(app.limitShotHistory, isTrue);

    final retentionLimit =
        find.byKey(const ValueKey('shot-history-retention-limit'));
    await tester.tap(retentionLimit);
    await tester.enterText(retentionLimit, '75');
    await tester.pump();
    expect(app.shotHistoryLimit, 75);
    await tester.tap(
      find.byKey(const ValueKey('shot-history-retention-restore-default')),
    );
    await tester.pump();
    expect(app.shotHistoryLimit, AppState.defaultShotHistoryLimit);
    expect(
      tester.widget<TextField>(retentionLimit).controller?.text,
      '${AppState.defaultShotHistoryLimit}',
    );
    tester.testTextInput.hide();
    await tester.pumpAndSettle();

    final selectedShot =
        find.byKey(const ValueKey('shot-history-select-163702'));
    await tester.ensureVisible(selectedShot);
    await tester.pumpAndSettle();
    await tester.tap(selectedShot);
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('shot-history-delete-selected')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete selected shot history?'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('shot-history-confirm-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('shot-history-selection-list')),
      findsOneWidget,
    );
    expect(app.shotHistory, ['163703', '163702', '163701']);

    await tester.tap(
      find.byKey(const ValueKey('shot-history-delete-selected')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('shot-history-confirm-selected')),
    );
    await tester.pumpAndSettle();
    expect(app.shotHistory, ['163703', '163701']);
    expect(
      find.byKey(const ValueKey('shot-history-selection-list')),
      findsOneWidget,
    );

    final selectAll = find.byKey(const ValueKey('shot-history-select-all'));
    await tester.ensureVisible(selectAll);
    await tester.pumpAndSettle();
    await tester.tap(selectAll);
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('shot-history-delete-selected')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Delete selected shot history?'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('shot-history-confirm-selected')),
    );
    await tester.pumpAndSettle();

    expect(app.shotHistory, isEmpty);
    expect(find.text('Shot history is empty'), findsOneWidget);
    expect(find.text('Manage Shot History'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString('shotHistory'), '[]');
    await tester.tap(
      find.byKey(const ValueKey('shot-history-manager-close')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('toolbar-shot-history-dropdown')),
      findsNothing,
    );
  });

  testWidgets('Waveform context menu is polished, grouped, and actionable',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 1],
          [1, 2],
        ],
        null);
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: MdsScopeTheme.light(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                height: 420,
                child: PlotPanel(plotIdx: 0),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.byType(PlotPanel)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    for (final section in const ['VIEW', 'SCALE', 'DATA', 'CONFIGURE']) {
      expect(find.text(section), findsOneWidget);
    }
    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.fullscreen_rounded), findsOneWidget);
    expect(find.byIcon(Icons.restart_alt_rounded), findsOneWidget);
    expect(find.byIcon(Icons.storage_rounded), findsOneWidget);
    expect(
      find.byKey(const ValueKey('plot-context-menu-group-divider-1')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
    );
    await tester.pumpAndSettle();
    expect(app.maximizedPlot, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Empty data source fields expose every available suggestion',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 700);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: MdsScopeTheme.light(),
          home: const Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                height: 420,
                child: PlotPanel(plotIdx: 0),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.byType(PlotPanel)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('plot-context-menu-data-source')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    final signalField = find.byKey(const ValueKey('data-signal-0'));
    await tester.ensureVisible(signalField);
    final signalTextField =
        find.descendant(of: signalField, matching: find.byType(TextField));
    await tester.tap(signalTextField);
    await tester.enterText(signalTextField, '');
    final signalMenu = find.byKey(const ValueKey('autocomplete-signal-menu'));
    await tester.pumpAndSettle();
    expect(signalMenu, findsOneWidget);
    final signalList = tester.widget<ListView>(
      find.descendant(of: signalMenu, matching: find.byType(ListView)),
    );
    expect(signalList.semanticChildCount, 3967);

    final treeField = find.byKey(const ValueKey('data-tree-0'));
    await tester.ensureVisible(treeField);
    final treeTextField =
        find.descendant(of: treeField, matching: find.byType(TextField));
    await tester.tap(treeTextField);
    await tester.enterText(treeTextField, '');
    await tester.pumpAndSettle();
    final treeMenu = find.byKey(const ValueKey('autocomplete-tree-menu'));
    expect(treeMenu, findsOneWidget);
    final treeList = tester.widget<ListView>(
      find.descendant(of: treeMenu, matching: find.byType(ListView)),
    );
    expect(treeList.semanticChildCount, 18);
    final treeScrollbar = find.descendant(
      of: treeMenu,
      matching: find.byType(Scrollbar),
    );
    expect(treeScrollbar, findsOneWidget);
    expect(tester.widget<Scrollbar>(treeScrollbar).interactive, isTrue);
    final treeMenuRect = tester.getRect(treeMenu);
    final scrollbarDrag = await tester.startGesture(
      Offset(treeMenuRect.right - 2, treeMenuRect.top + 24),
      kind: PointerDeviceKind.mouse,
    );
    await scrollbarDrag.moveBy(const Offset(0, 100));
    await tester.pump();
    expect(treeMenu, findsOneWidget);
    expect(tester.widget<TextField>(treeTextField).focusNode?.hasFocus, isTrue);
    await scrollbarDrag.up();
    await tester.pumpAndSettle();
    expect(treeMenu, findsOneWidget);

    await tester.enterText(treeTextField, 'pcs');
    await tester.pumpAndSettle();
    final pcsTreeOption = find.text('pcs_east');
    expect(pcsTreeOption, findsOneWidget);
    final mouse = TestPointer(91, PointerDeviceKind.mouse);
    final treeOptionCenter = tester.getCenter(pcsTreeOption);
    await tester.sendEventToBinding(mouse.hover(treeOptionCenter));
    await tester.sendEventToBinding(mouse.down(treeOptionCenter));
    await tester.pump();
    expect(
        tester.widget<TextField>(treeTextField).controller?.text, 'pcs_east');
    await tester.sendEventToBinding(mouse.up());

    await tester.tap(signalTextField);
    await tester.enterText(signalTextField, r'\pcrl');
    await tester.pumpAndSettle();
    final signalOption = find.text(r'\PCRL01');
    expect(signalOption, findsOneWidget);
    final signalOptionCenter = tester.getCenter(signalOption);
    await tester.sendEventToBinding(mouse.hover(signalOptionCenter));
    await tester.sendEventToBinding(mouse.down(signalOptionCenter));
    await tester.pump();
    expect(
      tester.widget<TextField>(signalTextField).controller?.text,
      r'\PCRL01',
    );
    await tester.sendEventToBinding(mouse.up());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Data source Shot inherits the loaded shot when config is empty',
      (tester) async {
    expect(
      resolveDataSourceShot(
        signalShot: '',
        panelShot: '  ',
        displayedShot: '163888',
        inputShot: '163999',
      ),
      '163888',
    );

    final signals = <Map<String, dynamic>>[
      {
        'shot': '',
        'experiment': 'pcs_east',
        'y_expr': r'\PCRL01',
      },
    ];
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDataSourceSetupEditor(
                context,
                signals: signals,
                defaultShot: '163888',
              ),
              child: const Text('Open data source'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open data source'));
    await tester.pumpAndSettle();
    final scrollbarHost = find.byKey(
      const ValueKey('data-source-horizontal-scrollbar'),
    );
    final dataSourceScrollbar = tester.widget<Scrollbar>(
      find.descendant(
        of: scrollbarHost,
        matching: find.byType(Scrollbar),
      ),
    );
    expect(dataSourceScrollbar.thumbVisibility, isTrue);
    expect(dataSourceScrollbar.trackVisibility, isTrue);
    expect(dataSourceScrollbar.interactive, isTrue);
    expect(dataSourceScrollbar.thickness, 5);
    expect(
      dataSourceScrollbar.controller?.position.maxScrollExtent,
      greaterThan(0),
    );
    final initialScrollbarRevision = dataSourceScrollbar.key;
    final horizontalController = dataSourceScrollbar.controller!;
    horizontalController.jumpTo(
      horizontalController.position.maxScrollExtent / 2,
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Add Curve'));
    await tester.pumpAndSettle();
    final rebuiltScrollbar = tester.widget<Scrollbar>(
      find.descendant(
        of: scrollbarHost,
        matching: find.byType(Scrollbar),
      ),
    );
    expect(rebuiltScrollbar.thumbVisibility, isTrue);
    expect(rebuiltScrollbar.trackVisibility, isTrue);
    expect(rebuiltScrollbar.key, isNot(initialScrollbarRevision));
    expect(rebuiltScrollbar.controller, same(horizontalController));
    expect(rebuiltScrollbar.controller?.hasClients, isTrue);
    expect(
      rebuiltScrollbar.controller?.position.maxScrollExtent,
      greaterThan(0),
    );
    rebuiltScrollbar.controller?.jumpTo(
      rebuiltScrollbar.controller!.position.maxScrollExtent / 2,
    );
    await tester.pump();
    expect(rebuiltScrollbar.controller?.offset, greaterThan(0));
    final scrollbarRect = tester.getRect(
      find.byKey(const ValueKey('data-source-horizontal-scrollbar')),
    );
    final horizontalViewportRect = tester.getRect(
      find.byKey(const ValueKey('data-source-horizontal-scroll')),
    );
    expect(
      scrollbarRect.bottom - horizontalViewportRect.bottom,
      greaterThanOrEqualTo(9),
    );
    horizontalController.jumpTo(0);
    await tester.pump();
    final shotField = tester.widget<TextField>(
      find.byKey(const ValueKey('data-shot-0')),
    );
    expect(shotField.controller?.text, '163888');
    await tester.tap(find.byKey(const ValueKey('data-shot-0')));
    await tester.pump();
    final focusedShot = FocusManager.instance.primaryFocus;
    expect(focusedShot?.hasFocus, isTrue);
    final surfaceRect = tester.getRect(
      find.byKey(const ValueKey('data-source-dialog-surface')),
    );
    await tester.tapAt(Offset(surfaceRect.left + 4, surfaceRect.center.dy));
    await tester.pump();
    expect(focusedShot?.hasFocus, isFalse);
    await tester.enterText(
      find.byKey(const ValueKey('data-legend-0')),
      'Primary current',
    );
    expect(
      find.byKey(const ValueKey('data-hide-mode-dropdown-0')),
      findsOneWidget,
    );
    expect(find.byType(Checkbox), findsNothing);
    await tester.ensureVisible(
      find.byKey(const ValueKey('data-hide-mode-dropdown-0')),
    );
    await tester.tap(
      find.byKey(const ValueKey('data-hide-mode-dropdown-0')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('data-hide-mode-0-option-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(signals.single['legend'], 'Primary current');
    expect(signals.single['shot'], '163888');
    expect(signals.single['hide_mode'], signalHideModeTemporary);
    expect(signals.single['hidden'], isTrue);
  });

  testWidgets('SSH mode and font family use polished dropdown menus',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('SSH tunnel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ssh-mode-dropdown')), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<int>), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ssh-mode-dropdown')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ssh-mode-divider-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('ssh-mode-divider-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ssh-mode-option-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Customize fonts'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font-family-dropdown')), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(find.byKey(const ValueKey('font-family-dropdown')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('font-family-divider-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('font-family-divider-7')), findsOneWidget);
    const fontFamilies = <String>[
      'Arial',
      'Helvetica',
      'Times New Roman',
      'Courier New',
      'Georgia',
      'Verdana',
      'Monaco',
    ];
    for (var index = 0; index < fontFamilies.length; index++) {
      final family = fontFamilies[index];
      final optionLabel = tester.widget<Text>(
        find
            .descendant(
              of: find.byKey(
                ValueKey('font-family-option-${index + 1}'),
              ),
              matching: find.text(family),
            )
            .last,
      );
      expect(optionLabel.style?.fontFamily, family);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('About appears only in the icon-decorated settings menu',
      (tester) async {
    final app = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    expect(find.byTooltip('About MdsScope'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('About MdsScope'), findsOneWidget);
    expect(find.byIcon(Icons.language_rounded), findsOneWidget);
    expect(find.byIcon(Icons.dashboard_customize_rounded), findsOneWidget);
    expect(find.byIcon(Icons.font_download_outlined), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
  });

  testWidgets('Internal web pages use separated polished list items',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.addWebBookmark('Diagnostics', 'http://10.0.0.8/diagnostics');
    app.addWebBookmark('Archive', 'http://10.0.0.8/archive');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Internal web pages'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('internal-web-pages-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('internal-web-page-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('internal-web-page-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('internal-web-page-divider-0')),
      findsOneWidget,
    );
    expect(find.text('Diagnostics'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new_rounded), findsNWidgets(2));
    expect(
      find.byKey(const ValueKey('internal-web-page-edit-0')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('internal-web-page-edit-0')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Edit Web Page'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('edit-web-page-alias')),
      'Live diagnostics',
    );
    await tester.enterText(
      find.byKey(const ValueKey('edit-web-page-url')),
      'http://10.0.0.9/live',
    );
    await tester.tap(find.byKey(const ValueKey('edit-web-page-save')));
    await tester.pumpAndSettle();

    expect(app.webBookmarks.first, {
      'Live diagnostics': 'http://10.0.0.9/live',
    });
    expect(find.text('Live diagnostics'), findsOneWidget);
    expect(find.text('http://10.0.0.9/live'), findsOneWidget);
    final restored = AppState();
    await restored.preferencesReady;
    addTearDown(restored.dispose);
    expect(restored.webBookmarks.first, {
      'Live diagnostics': 'http://10.0.0.9/live',
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Bookmark removal supports selection, select all, and confirmation',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.addWebBookmark('Diagnostics', 'http://10.0.0.8/diagnostics');
    app.addWebBookmark('Archive', 'http://10.0.0.8/archive');
    app.addWebBookmark('Status', 'http://10.0.0.8/status');
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Internal web pages'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove...'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('bookmark-removal-selection-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('bookmark-select-all')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('bookmark-remove-1')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('bookmark-delete-selected')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Remove selected bookmarks?'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('bookmark-removal-confirm-cancel')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('bookmark-removal-selection-list')),
      findsOneWidget,
    );
    expect(app.webBookmarks, hasLength(3));

    await tester.tap(
      find.byKey(const ValueKey('bookmark-delete-selected')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bookmark-removal-confirm')),
    );
    await tester.pumpAndSettle();
    expect(app.webBookmarks.map((item) => item.keys.first), [
      'Diagnostics',
      'Status',
    ]);
    expect(
      find.byKey(const ValueKey('bookmark-removal-selection-list')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('bookmark-select-all')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('bookmark-delete-selected')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('bookmark-removal-confirm')),
    );
    await tester.pumpAndSettle();
    expect(app.webBookmarks, isEmpty);
    expect(find.text('No bookmarks remain'), findsWidgets);

    await tester.tap(
      find.byKey(const ValueKey('bookmark-removal-close')),
    );
    await tester.pumpAndSettle();
    expect(find.text('No Saved Web Addresses'), findsOneWidget);
  });

  testWidgets('Toolbar remains bounded with enlarged customized UI fonts',
      (tester) async {
    final app = AppState();
    app.applyFontSettings('System', 20, 20, 20, 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final width in [280.0, 390.0, 768.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
        ),
      );

      expect(tester.getSize(find.byKey(const ValueKey('toolbar-root'))).width,
          width);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Small screens can collapse controls without covering plots',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: MainPage()),
      ),
    );

    final collapse = find.byKey(const ValueKey('toolbar-collapse-control'));
    expect(collapse, findsOneWidget);
    expect(find.byKey(const ValueKey('toolbar-root')), findsOneWidget);
    final expandedPlotTop = tester.getTopLeft(find.byType(PlotGrid)).dy;
    expect(tester.getRect(collapse).bottom,
        lessThanOrEqualTo(expandedPlotTop + 0.01));

    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar-root')), findsNothing);
    expect(find.byKey(const ValueKey('toolbar-collapsed-summary')),
        findsOneWidget);
    final collapsedPlotTop = tester.getTopLeft(find.byType(PlotGrid)).dy;
    expect(collapsedPlotTop, lessThan(expandedPlotTop));
    expect(tester.getRect(collapse).bottom,
        lessThanOrEqualTo(collapsedPlotTop + 0.01));

    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar-root')), findsOneWidget);
  });

  testWidgets('Extremely small screens scroll controls but not the plot area',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(220, 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: MainPage()),
      ),
    );

    expect(
      find.byKey(const ValueKey('toolbar-controls-horizontal-scrollbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('toolbar-controls-vertical-scrollbar')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('toolbar-collapse-control')),
      findsOneWidget,
    );
    expect(find.byType(PlotGrid), findsOneWidget);
    expect(tester.getSize(find.byType(PlotGrid)).height, greaterThan(0));
    expect(
      find.descendant(
        of: find.byType(PlotGrid),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Settings dialogs gain two-axis scrolling on tiny screens',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(220, 300);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => LoginDialog.show(context),
              child: const Text('Open login'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open login'));
    await tester.pumpAndSettle();

    final horizontal = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('adaptive-dialog-horizontal-scrollbar')),
    );
    final vertical = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('adaptive-dialog-vertical-scrollbar')),
    );
    expect(horizontal.thumbVisibility, isTrue);
    expect(vertical.thumbVisibility, isTrue);
    expect(horizontal.controller?.position.maxScrollExtent, greaterThan(0));
    expect(vertical.controller?.position.maxScrollExtent, greaterThan(0));
    final dialogSize = tester.getSize(
      find.byKey(const ValueKey('keyboard-safe-dialog')),
    );
    expect(dialogSize.width, lessThanOrEqualTo(220));
    expect(dialogSize.height, lessThanOrEqualTo(300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Collapsed toolbar keeps controls fixed and scrolls metadata',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    app.shotText = '163714';
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(body: ResponsiveToolbar()),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('toolbar-collapsed-metadata-scroll')),
      findsNothing,
    );
    await tester.tap(find.text('Collapse controls'));
    await tester.pumpAndSettle();

    final metadataScrollbar = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('toolbar-collapsed-metadata-scrollbar')),
    );
    expect(metadataScrollbar.thumbVisibility, isTrue);
    expect(metadataScrollbar.interactive, isTrue);
    expect(metadataScrollbar.thickness, 2);
    final summaryFinder =
        find.byKey(const ValueKey('toolbar-collapsed-summary'));
    final summary = tester.widget<Text>(summaryFinder).data!;
    expect(summary, contains('Shot: 163714'));
    expect(summary, contains('Ip: --'));
    expect(summary, contains('Pulse: --'));
    expect(summary, contains('It: --'));
    expect(summary, contains('Time: --'));
    expect(RegExp('Shot:').allMatches(summary), hasLength(1));
    expect(summary, isNot(contains(app.status)));

    final metadataScroll =
        find.byKey(const ValueKey('toolbar-collapsed-metadata-scroll'));
    final horizontalScrollable = find.descendant(
      of: metadataScroll,
      matching: find.byType(Scrollable),
    );
    expect(horizontalScrollable, findsOneWidget);
    final scrollState =
        tester.state<ScrollableState>(horizontalScrollable.first);
    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    final fixedLeft = tester.getTopLeft(find.text('Expand controls'));
    await tester.drag(metadataScroll, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(scrollState.position.pixels, greaterThan(0));
    expect(tester.getTopLeft(find.text('Expand controls')), fixedLeft);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Comfortable screens do not show the collapse control',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 900);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: MainPage()),
      ),
    );

    expect(
        find.byKey(const ValueKey('toolbar-collapse-control')), findsNothing);
    expect(find.byKey(const ValueKey('toolbar-root')), findsOneWidget);
  });

  testWidgets('Layout Setup preview matches phone and tablet plot columns',
      (tester) async {
    final app = AppState();
    app.applyLayoutList([2, 1, 2]);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final (width, expectedColumns) in [(390.0, 3), (800.0, 3)]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
        ),
      );

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Layout setup'));
      await tester.pumpAndSettle();

      for (var column = 0; column < expectedColumns; column++) {
        expect(
          find.byKey(ValueKey('layout-preview-column-$column')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(ValueKey('layout-preview-column-$expectedColumns')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }
  });

  test('Layout reorder helpers move columns and panels across columns', () {
    Map<String, dynamic> panel(String title) => {'title': title};

    final columns = [
      [panel('Column 1')],
      [panel('Column 2')],
      [panel('Column 3')],
      [panel('Column 4')],
      [panel('Column 5')],
    ];
    expect(reorderLayoutColumn(columns, 4, 2), isTrue);
    expect(
      columns.map((column) => column.single['title']).toList(),
      ['Column 1', 'Column 2', 'Column 5', 'Column 3', 'Column 4'],
    );

    final panels = [
      [panel('1-1'), panel('1-2'), panel('1-3'), panel('1-4')],
      [panel('2-1')],
      [panel('3-1'), panel('3-2')],
    ];
    expect(
      reorderLayoutPanel(
        panels,
        sourceColumn: 2,
        sourceRow: 1,
        targetColumn: 0,
        insertionRow: 3,
      ),
      isTrue,
    );
    expect(
      panels[0].map((item) => item['title']).toList(),
      ['1-1', '1-2', '1-3', '3-2', '1-4'],
    );
    expect(panels[2].map((item) => item['title']).toList(), ['3-1']);

    expect(
      reorderLayoutPanel(
        panels,
        sourceColumn: 1,
        sourceRow: 0,
        targetColumn: 0,
        insertionRow: 0,
      ),
      isTrue,
    );
    expect(panels, hasLength(2));
    expect(panels[0].first['title'], '2-1');

    final splitColumns = [
      [panel('A'), panel('B')],
      [panel('C')],
    ];
    expect(
      moveLayoutPanelToNewColumn(
        splitColumns,
        sourceColumn: 0,
        sourceRow: 1,
        insertionIndex: 1,
      ),
      isTrue,
    );
    expect(
      splitColumns
          .map((column) => column.map((item) => item['title']).toList())
          .toList(),
      [
        ['A'],
        ['B'],
        ['C'],
      ],
    );
  });

  testWidgets('Layout Setup selects and deletes columns with icon actions',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.applyLayoutList([1, 1]);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout setup'));
    await tester.pumpAndSettle();
    expect(
      tester.widget(
        find.byKey(const ValueKey('layout-column-drag-1')),
      ),
      isA<LongPressDraggable>(),
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey('layout-panel-drag-1')),
      ),
      isA<LongPressDraggable>(),
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey('layout-column-drag-handle-1')),
      ),
      isA<Draggable>(),
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey('layout-panel-drag-handle-1')),
      ),
      isA<Draggable>(),
    );
    expect(
      find.byKey(const ValueKey('layout-column-drop-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('layout-panel-drop-0-1')),
      findsOneWidget,
    );
    final dragPreview = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey('layout-column-header-1')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('1 panels'), findsOneWidget);
    await dragPreview.cancel();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('layout-column-header-2')),
    );
    await tester.pump();
    final deleteColumn = find.byKey(const ValueKey('layout-delete-column-2'));
    expect(deleteColumn, findsOneWidget);
    expect(tester.widget(deleteColumn), isA<IconButton>());

    await tester.tap(
      find.byKey(const ValueKey('layout-setup-blank-area')),
    );
    await tester.pump();
    expect(deleteColumn, findsNothing);

    await tester.tap(find.byKey(const ValueKey('layout-preview-panel-0')));
    await tester.pump();
    expect(
      tester.widget(
        find.byKey(const ValueKey('layout-edit-panel-1')),
      ),
      isA<IconButton>(),
    );
    expect(
      tester.widget(
        find.byKey(const ValueKey('layout-delete-panel-1')),
      ),
      isA<IconButton>(),
    );

    await tester.tap(
      find.byKey(const ValueKey('layout-column-header-2')),
    );
    await tester.pump();
    await tester.tap(deleteColumn);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('layout-preview-column-1')),
      findsNothing,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(app.columns, hasLength(1));
  });

  testWidgets('A panel drag handle can create a column between columns',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.applyLayoutList([2, 1]);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(700, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout setup'));
    await tester.pumpAndSettle();

    final handle = find.byKey(const ValueKey('layout-panel-drag-handle-2'));
    final betweenColumns = find.byKey(const ValueKey('layout-column-drop-1'));
    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveTo(tester.getCenter(betweenColumns));
    await tester.pump(const Duration(milliseconds: 200));
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('layout-preview-column-2')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(app.columns.map((column) => column.length), [1, 1, 1]);
  });

  testWidgets('Layout Setup scrolls wide columns and tall panel lists',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.applyLayoutList([6, 1, 1, 1, 1]);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout setup'));
    await tester.pumpAndSettle();

    final horizontal = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('layout-horizontal-scrollbar')),
    );
    expect(horizontal.thumbVisibility, isTrue);
    expect(horizontal.controller?.position.maxScrollExtent, greaterThan(0));

    final tallColumn = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('layout-column-scrollbar-0')),
    );
    expect(tallColumn.thumbVisibility, isTrue);
    expect(tallColumn.controller?.position.maxScrollExtent, greaterThan(0));

    await tester.drag(
      find.byKey(const ValueKey('layout-column-scroll-0')),
      const Offset(0, -140),
    );
    await tester.pumpAndSettle();
    expect(tallColumn.controller?.position.pixels, greaterThan(0));

    await tester.drag(
      find.byKey(const ValueKey('layout-horizontal-scroll')),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontal.controller?.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Layout Setup shows metadata and supports draft panel actions',
      (tester) async {
    final app = AppState(
      signalFetchWorker: (_, __, ___) async => '[]',
    );
    await app.preferencesReady;
    app.applyLayoutList([2]);
    app.columns[0][0]
      ..['title'] = 'Magnetic overview'
      ..['signal_specs'] = [
        {'experiment': 'tree_a', 'y_expr': r'\signal_a'},
        {'experiment': 'tree_b'},
        {'y_expr': r'\signal_c'},
        <String, dynamic>{},
      ];
    app.columns[0][1]
      ..['title'] = ''
      ..['signal_specs'] = <Map<String, dynamic>>[];
    app.rebuild();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout setup'));
    await tester.pumpAndSettle();

    expect(find.text('Panel 1'), findsOneWidget);
    expect(find.text('Title: Magnetic overview'), findsOneWidget);
    expect(find.text('Curve 1 Tree: tree_a'), findsOneWidget);
    expect(find.text(r'Curve 1 Signal: \signal_a'), findsOneWidget);
    expect(find.text('Curve 2 Tree: tree_b'), findsOneWidget);
    expect(find.text(r'Curve 3 Signal: \signal_c'), findsOneWidget);
    expect(find.textContaining('Curve 4'), findsNothing);
    expect(find.text('Title: '), findsNothing);
    expect(find.byKey(const ValueKey('layout-edit-panel-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('layout-preview-panel-0')));
    await tester.pump();
    expect(find.byKey(const ValueKey('layout-edit-panel-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-delete-panel-1')), findsOneWidget);

    final layoutDialog = tester.getRect(
      find.byKey(const ValueKey('keyboard-safe-dialog')),
    );
    await tester.tapAt(Offset(layoutDialog.right - 20, layoutDialog.top + 20));
    await tester.pump();
    expect(find.byKey(const ValueKey('layout-edit-panel-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('layout-preview-panel-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('layout-edit-panel-1')));
    await tester.pumpAndSettle();
    expect(find.text('Panel Setup'), findsOneWidget);
    expect(find.text('Data Source Setup'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('layout-panel-setup-1')));
    await tester.pumpAndSettle();
    final titleField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Title',
    );
    await tester.enterText(titleField, 'Edited title');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Title: Edited title'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('layout-edit-panel-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('layout-data-source-setup-1')));
    await tester.pumpAndSettle();
    expect(find.text('Data Source Setup'), findsOneWidget);
    expect(find.byKey(const ValueKey('data-mode-dropdown-0')), findsOneWidget);
    await tester
        .ensureVisible(find.byKey(const ValueKey('data-mode-dropdown-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('data-mode-dropdown-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('data-mode-0-option-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('data-mode-0-divider-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('data-mode-0-divider-2')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('data-mode-0-option-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('layout-preview-panel-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('layout-delete-panel-2')));
    await tester.pump();
    expect(find.byKey(const ValueKey('layout-preview-panel-1')), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(app.columns, hasLength(1));
    expect(app.columns.single, hasLength(1));
    expect(app.columns.single.single['title'], 'Edited title');
    expect(tester.takeException(), isNull);
  });

  testWidgets('About dialog reflows and opens links on a phone',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    final openedUrls = <Uri>[];

    await tester.pumpWidget(
      MaterialApp(
        home: AboutDialogWidget(
          systemInfoLoader: () async => const RuntimeSystemInfo(
            name: 'iOS',
            version: '18.5',
            architecture: 'arm64',
          ),
          gitVersionLoader: () async => '7.0.r42.g123456789',
          urlOpener: (uri) async {
            openedUrls.add(uri);
            return true;
          },
          updateChecker: () async => const ReleaseUpdate(
            latestVersion: 'v99.0.0',
            releaseUrl:
                'https://github.com/wwktz/MdsScope/releases/tag/v99.0.0',
            updateAvailable: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('7.0.r42.g123456789'), findsOneWidget);
    expect(find.text('iOS (18.5) (arm64)'), findsOneWidget);

    final narrowVersionRow = find.byKey(
      const ValueKey('about-row-narrow-MdsScope Version'),
    );
    expect(narrowVersionRow, findsOneWidget);
    expect(
      tester.widget<Column>(narrowVersionRow).crossAxisAlignment,
      CrossAxisAlignment.center,
    );
    await tester.ensureVisible(find.text('MdsScope Version'));
    expect(
      tester.getCenter(find.text('MdsScope Version')).dx,
      closeTo(tester.getCenter(find.text(currentMdsScopeVersion)).dx, 0.5),
    );

    await tester.ensureVisible(find.text('GitHub'));
    await tester.tap(find.text('GitHub'));
    await tester.pump();
    expect(openedUrls.single, Uri.parse('https://github.com/wwktz/MdsScope'));

    await tester.ensureVisible(find.text('Update'));
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Open Release'), findsOneWidget);
    await tester.tap(find.text('Open Release'));
    await tester.pumpAndSettle();

    expect(
      openedUrls.last,
      Uri.parse('https://github.com/wwktz/MdsScope/releases/tag/v99.0.0'),
    );
    expect(tester.takeException(), isNull);
  });
}
