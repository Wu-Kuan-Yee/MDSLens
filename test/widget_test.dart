import 'package:flutter_test/flutter_test.dart';
import 'package:mdsscope/app.dart';

void main() {
  testWidgets('App renders smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const MdsScopeApp());
    expect(find.byType(MdsScopeApp), findsOneWidget);
  });
}
