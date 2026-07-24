import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'services/network_permission_service.dart';
import 'app.dart';

Future<void> _initializeApplication(AppState app) async {
  await app.preferencesReady;
  await WidgetsBinding.instance.endOfFrame;
  final networkAccess =
      await NetworkPermissionService.requestAllStartupPermissions(
    app.loginApiUrl,
  );
  await app.initializeStartupSession(
    preparedNetworkAccess: networkAccess,
  );
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  runApp(
    ChangeNotifierProvider.value(
      value: app,
      child: const MdsScopeApp(),
    ),
  );
  unawaited(_initializeApplication(app));
}
