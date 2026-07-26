import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'services/network_permission_service.dart';
import 'services/incoming_configuration_service.dart';
import 'app.dart';

Future<void> _initializeApplication(
  AppState app,
  List<String> commandLineArguments,
) async {
  await app.preferencesReady;
  await IncomingConfigurationService.start(
    app.openConfigurationPath,
    commandLineArguments: commandLineArguments,
  );
  await WidgetsBinding.instance.endOfFrame;
  final networkAccess =
      await NetworkPermissionService.requestAllStartupPermissions(
    app.loginApiUrl,
  );
  await app.initializeStartupSession(
    preparedNetworkAccess: networkAccess,
  );
}

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  runApp(
    ChangeNotifierProvider.value(
      value: app,
      child: const MdsScopeApp(),
    ),
  );
  unawaited(_initializeApplication(app, arguments));
}
