import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mdsscope/models/app_state.dart';
import 'package:mdsscope/services/network_permission_service.dart';
import 'package:mdsscope/widgets/network_permission_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mdsscope/services/user_data_store.dart';

void main() {
  setUp(() {
    UserDataStore.disableFileStorageForTests = true;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

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

  testWidgets('Startup requests the native system permission without a panel',
      (tester) async {
    const channel = MethodChannel('mdsscope/permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var requestCount = 0;
    addTearDown(
      () => messenger.setMockMethodCallHandler(channel, null),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'requestLocalNetworkAccess') requestCount++;
      return true;
    });
    final app = AppState();
    await app.preferencesReady;
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NetworkPermissionGate(
          app: app,
          enabled: true,
          requestOnStartup: true,
          child: const Scaffold(body: Text('MdsScope')),
        ),
      ),
    );
    await tester.pump();

    expect(requestCount, 1);
    expect(
      find.byKey(const ValueKey('network-permission-dialog')),
      findsNothing,
    );
  });

  test('First-launch Apple permission requests are issued sequentially',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('mdsscope/permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    addTearDown(
      () => messenger.setMockMethodCallHandler(channel, null),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'prepareNetworkAccess') return 'ready';
      if (call.method == 'requestLocalNetworkAccess') return true;
      return null;
    });

    final result = await NetworkPermissionService.requestAllStartupPermissions(
      'http://east.example/api',
    );

    expect(result, NetworkAccessPreparation.ready);
    expect(calls, [
      'prepareNetworkAccess',
      'requestLocalNetworkAccess',
    ]);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'First cellular denial stays with the system prompt and a later attempt offers settings',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('mdsscope/permissions');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var preparationCount = 0;
    var loginCount = 0;
    addTearDown(
      () => messenger.setMockMethodCallHandler(channel, null),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'prepareNetworkAccess') {
        preparationCount++;
        return preparationCount == 1
            ? 'deniedDuringRequest'
            : 'deniedPreviously';
      }
      return true;
    });
    final app = AppState(
      loginWorker: (_, __, ___, ____) async {
        loginCount++;
        return (token: 'unexpected', usedSsh: false);
      },
    );
    await app.preferencesReady;
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: NetworkPermissionGate(
          app: app,
          enabled: true,
          requestOnStartup: false,
          child: const Scaffold(body: Text('MdsScope')),
        ),
      ),
    );

    await expectLater(
      app.loginAndLoadLatest(
        apiUrl: 'http://east.example/api',
        user: 'user',
        password: 'password',
      ),
      throwsA(anything),
    );
    await tester.pumpAndSettle();
    expect(loginCount, 0);
    expect(
      find.byKey(const ValueKey('network-permission-dialog')),
      findsNothing,
    );

    await expectLater(
      app.loginAndLoadLatest(
        apiUrl: 'http://east.example/api',
        user: 'user',
        password: 'password',
      ),
      throwsA(anything),
    );
    await tester.pumpAndSettle();
    expect(loginCount, 0);
    expect(
      find.byKey(const ValueKey('network-permission-dialog')),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
