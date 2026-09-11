import 'dart:io';

/// 删除本地残留的不完整文件（IO 平台实现）
///
/// 用于「传输取消 / 中断」后清理半成品文件，避免占用存储空间、
/// 以及避免文件管理器里出现打不开的空白文件。
void deletePartialFile(String path) {
  final file = File(path);
  if (file.existsSync()) {
    file.deleteSync();
  }
}
