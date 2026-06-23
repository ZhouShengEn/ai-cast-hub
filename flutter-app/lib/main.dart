import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'services/local_storage.dart';

/// 应用入口
/// 在 runApp 之前初始化必要的服务（SharedPreferences 等）
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地存储（SharedPreferences + sqflite）
  await LocalStorage.instance.init();

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}
