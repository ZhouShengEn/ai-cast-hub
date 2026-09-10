import 'dart:typed_data';

/// 非主流平台的文件下载存根（无操作）
Future<String?> downloadFile(Uint8List bytes, String fileName) async => null;

/// 非主流平台的暂存存根（无操作）
///
/// 必须与 file_download_io / file_download_web 保持同名同签名，
/// 否则条件导出在分析期解析到本存根时会报 undefined_method。
Future<String?> saveToTempSandbox(Uint8List bytes, String fileName) async => null;

/// 非主流平台的公共目录复制存根（无操作）
Future<String?> copyToPublicDir(String tempPath, String fileName) async => null;
