import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'services/stylus_mode_channel.dart';
import 'services/theme_channel.dart';
import 'theme/mdslens_theme.dart';
import 'pages/main_page.dart';
import 'widgets/network_permission_gate.dart';

class MDSLensApp extends StatefulWidget {
  const MDSLensApp({super.key});
  @override
  State<MDSLensApp> createState() => _MDSLensAppState();
}

class _MDSLensAppState extends State<MDSLensApp> with WidgetsBindingObserver {
  bool _sysDark = false;
  int _themeEventRevision = 0;
  Timer? _themeCalibrationTimer;
  StreamSubscription<bool>? _themeSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sysDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    ThemeChannel.init();
    StylusModeChannel.init(
      (eraser) => context.read<AppState>().setStylusEraserMode(eraser),
    );
    // platformBrightness is authoritative during startup. A native method
    // query can complete before the host appearance has settled and overwrite
    // the correct initial value with a stale light-mode result.
    _themeSubscription = ThemeChannel.onThemeChanged.listen((d) {
      _themeEventRevision++;
      if (mounted && d != _sysDark) setState(() => _sysDark = d);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleThemeCalibration();
    });
    // Global Shift key tracking for Shift+drag pan
    HardwareKeyboard.instance.addHandler(_onAppKey);
  }

  void _scheduleThemeCalibration() {
    final revision = _themeEventRevision;
    _themeCalibrationTimer?.cancel();
    _themeCalibrationTimer = Timer(const Duration(milliseconds: 80), () async {
      final earlyNativeDark = await ThemeChannel.isDark();
      if (!mounted || revision != _themeEventRevision) return;

      // A dark result is safe to apply early and fixes platforms that briefly
      // report light through platformBrightness during startup. A light result
      // waits for the host appearance to settle so it cannot overwrite a
      // correct dark dispatcher value with a transient native value.
      if (earlyNativeDark == true && !_sysDark) {
        setState(() => _sysDark = true);
      }

      _themeCalibrationTimer = Timer(
        const Duration(milliseconds: 180),
        () async {
          final settledNativeDark = await ThemeChannel.isDark();
          if (!mounted || revision != _themeEventRevision) return;
          if (settledNativeDark != null && settledNativeDark != _sysDark) {
            setState(() => _sysDark = settledNativeDark);
          }
        },
      );
    });
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
    _themeEventRevision++;
    final isDark =
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
        Brightness.dark;
    if (isDark != _sysDark) setState(() => _sysDark = isDark);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleThemeCalibration();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onAppKey);
    _themeCalibrationTimer?.cancel();
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
      title: 'MDSLens',
      debugShowCheckedModeBanner: false,
      theme: MDSLensTheme.light(
        fontFamily: app.effectiveFontFamily,
        uiFontSize: app.fontUiSize.toDouble(),
      ),
      darkTheme: MDSLensTheme.dark(
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
