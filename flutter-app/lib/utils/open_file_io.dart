import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const MethodChannel _fileChannel = MethodChannel('ai_cast_hub/file');

/// Android 使用 FileProvider 打开文件，其他原生平台保留 file URI。
Future<bool> openLocalFile(String filePath, {String? mimeType}) async {
  try {
    if (Platform.isAndroid) {
      final opened = await _fileChannel.invokeMethod<bool>(
        'openFile',
        <String, dynamic>{
          'path': filePath,
          'mimeType': mimeType,
        },
      );
      debugPrint('[File] Android 打开结果: ${opened ?? false}, path=$filePath');
      return opened ?? false;
    }

    final uri = Uri.file(filePath);
    if (await canLaunchUrl(uri)) {
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      debugPrint('[File] 打开结果: $opened, path=$filePath');
      return opened;
    }
    debugPrint('[File] 无法打开文件: $filePath');
  } on PlatformException catch (e) {
    debugPrint('[File] Android 打开文件失败 [${e.code}]: ${e.message}');
  } catch (e) {
    debugPrint('[File] 打开文件失败: $e');
  }
  return false;
}
