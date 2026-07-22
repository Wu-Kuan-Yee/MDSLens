import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:mdsscope/models/app_state.dart';
import 'package:mdsscope/services/external_url_launcher.dart';
import 'package:mdsscope/widgets/plot_panel.dart';
import 'package:mdsscope/widgets/plot_grid.dart';
import 'package:mdsscope/widgets/toolbar.dart';
import 'package:provider/provider.dart';

void main() {
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

  testWidgets('Toolbar fills and reflows at phone, tablet, and desktop widths',
      (tester) async {
    final app = AppState();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;

    for (final width in [320.0, 768.0, 1440.0]) {
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
}
