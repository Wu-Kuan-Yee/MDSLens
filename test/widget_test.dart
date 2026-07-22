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

void main() {
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

  test('Responsive plot columns preserve order across screen sizes', () {
    final phone = buildResponsivePlotColumns([2, 1, 2], 390);
    expect(phone, hasLength(1));
    expect(phone.single.map((cell) => cell.plotIndex), [0, 1, 2, 3, 4]);

    final tablet = buildResponsivePlotColumns([2, 1, 2], 700);
    expect(tablet, hasLength(2));
    expect(tablet.map((column) => column.length), [3, 2]);

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

  testWidgets(
      'Touch plots use one finger for scrolling and two fingers for the view',
      (tester) async {
    final app = AppState();
    app.applyLayoutList([4]);
    for (var row = 0; row < 4; row++) {
      app.updatePlotSeriesByColRow(
          0,
          row,
          0,
          [
            [0, 0],
            [5, 5],
            [10, 10]
          ],
          null);
    }
    app.interactionMode = 1;
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

    final list = find.byKey(const ValueKey('plot-scroll-view'));
    final scrollable = find.descendant(
      of: list,
      matching: find.byType(Scrollable),
    );
    final scrollPosition = tester.state<ScrollableState>(scrollable).position;
    expect(scrollPosition.maxScrollExtent, greaterThan(0));
    LineChart firstChart() =>
        tester.widgetList<LineChart>(find.byType(LineChart)).first;
    final initialMinX = firstChart().data.minX;
    final initialMaxX = firstChart().data.maxX;
    final initialMinY = firstChart().data.minY;
    final initialMaxY = firstChart().data.maxY;

    final firstPanel = find.byKey(const ValueKey('plot-panel-0'));
    var center = tester.getCenter(firstPanel);
    await tester.tapAt(center);
    await tester.pump();
    final tappedCrosshair = app.crosshairX;
    expect(tappedCrosshair, isNotNull);

    final verticalDrag = await tester.startGesture(center, pointer: 10);
    await tester.pump();
    await verticalDrag.moveBy(const Offset(0, -40));
    await tester.pump();
    await verticalDrag.moveBy(const Offset(0, -40));
    await tester.pump();
    await verticalDrag.up();
    await tester.pumpAndSettle();

    expect(scrollPosition.pixels, greaterThan(0));
    expect(firstChart().data.minX, initialMinX);
    expect(firstChart().data.maxX, initialMaxX);
    expect(firstChart().data.minY, initialMinY);
    expect(firstChart().data.maxY, initialMaxY);
    expect(app.crosshairX, tappedCrosshair);

    scrollPosition.jumpTo(0);
    await tester.pumpAndSettle();
    center = tester.getCenter(firstPanel);
    final horizontalDrag = await tester.startGesture(center, pointer: 11);
    await horizontalDrag.moveBy(const Offset(120, 0));
    await tester.pump();
    await horizontalDrag.up();
    await tester.pumpAndSettle();

    expect(scrollPosition.pixels, 0);
    expect(firstChart().data.minX, initialMinX);
    expect(firstChart().data.maxX, initialMaxX);
    expect(firstChart().data.minY, initialMinY);
    expect(firstChart().data.maxY, initialMaxY);
    expect(app.crosshairX, tappedCrosshair);

    center = tester.getCenter(firstPanel);
    final first = await tester.startGesture(
      center.translate(-30, 20),
      pointer: 12,
    );
    final second = await tester.startGesture(
      center.translate(30, 20),
      pointer: 13,
    );
    await tester.pump();
    await first.moveBy(const Offset(-25, -55));
    await second.moveBy(const Offset(25, -55));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    expect(scrollPosition.pixels, 0);
    expect(firstChart().data.maxX - firstChart().data.minX,
        lessThan(initialMaxX - initialMinX));
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
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final (width, expectedColumns) in [(390.0, 1), (800.0, 2)]) {
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
