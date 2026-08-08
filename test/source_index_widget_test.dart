import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/models/app_state.dart';
import 'package:mdslens/services/user_data_store.dart';
import 'package:mdslens/theme/mdslens_theme.dart';
import 'package:mdslens/widgets/plot_panel.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    UserDataStore.disableFileStorageForTests = true;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Data Source loads focused and cross-tree suggestions', (
    tester,
  ) async {
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
          theme: MDSLensTheme.light(),
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
    final signalTextField = find.descendant(
      of: signalField,
      matching: find.byType(TextField),
    );
    await tester.tap(signalTextField);
    expect(
        tester.widget<TextField>(signalTextField).focusNode?.hasFocus, isTrue);
    await tester.enterText(signalTextField, '');
    final signalMenu = find.byKey(const ValueKey('autocomplete-signal-menu'));
    for (var attempt = 0;
        attempt < 120 && signalMenu.evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(signalMenu, findsOneWidget);
    final signalList = tester.widget<ListView>(
      find.descendant(of: signalMenu, matching: find.byType(ListView)),
    );
    expect(signalList.semanticChildCount, 3967);

    final treeField = find.byKey(const ValueKey('data-tree-0'));
    final treeTextField = find.descendant(
      of: treeField,
      matching: find.byType(TextField),
    );
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
      tester.widget<TextField>(treeTextField).controller?.text,
      'pcs_east',
    );
    await tester.sendEventToBinding(mouse.up());

    await tester.tap(signalTextField);
    await tester.enterText(signalTextField, r'\pcrl');
    await tester.pumpAndSettle();
    final stableSignalMenuElement = tester.element(signalMenu);
    await tester.enterText(signalTextField, r'\pcrl0');
    await tester.pump();
    expect(
      tester.element(signalMenu),
      same(stableSignalMenuElement),
      reason: 'typing should update the existing completion overlay in place',
    );
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

    await tester.tap(treeTextField);
    await tester.enterText(treeTextField, '');

    await tester.tap(signalTextField);
    await tester.enterText(signalTextField, r'\prad_axu');
    final ambiguousSignal = find.text(r'\PRAD_AXUV');
    for (var attempt = 0;
        attempt < 120 && ambiguousSignal.evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(ambiguousSignal, findsOneWidget);
    await tester.tap(ambiguousSignal);
    await tester.pumpAndSettle();
    expect(treeMenu, findsOneWidget);
    expect(find.text('analysis'), findsOneWidget);
    expect(find.text('prad_east'), findsOneWidget);
    expect(tester.widget<TextField>(treeTextField).focusNode?.hasFocus, isTrue);
    await tester.tap(find.text('analysis'));
    await tester.pump();
    expect(
        tester.widget<TextField>(treeTextField).controller?.text, 'analysis');
    expect(
      tester.widget<TextField>(signalTextField).focusNode?.hasFocus,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
