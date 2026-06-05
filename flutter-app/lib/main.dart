import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';

/// 应用入口
/// 在 runApp 之前初始化必要的服务（SharedPreferences 等）
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 预初始化 SharedPreferences（后续通过 Riverpod 访问）
  await SharedPreferences.getInstance();

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}
