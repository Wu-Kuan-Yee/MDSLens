import 'package:flutter/material.dart';
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

    final scrollbar = tester.widget<Scrollbar>(
      find.byKey(const ValueKey('long-dropdown-scrollbar')),
    );
    expect(scrollbar.interactive, isTrue);
    expect(scrollbar.thumbVisibility, isTrue);
    // Only visible entries need to be built initially; the scrollbar provides
    // access to the remaining locale records.
    expect(
      find.byKey(const ValueKey('long-dropdown-option-0')),
      findsOneWidget,
    );
  });
}
