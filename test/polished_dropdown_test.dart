import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdslens/widgets/polished_dropdown.dart';

void main() {
  testWidgets('long polished dropdown exposes a draggable scrollbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PolishedDropdown<int>(
            id: 'long-dropdown',
            value: 0,
            menuMaxHeight: 240,
            showScrollbar: true,
            options: [
              for (var index = 0; index < 40; index++)
                PolishedDropdownOption(
                  value: index,
                  label: 'Locale $index',
                ),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('long-dropdown-anchor')));
    await tester.pumpAndSettle();

    final scrollbarFinder = find.byKey(
      const ValueKey('long-dropdown-scrollbar'),
    );
    expect(scrollbarFinder, findsOneWidget);
    final scrollbar = tester.widget<RawScrollbar>(scrollbarFinder);
    expect(scrollbar.interactive, isTrue);
    expect(scrollbar.thumbVisibility, isTrue);
    final scrollableFinder = find.descendant(
      of: scrollbarFinder,
      matching: find.byType(Scrollable),
    );
    final scrollableState = tester.state<ScrollableState>(scrollableFinder);
    final before = scrollableState.position.pixels;
    final scrollbarRect = tester.getRect(scrollbarFinder);
    final gesture = await tester.startGesture(
      Offset(scrollbarRect.right - 2, scrollbarRect.top + 20),
    );
    await gesture.moveBy(const Offset(0, 80));
    await gesture.up();
    await tester.pump();
    expect(scrollableState.position.pixels, greaterThan(before));
    // The first entry remains mounted while the scrollbar provides access to
    // every remaining locale record.
    expect(
      find.byKey(const ValueKey('long-dropdown-option-0')),
      findsOneWidget,
    );
  });

  testWidgets('long polished dropdown supports gg and G edge navigation', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PolishedDropdown<int>(
            id: 'vim-dropdown',
            value: 0,
            menuMaxHeight: 240,
            showScrollbar: true,
            options: [
              for (var index = 0; index < 40; index++)
                PolishedDropdownOption(
                  value: index,
                  label: 'Locale $index',
                ),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('vim-dropdown-anchor')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'dropdown-vim-dropdown-option-0',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus?.debugLabel,
      'dropdown-vim-dropdown-option-39',
    );
  });

  testWidgets('long dropdown keeps its scrollbar inside a narrow viewport', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: PolishedDropdown<int>(
              id: 'narrow-dropdown',
              value: 0,
              minimumMenuWidth: 280,
              menuMaxHeight: 360,
              showScrollbar: true,
              options: [
                for (var index = 0; index < 40; index++)
                  PolishedDropdownOption(
                    value: index,
                    label: 'Locale $index',
                  ),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('narrow-dropdown-anchor')));
    await tester.pumpAndSettle();

    final scrollbarRect = tester.getRect(
      find.byKey(const ValueKey('narrow-dropdown-scrollbar')),
    );
    expect(scrollbarRect.left, greaterThanOrEqualTo(0));
    expect(scrollbarRect.right, lessThanOrEqualTo(320));
  });

  testWidgets('catalog dropdown wraps long option labels without truncation', (
    tester,
  ) async {
    const longLabel =
        'A very long native language name with a regional variant — '
        'A very long English language name with a regional variant';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PolishedDropdown<int>(
            id: 'wrapping-dropdown',
            value: 0,
            minimumMenuWidth: 280,
            menuMaxHeight: 240,
            menuLabelMaxLines: null,
            showScrollbar: true,
            options: const [
              PolishedDropdownOption(value: 0, label: 'System'),
              PolishedDropdownOption(value: 1, label: longLabel),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('wrapping-dropdown-anchor')));
    await tester.pumpAndSettle();

    final labelFinder = find.text(longLabel);
    final label = tester.widget<Text>(labelFinder);
    expect(label.maxLines, isNull);
    expect(label.overflow, TextOverflow.visible);
    expect(tester.getSize(labelFinder).height, greaterThan(24));
    expect(tester.takeException(), isNull);
  });
}
