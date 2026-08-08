import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:mdslens/app.dart';
import 'package:mdslens/pages/main_page.dart';
import 'package:mdslens/models/app_state.dart';
import 'package:mdslens/services/credential_store.dart';
import 'package:mdslens/services/external_url_launcher.dart';
import 'package:mdslens/services/identity_file_access.dart';
import 'package:mdslens/services/incoming_configuration_service.dart';
import 'package:mdslens/services/keyboard_shortcuts.dart';
import 'package:mdslens/services/platform_file_dialog.dart';
import 'package:mdslens/services/runtime_build_info.dart';
import 'package:mdslens/services/simple_zip.dart';
import 'package:mdslens/services/source_index.dart';
import 'package:mdslens/services/update_installer.dart';
import 'package:mdslens/services/update_service.dart';
import 'package:mdslens/services/user_data_store.dart';
import 'package:mdslens/theme/mdslens_theme.dart';
import 'package:mdslens/widgets/dialogs/about.dart';
import 'package:mdslens/widgets/dialogs/login.dart';
import 'package:mdslens/widgets/dialogs/keyboard_mode.dart';
import 'package:mdslens/widgets/dialogs/multi_panel_export.dart';
import 'package:mdslens/widgets/configuration_drop_region.dart';
import 'package:mdslens/widgets/plot_panel.dart';
import 'package:mdslens/widgets/plot_grid.dart';
import 'package:mdslens/widgets/plot_render_cache.dart';
import 'package:mdslens/widgets/polished_dropdown.dart';
import 'package:mdslens/widgets/polished_popup_menu.dart';
import 'package:mdslens/widgets/responsive_plot_layout.dart';
import 'package:mdslens/widgets/toolbar.dart';
import 'package:mdslens/widgets/vim_focus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Finder tooltipStartingWith(String prefix) => find.byWidgetPredicate(
      (widget) =>
          widget is Tooltip && (widget.message?.startsWith(prefix) ?? false),
    );

