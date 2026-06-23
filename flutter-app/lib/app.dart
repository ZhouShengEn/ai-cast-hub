import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/cast_screen.dart';
import 'screens/file_screen.dart';
import 'screens/settings_screen.dart';
import 'services/local_storage.dart';
import 'services/debug_service.dart';
import 'widgets/common/debug_ball.dart';

/// MaterialApp 根组件
/// 配置 Material 3 主题和路由表
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final storage = LocalStorage.instance;
    final debugService = DebugService();

    // 初始化调试服务状态
    debugService.enabled.value = storage.getDebugBallEnabled();

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
      initialRoute: '/',
      routes: {
        '/': (context) => const HomeScreen(),
        '/scan': (context) => const ScanScreen(),
        '/chat': (context) => const ChatScreen(),
        '/cast': (context) => const CastScreen(),
        '/file': (context) => const FileScreen(),
        '/settings': (context) => const SettingsScreen(),
      },
      // 使用 builder 在所有页面之上叠加 DebugBall（响应式）
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
  }
}
