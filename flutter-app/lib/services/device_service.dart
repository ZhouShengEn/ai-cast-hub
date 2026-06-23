import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// 设备注册与绑定服务
///
/// 管理手机设备注册、获取信息、绑定 PC 设备等操作。
class DeviceService {
  final ApiClient _client = ApiClient.instance;

  /// 注册当前设备
  /// [name] 设备名称，[platform] 平台标识（android/ios）
  Future<Map<String, dynamic>> register(String name, String platform) async {
    final data = await _client.post('/device/register', data: {
      'deviceName': name,
      'platform': platform,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  /// 获取当前设备信息
  Future<Map<String, dynamic>> getInfo() async {
    final data = await _client.get('/device/info');
    return Map<String, dynamic>.from(data as Map);
  }

  /// 绑定目标设备（扫码后绑定 PC）
  /// [targetUuid] 目标设备的 UUID
  Future<Map<String, dynamic>> bindDevice(String targetUuid) async {
    final data = await _client.post('/device/bind', data: {
      'targetUuid': targetUuid,
    });
    return Map<String, dynamic>.from(data as Map);
  }

  /// 获取已绑定设备列表
  Future<List<Map<String, dynamic>>> getDeviceList() async {
    final data = await _client.get('/device/list');
    return (data as List<dynamic>)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  /// 生成设备名称
  /// Android: "Android-{model}"，iOS: "iPhone-{model}" 或 "iPad-{model}"
  static String generateDeviceName() {
    try {
      if (kIsWeb) return 'Web Browser';
      if (defaultTargetPlatform == TargetPlatform.android) {
        return 'Android Device';
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        return 'iOS Device';
      }
    } catch (_) {}
    return 'Unknown Device';
  }
}
