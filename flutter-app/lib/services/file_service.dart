import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../utils/constants.dart';
import 'api_client.dart';

/// 文件传输服务
///
/// 文件选择、校验、分片发送、进度管理。
/// 所有平台统一使用 file_picker 的 bytes 属性读取文件数据。
class FileService {
  final ApiClient _client = ApiClient.instance;

  // ---- 文件选择与校验 ----

  /// 使用 file_picker 选择文件（加载 bytes 到内存）
  Future<PlatformFile?> pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    return result.files.first;
  }

  /// 校验文件大小不超过限制
  bool validateFile(int? fileSize, int maxSize) {
    if (fileSize == null) return false;
    return fileSize <= maxSize;
  }

  /// 计算文件 SHA-256 校验和（从 bytes）
  Future<String> calculateChecksum(Uint8List bytes) async {
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
    // 服务端返回整数 ID，转为字符串使用
    final tid = result['transferId'];
    return tid?.toString() ?? '';
  }

  /// 开始分片传输
  /// [transferId] 传输任务 ID
  /// [bytes] 文件二进制数据
  /// [checksum] 文件 SHA-256 校验和
  /// [dataChannel] WebRTC DataChannel（可选，通过 P2P 发送）
  /// 返回进度流
  Stream<double> startTransfer({
    required String transferId,
    required Uint8List bytes,
    required String checksum,
    webrtc.RTCDataChannel? dataChannel,
  }) async* {
    final totalChunks =
        ((bytes.length + AppConstants.chunkSize - 1) / AppConstants.chunkSize)
            .ceil();

    int sentChunks = 0;

    for (int seq = 0; seq < totalChunks; seq++) {
      final start = seq * AppConstants.chunkSize;
      final end = (start + AppConstants.chunkSize).clamp(0, bytes.length);
      final chunk = bytes.sublist(start, end);

      // 通过 DataChannel 发送（如果提供），否则通过 REST
      if (dataChannel != null) {
        final header = {
          'type': 'chunk',
          'seq': seq,
          'total': totalChunks,
        };
        final headerBytes = Uint8List.fromList('${header}\n'.codeUnits);
        final payload = Uint8List.fromList(headerBytes + chunk);
        dataChannel.send(webrtc.RTCDataChannelMessage.fromBinary(payload));
      } else {
        await _sendChunkViaHttp(transferId, seq, totalChunks, chunk);
      }

      sentChunks++;

      // 更新进度
      final progress = sentChunks / totalChunks;
      yield progress;
    }

    // 传输完成
    await _sendComplete(transferId, checksum: checksum);
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
    } catch (e) {
      throw Exception('分片 $seq 发送失败: $e');
    }
  }

  /// 发送传输完成信号
  Future<void> _sendComplete(String transferId, {required String checksum}) async {
    try {
      await _client.post('/file/transfer/$transferId/complete', data: {
        'checksum': checksum,
      });
    } catch (e) {
      throw Exception('传输完成确认失败: $e');
    }
  }

  /// 取消传输
  Future<void> cancelTransfer(String transferId) async {
    await _client.post('/file/transfer/$transferId/cancel');
  }
}
