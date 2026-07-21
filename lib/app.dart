import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    // Universal platform brightness listener (macOS fallback, Linux/Windows primary)
    WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged = _onBrightnessChanged;
    // Global Shift key tracking for Shift+drag pan
    HardwareKeyboard.instance.addHandler(_onAppKey);
  }

  bool _onAppKey(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight) {
      context.read<AppState>().shiftHeld = event is KeyDownEvent;
    }
    return false; // Don't absorb key events
  }

  void _onBrightnessChanged() {
    if (!mounted) return;
    final isDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    if (isDark != _sysDark) setState(() => _sysDark = isDark);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final mode = app.themeMode == 0
        ? ThemeMode.light
        : app.themeMode == 1
            ? ThemeMode.dark
            : ThemeMode.system;
    return MaterialApp(title: 'MdsScope', debugShowCheckedModeBanner: false,
      theme: MdsScopeTheme.light, darkTheme: MdsScopeTheme.dark, themeMode: mode, home: const MainPage());
  }
}
