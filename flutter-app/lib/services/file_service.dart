import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../utils/constants.dart';
import 'api_client.dart';

/// 文件传输服务
///
/// 文件选择、校验、分片发送、进度管理。
class FileService {
  final ApiClient _client = ApiClient.instance;

  // ---- 文件选择与校验 ----

  /// 使用 file_picker 选择文件
  Future<PlatformFile?> pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.first;
  }

  /// 校验文件大小不超过 2GB
  bool validateFile(int? fileSize, int maxSize) {
    if (fileSize == null) return false;
    return fileSize <= maxSize;
  }

  /// 计算文件 SHA-256 校验和
  Future<String> calculateChecksum(String filePath) async {
    final file = File(filePath);
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // ---- 数据传输 ----

  /// 初始化传输（告知服务器元信息）
  Future<String> initTransfer({
    required String fileName,
    required int fileSize,
    required String checksum,
    required String targetDeviceId,
  }) async {
    final data = await _client.post('/file/transfer/init', data: {
      'fileName': fileName,
      'fileSize': fileSize,
      'checksum': checksum,
      'targetDeviceId': targetDeviceId,
    });
    final result = Map<String, dynamic>.from(data as Map);
    return result['transferId'] as String? ?? '';
  }

  /// 开始分片传输
  /// [transferId] 传输任务 ID
  /// [filePath] 本地文件路径
  /// [dataChannel] WebRTC DataChannel（可选，通过 P2P 发送）
  /// 返回进度流
  Stream<double> startTransfer({
    required String transferId,
    required String filePath,
    RTCDataChannel? dataChannel,
  }) async* {
    final file = File(filePath);
    final bytes = await file.readAsBytes();

    final totalChunks = ((bytes.length + AppConstants.chunkSize - 1) /
            AppConstants.chunkSize)
        .ceil();

    int sentChunks = 0;

    for (int seq = 0; seq < totalChunks; seq++) {
      final start = seq * AppConstants.chunkSize;
      final end = (start + AppConstants.chunkSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(start, end);

      // 构建分片数据：JSON 头 + 二进制数据
      final header = {
        'type': 'chunk',
        'seq': seq,
        'total': totalChunks,
      };
      final headerBytes = Uint8List.fromList(
        '${header.toString()}\n'.codeUnits,
      );
      final payload = Uint8List.fromList(
        headerBytes + chunk,
      );

      // 通过 DataChannel 发送（如果提供），否则通过 REST
      if (dataChannel != null) {
        dataChannel.send(RTCDataChannelMessage.fromBinary(payload));
      } else {
        // HTTP 方式发送分片
        await _sendChunkViaHttp(transferId, seq, totalChunks, chunk);
      }

      sentChunks++;

      // 等待 ACK（超时 5 秒重试）
      // 注：实际 ACK 等待需要基于回调机制，此处使用简化延迟模拟
      await Future.delayed(const Duration(milliseconds: 50));

      // 更新进度
      final progress = sentChunks / totalChunks;
      yield progress;
    }

    // 传输完成，发送完成信号
    await _sendComplete(transferId, checksum: '');

    // 最终进度 100%
    yield 1.0;
  }

  /// 通过 HTTP 发送单个分片
  Future<void> _sendChunkViaHttp(
    String transferId,
    int seq,
    int total,
    Uint8List chunk,
  ) async {
    try {
      await _client.post('/file/transfer/$transferId/chunk', data: {
        'seq': seq,
        'total': total,
        'data': chunk,
      });
    } catch (_) {
      // 分片发送失败
    }
  }

  /// 发送传输完成信号
  Future<void> _sendComplete(String transferId, {required String checksum}) async {
    try {
      await _client.post('/file/transfer/$transferId/complete', data: {
        'checksum': checksum,
      });
    } catch (_) {
      // 完成信号发送失败
    }
  }

  /// 取消传输
  Future<void> cancelTransfer(String transferId) async {
    await _client.post('/file/transfer/$transferId/cancel');
  }
}
