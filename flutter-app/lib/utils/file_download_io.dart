import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 文件接收目录名（在文件管理「我的手机」中可见）
const String _receiveFolderName = 'ai-cast-hub';

/// 与原生约定的文件通道（获取内部存储根目录）
const MethodChannel _fileChannel = MethodChannel('ai_cast_hub/file');

/// 接收完成后暂存用的私有沙盒子目录名（文件管理器不可见，卸载即删）
const String _tempFolderName = 'ai-cast-hub-tmp';

/// 接收完成后先写入 App 私有沙盒（临时文件）。
///
/// 这样即使文件很大也不会在用户未确认前就占用公共空间；
/// 用户点【保存】后再由 [copyToPublicDir] 复制到 ai-cast-hub 公共目录。
Future<String?> saveToTempSandbox(Uint8List bytes, String fileName) async {
  try {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(path.join(docs.path, _tempFolderName));
    await dir.create(recursive: true);
    final file = File(_uniquePath(dir.path, _safeName(fileName)));
    await file.writeAsBytes(bytes);
    debugPrint('[File] 已写入私有沙盒: ${file.path}');
    return file.path;
  } catch (e) {
    debugPrint('[File] 写入私有沙盒失败: $e');
    return null;
  }
}

/// 把私有沙盒中的临时文件复制到 ai-cast-hub 公共目录。
///
/// 公共目录优先取内部存储根目录（需 MANAGE_EXTERNAL_STORAGE），
/// 失败则回退应用专属外部存储目录。复制成功后文件管理器与其他 App 均可访问，
/// 且卸载 App 不会删除它。
///
/// 注意：复制完成后沙盒内仍保留一份副本（可按需清理），因此会存在双倍占用。
Future<String?> copyToPublicDir(String tempPath, String fileName) async {
  try {
    final src = File(tempPath);
    if (!await src.exists()) {
      debugPrint('[File] 临时文件不存在: $tempPath');
      return null;
    }
    final dir = await _preferredReceiveDir();
    if (dir == null) return null;
    await dir.create(recursive: true);
    final dst = File(_uniquePath(dir.path, _safeName(fileName)));
    await dst.writeAsBytes(await src.readAsBytes());
    debugPrint('[File] 已保存到公共目录: ${dst.path}');
    return dst.path;
  } catch (e) {
    debugPrint('[File] 复制到公共目录失败: $e');
    return null;
  }
}

/// 规范化文件名，避免路径穿越与非法名
String _safeName(String fileName) {
  final normalized = fileName.replaceAll('\\', '/');
  var name = path.basename(normalized).trim();
  if (name.isEmpty || name == '.' || name == '..') {
    name = 'download_${DateTime.now().millisecondsSinceEpoch}';
  }
  return name;
}

/// 首启时确保接收目录已创建。
///
/// 优先级：已授予「所有文件访问」权限 → 内部存储根目录 `/ai-cast-hub`（文件管理器可见）；
/// 否则回退应用专属外部存储目录（保证目录一定存在，但位于 Android/data 下，部分系统不可直接浏览）。
Future<Directory?> ensureReceiveDir() async {
  try {
    final dir = await _preferredReceiveDir();
    if (dir != null) {
      await dir.create(recursive: true);
      debugPrint('[File] 接收目录已就绪: ${dir.path}');
    }
    return dir;
  } catch (e) {
    debugPrint('[File] 创建接收目录失败: $e');
    return null;
  }
}

/// 选择优先接收目录：授予 MANAGE_EXTERNAL_STORAGE 时用内部存储根目录，否则用应用专属目录。
Future<Directory?> _preferredReceiveDir() async {
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      if (await Permission.manageExternalStorage.isGranted) {
        final root = await _externalStorageRoot();
        if (root != null && root.isNotEmpty) {
          return Directory(path.join(root, _receiveFolderName));
        }
      }
    } catch (_) {
      // 权限查询异常时忽略，走兜底
    }
  }
  final candidates = await _receiveDirCandidates();
  return candidates.isNotEmpty ? candidates.first : null;
}

/// 通过原生通道获取内部存储根目录（如 /storage/emulated/0）
Future<String?> _externalStorageRoot() async {
  try {
    return await _fileChannel.invokeMethod<String>('getExternalStorageRoot');
  } on PlatformException catch (_) {
    return null;
  }
}

/// Android / iOS 平台的文件下载
///
/// 文件统一保存到 `ai-cast-hub` 接收目录（自动创建），方便用户集中查找。
/// 目录优先级：内部存储根目录 `/ai-cast-hub`（最直观，需所有文件访问权限）→ 应用文档目录 `/ai-cast-hub`（兜底）。
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
/// 1) 内部存储根目录下的 `ai-cast-hub`（用户最直观，需所有文件访问权限）
/// 2) 应用文档目录下的 `ai-cast-hub`（兜底，应用专属、无需运行时权限）
Future<List<Directory>> _receiveDirCandidates() async {
  final List<Directory> candidates = [];

  // 已授予所有文件访问权限时，优先放到内部存储根目录（文件管理器可见）
  if (defaultTargetPlatform == TargetPlatform.android) {
    try {
      if (await Permission.manageExternalStorage.isGranted) {
        final root = await _externalStorageRoot();
        if (root != null && root.isNotEmpty) {
          candidates.add(Directory(path.join(root, _receiveFolderName)));
        }
      }
    } catch (_) {
      // 忽略，走下方兜底
    }
  }

  // 应用专属外部存储目录（作用域存储下为 Android/data/<pkg>/files/ai-cast-hub）
  // ignore: deprecated_member_use
  final extDir = await getExternalStorageDirectory();
  if (extDir != null) {
    candidates.add(Directory(path.join(extDir.path, _receiveFolderName)));
  }
  try {
    final docsDir = await getApplicationDocumentsDirectory();
    candidates.add(Directory(path.join(docsDir.path, _receiveFolderName)));
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
