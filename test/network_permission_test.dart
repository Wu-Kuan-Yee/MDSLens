import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdsscope/models/app_state.dart';
import 'package:mdsscope/services/network_permission_service.dart';
import 'package:mdsscope/widgets/network_permission_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Only permission-shaped network failures request permission recovery',
      () {
    expect(
      NetworkPermissionService.isLikelyPermissionFailure(
        'SocketException: Operation not permitted (OS Error: 1)',
      ),
      isTrue,
    );
    expect(
      NetworkPermissionService.isLikelyPermissionFailure(
        'NWPath.UnsatisfiedReason.localNetworkDenied',
      ),
      isTrue,
    );
    expect(
      NetworkPermissionService.isLikelyPermissionFailure(
        'Connection refused by 10.0.0.8:8000',
      ),
      isFalse,
    );
    expect(
      NetworkPermissionService.isLikelyPermissionFailure(
        'Authentication failed',
      ),
      isFalse,
    );
  });

  testWidgets('A denied operation offers recovery again on the next attempt',
      (tester) async {
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);
    var retryCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: NetworkPermissionGate(
          app: app,
          enabled: true,
          child: const Scaffold(body: Text('MdsScope')),
        ),
      ),
    );

    app.reportNetworkPermissionFailure(
      'Operation not permitted',
      retry: () async {
        retryCount++;
      },
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('network-permission-dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey('network-permission-cancel')),
    );
    await tester.pumpAndSettle();

    app.reportNetworkPermissionFailure(
      'Operation not permitted',
      retry: () async {
        retryCount++;
      },
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('network-permission-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('network-permission-retry')));
    await tester.pumpAndSettle();
    expect(retryCount, 1);
  });

  test('System settings channel is callable', () async {
    const channel = MethodChannel('mdsscope/permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(channel, null),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'openAppSettings');
      return true;
    });

    expect(await NetworkPermissionService.openAppSettings(), isTrue);
  });
}
