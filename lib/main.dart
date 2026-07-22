import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState();
  runApp(
    ChangeNotifierProvider.value(
      value: app,
      child: const MdsScopeApp(),
    ),
  );
  unawaited(app.initializeStartupSession());
}
