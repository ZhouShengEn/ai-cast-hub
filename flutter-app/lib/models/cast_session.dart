/// 投屏会话数据模型
///
/// 表示一次 WebRTC 投屏会话的状态。
class CastSession {
  final String roomId;
  final String pcDeviceId;
  final String status; // 'connecting' | 'connected' | 'disconnected'
  final String? streamUrl;

  const CastSession({
    required this.roomId,
    required this.pcDeviceId,
    this.status = 'connecting',
    this.streamUrl,
  });

  bool get isConnecting => status == 'connecting';
  bool get isConnected => status == 'connected';
  bool get isDisconnected => status == 'disconnected';

  factory CastSession.fromJson(Map<String, dynamic> json) {
    return CastSession(
      roomId: json['roomId'] as String? ?? '',
      pcDeviceId: json['pcDeviceId'] as String? ?? '',
      status: json['status'] as String? ?? 'connecting',
      streamUrl: json['streamUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'roomId': roomId,
      'pcDeviceId': pcDeviceId,
      'status': status,
      'streamUrl': streamUrl,
    };
  }

  CastSession copyWith({
    String? roomId,
    String? pcDeviceId,
    String? status,
    String? streamUrl,
  }) {
    return CastSession(
      roomId: roomId ?? this.roomId,
      pcDeviceId: pcDeviceId ?? this.pcDeviceId,
      status: status ?? this.status,
      streamUrl: streamUrl ?? this.streamUrl,
    );
  }

  @override
  String toString() => 'CastSession($roomId, $status)';
}
