import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import 'webrtc_codec_prefs_stub.dart'
    if (dart.library.io) 'webrtc_codec_prefs_io.dart';
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

  /// ICE 候选回调
  void Function(webrtc.RTCIceCandidate)? _onIceCandidateCallback;

  /// ICE 断开回调（PeerConnection 断开时触发）
  void Function()? _onIceDisconnectedCallback;

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
  void onIceDisconnected(void Function() callback) {
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
          '🔔 收到远端track: kind=${event.track?.kind}, id=${event.track?.id}, streams数量=${event.streams.length}');
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
      if (state ==
              webrtc.RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == webrtc.RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == webrtc.RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _rtcLog('🧊 ICE连接断开/失败，通知上层', level: LogLevel.warn);
        _onIceDisconnectedCallback?.call();
      }
    };

    return _peerConnection!;
  }

  /// 创建 SDP Offer
  Future<webrtc.RTCSessionDescription> createOffer() async {
    _ensureConnection();
    _rtcLog('createOffer: 创建中...');
    final offer = await _peerConnection!.createOffer({});
    await _peerConnection!.setLocalDescription(offer);
    _rtcLog('createOffer: 已创建, SDP长度=${offer.sdp?.length ?? 0}');
    return offer;
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

  /// 设置 H.264 视频编码偏好
  ///
  /// Android 硬件编码 H.264 比 VP8/VP9 功耗更低、帧率更稳定。
  /// 在 addTrack 之后、createOffer/createAnswer 之前调用。
  /// Web 平台通过条件导入自动跳过，编译期无平台 API 引用。
  Future<void> setH264Preference() async {
    await setH264CodecPreferences(_peerConnection);
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
