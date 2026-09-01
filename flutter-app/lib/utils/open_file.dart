import 'open_file_stub.dart' if (dart.library.io) 'open_file_io.dart';

/// 使用系统应用打开本地文件。
///
/// Android 由原生 FileProvider 生成 content:// URI；[mimeType] 为空时由
/// 原生侧根据扩展名自动识别。
Future<bool> openFile(String filePath, {String? mimeType}) =>
    openLocalFile(filePath, mimeType: mimeType);
