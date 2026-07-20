import 'package:flutter/material.dart';
import 'theme/mdsscope_theme.dart';
import 'pages/main_page.dart';

class MdsScopeApp extends StatelessWidget {
  const MdsScopeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MdsScope',
      debugShowCheckedModeBanner: false,
      theme: MdsScopeTheme.light,
      darkTheme: MdsScopeTheme.dark,
      themeMode: ThemeMode.system,
      home: const MainPage(),
    );
  }
}
