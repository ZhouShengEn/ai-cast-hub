import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// 设置 H.264 视频编码偏好（仅 Android/iOS 等原生平台可用）
///
/// Android 硬件编码 H.264 比 VP8/VP9 功耗更低、帧率更稳定。
Future<void> setH264CodecPreferences(webrtc.RTCPeerConnection? pc) async {
  if (pc == null) return;
  try {
    final transceivers = await pc.getTransceivers();
    for (final transceiver in transceivers) {
      if (transceiver.sender.track?.kind != 'video') continue;
      final codecs =
          webrtc.RTCRtpSender.getCapabilities('video')?.codecs ?? [];
      // 按优先级排序：H.264 优先
      final preferred = <webrtc.RTCRtpCodecCapability>[];
      for (final codec in codecs) {
        final mime = codec.mimeType.toLowerCase();
        if (mime.contains('h264') || mime.contains('h.264')) {
          preferred.insert(0, codec);
        } else {
          preferred.add(codec);
        }
      }
      if (preferred.isNotEmpty) {
        await transceiver.setCodecPreferences(preferred);
        debugPrint(
            '[WebRTC] H.264 编码偏好已设置 (${preferred.length} codecs)');
      }
    }
  } catch (e) {
    debugPrint('[WebRTC] 设置 H.264 偏好失败（非致命）: $e');
  }
}
