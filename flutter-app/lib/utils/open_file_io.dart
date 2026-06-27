import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// Android / iOS 平台的文件打开（使用 url_launcher 调用系统默认应用）
Future<void> openLocalFile(String filePath) async {
  try {
    final uri = Uri.file(filePath);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      debugPrint('[File] 已打开: $filePath');
    } else {
      debugPrint('[File] 无法打开文件: $filePath');
    }
  } catch (e) {
    debugPrint('[File] 打开文件失败: $e');
  }
}
