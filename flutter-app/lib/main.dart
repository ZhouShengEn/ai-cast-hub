import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app.dart';
import 'services/local_storage.dart';
import 'utils/file_download_io.dart';

/// 应用入口
/// 在 runApp 之前初始化必要的服务（SharedPreferences 等）
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化本地存储（SharedPreferences + sqflite）
  await LocalStorage.instance.init();

  // 首启创建文件接收目录（申请「所有文件访问」权限后落在「我的手机」根目录，
  // 用户无需先传文件即可在文件管理器中看到 ai-cast-hub 文件夹）
  unawaited(_prepareReceiveDir());

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

/// 在内部存储根目录创建可见的 ai-cast-hub 接收文件夹。
///
/// Android 11+ 作用域存储下，只有授予 MANAGE_EXTERNAL_STORAGE 才能写到根目录；
/// 因此首启时引导用户授权，授权后 ensureReceiveDir 会把目录建在 /storage/emulated/0/ai-cast-hub。
/// 已永久拒绝或授权失败则回退到应用专属目录（目录仍存在，只是路径在 Android/data 下）。
Future<void> _prepareReceiveDir() async {
  try {
    if (defaultTargetPlatform == TargetPlatform.android) {
      final status = await Permission.manageExternalStorage.status;
      if (!status.isGranted && !status.isPermanentlyDenied) {
        // 仅弹一次系统授权页（Android 11+ 会跳转到设置页，用户手动开启）
        await Permission.manageExternalStorage.request();
      }
    }
    await ensureReceiveDir();
  } catch (e) {
    debugPrint('[Main] 准备接收目录失败: $e');
  }
}

