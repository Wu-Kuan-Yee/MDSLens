import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'services/network_permission_service.dart';
import 'services/incoming_configuration_service.dart';
import 'services/update_installer.dart';
import 'app.dart';

Future<void> _initializeApplication(
  AppState app,
  List<String> commandLineArguments,
) async {
  await app.preferencesReady;
  try {
    await IncomingConfigurationService.start(
      app.openConfigurationPath,
      commandLineArguments: commandLineArguments,
    );
    await WidgetsBinding.instance.endOfFrame;
    final networkAccess =
        await NetworkPermissionService.requestAllStartupPermissions(
      app.loginApiUrl,
    );
    await app.initializeStartupSession(preparedNetworkAccess: networkAccess);
  } finally {
    app.markStartupInitializationComplete();
    unawaited(scheduleLinuxPortableRollbackCleanup());
  }
}

void main(List<String> arguments) {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  // The provider owns AppState so application teardown always cancels native
  // reads and SSH relays, including when a window is closed while Loading.
  runApp(
    ChangeNotifierProvider(
      create: (_) => app,
      child: const MDSLensApp(),
    ),
  );
  unawaited(_initializeApplication(app, arguments));
}
