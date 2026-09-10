import 'package:flutter/material.dart';

/// 全局 Navigator Key
///
/// 独立成文件以避免循环依赖：
/// app.dart → 页面 → provider → app.dart。
///
/// 供防盗服务在响铃被远程触发时弹出「设备防盗」页，
/// 保证该行为对设备持有者立即可见、可停止。
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();
