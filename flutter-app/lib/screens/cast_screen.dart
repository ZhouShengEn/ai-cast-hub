import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/cast_provider.dart';
import '../providers/device_provider.dart';
import '../widgets/cast/cast_control_panel.dart';
import '../widgets/cast/device_scanner.dart';
import '../widgets/cast/status_indicator.dart';

/// 投屏页面 — 扫码连接 PC + WebRTC 投屏控制
class CastScreen extends ConsumerStatefulWidget {
  const CastScreen({super.key});

  @override
  ConsumerState<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends ConsumerState<CastScreen> {
  bool _showScanner = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final castState = ref.watch(castProvider);
    final deviceState = ref.watch(deviceProvider);
    final castNotifier = ref.read(castProvider.notifier);

    // 获取第一个已绑定 PC 名称
    final pcName = deviceState.pairedDevices.isNotEmpty
        ? deviceState.pairedDevices.first.deviceName
        : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('投屏'),
        actions: [
          if (!_showScanner)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner),
              tooltip: '重新扫描',
              onPressed: () => setState(() => _showScanner = true),
            ),
        ],
      ),
      body: _showScanner && !castState.isCasting
          ? _buildScannerView(castNotifier)
          : _buildControlView(castState, castNotifier, pcName),
    );
  }

  Widget _buildScannerView(dynamic castNotifier) {
    return DeviceScanner(
      onDeviceScanned: (deviceUuid) {
        setState(() => _showScanner = false);
        castNotifier.startCasting(deviceUuid);
      },
    );
  }

  Widget _buildControlView(
    dynamic castState,
    dynamic castNotifier,
    String? pcName,
  ) {
    final theme = Theme.of(context);

    if (castState.error != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(castState.error!),
            backgroundColor: theme.colorScheme.error,
          ),
        );
      });
    }

    return Column(
      children: [
        const SizedBox(height: 8),
        // 连接状态指示器
        Center(
          child: StatusIndicator(
            status: castState.connectionState,
            dotSize: 12,
          ),
        ),
        const SizedBox(height: 8),

        // 投屏控制面板
        Expanded(
          child: Center(
            child: CastControlPanel(
              isCasting: castState.isCasting,
              connectionState: castState.connectionState,
              pcDeviceName: pcName,
              onStartCast: () {
                // 如果已绑定设备，直接投屏；否则显示扫码器
                if (pcName != null) {
                  castNotifier.startCasting('');
                } else {
                  setState(() => _showScanner = true);
                }
              },
              onStopCast: () => castNotifier.stopCasting(),
              onQualityChanged: (quality) {
                // 投屏质量变更（可扩展）
              },
            ),
          ),
        ),
      ],
    );
  }
}
