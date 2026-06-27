import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Android / iOS 平台的文件下载
///
/// 将文件保存到应用的文档目录，Android 同时尝试保存到共享下载目录。
Future<void> downloadFile(Uint8List bytes, String fileName) async {
  try {
    // 1. 保存到应用内部文档目录（始终可用）
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes);
    debugPrint('[File] 已保存到: ${file.path}');

    // 2. Android 尝试保存到公共下载目录
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final downloadsDir = Directory('/storage/emulated/0/Download');
        if (await downloadsDir.exists()) {
          final downloadsFile = File('${downloadsDir.path}/$fileName');
          await downloadsFile.writeAsBytes(bytes);
          debugPrint('[File] 已保存到下载目录: ${downloadsFile.path}');
        }
      } catch (e) {
        debugPrint('[File] 保存到下载目录失败（非致命）: $e');
      }
    }
  } catch (e) {
    debugPrint('[File] 下载失败: $e');
  }
}
