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
import 'package:mdsscope/services/update_service.dart';
import 'package:mdsscope/theme/mdsscope_theme.dart';
import 'package:mdsscope/widgets/dialogs/about.dart';
import 'package:mdsscope/widgets/plot_panel.dart';
import 'package:mdsscope/widgets/plot_grid.dart';
import 'package:mdsscope/widgets/plot_render_cache.dart';
import 'package:mdsscope/widgets/responsive_plot_layout.dart';
import 'package:mdsscope/widgets/toolbar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
  });

  test('Release versions are compared semantically', () {
    expect(compareVersions('v7.1.0', '7.0.9'), greaterThan(0));
    expect(compareVersions('7.0', '7.0.0'), 0);
    expect(compareVersions('6.9.9', '7.0.0'), lessThan(0));
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

    await app.openFile();
    await Future<void>.delayed(Duration.zero);

    expect(app.shotText, '143850');
    expect(jsonDecode(requestedConfig!)['columns'][0][0]['shot'], '143850');
    expect(app.plots.single.series.single?.points, [
      [0.0, 1.0]
    ]);
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

    await app.openFile();
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

    await app.openFile();

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

    await app.openFile();
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
    final shotField = tester.widget<TextField>(
      find.byKey(const ValueKey('data-shot-0')),
    );
    expect(shotField.controller?.text, '163888');
    await tester.enterText(
      find.byKey(const ValueKey('data-legend-0')),
      'Primary current',
    );
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(signals.single['legend'], 'Primary current');
    expect(signals.single['shot'], '163888');
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

    final layoutDialog = tester.getRect(find.byType(AlertDialog));
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
