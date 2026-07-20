import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'theme/mdsscope_theme.dart';
import 'pages/main_page.dart';

class MdsScopeApp extends StatelessWidget {
  const MdsScopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final sysDark = MediaQuery.of(context).platformBrightness == Brightness.dark;
    final mode = switch (app.themeMode) { 0 => ThemeMode.light, 1 => ThemeMode.dark, _ => sysDark ? ThemeMode.dark : ThemeMode.light };
    return MaterialApp(
      title: 'MdsScope',
      debugShowCheckedModeBanner: false,
      theme: MdsScopeTheme.light,
      darkTheme: MdsScopeTheme.dark,
      themeMode: mode,
      home: MainPage(),
    );
  }
}
