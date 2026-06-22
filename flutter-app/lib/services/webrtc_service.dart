import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// WebRTC 服务
///
/// 封装 WebRTC PeerConnection 操作：创建连接、SDP 协商、ICE 候选、数据通道、视频轨。
class WebrtcService {
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;

  /// 远端媒体流通知
  final StreamController<MediaStream> _remoteStreamController =
      StreamController<MediaStream>.broadcast();

  /// 数据通道消息通知
  final StreamController<RTCDataChannelMessage> _dataChannelMessageController =
      StreamController<RTCDataChannelMessage>.broadcast();

  /// 远端媒体流
  Stream<MediaStream> get onRemoteStream => _remoteStreamController.stream;

  /// 数据通道消息
  Stream<RTCDataChannelMessage> get onDataChannelMessage =>
      _dataChannelMessageController.stream;

  /// 创建 RTCPeerConnection
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration,
  ) async {
    await _closeExisting();

    _peerConnection = await createPeerConnection(configuration);

    // 远端媒体流监听
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        if (!_remoteStreamController.isClosed) {
          _remoteStreamController.add(event.streams.first);
        }
      }
    };

    // 数据通道监听（远端创建的 DataChannel）
    _peerConnection!.onDataChannel = (RTCDataChannel channel) {
      _dataChannel = channel;
      _setupDataChannelListeners(channel);
    };

    // ICE 候选事件
    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      // ICE 候选将通过回调方式传出（在 cast_service 中处理）
    };

    // ICE 连接状态变化
    _peerConnection!.onIceConnectionState = (RTCIceConnectionState state) {};

    return _peerConnection!;
  }

  /// 创建 SDP Offer
  Future<RTCSessionDescription> createOffer() async {
    _ensureConnection();
    final offer = await _peerConnection!.createOffer({});
    await _peerConnection!.setLocalDescription(offer);
    return offer;
  }

  /// 创建 SDP Answer
  Future<RTCSessionDescription> createAnswer() async {
    _ensureConnection();
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

  /// 处理远端 Offer
  Future<RTCSessionDescription> handleOffer(String sdp) async {
    _ensureConnection();
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    return answer;
  }

  /// 处理远端 Answer
  Future<void> handleAnswer(String sdp) async {
    _ensureConnection();
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
  }

  /// 处理远端 ICE 候选
  Future<void> handleIceCandidate(Map<String, dynamic> candidate) async {
    _ensureConnection();
    await _peerConnection!.addCandidate(
      RTCIceCandidate(
        candidate['candidate'] as String? ?? '',
        candidate['sdpMid'] as String? ?? '',
        candidate['sdpMLineIndex'] as int? ?? 0,
      ),
    );
  }

  /// 创建 DataChannel
  Future<RTCDataChannel> createDataChannel(String label) async {
    _ensureConnection();
    final channel = await _peerConnection!.createDataChannel(
      label,
      RTCDataChannelInit(),
    );
    _dataChannel = channel;
    _setupDataChannelListeners(channel);
    return channel;
  }

  /// 通过 DataChannel 发送消息
  void sendViaDataChannel(RTCDataChannelMessage message) {
    _dataChannel?.send(message);
  }

  /// 通过 DataChannel 发送二进制数据
  void sendViaDataChannelBinary(Uint8List data) {
    _dataChannel?.send(RTCDataChannelMessage.fromBinary(data));
  }

  /// 添加本地视频轨（投屏使用）
  Future<void> addVideoTrack(MediaStreamTrack track) async {
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
  RTCPeerConnection? get peerConnection => _peerConnection;

  /// 获取当前 DataChannel 实例
  RTCDataChannel? get dataChannel => _dataChannel;

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

  void _setupDataChannelListeners(RTCDataChannel channel) {
    channel.onMessage = (RTCDataChannelMessage message) {
      if (!_dataChannelMessageController.isClosed) {
        _dataChannelMessageController.add(message);
      }
    };
    channel.onDataChannelState = (RTCDataChannelState state) {
      // 状态变化处理
    };
  }
}

