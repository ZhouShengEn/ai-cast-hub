import 'dart:typed_data';

import 'open_file_stub.dart'
    if (dart.library.io) 'open_file_io.dart';

/// 打开本地文件（使用系统默认应用）
Future<void> openFile(String filePath) => openLocalFile(filePath);
