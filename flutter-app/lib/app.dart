import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/cast_screen.dart';
import 'screens/file_screen.dart';
import 'screens/settings_screen.dart';

/// MaterialApp 根组件
/// 配置 Material 3 主题和路由表
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Cast Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          elevation: 0,
        ),
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      // 路由配置
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/scan': (context) => const ScanScreen(),
        '/chat': (context) => const ChatScreen(),
        '/cast': (context) => const CastScreen(),
        '/file': (context) => const FileScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
    );
  }
}
