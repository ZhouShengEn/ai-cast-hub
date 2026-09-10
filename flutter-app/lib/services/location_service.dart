import 'package:geolocator/geolocator.dart';

/// 高精度定位服务
///
/// 合规约束：本服务**只在用户已开启「位置共享」时**被调用，且共享期间
/// Android 侧会常驻「正在共享设备位置」的前台通知，用户随时可停止。
/// 不做熄屏/后台静默定位。
class LocationService {
  /// 确认已具备定位权限（缺失时向用户发起授权请求）
  ///
  /// 返回是否已获得定位权限；用户拒绝或系统定位未开启时返回 false，
  /// 调用方应据此提示用户，而不是反复重试。
  Future<bool> ensurePermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  /// 权限是否被用户永久拒绝（需引导去系统设置开启）
  Future<bool> isPermissionDeniedForever() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.deniedForever;
  }

  /// 系统定位服务是否开启
  Future<bool> isLocationServiceEnabled() =>
      Geolocator.isLocationServiceEnabled();

  /// 获取当前高精度坐标；失败或无权限返回 null
  Future<Position?> getCurrentPosition() async {
    try {
      final hasPermission = await ensurePermission();
      if (!hasPermission) return null;
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (_) {
      return null;
    }
  }
}
