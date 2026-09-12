import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers/anti_theft_provider.dart';
import 'screens/home_screen.dart';
import 'screens/scan_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/cast_screen.dart';
import 'screens/message_screen.dart';
import 'screens/file_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/network_tools_screen.dart';
import 'screens/anti_theft_screen.dart';
import 'services/local_storage.dart';
import 'services/debug_service.dart';
import 'services/anti_theft_service.dart';
import 'services/message_service.dart';
import 'services/websocket_service.dart';
import 'utils/navigator_key.dart';
import 'widgets/common/debug_ball.dart';

/// 全局路由观察者
///
/// 供需要感知「页面是否被覆盖 / 是否返回」的页面（如消息页）订阅，
/// 用于精确维护 isViewing 状态，避免依赖 dispose 带来的状态残留。
final RouteObserver<ModalRoute<void>> routeObserver = RouteObserver<ModalRoute<void>>();

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
    // 启动即建立并保持 WebSocket 长连接。
    // 关键修复：此前 WS 仅在消息/投屏/文件屏才 connect，导致手机回到首页或
    // 后台待机时连接断开，服务端转发防盗指令（响铃/定位）因找不到在线连接而
    // 被「离线丢弃」，表现为 Web 端下发指令后手机毫无反应。
    // 现在 App 启动即常驻连接，配合 BackgroundConnectionService 的 WakeLock，
    // 即使 App 在后台也能收到并响应远程指令。connect() 自带去重，与各业务屏
    // 的 connect() 调用不冲突。
    _ensureWsConnected();
  }

  /// 启动级 WebSocket 连接（设备已注册才连，未注册则等配对流程触发）
  void _ensureWsConnected() {
    final uuid = LocalStorage.instance.getDeviceUuid();
    final key = LocalStorage.instance.getTransferKey();
    if (uuid == null || uuid.isEmpty || key == null || key.isEmpty) {
      DebugService().info('[App] 设备尚未注册，暂缓启动 WS 连接');
      return;
    }
    WebSocketService.instance.connect().then((_) {
      // WS 建连后启动消息通道后台监听（P1-5）。
      // 消息通道必须与 UI 解耦：Web 端点击「主动连接消息」时，
      // App 即使停在首页 / 后台也能收到 room_invitation 并建立 DataChannel。
      unawaited(_startMessageChannel());
      // 启动防盗指令后台监听（P2-3）：响铃 / 定位指令必须与 UI 解耦，
      // 即使 App 停在首页 / 后台 / 锁屏，也能通过 WS（由 BackgroundConnectionService
      // 持 WakeLock 保活）收到并响应 PC 下发的远程指令。
      unawaited(AntiTheftService().startListening());
    }).catchError((e) {
      DebugService().warn('[App] 启动 WS 连接失败（将自动重连）: $e');
    });
  }

  /// 启动常驻消息通道监听
  Future<void> _startMessageChannel() async {
    try {
      await MessageService().startListening();
      DebugService().info('[App] 消息通道后台监听已启动');
    } catch (e) {
      DebugService().warn('[App] 消息通道启动失败: $e');
    }
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
          navigatorKey: navigatorKey,
          navigatorObservers: [routeObserver],
          routes: {
            '/': (context) => const HomeScreen(),
            '/scan': (context) => const ScanScreen(),
            '/chat': (context) => const ChatScreen(),
            '/cast': (context) => const CastScreen(),
            '/message': (context) => const MessageScreen(),
            '/file': (context) => const FileScreen(),
            '/settings': (context) => const SettingsScreen(),
            '/network-tools': (context) => const NetworkToolsScreen(),
            '/anti-theft': (context) => const AntiTheftScreen(),
          },
          builder: (context, child) {
            // 丢失模式：全屏锁定提示（App 级，用户始终知情并可自行解除）
            return Consumer(
              builder: (context, ref, _) {
                final lostMode = ref.watch(antiTheftProvider).lostMode;
                return Stack(
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: debugService.enabled,
                      builder: (context, enabled, _) {
                        return Stack(
                          children: [
                            child ?? const SizedBox.shrink(),
                            if (enabled) const DebugBall(),
                          ],
                        );
                      },
                    ),
                    if (lostMode) const LostModeOverlay(),
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
