import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'services/stylus_mode_channel.dart';
import 'services/theme_channel.dart';
import 'theme/mdsscope_theme.dart';
import 'pages/main_page.dart';
import 'widgets/network_permission_gate.dart';

class MdsScopeApp extends StatefulWidget {
  const MdsScopeApp({super.key});
  @override
  State<MdsScopeApp> createState() => _MdsScopeAppState();
}

class _MdsScopeAppState extends State<MdsScopeApp> with WidgetsBindingObserver {
  bool _sysDark = false;
  StreamSubscription<bool>? _themeSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sysDark = WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    ThemeChannel.init();
    StylusModeChannel.init(
      (eraser) => context.read<AppState>().setStylusEraserMode(eraser),
    );
    ThemeChannel.isDark().then((d) {
      if (mounted && d != null) setState(() => _sysDark = d);
    });
    _themeSubscription = ThemeChannel.onThemeChanged.listen((d) {
      if (mounted) setState(() => _sysDark = d);
    });
    // Global Shift key tracking for Shift+drag pan
    HardwareKeyboard.instance.addHandler(_onAppKey);
  }

  bool _onAppKey(KeyEvent event) {
    final app = context.read<AppState>();
    if (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
        event.logicalKey == LogicalKeyboardKey.shiftRight) {
      app.shiftHeld = event is KeyDownEvent;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      return app.handleEscapeKey();
    }
    return false; // Don't absorb key events
  }

  @override
  void didChangePlatformBrightness() {
    if (!mounted) return;
    final isDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark;
    if (isDark != _sysDark) setState(() => _sysDark = isDark);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onAppKey);
    _themeSubscription?.cancel();
    StylusModeChannel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final isDark = app.themeMode == 0
        ? false
        : app.themeMode == 1
            ? true
            : _sysDark;
    return MaterialApp(
      title: 'MdsScope',
      debugShowCheckedModeBanner: false,
      theme: MdsScopeTheme.light(
        fontFamily: app.effectiveFontFamily,
        uiFontSize: app.fontUiSize.toDouble(),
      ),
      darkTheme: MdsScopeTheme.dark(
        fontFamily: app.effectiveFontFamily,
        uiFontSize: app.fontUiSize.toDouble(),
      ),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      home: NetworkPermissionGate(
        app: app,
        requestOnStartup: false,
        child: const MainPage(),
      ),
    );
  }
}
