import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Web 平台的浏览器文件下载
/// 返回 null（浏览器下载不产生文件系统路径）
Future<String?> downloadFile(Uint8List bytes, String fileName) async {
  try {
    final blob = html.Blob([bytes]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.AnchorElement(href: url)
      ..setAttribute('download', fileName)
      ..click();
    html.Url.revokeObjectUrl(url);
    debugPrint('[File] 已下载: $fileName');
  } catch (e) {
    debugPrint('[File] 下载失败: $e');
  }
  return null;
}
