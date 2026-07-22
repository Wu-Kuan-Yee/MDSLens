import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
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

    final zoomedWidth = chart().data.maxX - chart().data.minX;
    expect(zoomedWidth, lessThan(initialWidth));

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

    Finder elevatedButtons(Finder group) =>
        find.descendant(of: group, matching: find.byType(ElevatedButton));
    Finder outlinedButtons(Finder group) =>
        find.descendant(of: group, matching: find.byType(OutlinedButton));

    final fileActions = find.byKey(const ValueKey('toolbar-file-actions'));
    final navigation = find.byKey(const ValueKey('toolbar-shot-navigation'));
    final modes = find.byKey(const ValueKey('toolbar-mode-actions'));
    final themes = find.byKey(const ValueKey('toolbar-theme-actions'));
    expectEqualRow(fileActions, elevatedButtons, 3);
    expectEqualRow(navigation, elevatedButtons, 3);
    expectEqualRow(modes, outlinedButtons, 2);
    expectEqualRow(themes, outlinedButtons, 3);

    final orderedGroups = [
      fileActions,
      themes,
      find.byKey(const ValueKey('toolbar-shot-info')),
      find.byKey(const ValueKey('toolbar-shot-entry')),
      navigation,
    ];
    final tops = orderedGroups.map(tester.getTopLeft).map((p) => p.dy).toList();
    for (var i = 1; i < tops.length; i++) {
      expect(tops[i], greaterThan(tops[i - 1]));
    }
    expect(tester.getTopLeft(modes).dy,
        closeTo(tester.getTopLeft(navigation).dy, 0.01));
    expect(tester.takeException(), isNull);
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
