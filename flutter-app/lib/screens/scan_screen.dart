import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_provider.dart';
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

  /// 扫描成功回调
  Future<void> _onDeviceScanned(String deviceUuid) async {
    setState(() {
      _isBinding = true;
      _bindingDeviceUuid = deviceUuid;
    });

    try {
      // 调用 provider 完成绑定
      await ref.read(deviceProvider.notifier).bindDevice(deviceUuid);

      if (!mounted) return;

      // 绑定成功
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ 设备绑定成功'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      // 延迟返回让用户看到提示
      await Future.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
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
}
