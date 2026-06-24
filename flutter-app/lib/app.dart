import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/cast_screen.dart';
import 'screens/file_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/network_tools_screen.dart';
import 'services/local_storage.dart';
import 'services/debug_service.dart';
import 'widgets/common/debug_ball.dart';

/// 背景风格枚举
enum BackgroundStyle { day, night, eyeCare }

/// 全局主题通知器，供设置页面直接切换
final ValueNotifier<BackgroundStyle> backgroundStyleNotifier =
    ValueNotifier(BackgroundStyle.day);

/// 从存储读取背景风格并初始化
BackgroundStyle _parseStyle(String s) {
  switch (s) {
    case 'night':
      return BackgroundStyle.night;
    case 'eyeCare':
      return BackgroundStyle.eyeCare;
    default:
      return BackgroundStyle.day;
  }
}

/// MaterialApp 根组件
/// 配置 Material 3 主题和路由表
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  /// 供外部设置页切换背景风格
  static void updateBackgroundStyle(BuildContext context, BackgroundStyle style) {
    backgroundStyleNotifier.value = style;
  }

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();
    final saved = LocalStorage.instance.getBackgroundStyle();
    backgroundStyleNotifier.value = _parseStyle(saved);
  }

  @override
  Widget build(BuildContext context) {
    final debugService = DebugService();

    return ValueListenableBuilder<BackgroundStyle>(
      valueListenable: backgroundStyleNotifier,
      builder: (context, style, _) {
        return MaterialApp(
          title: 'AI Cast Hub',
          debugShowCheckedModeBanner: false,
          theme: style == BackgroundStyle.eyeCare ? _eyeCareTheme : _lightTheme,
          darkTheme: _darkTheme,
          themeMode: style == BackgroundStyle.day
              ? ThemeMode.light
              : style == BackgroundStyle.night
                  ? ThemeMode.dark
                  : ThemeMode.light, // 护眼基于浅色
          initialRoute: '/',
          routes: {
            '/': (context) => const HomeScreen(),
            '/scan': (context) => const ScanScreen(),
            '/chat': (context) => const ChatScreen(),
            '/cast': (context) => const CastScreen(),
            '/file': (context) => const FileScreen(),
            '/settings': (context) => const SettingsScreen(),
            '/network-tools': (context) => const NetworkToolsScreen(),
          },
          builder: (context, child) {
            return ValueListenableBuilder<bool>(
              valueListenable: debugService.enabled,
              builder: (context, enabled, _) {
                return Stack(
                  children: [
                    child ?? const SizedBox.shrink(),
                    if (enabled) const DebugBall(),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }
}

// ============ 白天主题 ============
final ThemeData _lightTheme = ThemeData(
  colorSchemeSeed: Colors.blue,
  useMaterial3: true,
  brightness: Brightness.light,
  appBarTheme: const AppBarTheme(
    centerTitle: true,
    elevation: 0,
  ),
);

// ============ 黑夜主题 ============
final ThemeData _darkTheme = ThemeData(
  colorSchemeSeed: Colors.blue,
  useMaterial3: true,
  brightness: Brightness.dark,
);

// ============ 护眼主题 ============
final ThemeData _eyeCareTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.light,
  // 暖色系种子色，模拟纸张/护眼灯的低蓝光暖色调
  colorSchemeSeed: const Color(0xFF8D6E3F), // 暖棕色
  scaffoldBackgroundColor: const Color(0xFFF5F0E8), // 米白纸张色
  cardColor: const Color(0xFFFFFBF0), // 暖白卡片
  appBarTheme: const AppBarTheme(
    centerTitle: true,
    elevation: 0,
    backgroundColor: Color(0xFFEDE5D8),
    foregroundColor: Color(0xFF5D4037),
  ),
  bottomNavigationBarTheme: const BottomNavigationBarThemeData(
    backgroundColor: Color(0xFFEDE5D8),
    selectedItemColor: Color(0xFF8D6E3F),
    unselectedItemColor: Color(0xFFA1887F),
  ),
  floatingActionButtonTheme: const FloatingActionButtonThemeData(
    backgroundColor: Color(0xFFA1887F),
    foregroundColor: Colors.white,
  ),
  chipTheme: const ChipThemeData(
    backgroundColor: Color(0xFFEDE5D8),
    selectedColor: Color(0xFFD7CCC8),
  ),
  inputDecorationTheme: const InputDecorationTheme(
    fillColor: Color(0xFFFFFBF0),
    filled: true,
  ),
);
