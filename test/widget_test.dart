import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:mdsscope/app.dart';
import 'package:mdsscope/pages/main_page.dart';
import 'package:mdsscope/models/app_state.dart';
import 'package:mdsscope/services/external_url_launcher.dart';
import 'package:mdsscope/services/update_service.dart';
import 'package:mdsscope/theme/mdsscope_theme.dart';
import 'package:mdsscope/widgets/dialogs/about.dart';
import 'package:mdsscope/widgets/plot_panel.dart';
import 'package:mdsscope/widgets/plot_grid.dart';
import 'package:mdsscope/widgets/responsive_plot_layout.dart';
import 'package:mdsscope/widgets/toolbar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    expectEqualRow(fileActions, outlinedButtons, 3);
    expectEqualRow(navigation, outlinedButtons, 3);
    expectEqualRow(modes, outlinedButtons, 2);
    expect(
      find.descendant(of: themes, matching: find.byType(OutlinedButton)),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('theme-mode-switch')), findsOneWidget);
    expect(find.byIcon(Icons.light_mode_rounded), findsOneWidget);
    expect(find.byIcon(Icons.computer_rounded), findsOneWidget);
    expect(find.byIcon(Icons.dark_mode_rounded), findsOneWidget);
    expect(find.byTooltip('Open configuration'), findsOneWidget);
    expect(find.byTooltip('Save configuration'), findsOneWidget);
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
    final firstRateOption = tester.widget<Container>(
      find.byKey(const ValueKey('rate-option-0')),
    );
    final decoration = firstRateOption.decoration as BoxDecoration;
    expect(decoration.border?.bottom.width, greaterThan(0));
    final rateDropdown = tester.widget<DropdownButton<int>>(
      find.byKey(const ValueKey('toolbar-rate-dropdown')),
    );
    expect(rateDropdown.itemHeight, 48);
    expect(rateDropdown.menuMaxHeight, 320);
    expect(rateDropdown.borderRadius, BorderRadius.circular(12));
    await tester.tap(find.byKey(const ValueKey('rate-option-0')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuDivider), findsNWidgets(3));
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
