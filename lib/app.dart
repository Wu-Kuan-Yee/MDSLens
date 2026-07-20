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

  @override void initState() { super.initState(); _checkSysTheme(); }
  void _checkSysTheme() async {
    try {
      final r = await Process.run('defaults', ['read', '-g', 'AppleInterfaceStyle']);
      final dark = r.stdout.toString().trim().toLowerCase() == 'dark';
      if (dark != _sysDark && mounted) setState(() => _sysDark = dark);
    } catch (_) {}
    Future.delayed(const Duration(seconds: 2), () { if (mounted) _checkSysTheme(); });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final mode = switch (app.themeMode) { 0 => ThemeMode.light, 1 => ThemeMode.dark, _ => _sysDark ? ThemeMode.dark : ThemeMode.light };
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
