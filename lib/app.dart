import 'dart:io';
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
  bool _sysDark = false;

  @override void initState() { super.initState(); _sysDark = _readPlatform(); WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _checkSysTheme(); }); }
  bool _readPlatform() => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  void _checkSysTheme() async {
    try {
      final r = Process.runSync('defaults', ['read', '-g', 'AppleInterfaceStyle']);
      final out = r.stdout.toString().trim();
      final dark = out.toLowerCase() == 'dark';
      if (!mounted) return;
      if (dark != _sysDark) setState(() => _sysDark = dark);
    } catch (_) {
    }
    Future.delayed(const Duration(seconds: 2), () { if (mounted) _checkSysTheme(); });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final isAuto = app.themeMode != 0 && app.themeMode != 1;
    final mode = app.themeMode == 0 ? ThemeMode.light : app.themeMode == 1 ? ThemeMode.dark : _sysDark ? ThemeMode.dark : ThemeMode.light;
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
