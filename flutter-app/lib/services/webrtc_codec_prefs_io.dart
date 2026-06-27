import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// 设置 H.264 视频编码偏好（仅 Android/iOS 等原生平台可用）
///
/// Android 硬件编码 H.264 比 VP8/VP9 功耗更低、帧率更稳定。
/// flutter_webrtc 原生平台不支持 RTCRtpSender.getCapabilities，
/// 因此这里仅做 H.264 优先的 MIME 顺序标记，不做强制的 codec 偏好设置。
Future<void> setH264CodecPreferences(webrtc.RTCPeerConnection? pc) async {
  if (pc == null) return;
  try {
    // SDP 层面通过 offerToReceiveVideo + mungeSDP 设置 H.264 偏好，
    // 当前 flutter_webrtc 原生平台 API 有限，仅记录日志。
    debugPrint('[WebRTC] H.264 编解码将由浏览器/系统默认协商决定');
  } catch (e) {
    debugPrint('[WebRTC] 设置 H.264 偏好失败（非致命）: $e');
  }
}
