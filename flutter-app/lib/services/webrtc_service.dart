import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'debug_service.dart';

/// WebRTC 服务日志
void _rtcLog(String msg, {LogLevel level = LogLevel.debug}) {
  final text = '[WebRTC] $msg';
  debugPrint(text);
  DebugService().log(text, level: level);
}

/// WebRTC 服务
///
/// 封装 WebRTC PeerConnection 操作：创建连接、SDP 协商、ICE 候选、数据通道、视频轨。
class WebrtcService {
  webrtc.RTCPeerConnection? _peerConnection;
  webrtc.RTCDataChannel? _dataChannel;
  webrtc.MediaStream? _localStream;

  /// 是否在 offer SDP 中把 H.264 排到最前（启用硬件编码，避免软件 VP8 卡顿）。
  /// 仅原生平台启用（Web 平台不投屏、无需处理）。
  bool _preferH264 = false;

  /// ICE 候选回调
  void Function(webrtc.RTCIceCandidate)? _onIceCandidateCallback;

  /// ICE 断开回调（PeerConnection 断开时触发，参数为 disconnected/failed/closed）
  void Function(String state)? _onIceDisconnectedCallback;

  /// 远端媒体流通知
  final StreamController<webrtc.MediaStream> _remoteStreamController =
      StreamController<webrtc.MediaStream>.broadcast();

  /// 数据通道消息通知
  final StreamController<webrtc.RTCDataChannelMessage>
      _dataChannelMessageController =
      StreamController<webrtc.RTCDataChannelMessage>.broadcast();

  /// 远端DataChannel创建通知
  final StreamController<webrtc.RTCDataChannel> _remoteDataChannelController =
      StreamController<webrtc.RTCDataChannel>.broadcast();

  /// 远端媒体流
  Stream<webrtc.MediaStream> get onRemoteStream =>
      _remoteStreamController.stream;

  /// 数据通道消息
  Stream<webrtc.RTCDataChannelMessage> get onDataChannelMessage =>
      _dataChannelMessageController.stream;

  /// 远端DataChannel创建事件
  Stream<webrtc.RTCDataChannel> get onRemoteDataChannel =>
      _remoteDataChannelController.stream;

  /// 设置 ICE 候选回调
  void onIceCandidate(void Function(webrtc.RTCIceCandidate) callback) {
    _onIceCandidateCallback = callback;
  }

  /// 设置 ICE 断开回调（PeerConnection 断开时通知调用方）
  /// [state] 为 'disconnected' | 'failed' | 'closed'，便于上层区分「可恢复」与「不可恢复」
  void onIceDisconnected(void Function(String state) callback) {
    _onIceDisconnectedCallback = callback;
  }

