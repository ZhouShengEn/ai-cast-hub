import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Android / iOS 平台的文件下载
///
/// 文件保存到应用私有文档目录，不需要 Android 存储运行时权限。
/// Android 第三方应用通过 FileProvider 的临时只读授权访问文件。
Future<String?> downloadFile(Uint8List bytes, String fileName) async {
  try {
    final dir = await getApplicationSupportDirectory();
    final receivedDir = Directory(path.join(dir.path, 'received_files'));
    await receivedDir.create(recursive: true);

    final normalizedName = fileName.replaceAll('\\', '/');
    var safeName = path.basename(normalizedName).trim();
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      safeName = 'download_${DateTime.now().millisecondsSinceEpoch}';
    }

    final file = File(path.join(receivedDir.path, safeName));
    await file.writeAsBytes(bytes);
    debugPrint('[File] 已保存到: ${file.path}');
    return file.path;
  } catch (e) {
    debugPrint('[File] 下载失败: $e');
    return null;
  }
}
