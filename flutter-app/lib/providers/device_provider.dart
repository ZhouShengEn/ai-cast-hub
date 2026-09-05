import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/device_service.dart';
import '../services/local_storage.dart';
import '../services/debug_service.dart';
import '../services/websocket_service.dart';

/// 设备状态
class DeviceState {
  final Device? device;
  final List<Device> pairedDevices;
  final bool isLoading;
  final String? error;

  const DeviceState({
    this.device,
    this.pairedDevices = const [],
    this.isLoading = false,
    this.error,
  });

  DeviceState copyWith({
    Device? device,
    List<Device>? pairedDevices,
    bool? isLoading,
    String? error,
  }) {
    return DeviceState(
      device: device ?? this.device,
      pairedDevices: pairedDevices ?? this.pairedDevices,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }

  /// 是否已绑定 PC 设备
  bool get hasPairedDevice => pairedDevices.isNotEmpty;
}

/// 设备状态管理
class DeviceNotifier extends StateNotifier<DeviceState> {
  final DeviceService _service = DeviceService();
  final LocalStorage _storage = LocalStorage.instance;

  /// WebSocket 消息订阅（用于实时接收上下线 / 自动解绑事件）
  StreamSubscription<Map<String, dynamic>>? _wsSubscription;

  DeviceNotifier() : super(const DeviceState()) {
    _initWsListener();
  }

  /// 订阅全局 WebSocket 消息流，处理 device_status / device_unbound 事件
  void _initWsListener() {
    _wsSubscription = WebSocketService.instance.messages.listen(_onWsMessage);
  }

  void _onWsMessage(Map<String, dynamic> msg) {
    final type = msg['type'] as String?;
    if (type == 'device_status') {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final uuid = payload['deviceUuid'] as String?;
      final status = payload['status'] as String?;
      if (uuid != null && status != null) {
        _applyDeviceStatus(uuid, status == 'online');
      }
    } else if (type == 'device_unbound') {
      final payload = msg['payload'] as Map<String, dynamic>? ?? {};
      final from = payload['fromDeviceUuid'] as String?;
      if (from != null) {
        _applyDeviceUnbound(from, auto: payload['reason'] == 'auto');
      }
    }
  }

  /// 实时更新某配对设备的在线状态（通过修改其 lastSeenAt，复用已有 isOnline() 逻辑）
  void _applyDeviceStatus(String deviceUuid, bool online) {
    if (state.pairedDevices.isEmpty) return;
    final devices = state.pairedDevices.map((d) {
      if (d.deviceUuid != deviceUuid) return d;
      final newLastSeen = online
          ? DateTime.now()
          : DateTime.now().subtract(const Duration(hours: 1));
      return d.copyWith(lastSeenAt: newLastSeen);
    }).toList();
    if (!listEquals(devices, state.pairedDevices)) {
      state = state.copyWith(pairedDevices: devices);
    }
  }

  /// 收到解绑事件（手动或离线超10分钟自动解绑），从配对列表移除对方
  void _applyDeviceUnbound(String fromDeviceUuid, {bool auto = false}) {
    final devices =
        state.pairedDevices.where((d) => d.deviceUuid != fromDeviceUuid).toList();
    if (devices.length != state.pairedDevices.length) {
      state = state.copyWith(pairedDevices: devices);
      DebugService().info(
        '[Device] 收到解绑事件(${auto ? "自动" : "手动"}): $fromDeviceUuid',
      );
    }
  }

  /// 将异常转换为用户友好的中文提示
  String _friendlyError(Object e) {
    final str = e.toString();
    if (str.contains('401') || str.contains('Unauthorized')) {
      return '设备未注册，正在自动注册...';
    }
    if (str.contains('Connection refused') || str.contains('SocketException') || str.contains('No route to host')) {
      return '无法连接到服务器，请检查服务器地址和网络连接';
    }
    if (str.contains('Timeout') || str.contains('timed out')) {
      return '连接超时，请检查网络是否正常';
    }
    if (str.contains('404')) {
      return '服务器资源不存在，请检查服务器版本';
    }
    if (str.contains('500') || str.contains('Server')) {
      return '服务器内部错误，请稍后重试';
    }
    return '操作失败，请检查网络后重试';
  }

  /// 注册当前设备（最多重试3次，指数退避）
  Future<void> registerDevice({int retryCount = 0}) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      // 1. 先生成 UUID（如果不存在），确保请求时有 X-Device-UUID 头
      String? uuid = _storage.getDeviceUuid();
      if (uuid == null || uuid.isEmpty) {
        uuid = _generateUUID();
        await _storage.saveDeviceUuid(uuid);
        DebugService().info('[注册] 生成新 UUID: ${uuid.substring(0, 8)}...');
      }

