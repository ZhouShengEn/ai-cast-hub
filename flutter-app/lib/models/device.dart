/// 设备数据模型
///
/// 表示一个已注册的设备（手机自身或已绑定的 PC）。
class Device {
  final String id;
  final String deviceUuid;
  final String deviceName;
  final String platform;
  final String? transferKey;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  const Device({
    required this.id,
    required this.deviceUuid,
    required this.deviceName,
    required this.platform,
    this.transferKey,
    required this.createdAt,
    required this.lastSeenAt,
  });

  /// 判断设备是否在线（5 分钟内有活动）
  bool isOnline() {
    return lastSeenAt.isAfter(DateTime.now().subtract(const Duration(minutes: 5)));
  }

  factory Device.fromJson(Map<String, dynamic> json) {
    return Device(
      id: (json['id'] as String?) ?? (json['deviceUuid'] as String?) ?? (json['uuid'] as String?) ?? '',
      deviceUuid: (json['deviceUuid'] as String?) ?? (json['uuid'] as String?) ?? '',
      deviceName: (json['deviceName'] as String?) ?? (json['name'] as String?) ?? '',
      platform: json['platform'] as String? ?? '',
      transferKey: json['transferKey'] as String?,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : DateTime.now(),
      lastSeenAt: json['lastSeenAt'] != null
          ? DateTime.parse(json['lastSeenAt'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'deviceUuid': deviceUuid,
      'deviceName': deviceName,
      'platform': platform,
      'transferKey': transferKey,
      'createdAt': createdAt.toIso8601String(),
      'lastSeenAt': lastSeenAt.toIso8601String(),
    };
  }

  Device copyWith({
    String? id,
    String? deviceUuid,
    String? deviceName,
    String? platform,
    String? transferKey,
    DateTime? createdAt,
    DateTime? lastSeenAt,
  }) {
    return Device(
      id: id ?? this.id,
      deviceUuid: deviceUuid ?? this.deviceUuid,
      deviceName: deviceName ?? this.deviceName,
      platform: platform ?? this.platform,
      transferKey: transferKey ?? this.transferKey,
      createdAt: createdAt ?? this.createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  @override
  String toString() => 'Device($deviceUuid, $deviceName, $platform)';
}
