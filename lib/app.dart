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

  @override void initState() { super.initState(); _sysDark = _readPlatform(); _checkSysTheme(); }
  bool _readPlatform() => WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
  void _checkSysTheme() async {
    try {
      final r = await Process.run('defaults', ['read', '-g', 'AppleInterfaceStyle']);
      final d = r.stdout.toString().trim().toLowerCase() == 'dark';
      if (!mounted) return;
      final pd = _readPlatform();
      final dark = d || pd;
      if (dark != _sysDark) setState(() => _sysDark = dark);
    } catch (_) {
      if (!mounted) return;
      final pd = _readPlatform();
      if (pd != _sysDark) setState(() => _sysDark = pd);
    }
    Future.delayed(const Duration(seconds: 1), () { if (mounted) _checkSysTheme(); });
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
