import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'services/network_permission_service.dart';
import 'services/incoming_configuration_service.dart';
import 'services/update_installer.dart';
import 'services/update_health.dart';
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
    // Report update health before network permission prompts or automatic
    // login.  Those are external conditions and must not make a successfully
    // launched replacement wait for the network before it can be committed.
    await acknowledgeUpdateHealth(commandLineArguments);
    await acknowledgeUpdateCommit(commandLineArguments);
    final networkAccess =
        await NetworkPermissionService.requestAllStartupPermissions(
      app.loginApiUrl,
    );
    await app.initializeStartupSession(preparedNetworkAccess: networkAccess);
  } finally {
    app.markStartupInitializationComplete();
    unawaited(scheduleNativeRollbackCleanup());
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
