import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// WebRTC 服务
///
/// 封装 WebRTC PeerConnection 操作：创建连接、SDP 协商、ICE 候选、数据通道、视频轨。
class WebrtcService {
  webrtc.RTCPeerConnection? _peerConnection;
  webrtc.RTCDataChannel? _dataChannel;
  webrtc.MediaStream? _localStream;

  /// 远端媒体流通知
  final StreamController<webrtc.MediaStream> _remoteStreamController =
      StreamController<webrtc.MediaStream>.broadcast();

  /// 数据通道消息通知
  final StreamController<webrtc.RTCDataChannelMessage> _dataChannelMessageController =
      StreamController<webrtc.RTCDataChannelMessage>.broadcast();

  /// 远端媒体流
  Stream<webrtc.MediaStream> get onRemoteStream => _remoteStreamController.stream;

  /// 数据通道消息
  Stream<webrtc.RTCDataChannelMessage> get onDataChannelMessage =>
      _dataChannelMessageController.stream;

  /// 创建 RTCPeerConnection
  Future<webrtc.RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration,
  ) async {
    await _closeExisting();

    // 调用 flutter_webrtc 包的全局函数（通过库前缀避免与类方法同名递归）
    _peerConnection = await webrtc.createPeerConnection(configuration);

    // 远端媒体流监听
    _peerConnection!.onTrack = (webrtc.RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        if (!_remoteStreamController.isClosed) {
          _remoteStreamController.add(event.streams.first);
        }
      }
    };

    // 数据通道监听（远端创建的 DataChannel）
    _peerConnection!.onDataChannel = (webrtc.RTCDataChannel channel) {
      _dataChannel = channel;
      _setupDataChannelListeners(channel);
    };

    // ICE 候选事件
    _peerConnection!.onIceCandidate = (webrtc.RTCIceCandidate candidate) {
      // ICE 候选将通过回调方式传出（在 cast_service 中处理）
    };

    // ICE 连接状态变化
    _peerConnection!.onIceConnectionState = (webrtc.RTCIceConnectionState state) {};

    return _peerConnection!;
  }

  /// 创建 SDP Offer
  Future<webrtc.RTCSessionDescription> createOffer() async {
    _ensureConnection();
    final offer = await _peerConnection!.createOffer({});
    await _peerConnection!.setLocalDescription(offer);
    return offer;
  }

  /// 创建 SDP Answer
  Future<webrtc.RTCSessionDescription> createAnswer() async {
    _ensureConnection();
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

  /// 处理远端 Offer
  Future<webrtc.RTCSessionDescription> handleOffer(String sdp) async {
    _ensureConnection();
    await _peerConnection!.setRemoteDescription(
      webrtc.RTCSessionDescription(sdp, 'offer'),
    );
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

  /// 处理远端 Answer
  Future<void> handleAnswer(String sdp) async {
    _ensureConnection();
    await _peerConnection!.setRemoteDescription(
      webrtc.RTCSessionDescription(sdp, 'answer'),
    );
  }

  /// 处理远端 ICE 候选
  Future<void> handleIceCandidate(Map<String, dynamic> candidate) async {
    _ensureConnection();
    await _peerConnection!.addCandidate(
      webrtc.RTCIceCandidate(
        candidate['candidate'] as String? ?? '',
        candidate['sdpMid'] as String? ?? '',
        candidate['sdpMLineIndex'] as int? ?? 0,
      ),
    );
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

  /// 关闭连接并清理资源
  Future<void> close() async {
    _dataChannel?.close();
    _dataChannel = null;
    _localStream?.dispose();
    _localStream = null;
    await _peerConnection?.close();
    _peerConnection = null;
  }

  /// 释放所有资源
  void dispose() {
    close();
    _remoteStreamController.close();
    _dataChannelMessageController.close();
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

