import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'services/theme_channel.dart';
import 'theme/mdsscope_theme.dart';
import 'pages/main_page.dart';

class MdsScopeApp extends StatefulWidget {
  const MdsScopeApp({super.key});
  @override State<MdsScopeApp> createState() => _MdsScopeAppState();
}

class _MdsScopeAppState extends State<MdsScopeApp> {
  bool _sysDark = false;

  @override void initState() {
    super.initState();
    _sysDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    ThemeChannel.init();
    ThemeChannel.isDark().then((d) { if (mounted) setState(() => _sysDark = d); });
    ThemeChannel.onThemeChanged.listen((d) { if (mounted) setState(() => _sysDark = d); });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final mode = app.themeMode == 0 ? ThemeMode.light : app.themeMode == 1 ? ThemeMode.dark : _sysDark ? ThemeMode.dark : ThemeMode.light;
    return MaterialApp(title: 'MdsScope', debugShowCheckedModeBanner: false,
      theme: MdsScopeTheme.light, darkTheme: MdsScopeTheme.dark, themeMode: mode, home: MainPage());
  }
}
