import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'theme/mdsscope_theme.dart';
import 'pages/main_page.dart';

class MdsScopeApp extends StatefulWidget {
  const MdsScopeApp({super.key});
  @override State<MdsScopeApp> createState() => _MdsScopeAppState();
}

class _MdsScopeAppState extends State<MdsScopeApp> {
  @override void initState() {
    super.initState();
    PlatformDispatcher.instance.onPlatformBrightnessChanged = () {
      if (mounted) setState(() {});
    };
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final sysDark = PlatformDispatcher.instance.platformBrightness == Brightness.dark;
    final mode = app.themeMode == 0 ? ThemeMode.light : app.themeMode == 1 ? ThemeMode.dark : sysDark ? ThemeMode.dark : ThemeMode.light;
    return MaterialApp(
      title: 'MdsScope', debugShowCheckedModeBanner: false,
      theme: MdsScopeTheme.light, darkTheme: MdsScopeTheme.dark, themeMode: mode,
      home: MainPage(),
    );
  }
}
