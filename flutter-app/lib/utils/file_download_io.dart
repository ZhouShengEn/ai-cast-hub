import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Android / iOS 平台的文件下载
///
/// 文件统一保存到 `ai-cast-hub` 接收目录（自动创建），方便用户集中查找。
/// 目录优先级：外部存储根目录 `/ai-cast-hub`（最直观）→ 应用文档目录 `/ai-cast-hub`（兜底，无需存储权限）。
/// 同名文件自动追加 `(1)`/`(2)` 序号，避免覆盖。
Future<String?> downloadFile(Uint8List bytes, String fileName) async {
  try {
    // 规范化文件名
    final normalizedName = fileName.replaceAll('\\', '/');
    var safeName = path.basename(normalizedName).trim();
    if (safeName.isEmpty || safeName == '.' || safeName == '..') {
      safeName = 'download_${DateTime.now().millisecondsSinceEpoch}';
    }

    // 依次尝试候选接收目录，第一个可写即返回
    for (final dir in await _receiveDirCandidates()) {
      try {
        await dir.create(recursive: true);
        final file = File(_uniquePath(dir.path, safeName));
        await file.writeAsBytes(bytes);
        debugPrint('[File] 已保存到: ${file.path}');
        return file.path;
      } catch (e) {
        debugPrint('[File] 保存到 ${dir.path} 失败，尝试下一个目录: $e');
      }
    }
    return null;
  } catch (e) {
    debugPrint('[File] 下载失败: $e');
    return null;
  }
}

/// 接收目录候选列表（按优先级）。
/// 1) 外部存储根目录下的 `ai-cast-hub`（用户最直观，部分系统受作用域存储限制可能不可写）
/// 2) 应用文档目录下的 `ai-cast-hub`（兜底，应用专属、无需运行时权限）
Future<List<Directory>> _receiveDirCandidates() async {
  final List<Directory> candidates = [];
  // ignore: deprecated_member_use
  final extDir = await getExternalStorageDirectory();
  if (extDir != null) {
    candidates.add(Directory(path.join(extDir.path, 'ai-cast-hub')));
  }
  try {
    final docsDir = await getApplicationDocumentsDirectory();
    candidates.add(Directory(path.join(docsDir.path, 'ai-cast-hub')));
  } catch (_) {
    // 兜底目录不可用时忽略
  }
  return candidates;
}

/// 若目标文件名已存在，追加 `(n)` 序号生成不冲突路径。
String _uniquePath(String dir, String name) {
  final base = path.join(dir, name);
  if (!File(base).existsSync()) return base;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  var i = 1;
  late String candidate;
  do {
    candidate = path.join(dir, '$stem($i)${ext}');
    i++;
  } while (File(candidate).existsSync());
  return candidate;
}
