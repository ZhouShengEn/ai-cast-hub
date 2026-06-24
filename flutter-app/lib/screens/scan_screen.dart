import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_provider.dart';
import '../services/api_client.dart';
import '../services/debug_service.dart';
import '../services/local_storage.dart';
import '../widgets/cast/device_scanner.dart';

/// 扫码绑定页面
///
/// 用于扫描 PC 端二维码完成设备绑定。
/// 绑定成功后自动返回首页。
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  bool _isBinding = false;
  String? _bindingDeviceUuid;
  String? _scanStatus; // 扫码状态信息
  String? _lastScannedCode; // 最近扫描到的原始数据

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceState = ref.watch(deviceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('扫码绑定'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Stack(
        children: [
          // 扫码器
          DeviceScanner(
            onDeviceScanned: _onDeviceScanned,
            onScanResult: _onScanResult,
          ),

          // 顶部提示
          Positioned(
            top: 24,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  '将 PC 端首页二维码对准扫描框',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ),
          ),

          // 扫码状态信息
          if (_scanStatus != null)
            Positioned(
              top: 80,
              left: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '扫码信息',
                      style: TextStyle(
                        color: Colors.green.shade300,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _scanStatus!,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // 绑定中 loading 遮罩
          if (_isBinding)
            Container(
              color: Colors.black54,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          '正在绑定设备...',
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (_bindingDeviceUuid != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            'UUID: ${_bindingDeviceUuid!.substring(0, _bindingDeviceUuid!.length > 12 ? 12 : _bindingDeviceUuid!.length)}...',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // 错误提示
          if (deviceState.error != null && !_isBinding)
            Positioned(
              bottom: 80,
              left: 20,
              right: 20,
              child: Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: theme.colorScheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          deviceState.error!,
                          style: TextStyle(color: theme.colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 扫码成功回调（弹窗确认后）
  Future<void> _onDeviceScanned(ScannedDeviceData scanned) async {
    final debug = DebugService();
    debug.info('[扫码] 收到扫描结果');
    debug.info('[扫码] deviceUuid: ${scanned.deviceUuid}');
    debug.info('[扫码] roomType: ${scanned.roomType ?? "无"}');
    debug.info('[扫码] serverUrl: ${scanned.serverUrl ?? "无"}');

    setState(() {
      _isBinding = true;
      _bindingDeviceUuid = scanned.deviceUuid;
    });

    try {
      // 如果二维码中包含服务器地址，先配置服务器
      if (scanned.serverUrl != null && scanned.serverUrl!.isNotEmpty) {
        final apiBaseUrl = '${scanned.serverUrl}/api/v1';
        debug.info('[扫码] 更新服务器地址: $apiBaseUrl');
        final storage = LocalStorage.instance;
        await storage.saveServerUrl(apiBaseUrl);
        ApiClient.instance.updateBaseUrl(apiBaseUrl);
      }

      debug.info('[扫码] 开始绑定设备...');
      await ref.read(deviceProvider.notifier).bindDevice(scanned.deviceUuid);
      debug.info('[扫码] 绑定成功');

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 设备绑定成功'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      debug.error('[扫码] 绑定失败: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('绑定失败: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isBinding = false;
          _bindingDeviceUuid = null;
        });
      }
    }
  }

  /// 扫码原始数据回调（用于实时显示扫描结果）
  void _onScanResult(String rawCode, bool isValid, String? info) {
    final debug = DebugService();
    if (isValid && info != null) {
      debug.info('[扫码] 识别到有效二维码: $info');
    } else {
      debug.warn('[扫码] 无效扫码数据: ${rawCode.length > 100 ? "${rawCode.substring(0, 100)}..." : rawCode}');
    }
    setState(() {
      _lastScannedCode = rawCode;
      _scanStatus = info ?? '扫描到无效数据';
    });
  }
}