void main() {
  setUp(() {
    UserDataStore.disableFileStorageForTests = true;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('Configuration drop accepts only TOML and WebScope file names', () {
    expect(isSupportedConfigurationFileName('layout.toml'), isTrue);
    expect(isSupportedConfigurationFileName('LAYOUT.WEBSCP'), isTrue);
    expect(isSupportedConfigurationFileName('layout.webscp.txt'), isFalse);
    expect(isSupportedConfigurationFileName('layout.json'), isFalse);
  });

  testWidgets('Dropped configuration requires explicit confirmation', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await confirmDroppedConfigurationImport(
                context,
                'experiment.webscp',
              );
            },
            child: const Text('Confirm drop'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Confirm drop'));
    await tester.pumpAndSettle();
    expect(find.text('Import Dropped Configuration?'), findsOneWidget);
    expect(find.text('experiment.webscp'), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();
    expect(
      find.text('Import Dropped Configuration?'),
      findsOneWidget,
      reason: 'tapping the modal barrier must not silently abandon the import',
    );
    expect(result, isNull);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>(),
      isNull,
    );
    expect(result, isFalse);

    await tester.tap(find.text('Confirm drop'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('cancel-dropped-configuration')),
    );
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('Confirm drop'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('import-dropped-configuration')),
    );
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('Android dropped content URIs are read through ContentResolver', (
    tester,
  ) async {
    const channel = MethodChannel('mdslens/drop_file_access.test');
    final expected = Uint8List.fromList(utf8.encode('title = "Ip"'));
    String? receivedUri;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      receivedUri = call.arguments as String;
      return expected;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final file = DropItemFile(
      'content://zte.com.cn.filer.fileprovider/config1.toml',
      name: 'config1.toml',
    );

    final bytes = await readDroppedConfigurationBytes(
      file,
      androidOverride: true,
      channel: channel,
    );

    expect(receivedUri, file.path);
    expect(bytes, expected);
  });

  testWidgets('Only the waveform area is a configuration drop target', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: MainPage()),
      ),
    );
    await tester.pump();

    final dropRegion = find.byKey(
      const ValueKey('waveform-configuration-drop-region'),
    );
    final toolbar = find.byType(ResponsiveToolbar);
    expect(dropRegion, findsOneWidget);
    expect(toolbar, findsOneWidget);
    expect(
      tester.getTopLeft(dropRegion).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(toolbar).dy),
    );
  });

  testWidgets('Vim mode opens a keyboard command palette', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: MainPage()),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.semicolon,
      character: ':',
      physicalKey: PhysicalKeyboardKey.semicolon,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.semicolon);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('vim-command-palette')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('vim-command-query')),
      'Point mode',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(app.interactionMode, 1);

    // With an empty command line, Vim j selects the next command and Enter
    // runs it without requiring a mouse click.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.semicolon,
      character: ':',
      physicalKey: PhysicalKeyboardKey.semicolon,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.semicolon);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('recent-configurations-dialog')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('Vim command input accepts g in Insert mode', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(
      LogicalKeyboardKey.semicolon,
      character: ':',
      physicalKey: PhysicalKeyboardKey.semicolon,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.semicolon);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    // Insert mode keeps the Vim ring animation alive, so settling forever is
    // neither necessary nor possible here.
    await tester.pump(const Duration(milliseconds: 300));

    final palette = find.byKey(const ValueKey('vim-command-palette'));
    final queryFinder = find.byKey(const ValueKey('vim-command-query'));
    final queryContext = tester.element(queryFinder);
    final query = tester.widget<TextField>(queryFinder);
    query.controller!.clear();
    query.focusNode!.requestFocus();
    VimInputModeScope.setMode(
      tester.element(palette),
      VimInputMode.normal,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(VimInputModeScope.mode(queryContext), VimInputMode.insert);

    // Two G strokes must remain ordinary text-input events. Before the fix,
    // the popup route's global handler interpreted them as Vim `gg` and
    // moved focus away from the command field.
    for (var index = 0; index < 2; index++) {
      await tester.sendKeyDownEvent(
        LogicalKeyboardKey.keyG,
        character: 'g',
        physicalKey: PhysicalKeyboardKey.keyG,
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyG);
    }
    await tester.pump();
    expect(query.focusNode!.hasFocus, isTrue);
    expect(VimInputModeScope.mode(queryContext), VimInputMode.insert);
    await tester.enterText(queryFinder, 'g');
    expect(query.controller!.text, 'g');

    // Esc now leaves the input cell in Normal mode without closing the
    // palette.  The filtered command list remains available to j/k.
    await tester.enterText(queryFinder, 'panel');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('vim-command-palette')), findsOneWidget);
    expect(VimInputModeScope.mode(queryContext), VimInputMode.normal);
    expect(query.controller!.text, 'panel');
    final commandTiles = find.descendant(
      of: find.byKey(const ValueKey('vim-command-list')),
      matching: find.byType(ListTile),
    );
    int selectedCommandIndex() => tester
        .widgetList<ListTile>(commandTiles)
        .toList()
        .indexWhere((tile) => tile.selected);
    final beforeJ = selectedCommandIndex();
    expect(beforeJ, greaterThanOrEqualTo(0));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(selectedCommandIndex(), isNot(beforeJ));
    expect(find.byKey(const ValueKey('vim-command-palette')), findsOneWidget);
  });

  testWidgets('Vim mode gives dialogs and plots a complete keyboard path', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    // The login action can be opened with Enter once its toolbar control owns
    // focus, and the first field is immediately ready for keyboard input.
    await tester.tap(find.byTooltip('Login'));
    await tester.pumpAndSettle();
    final apiFocus = tester
        .widget<TextField>(
          find.byKey(const ValueKey('login-api-url')),
        )
        .focusNode!;
    expect(apiFocus.hasFocus, isTrue);

    // Escape leaves text-editing mode without dismissing the dialog; a second
    // Escape cancels the dialog itself.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('login-api-url')), findsOneWidget);
    expect(apiFocus.hasFocus, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('login-api-url')), findsNothing);

    // A focused plot represents its parent Column first. Enter explicitly
    // enters that Column; a second Enter activates the selected Panel and
    // opens its context menu.
    final plot = find.byType(PlotPanel).first;
    await tester.tap(plot);
    await tester.pump();
    expect(app.selectedPlotIndex, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.panel,
    );
    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsNothing,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('plot-context-menu-maximize')),
      findsNothing,
    );

    // Maximizing a non-first Panel must preserve its identity. The context
    // menu then operates on that Panel, not on the state that happened to be
    // first in the regular grid.
    app.plots[1].setViewRange(1, 2, 3, 4);
    app.maximizePlot(1);
    await tester.pumpAndSettle();
    final maximized = find.byKey(const ValueKey('plot-panel-1'));
    expect(maximized, findsOneWidget);
    await tester.tapAt(
      tester.getCenter(maximized),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await tester.pump();
    final menuFocus = tester
        .widgetList<Focus>(
          find.descendant(
            of: find.byKey(
              const ValueKey('plot-context-menu-show-all'),
            ),
            matching: find.byType(Focus),
          ),
        )
        .map((widget) => widget.focusNode)
        .whereType<FocusNode>()
        .firstWhere(
          (node) => node.debugLabel == 'polished-popup-menu-item',
        );
    menuFocus.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(menuFocus));
    await tester.pump(const Duration(milliseconds: 35));
    expect(
      find.byKey(const ValueKey('plot-context-menu-show-all')),
      findsOneWidget,
    );

    void expectMenuRingAligned() {
      final ring = tester.getRect(
        find.byKey(const ValueKey('vim-popup-focus-ring')),
      );
      final focusedItem = tester.getRect(
        find.byKey(const ValueKey('plot-context-menu-show-all')),
      );
      expect(
        (ring.center - focusedItem.center).distance,
        lessThan(1),
        reason: 'the Vim ring must follow the popup route animation',
      );
    }

    expectMenuRingAligned();
    await tester.pump(const Duration(milliseconds: 70));
    expectMenuRingAligned();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('plot-context-menu-show-all')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('plot-context-menu-reset-current')),
    );
    await tester.pumpAndSettle();
    expect(app.plots[1].viewMinX, isNull);
  });

  testWidgets('Vim root navigation does not implicitly enter a plot Column', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    final plot = find.byType(PlotPanel).first;
    await tester.tap(plot);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlotPanel>(),
      isNotNull,
    );

    // A selected Column is a character of the root page. K therefore moves
    // on that parent page and must not silently enter its last Panel.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlotPanel>(),
      isNull,
    );

    // G returns to the root page's final row, whose first character is the
    // first waveform Column. J at that level remains a parent-page motion;
    // it does not enter a Panel.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.column,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.column,
    );
  });

  testWidgets('Panel selection frame stays separate from the Vim focus ring', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(false);
    app.selectPanel(0, 0);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    BoxDecoration panelDecoration() {
      final frame = tester.widget<Container>(
        find.byKey(const ValueKey('plot-panel-frame-0')),
      );
      return frame.decoration! as BoxDecoration;
    }

    expect(
      panelDecoration().border!.top.color,
      const Color(0xFFFF00FF),
    );

    app.setVimMode(true);
    await tester.pump();
    expect(
      panelDecoration().border!.top.color,
      isNot(const Color(0xFFFF00FF)),
    );

    await tester.tap(find.byKey(const ValueKey('plot-panel-0')));
    await tester.pump();
    expect(find.byKey(const ValueKey('vim-focus-ring')), findsOneWidget);
    expect(
      panelDecoration().border!.top.color,
      isNot(const Color(0xFFFF00FF)),
    );
  });

  testWidgets('Vim Normal-mode inputs release HJKL to nearby controls', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'shotHistory': '["163702"]',
      'shot': '163703',
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    final shot = find.byKey(const ValueKey('toolbar-shot-entry'));
    await tester
        .tap(find.descendant(of: shot, matching: find.byType(TextField)));
    await tester.pump();
    expect(app.shotFocusNode.hasFocus, isTrue);

    // Normal mode treats the field as a control. H must immediately reach the
    // recent-shot dropdown instead of being consumed by the text cursor.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PolishedDropdown<String>>(),
      isNotNull,
    );
  });

  testWidgets('Vim virtual pages support gg, G, and i field editing', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    final plot = find.byType(PlotPanel).first;
    await tester.tap(plot);
    await tester.pump();

    // A Column is a child page of the application page. While the outer
    // cursor is still on that Column, gg/G operate on the parent page: gg is
    // the first root character (Open configuration) and G is the first
    // character in its last row (Column 1).
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlotPanel>(),
      isNull,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    var firstPanel = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(firstPanel?.vimColumn, 0);
    expect(firstPanel?.vimRow, 0);
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.column,
    );

    // J/K move only within the current parent page and may not enter a Column
    // implicitly. Enter (or i) is the explicit child-page transition.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    firstPanel = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(firstPanel?.vimColumn, 0);
    expect(firstPanel?.vimRow, 0);
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.column,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.panel,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    final lastPanel = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(lastPanel?.vimColumn, 0);
    expect(lastPanel?.vimRow, greaterThanOrEqualTo(firstPanel?.vimRow ?? 0));

    // Reaching a TextField selects it as one virtual character cell.  Normal
    // mode is read-only; i enters Insert mode and toggles the real field.
    app.shotFocusNode.requestFocus();
    await tester.pump();
    final shotField = find.byKey(const ValueKey('toolbar-shot-entry'));
    final field =
        find.descendant(of: shotField, matching: find.byType(TextField));
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    final originalShot = app.shotCtrl.text;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(tester.widget<TextField>(field).readOnly, isFalse);
    await tester.enterText(field, 'vim-cancelled');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(app.shotCtrl.text, originalShot);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    app.shotCtrl.text = 'vim-committed';
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(app.shotCtrl.text, 'vim-committed');
  });

  testWidgets('Vim gg starts at Open configuration', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlotPanel).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    final tooltip = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<Tooltip>()
        ?.message;
    expect(tooltip, startsWith('Open configuration'));
  });

  testWidgets('Vim Enter activates a toolbar control only once',
      (tester) async {
    var openCalls = 0;
    final app = AppState(
      configOpenPicker: () async {
        openCalls++;
        return null;
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlotPanel).first);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<Tooltip>()
          ?.message,
      startsWith('Open configuration'),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(openCalls, 1);
  });

  testWidgets('Vim Enter activates custom toolbar controls and dropdowns',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'shotHistory': '["163702"]',
      'shot': '163703',
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    FocusManager.instance.rootScope.descendants
        .firstWhere((node) => node.debugLabel == 'dropdown-toolbar-rate')
        .requestFocus();
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'dropdown-toolbar-rate',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar-rate-option-0')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    FocusManager.instance.rootScope.descendants
        .firstWhere((node) => node.debugLabel == 'theme-mode-dark')
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(app.themeMode, 1);

    FocusManager.instance.rootScope.descendants
        .firstWhere(
          (node) => node.debugLabel == 'dropdown-toolbar-shot-history',
        )
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('toolbar-shot-history-menu-action')),
      findsOneWidget,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    FocusManager.instance.rootScope.descendants
        .firstWhere(
          (node) => node.debugLabel == 'toolbar-recent-configurations',
        )
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Recent Configurations'), findsOneWidget);
  });

  testWidgets('Vim can leave Manage Shot History with Escape', (tester) async {
    SharedPreferences.setMockInitialValues({
      'shotHistory': '["163702","163701"]',
      'shot': '163703',
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    FocusManager.instance.rootScope.descendants
        .firstWhere(
          (node) => node.debugLabel == 'dropdown-toolbar-shot-history',
        )
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shot-history-selection-list')),
        findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<VimPageScope>()
          ?.pageId,
      'dialog',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('shot-history-selection-list')),
        findsNothing);
  });

  testWidgets('Vim dropdown menus navigate options with j and k',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    FocusManager.instance.rootScope.descendants
        .firstWhere((node) => node.debugLabel == 'dropdown-toolbar-rate')
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'dropdown-toolbar-rate-option-0',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'dropdown-toolbar-rate-option-1',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(app.dataMode, 1);
  });

  testWidgets('Vim data source dropdown keeps its last option framed',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          builder: (context, child) => VimModeScope(
            notifier: app,
            child: VimFocusHost(child: child ?? const SizedBox.shrink()),
          ),
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDataSourceSetupEditor(
                context,
                signals: const [],
                defaultShot: '163701',
              ),
              child: const Text('Open data source'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open data source'));
    await tester.pumpAndSettle();

    FocusManager.instance.rootScope.descendants
        .firstWhere(
          (node) => node.debugLabel == 'dropdown-data-hide-mode-0',
        )
        .requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'dropdown-data-hide-mode-0-option-0',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'dropdown-data-hide-mode-0-option-2',
    );
    final option = tester.getRect(
      find.byKey(const ValueKey('data-hide-mode-0-option-2')),
    );
    final vimFrame = find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
        return false;
      }
      final border = (widget.decoration as BoxDecoration).border;
      return border is Border && border.top.color == const Color(0xFFD946EF);
    });
    expect(vimFrame, findsOneWidget);
    final frame = tester.getRect(vimFrame);
    expect(frame.center.dx, closeTo(option.center.dx, 1));
    expect(frame.center.dy, closeTo(option.center.dy, 1));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<PolishedDropdown<int>>(
            find.byKey(const ValueKey('data-hide-mode-dropdown-0')),
          )
          .value,
      signalHideModePersistent,
    );
  });

  testWidgets('Vim data source can enter Curve Color settings', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          builder: (context, child) => VimModeScope(
            notifier: app,
            child: VimFocusHost(child: child ?? const SizedBox.shrink()),
          ),
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDataSourceSetupEditor(
                context,
                signals: const [],
                defaultShot: '163701',
              ),
              child: const Text('Open data source'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open data source'));
    await tester.pumpAndSettle();

    final colorFocus = tester.widget<Focus>(
      find.byKey(const ValueKey('data-color-0')),
    );
    colorFocus.focusNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Curve Color'), findsOneWidget);
    expect(find.byKey(const ValueKey('curve-color-preset-0')), findsOneWidget);
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'curve-color-preset-0',
    );
  });

  testWidgets('Vim plot navigation follows columns and Point edit mode', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    for (final plot in app.plots) {
      plot.series[0] = SeriesData(
        points: const [
          [0, 1],
          [1, 2],
          [2, 3],
        ],
      );
    }
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> expectFocusedPlot(int plotIndex) async {
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlotPanel>();
      expect(focused?.plotIdx, plotIndex);
    }

    await tester.tap(find.byKey(const ValueKey('plot-panel-0')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await expectFocusedPlot(3); // Column 2, Panel 1.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await expectFocusedPlot(3); // Still on the Column character.
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.column,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await expectFocusedPlot(4); // Column 2, Panel 2 after explicit entry.

    // An entered Column is isolated: H cannot leak into a sibling Column. Esc
    // returns to the parent plot-grid page, where H selects Column 1 without
    // consuming the key for Point-mode crosshair stepping.
    app.interactionMode = 1;
    app.activatePointForCurrentPanel();
    final beforeNormalMove = app.crosshairX;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await expectFocusedPlot(4);
    expect(app.crosshairX, beforeNormalMove);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await expectFocusedPlot(0); // Column 1 representative.
    expect(app.crosshairX, beforeNormalMove);

    // Enter enters the selected Column and chooses its first Panel. i then
    // enters plot editing; H/L and the arrow keys move the crosshair, and
    // Escape returns to the non-blinking Normal state.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await expectFocusedPlot(0); // Column 1, Panel 1.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    final mainContext = tester.element(find.byType(MainPage));
    expect(VimInputModeScope.mode(mainContext), VimInputMode.plot);
    final beforeEditMove = app.crosshairX;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(app.crosshairX, isNot(beforeEditMove));
    // b/w use a viewport-relative step while Point editing is active. With
    // this deliberately small fixture the adaptive step is one real sample,
    // which still proves the key path does not leak back into page navigation.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pump();
    expect(app.crosshairX, lessThan(beforeEditMove!));
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlotPanel>()
          ?.plotIdx,
      0,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(VimInputModeScope.mode(mainContext), VimInputMode.normal);
    expect(
      VimInputModeScope.plotSelectionLevel(mainContext),
      VimPlotSelectionLevel.column,
    );
  });

  testWidgets('Vim plot navigation keeps unequal columns nested',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    app.applyLayoutList([10, 11, 10, 8]);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('plot-panel-0')));
    await tester.pump();
    // A Column is a child page of the application page. gg/G at this level
    // must stay on the parent page rather than entering a Panel implicitly.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlotPanel>(),
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('plot-panel-0')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    var focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(focused?.vimColumn, 0);
    expect(focused?.vimRow, 9);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(focused?.vimColumn, 0);
    expect(focused?.vimRow, 9);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(focused?.vimRow, 9);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(focused?.vimRow, 0);

    // One physical Escape leaves exactly one semantic level: Panel -> its
    // unique parent Column. Holding the key long enough to generate repeats
    // must not immediately escape the Column as well.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.column,
    );
    focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(focused?.vimColumn, 0);

    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    focused = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<PlotPanel>();
    expect(focused?.vimColumn, 0);
    expect(
      VimInputModeScope.plotSelectionLevel(
        tester.element(find.byType(MainPage)),
      ),
      VimPlotSelectionLevel.column,
    );
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);

    // A new, deliberate Escape leaves the selected Column for the plot grid.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<PlotPanel>(),
      isNull,
    );
  });

  testWidgets('Vim settings menu focuses its first option', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'settings-web',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'settings-layout');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'settings-fonts');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'settings-layout');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Layout Setup'), findsOneWidget);
    final firstLayoutCell = Focus.maybeOf(
      tester.element(find.byKey(const ValueKey('layout-column-focus-0'))),
      scopeOk: false,
    );
    expect(firstLayoutCell?.hasFocus, isTrue);
  });

  testWidgets('Vim Layout Setup keeps Column pages isolated', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    app.applyLayoutList([2, 1]);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();

    VimLayoutFocus? focusedLayout() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<VimLayoutFocus>();

    // The root Layout Setup page starts with the semantic row of Columns,
    // regardless of which action bar control happened to have focus before
    // `gg` was pressed.
    final addPanel = Focus.maybeOf(
      tester.element(find.text('Add panel')),
      scopeOk: false,
    );
    addPanel!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(focusedLayout()?.isColumn, isTrue);
    expect(focusedLayout()?.column, 0);

    expect(focusedLayout()?.isColumn, isTrue);
    expect(focusedLayout()?.column, 0);

    // `i` explicitly enters the selected Column's child page.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(focusedLayout()?.isColumn, isFalse);
    expect(focusedLayout()?.column, 0);
    expect(focusedLayout()?.row, 0);

    // Once inside Column 1, horizontal motion is consumed instead of
    // switching to Column 2.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(focusedLayout()?.isColumn, isFalse);
    expect(focusedLayout()?.column, 0);

    // Escape returns to the Column character on the parent page, where L can
    // select the next Column. It must not implicitly enter that Column.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(focusedLayout()?.isColumn, isTrue);
    expect(focusedLayout()?.column, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(focusedLayout()?.isColumn, isTrue);
    expect(focusedLayout()?.column, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(focusedLayout()?.isColumn, isFalse);
    expect(focusedLayout()?.column, 1);
  });

  testWidgets('Vim About panel exposes links and actions', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About MDSLens'));
    await tester.pumpAndSettle();

    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<VimPageScope>()
          ?.pageId,
      'about',
    );
    final firstAboutFocus = Focus.maybeOf(
      tester.element(find.text('MdsScope project')),
      scopeOk: false,
    );
    expect(firstAboutFocus?.hasFocus, isTrue);

    // H/J/K/L stay inside the About page and eventually reach its action row.
    for (var index = 0; index < 12; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
    }
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    expect(
      focusedContext?.findAncestorWidgetOfExactType<OutlinedButton>() != null ||
          focusedContext?.findAncestorWidgetOfExactType<FilledButton>() != null,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<VimPageScope>()
          ?.pageId,
      'about',
    );
  });

  testWidgets('Vim Keyboard Mode reaches both action buttons', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    // The panel must keep its own H/J/K/L route even while the application
    // is already in Vim mode; this is the path reached from Settings in real
    // keyboard-only use.
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keyboard Mode'));
    await tester.pumpAndSettle();

    bool primaryHasKey(Key key) {
      final primaryContext = FocusManager.instance.primaryFocus?.context;
      var found = primaryContext?.widget.key == key;
      primaryContext?.visitAncestorElements(
        (element) {
          if (element.widget.key == key) {
            found = true;
            return false;
          }
          return true;
        },
      );
      return found;
    }

    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'keyboard-mode-standard',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'keyboard-mode-vim',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      primaryHasKey(const ValueKey('keyboard-mode-toggle-shortcut')),
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      primaryHasKey(const ValueKey('keyboard-mode-cancel')),
      isTrue,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(
      primaryHasKey(const ValueKey('keyboard-mode-apply')),
      isTrue,
    );
  });

  testWidgets('Keyboard Mode keeps HJKL navigation before Vim is enabled',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          builder: (context, child) => VimModeScope(
            notifier: app,
            child: VimFocusHost(child: child ?? const SizedBox.shrink()),
          ),
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => KeyboardModeDialog.show(context),
              child: const Text('Open keyboard mode'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open keyboard mode'));
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel,
        'keyboard-mode-standard');
    expect(find.byKey(const ValueKey('vim-focus-ring')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'keyboard-mode-vim');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'keyboard-mode-toggle-shortcut',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'keyboard-mode-cancel');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(
        FocusManager.instance.primaryFocus?.debugLabel, 'keyboard-mode-apply');
  });

  testWidgets('Vim Keyboard Mode activates cards and actions with Enter',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          builder: (context, child) => VimModeScope(
            notifier: app,
            child: VimFocusHost(child: child ?? const SizedBox.shrink()),
          ),
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => KeyboardModeDialog.show(context),
              child: const Text('Open keyboard mode'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open keyboard mode'));
    await tester.pumpAndSettle();

    // Standard is initially selected. Enter on the Vim card must behave
    // exactly like a pointer tap, before the application preference itself
    // has been switched to Vim mode.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byIcon(Icons.radio_button_checked_rounded), findsOneWidget);

    // The action row must use the same activation path.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(app.vimMode, isTrue);
    expect(find.byKey(const ValueKey('keyboard-mode-dialog')), findsNothing);
  });

  testWidgets('Vim mode can be toggled directly by its configured shortcut',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: MainPage()),
      ),
    );
    await tester.pump();

    final shortcut = app.keyboardShortcuts[MdsShortcutCommand.toggleVimMode]!
        .primary!.strokes.single;
    final modifiers = <LogicalKeyboardKey>[
      if (shortcut.control) LogicalKeyboardKey.controlLeft,
      if (shortcut.alt) LogicalKeyboardKey.altLeft,
      if (shortcut.meta) LogicalKeyboardKey.metaLeft,
      if (shortcut.shift) LogicalKeyboardKey.shiftLeft,
    ];

    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(shortcut.key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.pump();
    expect(app.vimMode, isTrue);

    for (final modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyEvent(shortcut.key);
    for (final modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.pump();
    expect(app.vimMode, isFalse);
  });

  testWidgets('Vim Layout Setup exposes its action row and scroll targets',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    app.applyLayoutList([6, 1, 1, 1, 1]);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();

    final layoutPanelFocus = Focus.maybeOf(
      tester.element(find.byKey(const ValueKey('layout-panel-focus-1'))),
      scopeOk: false,
    );
    layoutPanelFocus!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('layout-delete-selected')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('layout-delete-selected')),
          )
          .onPressed,
      isNull,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('layout-preview-column-0')));
    await tester.pump();
    FocusManager.instance.rootScope.descendants.firstWhere((node) {
      final layout =
          node.context?.findAncestorWidgetOfExactType<VimLayoutFocus>();
      return layout?.isColumn == true && layout?.column == 0;
    }).requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    // The outer semantic Focus owns the action, so its stable debug label is
    // the authoritative identity rather than a descendant Button key.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'layout-reset');

    final mainContext = tester.element(find.byType(MainPage));
    await tester.tap(find.byKey(const ValueKey('layout-preview-column-0')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    // Enter the first Column explicitly before navigating its panel page.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
    }
    final verticalDuringNavigation = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('layout-column-scrollbar-0')),
    );
    expect(
      verticalDuringNavigation.controller?.position.pixels,
      greaterThan(0),
    );
    // Horizontal motion is isolated while inside the Column. Leave the
    // nested page before selecting sibling Columns and scrolling horizontally.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
    }
    final horizontalDuringNavigation = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('layout-horizontal-scrollbar')),
    );
    expect(
      horizontalDuringNavigation.controller?.position.pixels,
      greaterThan(0),
    );
    // H/J/K/L can enter the newly opened route even if Flutter has only
    // focused its scope, and repeated J reaches the bottom action row.
    for (var i = 0; i < 24; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
    }
    // The horizontal and first column vertical scroll positions are both
    // allowed to change when focus moves to an off-screen panel.
    final horizontal = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('layout-horizontal-scrollbar')),
    );
    expect(horizontal.controller?.position.maxScrollExtent, greaterThan(0));
    final vertical = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('layout-column-scrollbar-0')),
    );
    expect(vertical.controller?.position.maxScrollExtent, greaterThan(0));
    expect(VimInputModeScope.mode(mainContext), VimInputMode.normal);
  });

  testWidgets('Multiple panel export selects loaded panels in one dialog', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.plots[0].series[0] = SeriesData(
      points: const [
        [0, 1],
      ],
    );
    app.plots[1].series[0] = SeriesData(
      points: const [
        [0, 2],
      ],
    );
    PanelExportRequest? selected;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                selected = await showMultiPanelExportDialog(context, app);
              },
              child: const Text('Export panels'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Export panels'));
    await tester.pumpAndSettle();
    expect(find.text('Export multiple panels'), findsOneWidget);
    expect(find.text('Export 2 panel(s)'), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-export-format')), findsOneWidget);
    expect(find.byKey(const ValueKey('panel-export-range')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('multi-panel-export-1')),
    );
    await tester.pump();
    expect(find.text('Export 1 panel(s)'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('multi-panel-export-confirm')),
    );
    await tester.pumpAndSettle();
    expect(selected?.panels, {0});
    expect(selected?.format, PanelExportFormat.csv);
    expect(selected?.range, PanelExportRange.allData);
  });

  testWidgets(
    'Multiple panel export mirrors the live waveform column arrangement',
    (tester) async {
      final app = AppState();
      await app.preferencesReady;
      addTearDown(app.dispose);
      app.applyLayoutList([2, 1, 3]);
      for (var index = 0; index < app.plots.length; index++) {
        app.plots[index].series[0] = SeriesData(
          points: [
            [0, index.toDouble()],
          ],
        );
      }
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 950);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showMultiPanelExportDialog(context, app),
                child: const Text('Open export layout'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open export layout'));
      await tester.pumpAndSettle();

      expect(panelExportChoiceColumns(app).map((column) => column.length), [
        2,
        1,
        3,
      ]);
      final panel1 = tester.getRect(
        find.byKey(const ValueKey('multi-panel-export-0')),
      );
      final panel2 = tester.getRect(
        find.byKey(const ValueKey('multi-panel-export-1')),
      );
      final panel3 = tester.getRect(
        find.byKey(const ValueKey('multi-panel-export-2')),
      );
      final panel4 = tester.getRect(
        find.byKey(const ValueKey('multi-panel-export-3')),
      );

      expect(panel2.left, closeTo(panel1.left, 0.1));
      expect(panel2.top, greaterThan(panel1.bottom));
      expect(panel3.left, greaterThan(panel1.right));
      expect(panel4.left, greaterThan(panel3.right));
      expect(panel3.height, greaterThan(panel1.height * 1.7));
      expect(
        find.byKey(const ValueKey('panel-export-horizontal-scrollbar')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('panel-export-vertical-scrollbar')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Vim multi-panel export uses semantic rows before entering Columns',
    (tester) async {
      final app = AppState();
      await app.preferencesReady;
      addTearDown(app.dispose);
      app.setVimMode(true);
      // Deliberately uneven source Columns: a geometry-derived traversal used
      // to treat their cards as several unrelated rows.  The export dialog
      // must instead expose all four Columns as one semantic Vim line.
      app.applyLayoutList([2, 3, 1, 4]);
      for (var index = 0; index < app.plots.length; index++) {
        app.plots[index].series[0] = SeriesData(
          points: [
            [0, index.toDouble()],
          ],
        );
      }
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            builder: (context, child) => VimModeScope(
              notifier: app,
              child: VimFocusHost(child: child ?? const SizedBox.shrink()),
            ),
            home: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showMultiPanelExportDialog(context, app),
                child: const Text('Open Vim export'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open Vim export'));
      await tester.pumpAndSettle();

      FocusNode panelNode(int column, int row) =>
          FocusManager.instance.rootScope.descendants
              .where((node) => node.canRequestFocus && !node.skipTraversal)
              .firstWhere((node) {
            final marker =
                node.context?.findAncestorWidgetOfExactType<VimPlotFocus>();
            return marker?.column == column && marker?.row == row;
          });

      VimPlotFocus? focusedPanel() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<VimPlotFocus>();

      FocusNode controlNode(int row, int column) =>
          FocusManager.instance.rootScope.descendants
              .where((node) => node.canRequestFocus && !node.skipTraversal)
              .firstWhere((node) {
            final marker = node.context
                ?.findAncestorWidgetOfExactType<VimPanelExportControl>();
            return marker?.row == row && marker?.column == column;
          });

      VimPanelExportControl? focusedControl() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<VimPanelExportControl>();

      final dialogContext = tester.element(find.text('Export multiple panels'));

      // J/K move between the dialog's fixed semantic rows.  They must never
      // be affected by how tall any source Column happens to be.
      controlNode(0, 0).requestFocus();
      await tester.pump();
      expect(focusedControl()?.row, 0);
      expect(focusedControl()?.column, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(focusedControl()?.row, 1);
      expect(focusedControl()?.column, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(focusedPanel()?.column, 0);
      expect(focusedPanel()?.row, 0);
      expect(
        VimInputModeScope.plotSelectionLevel(dialogContext),
        VimPlotSelectionLevel.column,
      );

      // H/L traverse the one row of source Column characters.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(focusedPanel()?.column, 1);
      expect(focusedPanel()?.row, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(focusedPanel()?.column, 2);
      expect(focusedPanel()?.row, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(focusedPanel()?.column, 3);
      expect(focusedPanel()?.row, 0);

      // Moving down from Column 3 reaches the action row (with the preferred
      // column clamped to its second action), rather than another tall card.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(focusedControl()?.row, 3);
      expect(focusedControl()?.column, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(focusedPanel()?.column, 1);
      expect(focusedPanel()?.row, 0);

      panelNode(0, 0).requestFocus();
      await tester.pump();
      expect(
        VimInputModeScope.plotSelectionLevel(dialogContext),
        VimPlotSelectionLevel.column,
      );

      // H/L select sibling Column characters on the dialog page.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump();
      expect(focusedPanel()?.column, 1);
      expect(focusedPanel()?.row, 0);
      expect(
        VimInputModeScope.plotSelectionLevel(dialogContext),
        VimPlotSelectionLevel.column,
      );

      // Only Enter enters the selected Column. J/K then move between its
      // Panel characters, while H/L cannot leak into a sibling Column.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        VimInputModeScope.plotSelectionLevel(dialogContext),
        VimPlotSelectionLevel.panel,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
      await tester.pump();
      expect(focusedPanel()?.column, 1);
      expect(focusedPanel()?.row, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      expect(focusedPanel()?.column, 1);
      expect(focusedPanel()?.row, 1);

      // A Panel is a leaf control in this dialog, so Enter is equivalent to
      // clicking it and toggles only that Panel's export selection.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Export 9 panel(s)'), findsOneWidget);
    },
  );

  testWidgets('Vim Export panel data reaches every control', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    app.plots[0].series[0] = SeriesData(
      points: const [
        [0, 1],
      ],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          builder: (context, child) => VimModeScope(
            notifier: app,
            child: VimFocusHost(child: child ?? const SizedBox.shrink()),
          ),
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showMultiPanelExportDialog(
                context,
                app,
                initialSelection: const {0},
                allowPanelSelection: false,
              ),
              child: const Text('Export panel data'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Export panel data'));
    await tester.pumpAndSettle();

    FocusNode controlNode(int row, int column) =>
        FocusManager.instance.rootScope.descendants
            .where((node) => node.canRequestFocus && !node.skipTraversal)
            .firstWhere((node) {
          final marker = node.context
              ?.findAncestorWidgetOfExactType<VimPanelExportControl>();
          return marker?.row == row && marker?.column == column;
        });
    VimPanelExportControl? focusedControl() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<VimPanelExportControl>();

    controlNode(0, 0).requestFocus();
    await tester.pump();
    expect(focusedControl()?.row, 0);
    expect(focusedControl()?.column, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(focusedControl()?.row, 3);
    expect(focusedControl()?.column, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pump();
    expect(focusedControl()?.row, 3);
    expect(focusedControl()?.column, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.pump();
    expect(focusedControl()?.row, 0);
    expect(focusedControl()?.column, 1);
  });

  test('Multiple panel CSV preserves panel and signal metadata', () {
    final csv = encodeMultiplePanelCsv([
      {
        'index': 1,
        'column': 0,
        'row': 1,
        'title': 'Ip, primary',
        'series': [
          {
            'index': 0,
            'legend': 'plasma "current"',
            'shot': '170010',
            'tree': 'pcs_east',
            'signal': r'\pcrl01',
            'server': '202.127.204.12',
            'x_name': 'time',
            'x_unit': 's',
            'y_unit': 'A',
            'points': const [
              [0.1, 500000.0],
            ],
          },
        ],
      },
    ]);

    expect(csv, contains('"plasma ""current"""'));
    expect(csv, contains(r'\pcrl01'));
    expect(csv, contains('time,s,A,0.1,500000.0'));
  });

  test('Panel export creates independent files in every supported format', () {
    final panels = [
      {
        'index': 0,
        'column': 0,
        'row': 0,
        'title': 'Plasma current',
        'series': [
          {
            'index': 0,
            'legend': 'Ip',
            'shot': '170010',
            'tree': 'pcs_east',
            'signal': r'\pcrl01',
            'server': '202.127.204.12',
            'x_name': 'time',
            'x_unit': 's',
            'y_unit': 'A',
            'points': const [
              [0.1, 1.0],
            ],
          },
        ],
      },
      {
        'index': 1,
        'column': 0,
        'row': 1,
        'title': 'Density',
        'series': [
          {
            'index': 0,
            'legend': 'ne',
            'shot': '170010',
            'tree': 'east',
            'signal': r'\ne',
            'server': '202.127.204.12',
            'x_name': 'time',
            'x_unit': 's',
            'y_unit': 'm-3',
            'points': const [
              [0.1, 2.0],
            ],
          },
        ],
      },
    ];

    for (final format in PanelExportFormat.values) {
      final files = buildPanelExportFiles(panels, format);
      expect(files, hasLength(2));
      expect(files.first.name, 'panel-01-Plasma-current.${format.extension}');
      expect(files.last.name, 'panel-02-Density.${format.extension}');
      expect(files.every((file) => file.bytes.isNotEmpty), isTrue);
    }
  });

  test('Current view export filters each panel by its visible X range', () {
    final app = AppState();
    addTearDown(app.dispose);
    app.applyLayoutList([1]);
    app.plots[0]
      ..series[0] = SeriesData(
        points: const [
          [0, 10],
          [1, 20],
          [2, 30],
        ],
        xName: 'time',
      )
      ..setViewRange(0.5, 1.5, 0, 40);

    final snapshot = panelExportSnapshot(
      app,
      const PanelExportRequest(
        panels: {0},
        format: PanelExportFormat.csv,
        range: PanelExportRange.currentView,
      ),
    );
    final points =
        ((snapshot.single['series'] as List).single as Map)['points'] as List;
    expect(points, [
      [1.0, 20.0],
    ]);
  });

  test('Mobile multi-panel export ZIP contains one named entry per panel', () {
    final archive = createStoredZip({
      'panel-01.csv': Uint8List.fromList(utf8.encode('one')),
      'panel-02.csv': Uint8List.fromList(utf8.encode('two')),
    });
    final text = latin1.decode(archive);

    expect(archive.sublist(0, 4), [0x50, 0x4b, 0x03, 0x04]);
    expect(text, contains('panel-01.csv'));
    expect(text, contains('panel-02.csv'));
    expect(
      archive.sublist(archive.length - 22, archive.length - 18),
      [0x50, 0x4b, 0x05, 0x06],
    );
  });

  test('Point readout interpolates ascending and descending waveforms', () {
    expect(
      interpolateWaveformY([
        [0, 10],
        [2, 20],
      ], 0.5),
      12.5,
    );
    expect(
      interpolateWaveformY([
        [2, 20],
        [0, 10],
      ], 0.5),
      12.5,
    );
    expect(
      interpolateWaveformY([
        [0, 10],
        [2, 20],
      ], -1),
      10,
    );
  });

  test('Point readout preserves the local X sampling precision', () {
    const points = [
      [10000.0000, 1.0],
      [10000.0001, 2.0],
      [10000.0002, 3.0],
    ];
    expect(formatPointXForReadout(10000.0001, points), '10000.0001');
    expect(
      formatPointXForReadout(0.0000025, const [
        [0.0, 1.0],
        [0.0000025, 2.0],
        [0.0000050, 3.0],
      ]),
      '0.0000025',
    );
    expect(
      formatPointXForReadout(2.0001, const [
        [2.0002, 1.0],
        [2.0001, 2.0],
        [2.0000, 3.0],
      ]),
      '2.0001',
    );
  });

  test('Point stepping stays on the active plot and curve', () async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.selectPanel(0, 0);
    app.interactionMode = 1;
    app.plots[0].series = [
      SeriesData(points: [
        [0, 1],
        [1, 2],
        [2, 3],
      ]),
      SeriesData(points: [
        [10, 4],
        [11, 5],
        [12, 6],
      ]),
    ];

    app.activatePointForCurrentPanel(seriesOrdinal: 1);
    expect(app.crosshairSourcePlot, 0);
    expect(app.crosshairSourceSeries, 1);
    expect(app.crosshairX, 11);

    expect(app.stepActivePoint(-1), isTrue);
    expect(app.crosshairX, 10);
    expect(app.crosshairSourceSeries, 1);
    expect(app.stepActivePoint(1), isTrue);
    expect(app.crosshairX, 11);
  });

  test('Point quick motions adapt to the visible range and reach real edges',
      () async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.selectPanel(0, 0);
    app.interactionMode = 1;
    app.plots[0].series = [
      SeriesData(
        points: List<List<double>>.generate(
          101,
          (index) => [index.toDouble(), index.toDouble() * 2],
        ),
      ),
    ];
    app.plots[0].setViewRange(40, 60, 0, 200);

    expect(app.activatePointForCurrentPanel(), isTrue);
    expect(app.crosshairX, 50);
    // Eight percent of the 21 visible samples rounds to two points.
    expect(app.stepActivePointQuickly(1), isTrue);
    expect(app.crosshairX, 52);
    expect(app.stepActivePointQuickly(-1), isTrue);
    expect(app.crosshairX, 50);
    expect(app.moveActivePointToEdge(last: false), isTrue);
    expect(app.crosshairX, 0);
    expect(app.moveActivePointToEdge(last: true), isTrue);
    expect(app.crosshairX, 100);
  });

  test(
    'Login responses reject empty bodies without exposing JSON parser errors',
    () {
      expect(
        () => decodeLoginToken('', httpStatus: 200),
        throwsA(
          isA<EmptyApiResponseException>().having(
            (error) => error.toString(),
            'message',
            'Login server returned an empty response (HTTP 200).',
          ),
        ),
      );
      expect(
        () => decodeLoginToken('<html>gateway error</html>', httpStatus: 502),
        throwsA(
          predicate(
            (error) =>
                error.toString().contains('invalid JSON') &&
                !error.toString().contains('FormatException'),
          ),
        ),
      );
    },
  );

  test('Login responses support API and native transport formats', () {
    expect(
      decodeLoginToken(
        '{"code":"20000","data":{"token":"api-token"}}',
        httpStatus: 200,
      ),
      'api-token',
    );
    expect(
      decodeLoginToken(
        '{"ok":true,"token":"native-token"}',
        nativeResponse: true,
      ),
      'native-token',
    );
    expect(
      () => decodeLoginToken(
        '{"code":"20003","message":"Invalid username or password"}',
        httpStatus: 200,
      ),
      throwsA('Invalid username or password'),
    );
  });

  test('Latest-shot responses support API and native fallback formats', () {
    expect(
      decodeLatestShotResponse(
        '{"code":20000,"data":{"shot":170123,"ip":"502.1"}}',
        httpStatus: 200,
      ),
      {'shot': 170123, 'ip': '502.1'},
    );
    expect(
      decodeLatestShotResponse(
        '{"shot":170124,"ip":"502.2","pulse":"5.6s",'
        '"it":"10kA","time":"2026-07-26"}',
        nativeResponse: true,
      ),
      {
        'shot': 170124,
        'ip': '502.2',
        'pulse': '5.6s',
        'it': '10kA',
        'time': '2026-07-26',
      },
    );
    expect(
      () => decodeLatestShotResponse('', httpStatus: 200),
      throwsA(isA<EmptyApiResponseException>()),
    );
  });

  test(
    'Source index extracts MDS nodes from expressions and remembers them',
    () {
      expect(
        sourceIndexSignalNames(r'build_signal(\PCRL01 / 1000, \TIMEBASE)'),
        [r'\PCRL01', r'\TIMEBASE'],
      );
      expect(sourceIndexSignalNames('PCRL02'), [r'\PCRL02']);
      expect(sourceIndexSignalKey(r'\PCRL01 / 1000'), 'pcrl01');

      final memory = SourceIndexMemory();
      memory.remember('test_tree_for_source_index', r'\NEW_SIGNAL * 2');
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
    },
  );

  test('System open requests accept config files and MDSLens links', () {
    expect(
      configurationPathFromOpenRequest('/tmp/example.toml'),
      '/tmp/example.toml',
    );
    expect(
      configurationPathFromOpenRequest(
        'mdslens://open?path=%2Ftmp%2Fshared.webscp',
      ),
      '/tmp/shared.webscp',
    );
    expect(configurationPathFromOpenRequest('/tmp/notes.txt'), isNull);
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

  test('Compact uniform waveform renders when regular points are empty', () {
    final series = SeriesData(
      points: <List<double>>[],
      uniformY: Float32List.fromList(<double>[1, 2, 3]),
      uniformStart: -0.1,
      uniformStep: 0.05,
    );

    expect(series.hasData, isTrue);
    expect(series.pointCount, 3);

    final rendered = PlotRenderCache().render(series);
    expect(rendered.spots, <FlSpot>[
      const FlSpot(-0.1, 1),
      const FlSpot(-0.05, 2),
      const FlSpot(0, 3),
    ]);
    expect(rendered.minX, -0.1);
    expect(rendered.maxX, 0);
    expect(rendered.minY, 1);
    expect(rendered.maxY, 3);
  });

  test('Full uniform waveform render uses the Rust min/max block index', () {
    final values = Float32List(4096);
    values[1024 + 37] = -42;
    values[11 * 256 + 73] = 999;
    final minBlocks = Float32List.fromList(
      List<double>.generate(16, (block) => block == 4 ? -42 : 0),
    );
    final maxBlocks = Float32List.fromList(
      List<double>.generate(16, (block) => block == 11 ? 999 : 0),
    );
    final series = SeriesData(
      points: <List<double>>[],
      uniformY: values,
      uniformStart: 0,
      uniformStep: 0.001,
      minYBlocks: minBlocks,
      maxYBlocks: maxBlocks,
      minMaxBlockSize: 256,
    );

    final rendered = PlotRenderCache().render(series, maxPoints: 32);

    expect(rendered.minY, -42);
    expect(rendered.maxY, 999);
  });

  test('Compact irregular waveform renders and interpolates without expansion',
      () {
    final transferred = Float64List.fromList(<double>[
      0,
      10,
      0.5,
      20,
      1,
      5,
    ]);
    final series = SeriesData(interleavedPoints: transferred);

    expect(series.hasData, isTrue);
    expect(series.pointCount, 3);
    expect(series.valueAt(0.25), 15);
    expect(series.nearestPointIndex(0.7), 1);
    expect(series.localXResolution(0.7), 0.5);
    expect(series.dataBounds(), <double>[0, 1, 5, 20]);

    final rendered = PlotRenderCache().render(series);
    expect(rendered.spots, const <FlSpot>[
      FlSpot(0, 10),
      FlSpot(0.5, 20),
      FlSpot(1, 5),
    ]);
    expect(identical(series.interleavedPoints, transferred), isTrue);
    expect(series.points, isNull);
  });

  test('Compact waveform decoding retains its transferred typed buffer',
      () async {
    final transferred = Float32List.fromList(<double>[1, 2, 3]);
    final app = AppState(
      streamingSignalFetchWorker:
          (configJson, dataMode, sshSettings, onSignal) async {
        onSignal(<String, dynamic>{
          'column': 0,
          'row': 0,
          'signal': 0,
          'series': <String, dynamic>{
            'error': '',
            'points': <List<double>>[],
            'uniform_y': transferred,
            'uniform_start': -0.1,
            'uniform_step': 0.05,
          },
        });
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163870';

    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    expect(
        identical(app.plots.first.series.first?.uniformY, transferred), isTrue);
  });

  test('Compact irregular decoding retains its transferred typed buffer',
      () async {
    final transferred = Float64List.fromList(<double>[0, 1, 1, 2]);
    final app = AppState(
      streamingSignalFetchWorker:
          (configJson, dataMode, sshSettings, onSignal) async {
        onSignal(<String, dynamic>{
          'column': 0,
          'row': 0,
          'signal': 0,
          'series': <String, dynamic>{
            'error': '',
            'points': <List<double>>[],
            'uniform_y': <double>[],
            '_interleaved_points': transferred,
          },
        });
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163870';

    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    final series = app.plots.first.series.first;
    expect(identical(series?.interleavedPoints, transferred), isTrue);
    expect(series?.points, isEmpty);
    expect(series?.valueAt(0.5), 1.5);
  });

  test('Plot point budget follows visible panel width', () {
    expect(plotRenderPointBudget(100), 256);
    expect(plotRenderPointBudget(400), 800);
    expect(plotRenderPointBudget(2000), 2000);
  });

  test('Release versions are compared semantically', () {
    expect(compareVersions('v7.1.0', '7.0.9'), greaterThan(0));
    expect(compareVersions('7.0', '7.0.0'), 0);
    expect(compareVersions('6.9.9', '7.0.0'), lessThan(0));
  });

  test('Runtime system information normalizes versions and architectures', () {
    expect(
      normalizedOperatingSystemVersion('Version 15.5 (Build 24F74)'),
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

  test(
    'Runtime system information prefers the native platform channel',
    () async {
      const channel = MethodChannel('mdslens/system_info');
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
    },
  );

  test('Customize Fonts values are applied to the application theme', () {
    final theme = MDSLensTheme.light(
      fontFamily: 'Courier New',
      uiFontSize: 18,
      iconSize: 30,
    );

    expect(theme.textTheme.bodyMedium?.fontFamily, 'Courier New');
    expect(theme.textTheme.bodyMedium?.fontSize, 18);
    expect(theme.textTheme.labelLarge?.fontSize, 18);
    expect(theme.iconTheme.size, 30);
    expect(theme.inputDecorationTheme.filled, isTrue);
    final popupShape = theme.popupMenuTheme.shape as RoundedRectangleBorder;
    expect(popupShape.borderRadius, BorderRadius.circular(12));
  });

  testWidgets('Auto theme follows live platform brightness changes', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    app.themeMode = 2;
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const MDSLensApp()),
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    await tester.pump();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    await tester.pump();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );
  });

  testWidgets('Auto theme keeps the authoritative startup brightness', (
    tester,
  ) async {
    const channel = MethodChannel('mdslens/theme');
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
      ChangeNotifierProvider.value(value: app, child: const MDSLensApp()),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(nativeBrightnessQueries, 2);
  });

  testWidgets('Auto theme corrects a stale light startup value on macOS', (
    tester,
  ) async {
    const channel = MethodChannel('mdslens/theme');
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
      ChangeNotifierProvider.value(value: app, child: const MDSLensApp()),
    );
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.light,
    );

    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );

    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
  });

  testWidgets('Tapping empty main-page space dismisses the Shot keyboard', (
    tester,
  ) async {
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

  test('Global actions, Shot navigation, and Escape bypass focused editing',
      () {
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.previousShot,
        shotInputFocused: true,
      ),
      isTrue,
    );
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.nextShot,
        shotInputFocused: true,
      ),
      isTrue,
    );
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.latestShot,
        shotInputFocused: true,
      ),
      isTrue,
    );
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.pointMode,
        shotInputFocused: true,
      ),
      isFalse,
    );
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.openFile,
        shotInputFocused: true,
      ),
      isTrue,
    );
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.globalExport,
        shotInputFocused: false,
      ),
      isTrue,
    );
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.previousShot,
        shotInputFocused: false,
      ),
      isFalse,
    );
    expect(
      allowShortcutWhileEditing(
        MdsShortcutCommand.exitPoint,
        shotInputFocused: false,
      ),
      isTrue,
    );
  });

  testWidgets(
    'Global shortcuts remain active after the page loses child focus',
    (tester) async {
      final app = AppState();
      await app.preferencesReady;
      addTearDown(app.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(home: MainPage()),
        ),
      );
      await tester.pump();

      // This is the state produced by tapping empty waveform space: no
      // editable control owns focus, but the page route is still active.
      FocusManager.instance.primaryFocus?.unfocus();
      final modifier = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();

      expect(app.interactionMode, 1);
    },
  );

  test(
    'Shot navigation discards a draft and advances from the displayed shot',
    () async {
      final requestedShots = <String>[];
      final app = AppState(
        latestShotWorker: (_, __, ___) async => {'shot': 163701},
        signalFetchWorker: (configJson, _, __) async {
          final config = jsonDecode(configJson) as Map<String, dynamic>;
          final panel = (config['columns'] as List).first.first as Map;
          requestedShots.add(panel['shot'].toString());
          return '[{"column":0,"row":0,"signal":0,'
              '"series":{"points":[[0,1],[1,2]],"error":""}}]';
        },
      );
      await app.preferencesReady;
      addTearDown(app.dispose);
      app.setLoggedIn(true, 'test-token');
      app.shotText = '163700';
      app.startRefresh();
      await Future<void>.delayed(Duration.zero);
      expect(app.displayedShot, '163700');

      app.shotText = '999999';
      app.restoreDisplayedShotForNavigation();
      app.loadRelativeShot(1);
      await Future<void>.delayed(Duration.zero);

      expect(app.shotText, '163701');
      expect(app.shotCtrl.text, '163701');
      expect(requestedShots, ['163700', '163701']);

      app.loadRelativeShot(1);
      await Future<void>.delayed(Duration.zero);
      expect(app.shotText, '163701');
      expect(app.shotCtrl.text, '163701');
      expect(app.status, 'Already at latest shot 163701');
    },
  );

  test('Manual application settings survive an application restart', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'mdslens-user-data-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final store = UserDataStore(
      rootOverride: Directory('${temporary.path}/.mdslens'),
    );
    SharedPreferences.setMockInitialValues({
      'shotHistory': '["163700","163699"]',
    });

    final credentials = MemoryCredentialStore();
    final first = AppState(userDataStore: store, credentialStore: credentials);
    await first.preferencesReady;
    addTearDown(first.dispose);
    first.dataMode = 2;
    first.interactionMode = 1;
    first.themeMode = 0;
    first.toolbarCollapsed = true;
    first.setVimMode(true);
    first.setAutoCheckUpdates(false);
    first.shotText = '163701';
    first.applyFontSettings(
      'Courier New',
      17,
      14,
      13,
      16,
      iconSize: 30,
    );
    first.addWebBookmark('Status', 'http://10.0.0.8/status');
    first.applyLayoutList([1, 2]);
    first.columns[0][0]['title'] = 'Saved panel';
    first.columns[0][0]['custom_x_range'] = true;
    first.columns[0][0]['xmin'] = double.nan;
    first.rebuild();
    await first.savePreferences();

    final second = AppState(userDataStore: store, credentialStore: credentials);
    await second.preferencesReady;
    addTearDown(second.dispose);

    expect(second.dataMode, 2);
    expect(second.interactionMode, 1);
    expect(second.themeMode, 0);
    expect(second.toolbarCollapsed, isTrue);
    expect(second.vimMode, isTrue);
    expect(second.autoCheckUpdates, isFalse);
    expect(second.shotText, '163701');
    expect(second.fontFamily, 'Courier New');
    expect(second.fontLegendSize, 17);
    expect(second.iconSize, 30);
    expect(second.webBookmarks, [
      {'Status': 'http://10.0.0.8/status'},
    ]);
    expect(second.shotHistory, ['163700', '163699']);
    expect(second.columns.map((column) => column.length), [1, 2]);
    expect(second.columns[0][0]['title'], 'Saved panel');
    expect(second.columns[0][0]['xmin'], isNull);
    final settingsFile = File('${temporary.path}/.mdslens/settings.json');
    expect(await settingsFile.exists(), isTrue);
    expect(
      jsonDecode(await settingsFile.readAsString())['fontFamily'],
      'Courier New',
    );
    expect(jsonDecode(await settingsFile.readAsString())['iconSize'], 30);
    expect(
      jsonDecode(await settingsFile.readAsString())['autoCheckUpdates'],
      isFalse,
    );
    final legacy = await SharedPreferences.getInstance();
    expect(legacy.containsKey('shotHistory'), isFalse);
  });

  test(
    'Plaintext credentials migrate to the platform vault and are erased',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'mdslens-secure-settings-test-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final store = UserDataStore(
        rootOverride: Directory('${temporary.path}/.mdslens'),
      );
      final credentials = MemoryCredentialStore();
      SharedPreferences.setMockInitialValues({
        'rememberLogin': true,
        'loggedIn': true,
        'loginApiUrl': 'https://east.example/api',
        'loginUser': 'scientist',
        'loginPass': 'login-secret',
        'authToken': 'session-secret',
        'sshPass': 'ssh-secret',
        'themeMode': 2,
      });

      final first = AppState(
        userDataStore: store,
        credentialStore: credentials,
      );
      await first.preferencesReady;
      addTearDown(first.dispose);

      expect(first.loginPass, 'login-secret');
      expect(first.authToken, 'session-secret');
      expect(first.sshPass, 'ssh-secret');
      expect(credentials.values, {
        'mdslens.login.password': 'login-secret',
        'mdslens.login.token': 'session-secret',
        'mdslens.ssh.password': 'ssh-secret',
      });

      final oldPreferences = await SharedPreferences.getInstance();
      expect(oldPreferences.containsKey('loginPass'), isFalse);
      expect(oldPreferences.containsKey('authToken'), isFalse);
      expect(oldPreferences.containsKey('sshPass'), isFalse);

      final settingsFile = File('${temporary.path}/.mdslens/settings.json');
      final settingsText = await settingsFile.readAsString();
      expect(settingsText, isNot(contains('login-secret')));
      expect(settingsText, isNot(contains('session-secret')));
      expect(settingsText, isNot(contains('ssh-secret')));
      expect(jsonDecode(settingsText)['themeMode'], 2);

      final second = AppState(
        userDataStore: store,
        credentialStore: credentials,
      );
      await second.preferencesReady;
      addTearDown(second.dispose);
      expect(second.loginPass, 'login-secret');
      expect(second.authToken, 'session-secret');
      expect(second.sshPass, 'ssh-secret');
      expect(second.loggedIn, isTrue);
    },
  );

  test('Shot history retention is bounded, optional, and persisted', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'mdslens-shot-history-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final store = UserDataStore(
      rootOverride: Directory('${temporary.path}/.mdslens'),
    );
    final history = List<String>.generate(55, (index) => '${170000 - index}');
    SharedPreferences.setMockInitialValues({
      'shotHistory': jsonEncode(history),
    });

    final credentials = MemoryCredentialStore();
    final first = AppState(userDataStore: store, credentialStore: credentials);
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

    final second = AppState(userDataStore: store, credentialStore: credentials);
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

  test(
    'Configuration open accepts desktop paths and mobile file bytes',
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
        configOpenPicker: () async =>
            ConfigOpenSelection(name: 'mobile.toml', bytes: originalBytes),
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
    },
  );

  test('Recent local configurations are persisted and reopenable', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'mdslens-recent-config-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final store = UserDataStore(
      rootOverride: Directory('${temporary.path}/.mdslens'),
    );
    final configuration = File('${temporary.path}/saved.toml');
    await configuration.writeAsString('version = 1\n');
    const parsedConfig = '{"columns":[[{"title":"Recent panel",'
        '"x_label":"s","y_label":"A",'
        '"signal_specs":[{"y_expr":"\\\\ip"}]}]]}';

    final first = AppState(
      userDataStore: store,
      configOpenPicker: () async => ConfigOpenSelection(
        name: 'saved.toml',
        path: configuration.path,
      ),
      configParser: (_) => parsedConfig,
    );
    await first.preferencesReady;
    addTearDown(first.dispose);
    await first.openFile();

    expect(first.recentConfigurations, hasLength(1));
    expect(first.recentConfigurations.single.path, configuration.path);

    final second = AppState(
      userDataStore: store,
      configParser: (_) => parsedConfig,
    );
    await second.preferencesReady;
    addTearDown(second.dispose);
    expect(second.recentConfigurations, hasLength(1));
    expect(second.recentConfigurations.single.name, 'saved.toml');

    await second.openRecentConfiguration(second.recentConfigurations.single);
    expect(second.columns.single.single['title'], 'Recent panel');
  });

  test(
    'Configuration open never imports the legacy shared config directory',
    () async {
      var parserWasCalled = false;
      final state = AppState(
        configOpenPicker: () async => const ConfigOpenSelection(
          name: 'legacy.toml',
          path: '/home/example/.mdsscope/configurations/legacy.toml',
        ),
        configParser: (_) {
          parserWasCalled = true;
          return '{"columns":[]}';
        },
      );
      await state.preferencesReady;
      addTearDown(state.dispose);

      await state.openFile();

      expect(parserWasCalled, isFalse);
      expect(state.status, contains('legacy application'));
      expect(
        isLegacyMdsScopeConfigurationPath(
          r'C:\\Users\\example\\.config\\mdsscope\\old.toml',
        ),
        isTrue,
      );
    },
  );

  test(
    'Configuration save hands complete TOML bytes to the file dialog',
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
    },
  );

  test('Configuration save can encode and export WebScope files', () async {
    String? encodedJson;
    String? suggestedName;
    Uint8List? savedBytes;
    final expectedBytes = Uint8List.fromList(utf8.encode('cols:1\n1.rows:1\n'));
    final app = AppState(
      webscpConfigEncoder: (configJson) async {
        encodedJson = configJson;
        return expectedBytes;
      },
      configSavePicker: (name, bytes) async {
        suggestedName = name;
        savedBytes = bytes;
        return '/saved/config.webscp';
      },
    );
    await app.preferencesReady;
    app.shotText = '163999';

    await app.saveFile(format: ConfigurationFileFormat.webscp);

    expect(suggestedName, 'config.webscp');
    expect(savedBytes, expectedBytes);
    expect(jsonDecode(encodedJson!)['shot'], '163999');
    expect(app.status, 'Saved to config.webscp');
  });

  test(
    'Configuration save materializes every per-curve data source field',
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
        {'y_expr': r'\SECOND', 'experiment': 'tree_b', 'server_ip': '10.0.0.2'},
      ];

      await app.saveFile();

      final signals = (jsonDecode(encodedJson!)['columns'][0][0]
          ['signal_specs']) as List<dynamic>;
      expect(signals, hasLength(2));
      expect(signals[0], {
        'shot': '163899',
        'shot_fixed': false,
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
        'shot_fixed': false,
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
    },
  );

  test(
    'Opening a portable configuration restores its shot and fetches data',
    () async {
      String? requestedConfig;
      final app = AppState(
        configOpenPicker: () async =>
            ConfigOpenSelection(name: 'portable.toml', bytes: Uint8List(0)),
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
        [0.0, 1.0],
      ]);
    },
  );

  test('Empty configurations remain valid editable workspaces', () async {
    final app = AppState(
      configOpenPicker: () async =>
          ConfigOpenSelection(name: 'empty.toml', bytes: Uint8List(0)),
      configParser: (_) => '{"shot":"163700","columns":[[]]}',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);

    await app.openFile();
    expect(app.columns, isEmpty);
    expect(app.plots, isEmpty);
    expect(app.status, contains('0 panels'));

    app.applyLayoutColumns([
      [
        {
          'title': 'New panel',
          'signal_specs': <Map<String, dynamic>>[],
        },
      ],
    ]);
    expect(app.columns, hasLength(1));
    expect(app.plots, hasLength(1));

    app.applyLayoutColumns([]);
    expect(app.columns, isEmpty);
    expect(app.plots, isEmpty);
  });

  test('An empty workspace survives application restart', () async {
    SharedPreferences.setMockInitialValues({
      'lastConfigJson': '{"shot":"","columns":[]}',
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);

    expect(app.columns, isEmpty);
    expect(app.plots, isEmpty);
  });

  test('Configuration parser errors are shown without replacing the layout',
      () async {
    final app = AppState(
      configOpenPicker: () async =>
          ConfigOpenSelection(name: 'future.toml', bytes: Uint8List(0)),
      configParser: (_) =>
          '{"error":"Unsupported TOML configuration version 2; '
          'this build supports version 1."}',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    final previousColumns = app.columns;

    await app.openFile();

    expect(app.status, contains('Unsupported TOML configuration version 2'));
    expect(app.columns, same(previousColumns));
    expect(app.plots, isNotEmpty);
  });

  test(
    'Imported shots are ignored by default at every configuration level',
    () async {
      String? requestedConfig;
      final app = AppState(
        configOpenPicker: () async =>
            ConfigOpenSelection(name: 'layout-only.toml', bytes: Uint8List(0)),
        configParser: (_) =>
            '{"shot":"143850","columns":[[{"title":"Signals","shot":"143851",'
            '"signal_specs":['
            '{"shot":"143852","shot_fixed":false,"y_expr":"\\\\first",'
            '"experiment":"pcs_east"},'
            '{"shot":"143853","shot_fixed":false,"y_expr":"\\\\second",'
            '"experiment":"pcs_east"}'
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
    },
  );

  test(
    'A newly loaded shot overrides every imported per-signal shot',
    () async {
      final requestedConfigs = <Map<String, dynamic>>[];
      final app = AppState(
        configOpenPicker: () async =>
            ConfigOpenSelection(name: 'switchable.toml', bytes: Uint8List(0)),
        configParser: (_) =>
            '{"shot":"143850","columns":[[{"title":"Signals","shot":"143850",'
            '"signal_specs":['
            '{"shot":"143850","y_expr":"\\\\inherit","experiment":"pcs_east",'
            '"server_ip":"202.127.204.12","shot_fixed":false},'
            '{"shot":"143849","y_expr":"\\\\fixed","experiment":"pcs_east",'
            '"server_ip":"202.127.204.12","shot_fixed":false}]}]]}',
        signalFetchWorker: (configJson, _, __) async {
          final config = Map<String, dynamic>.from(
            jsonDecode(configJson) as Map,
          );
          requestedConfigs.add(config);
          final panel = (config['columns'] as List).first.first as Map;
          final panelShot = panel['shot'].toString();
          final signals = panel['signal_specs'] as List;
          final fixedShot =
              (signals[1] as Map)['shot']?.toString() ?? panelShot;
          return jsonEncode([
            {
              'column': 0,
              'row': 0,
              'signal': 0,
              'shot': panelShot,
              'series': {
                'error': '',
                'points': [
                  [0.0, 1.0],
                ],
              },
            },
            {
              'column': 0,
              'row': 0,
              'signal': 1,
              'shot': fixedShot,
              'series': {
                'error': '',
                'points': [
                  [0.0, 2.0],
                ],
              },
            },
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
    },
  );

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
          'shot_fixed': true,
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
          'shot_fixed': false,
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
      expect(
        signals.map((signal) => (signal as Map)['shot']),
        [
          '100001',
          '170001',
        ],
      );
      expect(
        signals.map((signal) => (signal as Map)['read_mode']),
        everyElement(1),
      );
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
      expect((stored[0] as Map)['shot'], '100001');
      expect((stored[0] as Map)['read_mode'], 1);
      expect((stored[0] as Map)['hide_mode'], signalHideModeVisible);
      expect((stored[1] as Map)['hide_mode'], signalHideModePersistent);
    },
  );

  testWidgets('Rate refresh preserves X range and resets Y range', (
    tester,
  ) async {
    final app = AppState(signalFetchWorker: (_, __, ___) async => '[]');
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '170001';
    app.plots.first.setViewRange(0.25, 0.75, -4, 8);
    final fullReset = app.viewResetId;
    final rateReset = app.rateViewResetId;

    app.dataMode = 1;
    app.startRateRefresh();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(app.viewResetId, fullReset);
    expect(app.rateViewResetId, rateReset + 1);
    expect(app.plots.first.viewMinX, 0.25);
    expect(app.plots.first.viewMaxX, 0.75);
    expect(app.plots.first.viewMinY, isNull);
    expect(app.plots.first.viewMaxY, isNull);
  });

  testWidgets('Rate changes publish one loading transition before preparation',
      (
    tester,
  ) async {
    final app = AppState(signalFetchWorker: (_, __, ___) async => '[]');
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');

    var notifications = 0;
    app.addListener(() => notifications++);
    app.changeDataModeAndRefresh(1);

    expect(notifications, 1);
    expect(app.ratePreparing, isTrue);
    expect(app.status, 'Medium rate selected; preparing...');

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(app.ratePreparing, isFalse);
  });

  test('Current panel rate changes only the selected panel', () async {
    String? requestedConfig;
    String? requestedMode;
    final app = AppState(
      signalFetchWorker: (configJson, dataMode, _) async {
        requestedConfig = configJson;
        requestedMode = dataMode;
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '170001';
    app.columns[0][0]['signal_specs'] = [
      {'y_expr': r'\FIRST', 'experiment': 'tree_a'},
    ];
    app.columns[0][1]['signal_specs'] = [
      {'y_expr': r'\SECOND', 'experiment': 'tree_b'},
    ];
    app.selectPanel(0, 0);

    app.changeSelectedPanelDataModeAndRefresh(2);
    for (var attempt = 0; attempt < 20 && requestedConfig == null; attempt++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(app.dataMode, 0);
    expect(
      (app.columns[0][0]['signal_specs'] as List).single['read_mode'],
      2,
    );
    expect(
      (app.columns[0][1]['signal_specs'] as List).single['read_mode'],
      isNull,
    );
    expect(requestedMode, '0');
    final config = jsonDecode(requestedConfig!) as Map<String, dynamic>;
    final columns = config['columns'] as List;
    final selectedSignals =
        ((columns[0] as List)[0] as Map)['signal_specs'] as List;
    expect((selectedSignals.single as Map)['read_mode'], 2);
    expect(((columns[0] as List)[1] as Map)['signal_specs'], isEmpty);
  });

  testWidgets('Rapid Full shot changes coalesce into the latest request', (
    tester,
  ) async {
    final requestedShots = <String>[];
    final app = AppState(
      signalFetchWorker: (configJson, _, __) async {
        final config = jsonDecode(configJson) as Map<String, dynamic>;
        final panel = ((config['columns'] as List).first as List).first as Map;
        requestedShots.add(panel['shot'].toString());
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.dataMode = 2;

    app.shotText = '170001';
    app.startRefresh();
    expect(app.fetching, isTrue);
    expect(requestedShots, isEmpty);

    await tester.pump(const Duration(milliseconds: 80));
    app.shotText = '170002';
    app.startRefresh();
    await tester.pump(const Duration(milliseconds: 259));
    expect(requestedShots, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    expect(requestedShots, ['170002']);
    expect(app.viewResetId, greaterThan(0));
  });

  testWidgets('Full rate changes debounce before releasing old waveforms', (
    tester,
  ) async {
    var requests = 0;
    final app = AppState(
      signalFetchWorker: (_, __, ___) async {
        requests++;
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.updatePlotSeriesByColRow(
      0,
      0,
      0,
      const [
        [0.0, 1.0],
        [1.0, 2.0],
      ],
      null,
    );
    app.dataMode = 2;
    app.startRateRefresh();

    expect(requests, 0);
    expect(app.plots.first.series.first?.hasData, isTrue);
    // The rate handoff is scheduled after the loading frame; flush the frame
    // and the following event turn before measuring the Full-mode debounce.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 118));
    expect(requests, 0);
    expect(app.plots.first.series.first?.hasData, isTrue);
    await tester.pump(const Duration(milliseconds: 1));
    expect(requests, 1);
    expect(app.plots.first.series.first?.hasData, isFalse);
  });

  testWidgets('Stop cancels a pending Full shot request', (tester) async {
    var requestCount = 0;
    final app = AppState(
      signalFetchWorker: (_, __, ___) async {
        requestCount++;
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.dataMode = 2;
    app.shotText = '170003';

    app.startRefresh();
    expect(app.fetching, isTrue);
    app.stopFetch();
    await tester.pump(const Duration(milliseconds: 500));

    expect(requestCount, 0);
    expect(app.fetching, isFalse);
    expect(app.status, 'Stopped');
  });

  testWidgets('Application exit cancels an active waveform load immediately', (
    tester,
  ) async {
    final neverCompletes = Completer<String>();
    final app = AppState(
      signalFetchWorker: (_, __, ___) => neverCompletes.future,
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '170004';

    app.startRefresh();
    await tester.pump();
    expect(app.fetching, isTrue);

    app.prepareForExit();

    expect(app.fetching, isFalse);
  });

  test(
    'A configuration imported before login keeps its shot and loads after login',
    () async {
      var latestShotRequests = 0;
      String? requestedConfig;
      final app = AppState(
        configOpenPicker: () async =>
            ConfigOpenSelection(name: 'before-login.toml', bytes: Uint8List(0)),
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
        [0.0, 7.0],
      ]);
    },
  );

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
    },
  );

  test(
    'Imported zero-point panels are repaired before waveform loading',
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
    },
  );

  test(
    'Waveform decoding keeps finite samples and skips null coordinates',
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
    },
  );

  test(
    'Uniform high-resolution payloads preserve samples and axis metadata',
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
      expect(series?.points, isEmpty);
      expect(series?.uniformY, [1.0, 2.0, 3.0]);
      expect(series?.materializePoints(), [
        [-0.1, 1.0],
        [-0.0999, 2.0],
        [-0.0998, 3.0],
      ]);
      expect(series?.unit, 'kA');
      expect(series?.xName, 'time');
      expect(series?.xUnit, 's');
    },
  );

  testWidgets('Point readout never fabricates a hard-coded x axis name', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.columns[0][0]['signal_specs'] = [
      {'y_expr': r'\IP', 'x_expr': '', 'legend': 'Ip', 'color_name': '#1976D2'},
    ];
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        const [
          [0.0, 1.0],
          [1.0, 2.0],
        ],
        null);
    app.interactionMode = 1;
    app.setCrosshair(0.5, sourcePlot: 0, sourceSeries: 0);

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
    await tester.pump();

    expect(find.textContaining(r'dim_of(\IP):'), findsOneWidget);
    expect(find.textContaining('x:'), findsNothing);
  });

  test(
    'A signal with no finite samples reports a meaningful data error',
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
      expect(app.status, contains('6 signals (0 loaded, 6 failed)'));
    },
  );

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
      configOpenPicker: () async =>
          ConfigOpenSelection(name: 'nine-panels.toml', bytes: Uint8List(0)),
      configParser: (_) => jsonEncode({'shot': '163807', 'columns': columns}),
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
    expect(app.status, contains('9 signals (9 loaded, 0 failed)'));
  });

  test(
    'Cross-platform saver writes desktop paths and supplies mobile bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp('mdslens-test-');
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

      Uint8List? browserDialogBytes;
      final browserName = await saveBytesWithFilePicker(
        dialogTitle: 'Save',
        fileName: 'config.webscp',
        allowedExtensions: const ['webscp'],
        bytes: bytes,
        mobileOverride: false,
        webOverride: true,
        saveDialog: (payload) async {
          browserDialogBytes = payload;
          return 'config.webscp';
        },
      );
      expect(browserDialogBytes, bytes);
      expect(browserName, 'config.webscp');
    },
  );

  testWidgets('Open and Save toolbar buttons invoke working file flows', (
    tester,
  ) async {
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

    await tester.tap(tooltipStartingWith('Open configuration'));
    await tester.pumpAndSettle();
    expect(openCalls, 1);
    expect(app.columns[0][0]['title'], 'Toolbar open');

    await tester.tap(tooltipStartingWith('Save configuration'));
    await tester.pumpAndSettle();
    expect(find.text('Save Configuration As'), findsOneWidget);
    expect(find.byKey(const ValueKey('save-format-toml')), findsOneWidget);
    expect(find.byKey(const ValueKey('save-format-webscp')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-format-toml')));
    await tester.pumpAndSettle();
    expect(saveCalls, 1);
    expect(app.status, 'Saved to config.toml');
  });

  testWidgets('Configuration import asks before applying its shot', (
    tester,
  ) async {
    final app = AppState(
      configOpenPicker: () async =>
          ConfigOpenSelection(name: 'with-shot.toml', path: '/with-shot.toml'),
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

    await tester.tap(tooltipStartingWith('Open configuration'));
    await tester.pumpAndSettle();

    expect(find.text('Use The Configuration Shot?'), findsOneWidget);
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

  test('Configuration import exposes every shot and fixed-shot choice',
      () async {
    ImportedConfigurationSummary? summary;
    final requestedConfigs = <Map<String, dynamic>>[];
    final app = AppState(
      configOpenPicker: () async => ConfigOpenSelection(
          name: 'multi-shot.toml', path: '/multi-shot.toml'),
      configParser: (_) => '{"shot":"170000","columns":[[{"shot":"170001",'
          '"signal_specs":['
          '{"shot":"170002","shot_fixed":true,"y_expr":"\\\\fixed"},'
          '{"shot":"170003","shot_fixed":false,"y_expr":"\\\\follow"}'
          ']}]]}',
      signalFetchWorker: (configJson, _, __) async {
        requestedConfigs.add(jsonDecode(configJson) as Map<String, dynamic>);
        return '[]';
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');

    await app.openFile(
      importedConfigurationDecision: (value) async {
        summary = value;
        return const ImportedConfigurationDecision(
          retainShots: true,
          retainFixedShots: true,
        );
      },
    );

    expect(summary?.shots, ['170000', '170001', '170002', '170003']);
    expect(summary?.signalCount, 2);
    expect(summary?.fixedSignalCount, 1);
    expect(app.shotText, '170000');
    final firstRequest = requestedConfigs.single;
    final panel = (firstRequest['columns'] as List).first.first as Map;
    expect(panel['shot'], '170001');
    final signals = panel['signal_specs'] as List;
    expect((signals[0] as Map)['shot'], '170002');
    expect((signals[0] as Map)['shot_fixed'], isTrue);
    expect((signals[1] as Map)['shot'], '170003');
    expect((signals[1] as Map)['shot_fixed'], isFalse);

    app.shotText = '180000';
    app.startRefresh();
    await Future<void>.delayed(Duration.zero);
    final refreshed = requestedConfigs.last;
    final refreshedSignals = ((refreshed['columns'] as List).first.first
        as Map)['signal_specs'] as List;
    expect((refreshedSignals[0] as Map)['shot'], '170002');
    expect((refreshedSignals[1] as Map)['shot'], '180000');
  });

  test('Legacy imported configurations assume signal shots are fixed',
      () async {
    ImportedConfigurationSummary? summary;
    final app = AppState(
      configOpenPicker: () async =>
          ConfigOpenSelection(name: 'legacy.toml', path: '/legacy.toml'),
      configParser: (_) => '{"shot":"170100","columns":[[{'
          '"signal_specs":[{"shot":"170101","y_expr":"\\\\legacy"}]'
          '}]]}',
    );
    await app.preferencesReady;
    addTearDown(app.dispose);

    await app.openFile(
      importedConfigurationDecision: (value) async {
        summary = value;
        return const ImportedConfigurationDecision(retainFixedShots: true);
      },
    );

    expect(summary?.fixedSignalCount, 1);
    expect(
      ((app.columns.single.single['signal_specs'] as List).single
          as Map)['shot_fixed'],
      isTrue,
    );
  });

  test(
    'Legacy fixed shots with no per-signal shot stay pinned after navigation',
    () async {
      final requestedConfigs = <Map<String, dynamic>>[];
      final app = AppState(
        configOpenPicker: () async =>
            ConfigOpenSelection(name: 'legacy-inherited.toml', path: '/legacy'),
        configParser: (_) => '{"shot":"170100","columns":[[{'
            '"signal_specs":[{"y_expr":"\\\\legacy"}]'
            '}]]}',
        signalFetchWorker: (configJson, _, __) async {
          requestedConfigs.add(jsonDecode(configJson) as Map<String, dynamic>);
          return '[]';
        },
      );
      await app.preferencesReady;
      addTearDown(app.dispose);
      app.setLoggedIn(true, 'test-token');

      await app.openFile(
        importedConfigurationDecision: (_) async =>
            const ImportedConfigurationDecision(
          retainShots: true,
          retainFixedShots: true,
        ),
      );

      final importedSignal =
          (app.columns.single.single['signal_specs'] as List).single as Map;
      expect(importedSignal['shot_fixed'], isTrue);
      expect(importedSignal['shot'], '170100');

      app.shotText = '170200';
      app.startRefresh();
      await Future<void>.delayed(Duration.zero);

      final refreshedSignal = ((requestedConfigs.last['columns'] as List)
          .first
          .first as Map)['signal_specs'] as List;
      expect((refreshedSignal.single as Map)['shot_fixed'], isTrue);
      expect((refreshedSignal.single as Map)['shot'], '170100');
    },
  );

  testWidgets('Toolbar restores and persists the default waveform layout', (
    tester,
  ) async {
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
    await tester.tap(tooltipStartingWith('Restore default configuration'));
    await tester.pumpAndSettle();

    expect(find.text('Restore Default Configuration?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('restore-default-cancel')));
    await tester.pumpAndSettle();
    expect(app.columns, hasLength(1));

    await tester.tap(tooltipStartingWith('Restore default configuration'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('restore-default-confirm')));
    await tester.pumpAndSettle();

    expect(app.columns, hasLength(2));
    expect(app.columns.map((column) => column.length), [3, 3]);
    expect(app.plots.map((plot) => plot.title), [
      'Ip',
      'R',
      'Z',
      'Vloop',
      'Ne',
      'Pf1 current',
    ]);

    final restored = AppState();
    await restored.preferencesReady;
    expect(restored.columns, hasLength(2));
    expect(restored.columns.map((column) => column.length), [3, 3]);
  });

  test(
    'Waveform loading stays interactive and discards stale results',
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
            [1, 11],
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
      expect(
        pending,
        hasLength(1),
        reason: 'the replacement must wait for the cancelled worker to finish',
      );

      pending[0].complete(
        '[{"column":0,"row":0,"signal":0,'
        '"series":{"points":[[0,111],[1,112]],"error":""}}]',
      );
      await Future<void>.delayed(Duration.zero);
      expect(pending, hasLength(2));
      expect(requestedConfigs.last, contains('163702'));
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
      expect(app.status, matches(RegExp(r', Load time: \d+\.\d{3} s$')));
    },
  );

  test('Completed panels render before the full waveform batch finishes',
      () async {
    final completion = Completer<String>();
    final firstSignal = <String, dynamic>{
      'column': 0,
      'row': 0,
      'signal': 0,
      'shot': '163701',
      'series': {
        'points': [
          [0.0, 42.0],
          [1.0, 43.0],
        ],
        'error': '',
      },
    };
    final app = AppState(
      streamingSignalFetchWorker:
          (configJson, dataMode, sshSettings, onSignal) {
        onSignal(firstSignal);
        return completion.future;
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');

    app.shotText = '163701';
    app.startRefresh();
    await Future<void>.delayed(Duration.zero);

    expect(app.fetching, isTrue);
    expect(app.plots.first.series.first?.points?.first.last, 42.0);
    expect(app.isPlotFetching(0), isFalse);
    expect(app.isPlotFetching(1), isTrue);
    expect(app.status, contains('1 panels ready'));

    completion.complete(jsonEncode([firstSignal]));
    await Future<void>.delayed(Duration.zero);
    expect(app.fetching, isFalse);
  });

  test(
    'Refresh reloads the displayed shot instead of the shot input',
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
    },
  );

  testWidgets('Waveform panels show Loading while keeping existing curves', (
    tester,
  ) async {
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
              width: 320,
              height: 240,
              child: PlotPanel(plotIdx: 0),
            ),
          ),
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

  testWidgets('Single panel reload loads only its target panel', (
    tester,
  ) async {
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
    expect(((columns[0] as List)[0] as Map)['signal_specs'], isEmpty);
    expect(((columns[0] as List)[1] as Map)['signal_specs'], isNotEmpty);
    expect(((columns[1] as List)[0] as Map)['signal_specs'], isEmpty);

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

  test('Panel reload waits for an active global waveform worker', () async {
    final pending = <Completer<String>>[];
    final requestedConfigs = <String>[];
    final app = AppState(
      signalFetchWorker: (configJson, _, __) {
        requestedConfigs.add(configJson);
        final result = Completer<String>();
        pending.add(result);
        return result.future;
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setLoggedIn(true, 'test-token');
    app.shotText = '163701';

    app.startRefresh();
    expect(pending, hasLength(1));
    unawaited(app.fetchSinglePanel(1));
    expect(
      pending,
      hasLength(1),
      reason: 'global and panel workers must not overlap',
    );

    pending.first.complete(
      '[{"column":0,"row":0,"signal":0,'
      '"series":{"points":[[0,10],[1,11]],"error":""}}]',
    );
    await Future<void>.delayed(Duration.zero);

    expect(pending, hasLength(2));
    final config = jsonDecode(requestedConfigs.last) as Map<String, dynamic>;
    final columns = config['columns'] as List;
    expect(((columns[0] as List)[0] as Map)['signal_specs'], isEmpty);
    expect(((columns[0] as List)[1] as Map)['signal_specs'], isNotEmpty);

    pending.last.complete(
      '[{"column":0,"row":1,"signal":0,'
      '"series":{"points":[[0,20],[1,21]],"error":""}}]',
    );
    await Future<void>.delayed(Duration.zero);
    expect(app.plots[1].series[0]?.points?.first.last, 20);
  });

  test(
    'Logout preserves loaded data and blocks authenticated operations',
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
    },
  );

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

  testWidgets('Signed-in account button opens a login panel with real logout', (
    tester,
  ) async {
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

  testWidgets('Login and SSH dialogs scroll above a virtual keyboard', (
    tester,
  ) async {
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
    expect(
      tester.getSize(find.byKey(const ValueKey('login-password'))).height,
      greaterThanOrEqualTo(48),
    );
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
    expect(
      tester.getSize(find.byKey(const ValueKey('ssh-host'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('ssh-password'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.getBottomRight(find.text('Save')).dy, lessThanOrEqualTo(340));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Credential fields keep the secure keyboard focus transition', (
    tester,
  ) async {
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

  testWidgets('Credential form labels have room without keyboard compression', (
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

  testWidgets('SSH dialog preserves a manually entered identity file path', (
    tester,
  ) async {
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

  test(
    'Identity file authorization returns the platform-authorized path',
    () async {
      const channel = MethodChannel('mdslens/identity_file_access');
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

      final path = await IdentityFileAccess.authorize('  ~/.ssh/id_ed25519  ');

      expect(path, '/authorized/id_ed25519');
      expect(receivedCall?.method, 'authorizeIdentityFile');
      expect(receivedCall?.arguments, {
        'path': '~/.ssh/id_ed25519',
        'promptIfNeeded': true,
      });
    },
  );

  testWidgets('SSH button lights only while a reachable tunnel is in use', (
    tester,
  ) async {
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
      find.byTooltip('SSH tunnel — reachable, not in use'),
      findsOneWidget,
    );

    app.recordSshUsage(true);
    await tester.pump();
    expect(app.sshConnected, isTrue);
    expect(find.byTooltip('SSH tunnel — in use'), findsOneWidget);

    app.recordSshUsage(false);
    await tester.pump();
    expect(app.sshConnected, isFalse);
    expect(
      find.byTooltip('SSH tunnel — reachable, not in use'),
      findsOneWidget,
    );

    app.setSshTestResult(false);
    await tester.pump();
    expect(find.byTooltip('SSH tunnel'), findsOneWidget);
  });

  test(
    'Disabling SSH cancels loading and actively disconnects tunnels',
    () async {
      final fetch = Completer<String>();
      var disconnects = 0;
      final app = AppState(
        signalFetchWorker: (_, __, ___) => fetch.future,
        sshDisconnect: () => disconnects++,
      );
      await app.preferencesReady;
      addTearDown(app.dispose);
      if (app.sshMode == 0) app.sshMode = 1;
      disconnects = 0;
      app.setLoggedIn(true, 'test-token');
      app.shotText = '170001';

      app.startRefresh();
      expect(app.fetching, isTrue);

      app.sshMode = 0;

      expect(disconnects, 1);
      expect(app.fetching, isFalse);
      expect(app.sshConnected, isFalse);
      expect(app.status, contains('Settings changed'));

      fetch.complete('[]');
      await Future<void>.delayed(Duration.zero);
      expect(app.fetching, isFalse);
    },
  );

  testWidgets(
    'SSH Test runs in the background and keeps the dialog responsive',
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
    },
  );

  test(
    'Startup signs in, fetches the latest shot, and loads its waveforms',
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
      expect(latestRequests, ['http://east.example/api|fresh-token|']);
      expect(signalRequests.single, contains('170001'));
      expect(app.loggedIn, isTrue);
      expect(app.authToken, 'fresh-token');
      expect(app.shotText, '170001');
      expect(app.shotInfoIp, '502.13');
      expect(app.plots[0].series[0]!.points![0], [0, 12]);
      expect(app.status, contains('170001'));
    },
  );

  test(
    'Automatic login falls back from direct access to an SSH tunnel',
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
        laterSettings.every((value) => jsonDecode(value)['mode'] == 2),
        isTrue,
      );
      expect(app.hasActiveSession, isTrue);
      expect(app.sshConnected, isTrue);
      expect(app.authToken, 'ssh-token');
      expect(app.displayedShot, '170002');
    },
  );

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

  test(
    'External web URLs are normalized before cross-platform launch',
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
    },
  );

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
            [2, 14],
          ],
          null);
      app.updatePlotSeriesByColRow(
          0,
          1,
          0,
          [
            [0, 20],
            [1, 22],
            [2, 24],
          ],
          null);
      app.interactionMode = 1;
      app.setCrosshair(1, sourcePlot: 0, sourceSeries: 0);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: app,
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 900, height: 700, child: PlotGrid()),
            ),
          ),
        ),
      );

      final charts =
          tester.widgetList<LineChart>(find.byType(LineChart)).toList();
      expect(charts, hasLength(2));
      expect(charts.every((chart) => chart.duration == Duration.zero), isTrue);
      expect(
        find.byKey(const ValueKey('plot-crosshair-v-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('plot-crosshair-v-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('plot-crosshair-h-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('plot-crosshair-h-1')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('plot-point-marker-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('plot-point-marker-1')), findsOneWidget);
      final marker = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byKey(const ValueKey('plot-point-marker-0')),
              matching: find.byType(Container),
            ),
          )
          .singleWhere(
            (container) =>
                container.decoration is BoxDecoration &&
                (container.decoration! as BoxDecoration).shape ==
                    BoxShape.circle,
          );
      expect(
        (marker.decoration! as BoxDecoration).color,
        isNull,
        reason: 'The crosshair lines must remain visible through the ring.',
      );
    },
  );

  test('Crosshair motion bypasses global application notifications', () {
    final app = AppState();
    addTearDown(app.dispose);
    var applicationNotifications = 0;
    var crosshairNotifications = 0;
    app.addListener(() => applicationNotifications++);
    app.crosshairChanges.addListener(() => crosshairNotifications++);

    app.setCrosshair(1.25, sourcePlot: 3, sourceSeries: 2);

    expect(app.crosshairX, 1.25);
    expect(app.crosshairChanges.value?.x, 1.25);
    expect(app.crosshairChanges.value?.sourcePlot, 3);
    expect(app.crosshairChanges.value?.sourceSeries, 2);
    expect(applicationNotifications, 0);
    expect(crosshairNotifications, 1);

    app.clearCrosshair();
    expect(app.crosshairX, isNull);
    expect(app.crosshairChanges.value, isNull);
    expect(applicationNotifications, 0);
    expect(crosshairNotifications, 2);
  });

  testWidgets('Plot legend uses signal names and supports custom labels', (
    tester,
  ) async {
    expect(signalLegendLabel({'y_expr': r'\PCRL01'}), 'PCRL01');
    expect(
      signalLegendLabel({'y_expr': r'\DFSDEV', 'legend': 'Density'}),
      'Density',
    );
    expect(
      signalLegendDisplayLabel({
        'y_expr': r'\PCRL01',
        'shot': '163714',
        'shot_fixed': true,
      }),
      'PCRL01 163714',
    );
    expect(
      signalLegendDisplayLabel(
        {'y_expr': r'\DFSDEV', 'legend': 'Density'},
        displayedShot: '163715',
        inputShot: '999999',
      ),
      'Density 163715',
    );

    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.shotText = '163715';
    app.columns[0][0]['signal_specs'] = [
      {'y_expr': r'\PCRL01', 'color_name': '#123456'},
      {'y_expr': r'\DFSDEV', 'legend': 'Density', 'color_name': '#654321'},
    ];
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 1],
          [1, 2],
        ],
        null);
    app.updatePlotSeriesByColRow(
        0,
        0,
        1,
        [
          [0, 2],
          [1, 3],
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

    expect(find.byKey(const ValueKey('plot-legend-0-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('plot-legend-0-1')), findsOneWidget);
    expect(find.text('PCRL01 163715'), findsOneWidget);
    expect(find.text('Density 163715'), findsOneWidget);
    expect(find.text('PCRL01'), findsNothing);
    expect(find.text('Density'), findsNothing);
    expect(find.text(r'\PCRL01'), findsNothing);
  });

  testWidgets('Point mode continuously follows a held touch drag', (
    tester,
  ) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
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

  testWidgets('Escape locks Point mode globally and a plot click unlocks it', (
    tester,
  ) async {
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
      ChangeNotifierProvider.value(value: app, child: const MDSLensApp()),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(app.pointLocked, isTrue);

    await tester.tap(find.byKey(const ValueKey('plot-panel-0')));
    await tester.pump();
    expect(app.pointLocked, isFalse);
    expect(app.crosshairX, isNotNull);
  });

  testWidgets('Plot title, axes, and units use customized fonts', (
    tester,
  ) async {
    final app = AppState();
    app.applyFontSettings('Courier New', 17, 14, 13, 16);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 10],
          [1, 12],
          [2, 14],
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MaterialApp(
          theme: MDSLensTheme.light(
            fontFamily: app.effectiveFontFamily,
            uiFontSize: app.fontUiSize.toDouble(),
          ),
          home: const Scaffold(
            body: SizedBox(
              width: 500,
              height: 400,
              child: PlotPanel(plotIdx: 0),
            ),
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

  testWidgets('Two-finger gestures pan and zoom a plot in Zoom/Move mode', (
    tester,
  ) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
        ],
        null);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 500,
                height: 400,
                child: PlotPanel(plotIdx: 0),
              ),
            ),
          ),
        ),
      ),
    );

    LineChart chart() => tester.widget<LineChart>(find.byType(LineChart));
    final initialWidth = chart().data.maxX - chart().data.minX;
    final initialCenter = (chart().data.minX + chart().data.maxX) / 2;

    final first = await tester.startGesture(const Offset(220, 200), pointer: 1);
    final second = await tester.startGesture(
      const Offset(280, 200),
      pointer: 2,
    );
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
    final panFirst = await tester.startGesture(
      const Offset(220, 200),
      pointer: 3,
    );
    final panSecond = await tester.startGesture(
      const Offset(280, 200),
      pointer: 4,
    );
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

  testWidgets('Trackpad pan/zoom events pan and zoom a plot together', (
    tester,
  ) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
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

  testWidgets('One-finger touch drag pans a plot in Zoom/Move mode', (
    tester,
  ) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
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
          [10, 10],
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
    expect(find.byKey(const ValueKey('plot-rubber-band-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stylus erase mode draws rubber-band and inverted tip points', (
    tester,
  ) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
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

  testWidgets('A standard stylus button temporarily selects rubber-band zoom', (
    tester,
  ) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
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

  testWidgets('Stylus long press tolerates jitter and opens context menu', (
    tester,
  ) async {
    final app = AppState();
    addTearDown(app.dispose);
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
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
            [10, 10],
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
    },
  );

  testWidgets('Plot view survives panel disposal and reconstruction', (
    tester,
  ) async {
    final app = AppState();
    app.updatePlotSeriesByColRow(
        0,
        0,
        0,
        [
          [0, 0],
          [5, 5],
          [10, 10],
        ],
        null);

    Widget panelApp(Widget child) => ChangeNotifierProvider.value(
          value: app,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                  child: SizedBox(width: 500, height: 400, child: child)),
            ),
          ),
        );

    await tester.pumpWidget(panelApp(const PlotPanel(plotIdx: 0)));
    final first = await tester.startGesture(const Offset(220, 200), pointer: 1);
    final second = await tester.startGesture(
      const Offset(280, 200),
      pointer: 2,
    );
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

  testWidgets('Phone overview keeps every plot visible without scrolling', (
    tester,
  ) async {
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
              [10, column * 20 + row * 10 + 10],
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
    for (var plot = 0; plot < 4; plot++) {
      expect(
        find.byKey(ValueKey('plot-crosshair-v-$plot')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('plot-crosshair-h-$plot')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('plot-point-marker-$plot')),
        findsOneWidget,
      );
    }

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

    expect(
      firstChart().data.maxX - firstChart().data.minX,
      lessThan(initialWidth),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Toolbar keeps ordered groups across responsive screen widths', (
    tester,
  ) async {
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
          of: toolbar,
          matching: find.byType(SingleChildScrollView),
        ),
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

  testWidgets('Phone toolbar button groups are aligned and equally sized', (
    tester,
  ) async {
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
      Finder group,
      Finder Function(Finder) buttonFinder,
      int count,
    ) {
      final buttons = buttonFinder(group);
      expect(buttons, findsNWidgets(count));
      final rects = [
        for (var i = 0; i < count; i++) tester.getRect(buttons.at(i)),
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
    expect(tooltipStartingWith('Open configuration'), findsOneWidget);
    expect(tooltipStartingWith('Save configuration'), findsOneWidget);
    expect(
      tooltipStartingWith('Restore default configuration'),
      findsOneWidget,
    );
    expect(tooltipStartingWith('Refresh waveforms'), findsOneWidget);
    Finder shortcutTooltip(String prefix) => find.byWidgetPredicate(
          (widget) =>
              widget is Tooltip &&
              (widget.message?.startsWith(prefix) ?? false),
        );
    expect(shortcutTooltip('Previous shot'), findsOneWidget);
    expect(shortcutTooltip('Next shot'), findsOneWidget);
    expect(shortcutTooltip('Latest shot'), findsOneWidget);
    expect(shortcutTooltip('Zoom and move mode'), findsOneWidget);
    expect(shortcutTooltip('Point mode'), findsOneWidget);

    final customizedShortcuts = Map<MdsShortcutCommand, MdsShortcutBinding>.of(
      app.keyboardShortcuts,
    )
      ..[MdsShortcutCommand.openFile] = MdsShortcutBinding(
        primary: MdsShortcutSequence.single(
          const MdsShortcutStroke(LogicalKeyboardKey.f12),
        ),
      )
      ..[MdsShortcutCommand.globalRate] = MdsShortcutBinding(
        primary: MdsShortcutSequence([
          const MdsShortcutStroke(LogicalKeyboardKey.keyG),
          const MdsShortcutStroke(LogicalKeyboardKey.keyQ),
        ]),
      );
    app.applyKeyboardShortcuts(customizedShortcuts);
    await tester.pump();
    final openTooltip = tester.widget<Tooltip>(
      tooltipStartingWith('Open configuration'),
    );
    expect(
      openTooltip.message,
      'Open configuration (${app.shortcutText(MdsShortcutCommand.openFile)})',
    );
    final rateTooltip = tester.widget<Tooltip>(tooltipStartingWith('Rate'));
    expect(
      rateTooltip.message,
      'Rate (${app.shortcutText(MdsShortcutCommand.globalRate)})',
    );
    expect(
      tester.getSize(tooltipStartingWith('Open configuration')).height,
      greaterThanOrEqualTo(44),
    );

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
      final thumbCenter = tester.getCenter(
        find.byKey(const ValueKey('theme-mode-thumb')),
      );
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
    expect(
      tester.getCenter(appActions).dy,
      closeTo(tester.getCenter(themes).dy, 0.01),
    );
    expect(
      tester.getTopLeft(modes).dy,
      closeTo(tester.getTopLeft(navigation).dy, 0.01),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Dropdown and popup menu choices have visible separators', (
    tester,
  ) async {
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

    final toolbarContext = tester.element(find.byType(ToolbarWidget));
    unawaited(showRateShortcutMenu(toolbarContext, app));
    await tester.pumpAndSettle();
    final rateAnchor = tester.getRect(
      find.byKey(const ValueKey('toolbar-rate-dropdown')),
    );
    final shortcutRateItem = tester.getRect(
      find.byKey(const ValueKey('shortcut-rate-menu-thin')),
    );
    expect(shortcutRateItem.top, greaterThanOrEqualTo(rateAnchor.bottom));
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PopupMenuDivider), findsNWidgets(6));
  });

  testWidgets('Shot history uses the polished compact dropdown', (
    tester,
  ) async {
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

  testWidgets(
    'Shot history uses one selectable list with nested confirmation',
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
        find.byKey(const ValueKey('toolbar-shot-history-menu-action')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('toolbar-shot-history-action-divider')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('toolbar-shot-history-menu-action')),
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

      final retentionToggle = find.byKey(
        const ValueKey('shot-history-retention-enabled'),
      );
      await tester.tap(retentionToggle);
      await tester.pump();
      expect(app.limitShotHistory, isFalse);
      await tester.tap(retentionToggle);
      await tester.pump();
      expect(app.limitShotHistory, isTrue);

      final retentionLimit = find.byKey(
        const ValueKey('shot-history-retention-limit'),
      );
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

      final selectedShot = find.byKey(
        const ValueKey('shot-history-select-163702'),
      );
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
      await tester.tap(
        find.byKey(const ValueKey('shot-history-manager-close')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('toolbar-shot-history-dropdown')),
        findsNothing,
      );
    },
  );

  testWidgets('Waveform context menu is polished, grouped, and actionable', (
    tester,
  ) async {
    final app = AppState();
    addTearDown(app.dispose);
    var exportDialogCalls = 0;
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
          theme: MDSLensTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                height: 420,
                child: PlotPanel(
                  plotIdx: 0,
                  exportSaveDialog: (_) async {
                    exportDialogCalls++;
                    return null;
                  },
                ),
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
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            widget.message ==
                'Maximize Panel (${app.shortcutText(MdsShortcutCommand.maximizePanel)})',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('plot-context-menu-maximize')));
    await tester.pumpAndSettle();
    expect(app.maximizedPlot, 0);

    await tester.tapAt(
      tester.getCenter(find.byType(PlotPanel)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('plot-context-menu-export')));
    await tester.pumpAndSettle();
    expect(find.text('Export panel data'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('multi-panel-export-confirm')),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 20 && exportDialogCalls == 0; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();
    expect(exportDialogCalls, 1, reason: app.status);
    expect(app.status, 'Export cancelled');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Popup menus honor configured multi-stroke shortcuts', (
    tester,
  ) async {
    String? selected;
    final menuShortcuts = <MdsShortcutCommand, MdsShortcutBinding>{
      for (final command in const [
        MdsShortcutCommand.menuLeft,
        MdsShortcutCommand.menuDown,
        MdsShortcutCommand.menuUp,
        MdsShortcutCommand.menuRight,
        MdsShortcutCommand.menuActivate,
      ])
        command: const MdsShortcutBinding(),
    };
    menuShortcuts[MdsShortcutCommand.menuDown] = MdsShortcutBinding(
      primary: MdsShortcutSequence.single(
        MdsShortcutStroke(LogicalKeyboardKey.keyJ),
      ),
    );
    menuShortcuts[MdsShortcutCommand.menuUp] = MdsShortcutBinding(
      primary: MdsShortcutSequence.single(
        MdsShortcutStroke(LogicalKeyboardKey.keyK),
      ),
    );
    menuShortcuts[MdsShortcutCommand.menuActivate] = MdsShortcutBinding(
      primary: MdsShortcutSequence([
        MdsShortcutStroke(LogicalKeyboardKey.keyG),
        MdsShortcutStroke(LogicalKeyboardKey.keyR),
      ]),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: MDSLensTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () {
                unawaited(
                  showPolishedPopupMenu<String>(
                    context: context,
                    globalPosition: const Offset(200, 200),
                    id: 'multi-stroke-popup-test',
                    keyboardShortcuts: menuShortcuts,
                    groups: const [
                      PolishedPopupMenuGroup(
                        label: 'Test',
                        options: [
                          PolishedPopupMenuOption(
                            id: 'first',
                            value: 'first',
                            label: 'First',
                            icon: Icons.check,
                          ),
                          PolishedPopupMenuOption(
                            id: 'second',
                            value: 'second',
                            label: 'Second',
                            icon: Icons.check_circle_outline,
                          ),
                        ],
                      ),
                    ],
                  ).then((value) => selected = value),
                );
              },
              child: const Text('Open menu'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    expect(find.text('First'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(find.text('First'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();

    expect(selected, 'first');
    expect(find.text('First'), findsNothing);

    selected = null;
    await tester.tap(find.text('Open menu'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(selected, 'second');
  });

  testWidgets('Vim Tab enters Tree suggestions only from Insert mode', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tapAt(
      tester.getCenter(find.byType(PlotPanel).first),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('plot-context-menu-data-source')),
    );
    await tester.pumpAndSettle();

    final treeField = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('data-tree-0')),
        matching: find.byType(TextField),
      ),
    );
    treeField.focusNode!.requestFocus();
    await tester.pump();
    // Tab in Normal mode retains its ordinary traversal behavior.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      isNot('autocomplete-tree-option-0'),
    );

    treeField.focusNode!.requestFocus();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(
      VimInputModeScope.mode(
        tester.element(find.byKey(const ValueKey('data-tree-0'))),
      ),
      VimInputMode.insert,
    );
    treeField.controller!.value = const TextEditingValue(
      text: '',
      selection: TextSelection.collapsed(offset: 0),
    );
    // Tree names are published immediately, then the complete bundled index
    // refines the same overlay in the background. The fallback still forms a
    // valid one-item page on a very busy runner; when the full list has arrived
    // J must advance, otherwise it must remain deterministically at item 0.
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('autocomplete-tree-menu')), findsOneWidget);
    final hasSecondTreeSuggestion = find
        .byKey(const ValueKey('autocomplete-tree-option-1'))
        .evaluate()
        .isNotEmpty;

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'autocomplete-tree-option-0',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      hasSecondTreeSuggestion
          ? 'autocomplete-tree-option-1'
          : 'autocomplete-tree-option-0',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(treeField.controller!.text, isNotEmpty);
  });

  testWidgets(
    'Data source Shot inherits the loaded shot when config is empty',
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
        {'shot': '', 'experiment': 'pcs_east', 'y_expr': r'\PCRL01'},
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
      expect(
        tester.getSize(find.byKey(const ValueKey('data-server-0'))).width,
        greaterThan(100),
      );
      final scrollbarHost = find.byKey(
        const ValueKey('data-source-horizontal-scrollbar'),
      );
      final dataSourceScrollbar = tester.widget<Scrollbar>(
        find.descendant(of: scrollbarHost, matching: find.byType(Scrollbar)),
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
        find.descendant(of: scrollbarHost, matching: find.byType(Scrollbar)),
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
      // This round-trip test does not exercise modal-barrier behaviour. Clear
      // the editor focus directly rather than tapping outside the dialog
      // route, which would intentionally dismiss a normal dialog.
      focusedShot?.unfocus();
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
      final shotBehavior = tester.widget<PolishedDropdown<bool>>(
        find.byKey(const ValueKey('data-shot-fixed-dropdown-0')),
      );
      expect(shotBehavior.value, isFalse);
      expect(find.byType(Checkbox), findsNothing);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(signals.single['legend'], 'Primary current');
      expect(signals.single['shot'], '163888');
      expect(signals.single['shot_fixed'], isFalse);
      expect(signals.single['hide_mode'], signalHideModeVisible);
      expect(signals.single['hidden'], isFalse);
    },
  );

  testWidgets('SSH mode and font family use polished dropdown menus', (
    tester,
  ) async {
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
    await tester.tap(find.text('Customize Fonts'));
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
              of: find.byKey(ValueKey('font-family-option-${index + 1}')),
              matching: find.text(family),
            )
            .last,
      );
      expect(optionLabel.style?.fontFamily, family);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('About appears only in the icon-decorated settings menu', (
    tester,
  ) async {
    final app = AppState();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    expect(app.vimMode, isFalse);
    expect(find.byTooltip('About MDSLens'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('About MDSLens'), findsOneWidget);
    expect(find.byIcon(Icons.language_rounded), findsOneWidget);
    expect(find.byIcon(Icons.dashboard_customize_rounded), findsOneWidget);
    expect(find.byIcon(Icons.font_download_outlined), findsOneWidget);
    expect(find.text('Vim mode (keyboard-only)'), findsOneWidget);
    expect(find.byIcon(Icons.restore_rounded), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-auto-update-check')),
      findsNothing,
    );
    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-vim-mode')));
    await tester.pumpAndSettle();
    expect(app.vimMode, isTrue);
  });

  testWidgets('Settings can restore every preference after confirmation', (
    tester,
  ) async {
    final app = AppState(credentialStore: MemoryCredentialStore());
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.themeMode = 1;
    app.dataMode = 2;
    app.setVimMode(true);
    app.applyFontSettings('Arial', 17, 12, 13, 16, iconSize: 30);
    app.addWebBookmark('Example', 'https://example.com');
    app.shotText = '163714';
    app.sourceIndexMemory.remember('pcs_east', r'\\ip');
    app.setLoginUser('user');
    app.setLoginPass('secret');
    app.setSshHost('host');

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore All Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Restore All Settings?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('restore-all-settings-cancel')));
    await tester.pumpAndSettle();
    expect(app.themeMode, 1);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore All Settings'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('restore-all-settings-confirm')));
    await tester.pumpAndSettle();

    expect(app.themeMode, 2);
    expect(app.vimMode, isFalse);
    expect(app.dataMode, 0);
    expect(app.fontFamily, 'System');
    expect(app.fontLegendSize, 11);
    expect(app.fontAxisSize, 8);
    expect(app.fontUnitSize, 9);
    expect(app.fontUiSize, 12);
    expect(app.iconSize, 22);
    expect(app.webBookmarks, isEmpty);
    expect(app.shotHistory, isEmpty);
    expect(app.shotText, isEmpty);
    expect(app.loginUser, isEmpty);
    expect(app.loginPass, isEmpty);
    expect(app.sshHost, isEmpty);
    expect(app.sourceIndexMemory.trees, isEmpty);
    expect(app.columns.map((column) => column.length), [3, 3]);
  });

  testWidgets('Automatic update checks are enabled by default and configurable',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    expect(app.autoCheckUpdates, isTrue);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-auto-update-check')),
      findsNothing,
    );
    await tester.tap(find.text('About MDSLens'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('about-auto-update-check')),
          )
          .value,
      isTrue,
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey('about-auto-update-check')),
    );
    await tester.tap(
      find.byKey(const ValueKey('about-auto-update-check')),
    );
    await tester.pumpAndSettle();
    expect(app.autoCheckUpdates, isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About MDSLens'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('about-auto-update-check')),
          )
          .value,
      isFalse,
    );
  });

  testWidgets('Startup update check runs independently of initialization',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    var checks = 0;
    var hasNavigator = false;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(
          automaticUpdateChecker: (context) async {
            checks++;
            hasNavigator = Navigator.maybeOf(context) != null;
          },
        ),
      ),
    );
    await tester.pump();
    expect(checks, 1);
    expect(hasNavigator, isTrue);
  });

  testWidgets('Startup update check does not wait for login or no-login path',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    final updateStarted = Completer<void>();
    final updateMayFinish = Completer<void>();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(
          automaticUpdateChecker: (context) async {
            updateStarted.complete();
            await updateMayFinish.future;
          },
        ),
      ),
    );
    await tester.pump();
    await expectLater(updateStarted.future, completes);
    updateMayFinish.complete();
  });

  testWidgets('Disabled startup update check does not run', (tester) async {
    final app = AppState();
    await app.preferencesReady;
    app.setAutoCheckUpdates(false);
    addTearDown(app.dispose);
    var checks = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(
          automaticUpdateChecker: (context) async {
            checks++;
          },
        ),
      ),
    );
    app.markStartupInitializationComplete();
    await tester.pump();
    expect(checks, 0);
  });

  testWidgets('Automatic update failures remain silent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => AboutDialogWidget.checkAutomatically(
              context,
              versionLoader: () async => '0.0.1',
              updateChecker: () async => throw Exception('offline'),
              retryDelays: const [],
            ),
            child: const Text('Check silently'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check silently'));
    await tester.pumpAndSettle();
    expect(find.text('Update check failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Automatic update checks retry transient lookup failures',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => AboutDialogWidget.checkAutomatically(
              context,
              versionLoader: () async => '0.2.0',
              updateChecker: () async {
                attempts++;
                if (attempts == 1) throw Exception('temporarily offline');
                return const ReleaseUpdate(
                  latestVersion: 'v0.2.0',
                  releaseUrl:
                      'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v0.2.0',
                  updateAvailable: false,
                );
              },
              retryDelays: const [Duration.zero],
            ),
            child: const Text('Check with retry'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check with retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.text('Update check failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Automatic update checks offer details, direct update, or not now',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => AboutDialogWidget.checkAutomatically(
              context,
              directUpdateSupportOverride: true,
              versionLoader: () async => '0.0.1',
              updateChecker: () async => const ReleaseUpdate(
                latestVersion: 'v1.0.0',
                releaseUrl:
                    'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.0.0',
                updateAvailable: true,
                assets: [
                  ReleaseAssetLocation(
                    name: 'update-manifest.json',
                    url: 'https://example.invalid/update-manifest.json',
                    size: 1,
                  ),
                ],
              ),
            ),
            child: const Text('Check automatically'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Check automatically'));
    await tester.pumpAndSettle();
    expect(find.text('Update Available'), findsOneWidget);
    expect(find.text('Not Now'), findsOneWidget);
    expect(find.text('View Details'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('install-update-directly')),
      findsOneWidget,
    );
    await tester.tap(find.text('Not Now'));
    await tester.pumpAndSettle();
    expect(find.text('Update Available'), findsNothing);
  });

  testWidgets('Internal web pages use separated polished list items', (
    tester,
  ) async {
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
    await tester.tap(find.text('Internal Web Pages'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('internal-web-pages-list')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('internal-web-page-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('internal-web-page-1')), findsOneWidget);
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

    await tester.tap(find.byKey(const ValueKey('internal-web-page-edit-0')));
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
      await tester.tap(find.text('Internal Web Pages'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove...'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('bookmark-removal-selection-list')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('bookmark-select-all')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bookmark-remove-1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bookmark-delete-selected')));
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

      await tester.tap(find.byKey(const ValueKey('bookmark-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bookmark-removal-confirm')));
      await tester.pumpAndSettle();
      expect(app.webBookmarks.map((item) => item.keys.first), [
        'Diagnostics',
        'Status',
      ]);
      expect(
        find.byKey(const ValueKey('bookmark-removal-selection-list')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('bookmark-select-all')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bookmark-delete-selected')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('bookmark-removal-confirm')));
      await tester.pumpAndSettle();
      expect(app.webBookmarks, isEmpty);
      expect(find.text('No bookmarks remain'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('bookmark-removal-close')));
      await tester.pumpAndSettle();
      expect(find.text('No Saved Web Addresses'), findsOneWidget);
    },
  );

  testWidgets('Toolbar remains bounded with enlarged customized UI fonts', (
    tester,
  ) async {
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

      expect(
        tester.getSize(find.byKey(const ValueKey('toolbar-root'))).width,
        width,
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Small screens can collapse controls without covering plots', (
    tester,
  ) async {
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
    expect(
      tester.getRect(collapse).bottom,
      lessThanOrEqualTo(expandedPlotTop + 0.01),
    );

    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar-root')), findsNothing);
    expect(
      find.byKey(const ValueKey('toolbar-collapsed-summary')),
      findsOneWidget,
    );
    final collapsedPlotTop = tester.getTopLeft(find.byType(PlotGrid)).dy;
    expect(collapsedPlotTop, lessThan(expandedPlotTop));
    expect(
      tester.getRect(collapse).bottom,
      lessThanOrEqualTo(collapsedPlotTop + 0.01),
    );

    await tester.tap(collapse);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('toolbar-root')), findsOneWidget);
  });

  testWidgets('Extremely small screens scroll controls but not the plot area', (
    tester,
  ) async {
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

  testWidgets('Settings dialogs gain two-axis scrolling on tiny screens', (
    tester,
  ) async {
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

  testWidgets('Collapsed toolbar keeps controls fixed and scrolls metadata', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    app.shotText = '163714';
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ResponsiveToolbar())),
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
    final summaryFinder = find.byKey(
      const ValueKey('toolbar-collapsed-summary'),
    );
    final summary = tester.widget<Text>(summaryFinder).data!;
    expect(summary, contains('Shot: 163714'));
    expect(summary, contains('Ip: --'));
    expect(summary, contains('Pulse: --'));
    expect(summary, contains('It: --'));
    expect(summary, contains('Time: --'));
    expect(RegExp('Shot:').allMatches(summary), hasLength(1));
    expect(summary, isNot(contains(app.status)));

    final metadataScroll = find.byKey(
      const ValueKey('toolbar-collapsed-metadata-scroll'),
    );
    final horizontalScrollable = find.descendant(
      of: metadataScroll,
      matching: find.byType(Scrollable),
    );
    expect(horizontalScrollable, findsOneWidget);
    final scrollState = tester.state<ScrollableState>(
      horizontalScrollable.first,
    );
    expect(scrollState.position.maxScrollExtent, greaterThan(0));
    final fixedLeft = tester.getTopLeft(find.text('Expand controls'));
    await tester.drag(metadataScroll, const Offset(-180, 0));
    await tester.pumpAndSettle();
    expect(scrollState.position.pixels, greaterThan(0));
    expect(tester.getTopLeft(find.text('Expand controls')), fixedLeft);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Comfortable screens do not show the collapse control', (
    tester,
  ) async {
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
      find.byKey(const ValueKey('toolbar-collapse-control')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('toolbar-root')), findsOneWidget);
  });

  testWidgets('Layout Setup preview matches phone and tablet plot columns', (
    tester,
  ) async {
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
      await tester.tap(find.text('Layout Setup'));
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
    expect(columns.map((column) => column.single['title']).toList(), [
      'Column 1',
      'Column 2',
      'Column 5',
      'Column 3',
      'Column 4',
    ]);

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
    expect(panels[0].map((item) => item['title']).toList(), [
      '1-1',
      '1-2',
      '1-3',
      '3-2',
      '1-4',
    ]);
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

    final mergedColumns = [
      [panel('1-1')],
      [panel('2-1'), panel('2-2')],
      [panel('3-1')],
      [panel('4-1'), panel('4-2'), panel('4-3')],
    ];
    expect(
      insertLayoutColumnIntoColumn(
        mergedColumns,
        sourceColumn: 1,
        targetColumn: 3,
        insertionRow: 2,
      ),
      isTrue,
    );
    expect(
      mergedColumns
          .map((column) => column.map((item) => item['title']).toList())
          .toList(),
      [
        ['1-1'],
        ['3-1'],
        ['4-1', '4-2', '2-1', '2-2', '4-3'],
      ],
    );
    expect(
      insertLayoutColumnIntoColumn(
        mergedColumns,
        sourceColumn: 2,
        targetColumn: 2,
        insertionRow: 0,
      ),
      isFalse,
    );
  });

  test('Layout selection toggles panels and whole columns by identity', () {
    Map<String, dynamic> panel(String title) => {'title': title};
    final first = panel('First');
    final second = panel('Second');
    final third = panel('Third');
    final columns = [
      [first, second],
      [third],
    ];
    final selected = Set<Map<String, dynamic>>.identity();

    toggleLayoutColumnSelection(columns.first, selected);
    expect(selected, containsAll([first, second]));
    expect(layoutColumnIsSelected(columns.first, selected), isTrue);

    toggleLayoutPanelSelection(first, selected);
    expect(layoutColumnIsSelected(columns.first, selected), isFalse);
    expect(selected, contains(second));

    toggleLayoutColumnSelection(columns.first, selected);
    expect(layoutColumnIsSelected(columns.first, selected), isTrue);
    toggleLayoutPanelSelection(third, selected);
    expect(deleteSelectedLayoutPanels(columns, selected), 3);
    expect(columns, isEmpty);
    expect(selected, isEmpty);
  });

  testWidgets('Layout Setup multi-selects and deletes panels and columns', (
    tester,
  ) async {
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
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();
    expect(
      tester.widget(find.byKey(const ValueKey('layout-column-drag-1'))),
      isA<LongPressDraggable>(),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('layout-panel-drag-1'))),
      isA<LongPressDraggable>(),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('layout-column-drag-handle-1'))),
      isA<Draggable>(),
    );
    expect(
      tester.widget(find.byKey(const ValueKey('layout-panel-drag-handle-1'))),
      isA<Draggable>(),
    );
    expect(find.byKey(const ValueKey('layout-column-drop-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-panel-drop-0-1')), findsOneWidget);
    final dragPreview = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('layout-column-header-1'))),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('1 panels'), findsOneWidget);
    await dragPreview.cancel();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('layout-column-header-2')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('layout-column-selected-2')),
      findsOneWidget,
    );
    final deleteSelected = find.byKey(
      const ValueKey('layout-delete-selected'),
    );
    expect(tester.widget<FilledButton>(deleteSelected).onPressed, isNotNull);

    await tester.tap(find.byKey(const ValueKey('layout-setup-blank-area')));
    await tester.pump();
    expect(
      tester.widget<FilledButton>(deleteSelected).onPressed,
      isNull,
    );

    expect(
      tester.widget(find.byKey(const ValueKey('layout-edit-panel-1'))),
      isA<IconButton>(),
    );
    expect(find.byKey(const ValueKey('layout-delete-panel-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('layout-preview-panel-0')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('layout-column-header-2')));
    await tester.pump();
    expect(find.text('Delete 2'), findsOneWidget);
    await tester.tap(deleteSelected);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('layout-preview-column-0')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('layout-preview-column-1')), findsNothing);
    expect(tester.widget<FilledButton>(deleteSelected).onPressed, isNull);

    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(app.columns, isEmpty);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Add panel'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('layout-preview-column-0')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('layout-preview-panel-0')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(app.columns, hasLength(1));
    expect(app.columns.single, hasLength(1));
  });

  testWidgets('A panel drag handle can create a column between columns', (
    tester,
  ) async {
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
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();

    final handle = find.byKey(const ValueKey('layout-panel-drag-handle-2'));
    final betweenColumns = find.byKey(const ValueKey('layout-column-drop-1'));
    final drag = await tester.startGesture(tester.getCenter(handle));
    await drag.moveTo(tester.getCenter(betweenColumns));
    await tester.pump(const Duration(milliseconds: 200));
    await drag.up();
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>)
                .value
                .startsWith('layout-item-settle-'),
      ),
      findsWidgets,
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('layout-preview-column-2')),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(app.columns.map((column) => column.length), [1, 1, 1]);
  });

  testWidgets('A column drag inserts its Panels into another Column', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.applyLayoutList([1, 2, 1, 3]);
    for (var column = 0; column < app.columns.length; column++) {
      for (var row = 0; row < app.columns[column].length; row++) {
        app.columns[column][row]['title'] = 'C${column + 1}-${row + 1}';
      }
    }
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: const MaterialApp(home: Scaffold(body: ToolbarWidget())),
      ),
    );
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();

    final source = find.byKey(const ValueKey('layout-column-drag-handle-2'));
    final insertion = find.byKey(const ValueKey('layout-panel-drop-3-2'));
    final drag = await tester.startGesture(tester.getCenter(source));
    await drag.moveTo(tester.getCenter(insertion));
    await tester.pump(const Duration(milliseconds: 200));
    await drag.up();
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(
      app.columns
          .map((column) => column.map((panel) => panel['title']).toList())
          .toList(),
      [
        ['C1-1'],
        ['C3-1'],
        ['C4-1', 'C4-2', 'C2-1', 'C2-2', 'C4-3'],
      ],
    );
  });

  testWidgets('Vim cut and paste moves Layout Columns and Panels', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.reset);

    Future<void> seed() async {
      app.applyLayoutList([1, 2, 1, 3]);
      for (var column = 0; column < app.columns.length; column++) {
        for (var row = 0; row < app.columns[column].length; row++) {
          app.columns[column][row]['title'] = 'C${column + 1}-${row + 1}';
        }
      }
      await tester.pump();
    }

    List<List<String>> titles() => [
          for (final column in app.columns)
            [for (final panel in column) panel['title'] as String],
        ];

    Future<void> openLayout() async {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Layout Setup'));
      await tester.pumpAndSettle();
    }

    FocusNode layoutNode({
      required int column,
      int? row,
      required bool isColumn,
    }) =>
        FocusManager.instance.rootScope.descendants
            .where((node) => node.canRequestFocus && !node.skipTraversal)
            .firstWhere((node) {
          final marker =
              node.context?.findAncestorWidgetOfExactType<VimLayoutFocus>();
          return marker?.isColumn == isColumn &&
              marker?.column == column &&
              (isColumn || marker?.row == row);
        });

    Future<void> focusLayout({
      required int column,
      int? row,
      required bool isColumn,
    }) async {
      layoutNode(column: column, row: row, isColumn: isColumn).requestFocus();
      await tester.pump();
    }

    Future<void> pasteBefore() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
    }

    Future<void> apply() async {
      await tester.tap(find.byKey(const ValueKey('layout-apply')));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    // Column -> between sibling Columns: p places it after the target Column.
    await seed();
    await openLayout();
    await focusLayout(column: 1, isColumn: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pumpAndSettle();
    expect(find.textContaining('Cut Column 2'), findsOneWidget);
    // After a structural edit the focus ring must follow the replacement
    // Column, not a removed cell or one of its nested drag/edit controls.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'layout-column-1');
    final cutRing =
        tester.getRect(find.byKey(const ValueKey('vim-focus-ring')));
    final cutColumn = tester.getRect(
      find.byKey(const ValueKey('layout-preview-column-1')),
    );
    expect(cutRing.center.dx, closeTo(cutColumn.center.dx, 5));
    expect(cutRing.center.dy, closeTo(cutColumn.center.dy, 5));
    await focusLayout(column: 1, isColumn: true); // Original Column 3.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    await apply();
    expect(titles(), [
      ['C1-1'],
      ['C3-1'],
      ['C2-1', 'C2-2'],
      ['C4-1', 'C4-2', 'C4-3'],
    ]);

    // Column -> inside another Column: P inserts all of its Panels before the
    // selected target Panel. Entering the target Column is explicit.
    await seed();
    await openLayout();
    await focusLayout(column: 1, isColumn: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pumpAndSettle();
    await focusLayout(column: 2, isColumn: true); // Original Column 4.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    await pasteBefore();
    await apply();
    expect(titles(), [
      ['C1-1'],
      ['C3-1'],
      ['C4-1', 'C2-1', 'C2-2', 'C4-2', 'C4-3'],
    ]);

    // Panel -> between sibling Columns: P turns the cut Panel into its own
    // Column immediately before the target Column.
    await seed();
    await openLayout();
    await focusLayout(column: 1, row: 0, isColumn: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pumpAndSettle();
    expect(find.textContaining('Cut Panel 1'), findsOneWidget);
    // Cutting a Panel keeps us at the Panel level whenever the replacement
    // Column still has a sibling Panel. Its ring must follow that real card.
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'layout-panel-1-0',
    );
    final replacementPanelRing =
        tester.getRect(find.byKey(const ValueKey('vim-focus-ring')));
    final replacementPanel = tester.getRect(
      find.byKey(const ValueKey('layout-preview-panel-1')),
    );
    expect(
      replacementPanelRing.center.dx,
      closeTo(replacementPanel.center.dx, 5),
    );
    expect(
      replacementPanelRing.center.dy,
      closeTo(replacementPanel.center.dy, 5),
    );
    await focusLayout(column: 2, isColumn: true); // Column 3.
    await pasteBefore();
    await apply();
    expect(titles(), [
      ['C1-1'],
      ['C2-2'],
      ['C2-1'],
      ['C3-1'],
      ['C4-1', 'C4-2', 'C4-3'],
    ]);

    // Panel -> inside another Column: p places it immediately after the
    // selected target Panel.
    await seed();
    await openLayout();
    await focusLayout(column: 1, row: 0, isColumn: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
    await tester.pumpAndSettle();
    await focusLayout(column: 3, isColumn: true);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pumpAndSettle();
    await apply();
    expect(titles(), [
      ['C1-1'],
      ['C2-2'],
      ['C3-1'],
      ['C4-1', 'C4-2', 'C2-1', 'C4-3'],
    ]);
  });

  testWidgets('Layout Setup scrolls wide columns and tall panel lists', (
    tester,
  ) async {
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
    await tester.tap(find.text('Layout Setup'));
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

    tallColumn.controller!.jumpTo(140);
    await tester.pump();
    expect(tallColumn.controller?.position.pixels, greaterThan(0));

    await tester.drag(
      find.byKey(const ValueKey('layout-horizontal-scroll')),
      const Offset(-180, 0),
    );
    await tester.pumpAndSettle();
    expect(horizontal.controller?.position.pixels, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Vim selection ring follows Layout Setup scrolling', (
    tester,
  ) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    app.applyLayoutList([6]);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('layout-preview-panel-0')));
    await tester.pump();
    expect(find.byKey(const ValueKey('vim-focus-ring')), findsOneWidget);
    final before = tester.getRect(find.byKey(const ValueKey('vim-focus-ring')));

    final vertical = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('layout-column-scrollbar-0')),
    );
    vertical.controller!.jumpTo(80);
    await tester.pump();
    final after = tester.getRect(find.byKey(const ValueKey('vim-focus-ring')));
    expect(after.top, lessThan(before.top));
  });

  testWidgets('Vim Layout Setup activates every action control',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    app.setVimMode(true);
    app.applyLayoutList([1]);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: app,
        child: MDSLensApp(automaticUpdateChecker: (_) async {}),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> openLayout() async {
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Layout Setup'));
      await tester.pumpAndSettle();
    }

    Future<void> activate(String label) async {
      final node = Focus.maybeOf(
        tester.element(find.text(label)),
        scopeOk: false,
      );
      expect(node, isNotNull, reason: 'missing focus target for $label');
      node!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
    }

    await openLayout();
    await activate('Add panel');
    expect(
        find.byKey(const ValueKey('layout-preview-panel-1')), findsOneWidget);
    await activate('Add column');
    expect(find.byKey(const ValueKey('layout-column-focus-1')), findsOneWidget);
    await activate('Reset');
    expect(find.byKey(const ValueKey('layout-preview-panel-1')), findsNothing);

    // Select the only panel, then invoke Delete without touching the mouse.
    final panelNode = Focus.maybeOf(
      tester.element(find.byKey(const ValueKey('layout-panel-focus-1'))),
      scopeOk: false,
    );
    panelNode!.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await activate('Delete 1');
    expect(find.byKey(const ValueKey('layout-preview-panel-0')), findsNothing);

    await activate('Cancel');
    expect(find.byKey(const ValueKey('keyboard-safe-dialog')), findsNothing);

    await openLayout();
    await activate('Apply');
    expect(find.byKey(const ValueKey('keyboard-safe-dialog')), findsNothing);
  });

  testWidgets('Layout Setup shows metadata and supports draft panel actions', (
    tester,
  ) async {
    final app = AppState(signalFetchWorker: (_, __, ___) async => '[]');
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
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();

    expect(find.text('Panel 1'), findsOneWidget);
    expect(find.text('Title: Magnetic overview'), findsOneWidget);
    expect(find.text('Curve 1 Tree: tree_a'), findsOneWidget);
    expect(find.text(r'Curve 1 Signal: \signal_a'), findsOneWidget);
    expect(find.text('Curve 2 Tree: tree_b'), findsOneWidget);
    expect(find.text(r'Curve 3 Signal: \signal_c'), findsOneWidget);
    expect(find.textContaining('Curve 4'), findsNothing);
    expect(find.text('Title: '), findsNothing);
    expect(find.byKey(const ValueKey('layout-edit-panel-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('layout-delete-panel-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('layout-preview-panel-0')));
    await tester.pump();
    expect(find.byKey(const ValueKey('layout-edit-panel-1')), findsOneWidget);

    final layoutDialog = tester.getRect(
      find.byKey(const ValueKey('keyboard-safe-dialog')),
    );
    await tester.tapAt(Offset(layoutDialog.right - 20, layoutDialog.top + 20));
    await tester.pump();
    expect(find.byKey(const ValueKey('layout-edit-panel-1')), findsOneWidget);

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
    await tester.ensureVisible(
      find.byKey(const ValueKey('data-mode-dropdown-0')),
    );
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
    await tester.tap(find.byKey(const ValueKey('layout-delete-selected')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layout-preview-panel-1')), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(app.columns, hasLength(1));
    expect(app.columns.single, hasLength(1));
    expect(app.columns.single.single['title'], 'Edited title');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Layout Setup Reset restores the opening draft', (tester) async {
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
    await tester.tap(find.text('Layout Setup'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('layout-column-header-2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('layout-delete-selected')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('layout-preview-column-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('layout-reset')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('layout-preview-column-1')), findsOneWidget);
    expect(find.textContaining('0 panels selected'), findsOneWidget);
  });

  testWidgets(
    'Panel Setup follows actual plot metadata until the user overrides it',
    (tester) async {
      final panel = <String, dynamic>{
        'title': 'Configured title',
        'x_label': 's',
        'y_label': 'a.u.',
        'extraction_points': 2000,
        'grid': true,
      };
      final actual = ValueNotifier<PanelSetupValues>(
        const PanelSetupValues(
          title: 'Loaded title',
          xLabel: 'ms',
          yLabel: 'kA',
          extractionPoints: 4096,
        ),
      );
      addTearDown(actual.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPanelSetupEditor(
                context,
                panel,
                actualValues: () => actual.value,
                actualChanges: actual,
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      TextField field(Key key) => tester.widget<TextField>(find.byKey(key));
      expect(
        field(const ValueKey('panel-setup-title')).controller!.text,
        'Loaded title',
      );
      expect(
        field(const ValueKey('panel-setup-x-label')).controller!.text,
        'ms',
      );
      expect(
        field(const ValueKey('panel-setup-y-label')).controller!.text,
        'kA',
      );
      expect(
        field(const ValueKey('panel-setup-extraction-points')).controller!.text,
        '4096',
      );

      actual.value = const PanelSetupValues(
        title: 'New loaded title',
        xLabel: 'µs',
        yLabel: 'V',
        extractionPoints: 8192,
      );
      await tester.pump();
      expect(
        field(const ValueKey('panel-setup-title')).controller!.text,
        'New loaded title',
      );
      expect(
        field(const ValueKey('panel-setup-x-label')).controller!.text,
        'µs',
      );

      await tester.enterText(
        find.byKey(const ValueKey('panel-setup-title')),
        'User title',
      );
      actual.value = const PanelSetupValues(
        title: 'Later server title',
        xLabel: 'ns',
        yLabel: 'mV',
        extractionPoints: 16384,
      );
      await tester.pump();
      expect(
        field(const ValueKey('panel-setup-title')).controller!.text,
        'User title',
      );
      expect(
        field(const ValueKey('panel-setup-x-label')).controller!.text,
        'ns',
      );

      await tester.enterText(
        find.byKey(const ValueKey('panel-setup-y-label')),
        'tesla',
      );
      await tester.enterText(
        find.byKey(const ValueKey('panel-setup-extraction-points')),
        '12000',
      );
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();

      expect(panel['title'], 'User title');
      expect(panel['x_label'], 's');
      expect(panel['y_label'], 'tesla');
      expect(panel['extraction_points'], 12000);
    },
  );

  testWidgets('About dialog reflows and opens links on a phone', (
    tester,
  ) async {
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
          versionLoader: () async => '0.0.1',
          gitVersionLoader: () async => '0.0.1.r42.g123456789',
          urlOpener: (uri) async {
            openedUrls.add(uri);
            return true;
          },
          updateChecker: () async => const ReleaseUpdate(
            latestVersion: 'v99.0.0',
            releaseUrl:
                'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v99.0.0',
            updateAvailable: true,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('0.0.1.r42.g123456789'), findsOneWidget);
    expect(find.text('iOS (18.5) (arm64)'), findsOneWidget);

    final narrowVersionRow = find.byKey(
      const ValueKey('about-row-narrow-MDSLens Version'),
    );
    expect(narrowVersionRow, findsOneWidget);
    expect(
      tester.widget<Column>(narrowVersionRow).crossAxisAlignment,
      CrossAxisAlignment.center,
    );
    await tester.ensureVisible(find.text('MDSLens Version'));
    expect(
      tester.getCenter(find.text('MDSLens Version')).dx,
      closeTo(tester.getCenter(find.text('0.0.1')).dx, 0.5),
    );

    await tester.ensureVisible(find.text('MdsScope project'));
    await tester.tap(find.text('MdsScope project'));
    await tester.pump();
    expect(openedUrls.single, Uri.parse(originalMdsScopeRepositoryUrl));

    await tester.ensureVisible(find.text('Pingzhong Wu'));
    await tester.tap(find.text('Pingzhong Wu'));
    await tester.pump();
    expect(openedUrls.last, Uri.parse(mdsLensMaintainerUrl));

    await tester.ensureVisible(find.text('GitHub'));
    await tester.tap(find.text('GitHub'));
    await tester.pump();
    expect(openedUrls.last, Uri.parse(mdsLensSourceUrl));

    await tester.ensureVisible(find.text('Update'));
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('View Details'), findsOneWidget);
    final lastUrlBeforeUpdateChoice = openedUrls.last;
    await tester.tap(find.text('Not Now'));
    await tester.pumpAndSettle();
    expect(openedUrls.last, lastUrlBeforeUpdateChoice);

    await tester.ensureVisible(find.text('Update'));
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('View Details'), findsOneWidget);
    await tester.tap(find.text('View Details'));
    await tester.pumpAndSettle();

    expect(
      openedUrls.last,
      Uri.parse('https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v99.0.0'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('About downloads and installs a matching verified update', (
    tester,
  ) async {
    var installerCalled = false;
    var exitRequested = false;
    final finishInstallation = Completer<void>();
    final finishHandoff = Completer<void>();
    const manifest = ReleaseAssetLocation(
      name: 'update-manifest.json',
      url:
          'https://github.com/Wu-Kuan-Yee/MDSLens/releases/download/v1.0.0/update-manifest.json',
      size: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AboutDialogWidget(
          systemInfoLoader: () async => const RuntimeSystemInfo(
            name: 'macOS',
            version: '26.2',
            architecture: 'arm64',
          ),
          versionLoader: () async => '0.0.1',
          gitVersionLoader: () async => '0.0.1.r1.g123456789',
          applicationExitRequester: () async {
            exitRequested = true;
          },
          directUpdateSupportOverride: true,
          updateChecker: () async => const ReleaseUpdate(
            latestVersion: 'v1.0.0',
            releaseUrl:
                'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.0.0',
            updateAvailable: true,
            assets: [manifest],
          ),
          updateInstaller: (
            release,
            systemInfo, {
            required controller,
            onProgress,
          }) async {
            installerCalled = true;
            onProgress?.call(
              const UpdateDownloadProgress(received: 50, total: 100),
            );
            await finishInstallation.future;
            onProgress?.call(
              const UpdateDownloadProgress(received: 100, total: 100),
            );
            await finishHandoff.future;
            return const UpdateInstallResult(
              status: UpdateLaunchStatus.launched,
              message: 'The verified update installer is ready.',
              closeApplication: true,
            );
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('install-update-directly')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('install-update-directly')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Update Available'), findsNothing);
    expect(
        find.byKey(const ValueKey('update-download-dialog')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('update-download-progress')), findsOneWidget);
    finishInstallation.complete();
    await tester.pump();
    expect(find.text('Finishing update...'), findsOneWidget);
    expect(find.byKey(const ValueKey('cancel-update-download')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
        find.byKey(const ValueKey('update-download-dialog')), findsOneWidget);

    finishHandoff.complete();
    await tester.pumpAndSettle();

    expect(installerCalled, isTrue);
    expect(exitRequested, isTrue);
    expect(
        find.text('The verified update installer is ready.'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('update-download-progress')), findsNothing);
  });

  testWidgets('Dedicated update dialog cancels an active download', (
    tester,
  ) async {
    var cancellationObserved = false;
    const manifest = ReleaseAssetLocation(
      name: 'update-manifest.json',
      url:
          'https://github.com/Wu-Kuan-Yee/MDSLens/releases/download/v1.0.0/update-manifest.json',
      size: 1,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AboutDialogWidget(
          systemInfoLoader: () async => const RuntimeSystemInfo(
            name: 'macOS',
            version: '26.2',
            architecture: 'arm64',
          ),
          versionLoader: () async => '0.0.1',
          gitVersionLoader: () async => '0.0.1.r1.g123456789',
          directUpdateSupportOverride: true,
          updateChecker: () async => const ReleaseUpdate(
            latestVersion: 'v1.0.0',
            releaseUrl:
                'https://github.com/Wu-Kuan-Yee/MDSLens/releases/tag/v1.0.0',
            updateAvailable: true,
            assets: [manifest],
          ),
          updateInstaller: (
            release,
            systemInfo, {
            required controller,
            onProgress,
          }) async {
            final cancelled = Completer<void>();
            controller.bind(() {
              cancellationObserved = true;
              if (!cancelled.isCompleted) cancelled.complete();
            });
            onProgress?.call(
              const UpdateDownloadProgress(received: 25, total: 100),
            );
            await cancelled.future;
            controller.unbind();
            throw const UpdateCancelledException();
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('install-update-directly')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('update-download-dialog')), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);

    await tester.tapAt(const Offset(2, 2));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('update-download-dialog')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
        find.byKey(const ValueKey('update-download-dialog')), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
        find.byKey(const ValueKey('update-download-dialog')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cancel-update-download')));
    await tester.pumpAndSettle();

    expect(cancellationObserved, isTrue);
    expect(find.byKey(const ValueKey('update-download-dialog')), findsNothing);
    expect(find.text('MDSLens Version'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