      // 2. 检测平台类型
      final platform = _getPlatform();
      DebugService().info('[注册] 平台: $platform, 服务器: ${_storage.getServerUrl()}');

      // 3. 发送 POST 注册请求
      final name = DeviceService.generateDeviceName();
      DebugService().info('[注册] 发送注册请求(第${retryCount + 1}次): $name ($platform)');
      final result = await _service.register(name, platform);

      DebugService().info('[注册] 注册成功: $result');

      // 4. 保存服务端返回的信息
      final deviceUuid = result['deviceUuid'] as String? ?? uuid;
      final transferKey = result['transferKey'] as String? ?? '';

      await _storage.saveDeviceUuid(deviceUuid);
      await _storage.saveTransferKey(transferKey);

      final device = Device.fromJson(result);
      state = state.copyWith(
        device: device,
        isLoading: false,
      );

      // 注册后同步拉取绑定列表（失败不重试注册，注册已成功）
      try {
        await fetchDeviceInfo();
        await fetchDeviceList();
      } catch (e) {
        DebugService().warn('[注册] 注册成功但拉取信息失败: $e');
      }
    } catch (e) {
      DebugService().warn('[注册] 注册失败(第${retryCount + 1}次): $e');
      // 最多重试3次，指数退避
      if (retryCount < 3) {
        final delay = Duration(seconds: pow(2, retryCount).toInt());
        DebugService().info('[注册] 等待${delay.inSeconds}秒后重试...');
        await Future.delayed(delay);
        await registerDevice(retryCount: retryCount + 1);
      } else {
        state = state.copyWith(
          isLoading: false,
          error: '设备注册失败: ${_friendlyError(e)}',
        );
      }
    }
  }

  /// 获取设备信息
  Future<void> fetchDeviceInfo() async {
    try {
      final result = await _service.getInfo();
      final device = Device.fromJson(result);
      state = state.copyWith(device: device);
    } catch (e) {
      state = state.copyWith(error: '获取设备信息失败: ${_friendlyError(e)}');
      rethrow;
    }
  }

  /// 绑定 PC 设备
  Future<void> bindDevice(String targetUuid) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _service.bindDevice(targetUuid);
      await fetchDeviceList();
      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '绑定失败: ${_friendlyError(e)}',
      );
    }
  }

  /// 通过连接码绑定 PC 设备
  Future<void> bindByCode(String pairCode) async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      await _service.bindByCode(pairCode);
      await fetchDeviceList();
      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '绑定失败: ${_friendlyError(e)}',
      );
      rethrow;
    }
  }

  /// 获取已绑定设备列表
  Future<void> fetchDeviceList() async {
    try {
      final list = await _service.getDeviceList();
      final devices = list.map((e) => Device.fromJson(e)).toList();
      state = state.copyWith(pairedDevices: devices);
    } catch (e) {
      state = state.copyWith(error: '获取设备列表失败: ${_friendlyError(e)}');
      rethrow;
    }
  }

  /// 解除设备绑定
  Future<void> unbindDevice(String targetUuid) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _service.unbindDevice(targetUuid);
      await fetchDeviceList();
      state = state.copyWith(isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '解除绑定失败: ${_friendlyError(e)}',
      );
    }
  }

  /// 生成二维码数据（当前设备 UUID）
  String? generateQRData() {
    return _storage.getDeviceUuid();
  }

  /// 获取当前平台标识
  String _getPlatform() {
    if (kIsWeb) return 'web';
    try {
      if (defaultTargetPlatform == TargetPlatform.android) return 'android';
      if (defaultTargetPlatform == TargetPlatform.iOS) return 'ios';
    } catch (_) {}
    return 'unknown';
  }

  /// 生成简单的 UUID v4
  String _generateUUID() {
    final random = Random();
    final chars = '0123456789abcdef';
    String hex(int len) => List.generate(len, (_) => chars[random.nextInt(16)]).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${_hex89ab(random.nextInt(4))}${hex(3)}-${hex(12)}';
  }

  String _hex89ab(int n) => '89ab'[n];

  @override
  void dispose() {
    _wsSubscription?.cancel();
    _wsSubscription = null;
    super.dispose();
  }
}

/// 设备 Provider
final deviceProvider = StateNotifierProvider<DeviceNotifier, DeviceState>((ref) {
  return DeviceNotifier();
});