  /// 创建 RTCPeerConnection
  Future<webrtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration,
  ) async {
    await _closeExisting();

    // 调用 flutter_webrtc 包的全局函数（通过库前缀避免与类方法同名递归）
    _peerConnection = await webrtc.createPeerConnection(configuration);
    _rtcLog('PeerConnection已创建');

    // 远端媒体流监听
    _peerConnection!.onTrack = (webrtc.RTCTrackEvent event) {
      _rtcLog(
          '🔔 收到远端track: kind=${event.track.kind}, id=${event.track.id}, streams数量=${event.streams.length}');
      if (event.streams.isNotEmpty) {
        _rtcLog('  stream id: ${event.streams.first.id}');
        if (!_remoteStreamController.isClosed) {
          _remoteStreamController.add(event.streams.first);
          _rtcLog('  stream已添加到_remoteStreamController');
        }
      } else {
        _rtcLog('⚠️ track没有关联的stream');
      }
    };

    // 数据通道监听（远端创建的 DataChannel）
    _peerConnection!.onDataChannel = (webrtc.RTCDataChannel channel) {
      _rtcLog('收到远端DataChannel: ${channel.label}');
      _dataChannel = channel;
      _setupDataChannelListeners(channel);
      // 通知外部远端DataChannel已创建
      if (!_remoteDataChannelController.isClosed) {
        _remoteDataChannelController.add(channel);
      }
    };

    // ICE 候选事件 → 通过回调传出
    _peerConnection!.onIceCandidate = (webrtc.RTCIceCandidate candidate) {
      final cand = candidate.candidate ?? '';
      _rtcLog(
          '🧊 ICE候选: ${cand.length > 50 ? cand.substring(0, 50) : cand}...');
      _onIceCandidateCallback?.call(candidate);
    };

    // ICE 连接状态变化
    _peerConnection!.onIceConnectionState =
        (webrtc.RTCIceConnectionState state) {
      _rtcLog('🧊 ICE连接状态变化: $state');
      String name;
      if (state ==
          webrtc.RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        name = 'disconnected';
      } else if (state ==
          webrtc.RTCIceConnectionState.RTCIceConnectionStateFailed) {
        name = 'failed';
      } else if (state ==
          webrtc.RTCIceConnectionState.RTCIceConnectionStateClosed) {
        name = 'closed';
      } else {
        return;
      }
      _rtcLog('🧊 ICE连接 $name，通知上层', level: LogLevel.warn);
      _onIceDisconnectedCallback?.call(name);
    };

    return _peerConnection!;
  }

  /// 创建 SDP Offer
  Future<webrtc.RTCSessionDescription> createOffer() async {
    _ensureConnection();
    _rtcLog('createOffer: 创建中...');
    final offer = await _peerConnection!.createOffer({});
    String? sdp = offer.sdp;
    // 把 H.264 排到 m=video 最前：对端（Chrome/Safari/Firefox 均支持 H.264）会优先协商
    // 硬件编码的 H.264，避免回落到软件 VP8 导致投屏严重卡顿（这是「投屏很卡」的核心根因之一）。
    if (_preferH264 && sdp != null) {
      final munged = _preferH264InSdp(sdp);
      if (munged != sdp) {
        _rtcLog('createOffer: 已将 H.264 排到 m=video 最前（启用硬件编码）',
            level: LogLevel.info);
        sdp = munged;
      }
    }
    final result = webrtc.RTCSessionDescription(sdp, offer.type);
    await _peerConnection!.setLocalDescription(result);
    _rtcLog('createOffer: 已创建, SDP长度=${sdp?.length ?? 0}');
    return result;
  }

  /// 创建 SDP Answer
  Future<webrtc.RTCSessionDescription> createAnswer() async {
    _ensureConnection();
    _rtcLog('createAnswer: 创建中...');
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    _rtcLog('createAnswer: 已创建, SDP长度=${answer.sdp?.length ?? 0}');
    return answer;
  }

  /// 处理远端 Offer
  Future<webrtc.RTCSessionDescription> handleOffer(String sdp) async {
    _ensureConnection();
    _rtcLog('handleOffer: 设置远程SDP, 长度=${sdp.length}');
    await _peerConnection!.setRemoteDescription(
      webrtc.RTCSessionDescription(sdp, 'offer'),
    );
    _rtcLog('handleOffer: 远程SDP已设置，创建answer');
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    _rtcLog('handleOffer: answer已创建');
    return answer;
  }

  /// 处理远端 Answer
  Future<void> handleAnswer(String sdp) async {
    _ensureConnection();
    _rtcLog('handleAnswer: 设置远程SDP, 长度=${sdp.length}');
    await _peerConnection!.setRemoteDescription(
      webrtc.RTCSessionDescription(sdp, 'answer'),
    );
    _rtcLog('handleAnswer: 远程SDP已设置');
  }

  /// 处理远端 ICE 候选
  Future<void> handleIceCandidate(Map<String, dynamic> candidate) async {
    _ensureConnection();
    final candStr = candidate['candidate'] as String? ?? '';
    _rtcLog(
        'handleIceCandidate: 添加ICE候选, candidate=${candStr.length > 50 ? candStr.substring(0, 50) : candStr}...');
    await _peerConnection!.addCandidate(
      webrtc.RTCIceCandidate(
        candidate['candidate'] as String? ?? '',
        candidate['sdpMid'] as String? ?? '',
        candidate['sdpMLineIndex'] as int? ?? 0,
      ),
    );
    _rtcLog('handleIceCandidate: ICE候选已添加');
  }

  /// 创建 DataChannel
  Future<webrtc.RTCDataChannel> createDataChannel(String label) async {
    _ensureConnection();
    final channel = await _peerConnection!.createDataChannel(
      label,
      webrtc.RTCDataChannelInit(),
    );
    _dataChannel = channel;
    _setupDataChannelListeners(channel);
    return channel;
  }

  /// 创建辅助 DataChannel（不接管 _dataChannel、不接管消息监听）
  ///
  /// [createDataChannel] 会把通道记为 _dataChannel 并接管其 onMessage，
  /// 重复调用会顶掉前一个通道的引用。因此音频等旁路通道必须走这里：
  /// 否则 control 通道会被覆盖，且二进制音频帧会被当成 JSON 文本解析报错。
  ///
  /// [maxRetransmitTime] > 0 时该通道为「有限重传」，适合实时音频；
  /// 留空（默认 -1）则为可靠通道。
  Future<webrtc.RTCDataChannel> createAuxDataChannel(
    String label, {
    bool ordered = true,
    int maxRetransmitTime = -1,
  }) async {
    _ensureConnection();
    final init = webrtc.RTCDataChannelInit()
      ..ordered = ordered
      ..maxRetransmitTime = maxRetransmitTime;
    final channel = await _peerConnection!.createDataChannel(label, init);
    _rtcLog(
      '创建辅助DataChannel: $label '
      '(ordered=$ordered, maxRetransmitTime=$maxRetransmitTime)',
    );
    return channel;
  }

  /// 通过 DataChannel 发送消息
  void sendViaDataChannel(webrtc.RTCDataChannelMessage message) {
    _dataChannel?.send(message);
  }

  /// 动态调整视频编码参数（分辨率缩放 / 帧率 / 码率）
  ///
  /// 通过 RTCRtpSender.setParameters 实时生效，**无需重新协商、也无需重新采集屏幕**，
  /// 因此「切换画质」不会打断投屏。
  ///   - [scaleResolutionDownBy] 编码端按比例缩小分辨率（>1 即降分辨率，1 为原始）
  ///   - [maxFramerate] 限制输出帧率
  ///   - [maxBitrate] 限制输出码率（bps）
  /// 找不到视频发送器或无 encodings 时静默跳过（例如尚未 addTrack）。
  Future<void> setVideoEncoding({
    double? scaleResolutionDownBy,
    int? maxFramerate,
    int? maxBitrate,
  }) async {
    _ensureConnection();
    final senders = await _peerConnection!.getSenders();
    webrtc.RTCRtpSender? videoSender;
    for (final s in senders) {
      final track = s.track;
      if (track != null && track.kind == 'video') {
        videoSender = s;
        break;
      }
    }
    if (videoSender == null) {
      _rtcLog('未找到视频发送器，跳过画质调整', level: LogLevel.warn);
      return;
    }
    final params = videoSender.parameters;
    final encodings = params.encodings;
    if (encodings == null || encodings.isEmpty) {
      _rtcLog('视频编码参数无 encodings，跳过画质调整', level: LogLevel.warn);
      return;
    }
    final enc = encodings[0];
    if (scaleResolutionDownBy != null) {
      enc.scaleResolutionDownBy = scaleResolutionDownBy;
    }
    if (maxFramerate != null) enc.maxFramerate = maxFramerate;
    if (maxBitrate != null) enc.maxBitrate = maxBitrate;
    await videoSender.setParameters(params);
    _rtcLog(
      '画质参数已应用: scale=${enc.scaleResolutionDownBy}, '
      'fps=${enc.maxFramerate}, bitrate=${enc.maxBitrate}',
      level: LogLevel.info,
    );
  }

  /// 读取视频发送通道「已编码帧数」（用于「已连接但黑屏」检测）
  ///
  /// 黑屏最常见的成因是：轨道已添加、ICE 已连接，但编码器没出帧
  /// （Surface 生命周期不同步 / 编码参数未生效）。framesEncoded 不增长即可判定。
  /// 读不到（平台不支持）返回 null，调用方应跳过检测而不是误报。
  Future<int?> getVideoFramesEncoded() async {
    _ensureConnection();
    try {
      final reports = await _peerConnection!.getStats();
      int total = 0;
      bool found = false;
      for (final r in reports) {
        final values = r.values;
        final isVideo =
            values['kind'] == 'video' || values['mediaType'] == 'video';
        final frames = values['framesEncoded'];
        if (!isVideo || frames is! num) continue;
        // outbound-rtp 才是本端发送统计；track 级统计通常无该字段
        total += frames.toInt();
        found = true;
      }
      return found ? total : null;
    } catch (e) {
      _rtcLog('读取视频帧统计失败: $e', level: LogLevel.warn);
      return null;
    }
  }

  /// 用新轨道替换当前视频发送轨（不重新协商，用于黑屏自愈）
  Future<bool> replaceVideoTrack(webrtc.MediaStreamTrack track) async {
    _ensureConnection();
    try {
      final senders = await _peerConnection!.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          await s.replaceTrack(track);
          _rtcLog('视频发送轨已替换为 ${track.id}');
          return true;
        }
      }
      // 没有视频发送器（极端情况）则直接补加
      final stream = _localStream;
      if (stream != null) {
        await _peerConnection!.addTrack(track, stream);
      } else {
        await _peerConnection!.addTrack(track);
      }
      return true;
    } catch (e) {
      _rtcLog('替换视频轨失败: $e', level: LogLevel.error);
      return false;
    }
  }

  /// 读取当前视频轨实际分辨率高度（用于计算 scaleResolutionDownBy 的目标比例）
  /// 读不到时回退 1080，避免除零。
  Future<int> getVideoTrackHeight() async {
    _ensureConnection();
    final senders = await _peerConnection!.getSenders();
    for (final s in senders) {
      final track = s.track;
      if (track != null && track.kind == 'video') {
        try {
          final settings = track.getSettings();
          final h = settings['height'];
          if (h is int && h > 0) return h;
        } catch (e) {
          _rtcLog('读取视频轨分辨率失败: $e', level: LogLevel.warn);
        }
        return 1080;
      }
    }
    return 1080;
  }

  /// 通过 DataChannel 发送二进制数据
  void sendViaDataChannelBinary(Uint8List data) {
    _dataChannel?.send(webrtc.RTCDataChannelMessage.fromBinary(data));
  }

  /// 添加本地视频轨（投屏使用）
  Future<void> addVideoTrack(webrtc.MediaStreamTrack track) async {
    _ensureConnection();
    _peerConnection!.addTrack(track);
  }

  /// 将本地 MediaStream 的所有轨道添加到 PeerConnection
  /// 接收端通过 onTrack 事件能拿到完整的 streams
  Future<void> addStream(webrtc.MediaStream stream) async {
    _ensureConnection();
    _localStream = stream;
    _rtcLog('addStream: 准备添加${stream.getTracks().length}个轨道');
    for (final track in stream.getTracks()) {
      _rtcLog('addStream: 添加轨道 kind=${track.kind}, id=${track.id}');
      await _peerConnection!.addTrack(track, stream);
    }
    _rtcLog('addStream: 所有轨道已添加完成');
  }

  /// 设置 H.264 视频编码偏好（启用硬件编码）
  ///
  /// Android 硬件编码 H.264 比 VP8/VP9 软件编码功耗更低、帧率更稳定，
  /// 是投屏流畅性的关键。flutter_webrtc 原生 API 不直接暴露 setCodecPreferences 的便捷封装，
  /// 因此这里只置位偏好标记，真正的「H.264 优先」在 [createOffer] 里对 SDP 的 m=video 行做
  /// payload type 重排实现——既不丢弃其它编解码能力（保留 VP8/VP9 作降级），又能让对端协商到
  /// 硬件 H.264。在 addTrack 之后、createOffer 之前调用。
  /// Web 平台通过条件导入自动跳过，编译期无平台 API 引用。
  Future<void> setH264Preference() async {
    _preferH264 = !kIsWeb;
    _rtcLog('已启用 H.264 硬件编码偏好（offer SDP 将把 H.264 排到最前）',
        level: LogLevel.info);
  }

  /// 在 SDP 的 m=video 行把 H.264 的 payload type 重排到最前。
  ///
  /// WebRTC 协商时 offerer 列出的编解码顺序即偏好顺序，对端会在交集里优先选第一个受支持的。
  /// 把 H.264 排到最前即引导对端协商硬件 H.264；若设备本身不支持 H.264（极少数）则保持原样。
  String _preferH264InSdp(String sdp) {
    final lines = sdp.split('\r\n');
    int videoLineIdx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('m=video')) {
        videoLineIdx = i;
        break;
      }
    }
    if (videoLineIdx < 0) return sdp;

    // 建立 payload type → 编解码 的映射（a=rtpmap:<pt> <codec>/<clock>）
    final codecByPt = <String, String>{};
    for (final line in lines) {
      if (line.startsWith('a=rtpmap:')) {
        final rest = line.substring('a=rtpmap:'.length).split(' ');
        if (rest.length >= 2) {
          final pt = rest[0];
          final codec = rest[1].split('/').first.toLowerCase();
          codecByPt[pt] = codec;
        }
      }
    }

    final videoParts = lines[videoLineIdx].split(' ');
    final pts = videoParts.skip(1).where((p) => p.isNotEmpty).toList();
    if (pts.isEmpty) return sdp;

    final h264Pts = <String>[];
    final otherPts = <String>[];
    for (final pt in pts) {
      if (codecByPt[pt] == 'h264') {
        h264Pts.add(pt);
      } else {
        otherPts.add(pt);
      }
    }
    if (h264Pts.isEmpty) return sdp; // 不支持 H.264，保持原样

    final newPts = <String>[...h264Pts, ...otherPts];
    lines[videoLineIdx] = '${videoParts[0]} ${newPts.join(' ')}';
    return lines.join('\r\n');
  }

  /// 屏幕捕获（Web 端使用 getDisplayMedia）
  /// 返回包含视频轨（和可选音频轨）的 MediaStream
  Future<webrtc.MediaStream> startScreenCapture() async {
    final stream = await webrtc.navigator.mediaDevices.getDisplayMedia(
      <String, dynamic>{
        'video': <String, dynamic>{
          'mandatory': <String, dynamic>{
            'maxWidth': 1920,
            'maxHeight': 1080,
            'maxFrameRate': 30,
          },
        },
        'audio': true,
      },
    );
    _localStream = stream;
    return stream;
  }

  /// 停止屏幕捕获
  Future<void> stopScreenCapture() async {
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (e) {
          _rtcLog('停止本地轨道失败: $e', level: LogLevel.warn);
        }
      }
      try {
        await stream.dispose();
      } catch (e) {
        _rtcLog('释放本地媒体流失败: $e', level: LogLevel.warn);
      }
    }
  }

  /// 关闭连接并清理资源
  Future<void> close() async {
    try {
      await _dataChannel?.close();
    } catch (e) {
      _rtcLog('关闭 DataChannel 失败: $e', level: LogLevel.warn);
    }
    _dataChannel = null;
    await stopScreenCapture();

    final peerConnection = _peerConnection;
    _peerConnection = null;
    try {
      await peerConnection?.close();
    } catch (e) {
      _rtcLog('关闭 PeerConnection 失败: $e', level: LogLevel.warn);
    }
    _onIceCandidateCallback = null;
    _onIceDisconnectedCallback = null;
  }

  /// 释放所有资源
  void dispose() {
    close();
    _remoteStreamController.close();
    _dataChannelMessageController.close();
    _remoteDataChannelController.close();
    _onIceCandidateCallback = null;
  }

  /// 获取当前 PeerConnection 实例
  webrtc.RTCPeerConnection? get peerConnection => _peerConnection;

  /// 获取当前 DataChannel 实例
  webrtc.RTCDataChannel? get dataChannel => _dataChannel;

  // ---- 内部方法 ----

  void _ensureConnection() {
    if (_peerConnection == null) {
      throw StateError('PeerConnection 未创建，请先调用 createPeerConnection');
    }
  }

  Future<void> _closeExisting() async {
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
  }

  void _setupDataChannelListeners(webrtc.RTCDataChannel channel) {
    channel.onMessage = (webrtc.RTCDataChannelMessage message) {
      if (!_dataChannelMessageController.isClosed) {
        _dataChannelMessageController.add(message);
      }
    };
    channel.onDataChannelState = (webrtc.RTCDataChannelState state) {
      // 状态变化处理
    };
  }
}
