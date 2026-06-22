import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/device.dart';
import '../services/device_service.dart';
import '../services/local_storage.dart';

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

  DeviceNotifier() : super(const DeviceState());

  /// 注册当前设备
  Future<void> registerDevice() async {
    state = state.copyWith(isLoading: true, error: null);

    try {
      final name = DeviceService.generateDeviceName();
      const platform = 'android'; // 可通过 dart:io 检测
      final result = await _service.register(name, platform);

      final deviceUuid = result['deviceUuid'] as String? ?? '';
      final transferKey = result['transferKey'] as String? ?? '';

      await _storage.saveDeviceUuid(deviceUuid);
      await _storage.saveTransferKey(transferKey);

      final device = Device.fromJson(result);
      state = state.copyWith(
        device: device,
        isLoading: false,
      );

      // 注册后同步拉取绑定列表
      await fetchDeviceInfo();
      await fetchDeviceList();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: '设备注册失败: $e',
      );
    }
  }

  /// 获取设备信息
  Future<void> fetchDeviceInfo() async {
    try {
      final result = await _service.getInfo();
      final device = Device.fromJson(result);
      state = state.copyWith(device: device);
    } catch (e) {
      state = state.copyWith(error: '获取设备信息失败: $e');
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
        error: '绑定失败: $e',
      );
    }
  }

  /// 获取已绑定设备列表
  Future<void> fetchDeviceList() async {
    try {
      final list = await _service.getDeviceList();
      final devices = list.map((e) => Device.fromJson(e)).toList();
      state = state.copyWith(pairedDevices: devices);
    } catch (e) {
      state = state.copyWith(error: '获取设备列表失败: $e');
    }
  }

  /// 生成二维码数据（当前设备 UUID）
  String? generateQRData() {
    return _storage.getDeviceUuid();
  }
}

/// 设备 Provider
final deviceProvider = StateNotifierProvider<DeviceNotifier, DeviceState>((ref) {
  return DeviceNotifier();
});
