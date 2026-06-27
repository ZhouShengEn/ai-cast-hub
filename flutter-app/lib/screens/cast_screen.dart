import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/cast_provider.dart';
import '../providers/device_provider.dart';
import '../widgets/cast/cast_control_panel.dart';
import '../widgets/cast/status_indicator.dart';

/// 投屏页面 — 选择已绑定 PC 并投屏
///
/// 此页面只负责投屏控制，不包含绑定功能。
/// 绑定请使用首页的"输入连接码"按钮（/scan 路由）。
class CastScreen extends ConsumerStatefulWidget {
  const CastScreen({super.key});

  @override
  ConsumerState<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends ConsumerState<CastScreen> {
  @override
  void initState() {
    super.initState();
    // 进入页面时刷新设备列表
    Future.microtask(() {
      ref.read(deviceProvider.notifier).fetchDeviceList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    final deviceState = ref.watch(deviceProvider);
    final castNotifier = ref.read(castProvider.notifier);

    final theme = Theme.of(context);

    // 获取第一个已绑定 PC 名称
    final pcName = deviceState.pairedDevices.isNotEmpty
        ? deviceState.pairedDevices.first.deviceName
        : null;

    // 错误提示（使用 addPostFrameCallback 避免 build 期间调用 SnackBar，且防止重复弹出）
    ref.listen(castProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(next.error!),
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
            );
          }
        });
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('投屏'),
      ),
      body: deviceState.pairedDevices.isEmpty
          ? _buildNoDeviceView(theme)
          : _buildControlView(castState, castNotifier, pcName, theme),
    );
  }

  /// 未绑定任何 PC 设备的提示视图
  Widget _buildNoDeviceView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.devices_other,
              size: 80,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              '尚未绑定任何 PC 设备',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '请返回首页点击"输入连接码"按钮，\n在 PC 端查看连接码并输入完成绑定后再使用投屏功能',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () async {
                final result = await Navigator.pushNamed(context, '/scan');
                if (result == true) {
                  ref.read(deviceProvider.notifier).fetchDeviceList();
                }
              },
              icon: const Icon(Icons.link),
              label: const Text('去输入连接码'),
            ),
          ],
        ),
      ),
    );
  }

  /// 投屏控制视图
  Widget _buildControlView(
    dynamic castState,
    dynamic castNotifier,
    String? pcName,
    ThemeData theme,
  ) {
    return Column(
      children: [
        const SizedBox(height: 16),
        // 已绑定的 PC 信息
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.computer, color: Colors.green),
              title: Text(pcName ?? 'PC 设备'),
              subtitle: const Text('已绑定 · 可投屏'),
              trailing: const Icon(Icons.cast_connected, color: Colors.green),
            ),
          ),
        ),
        const SizedBox(height: 16),
        // 连接状态指示器
        Center(
          child: StatusIndicator(
            status: castState.connectionState,
            dotSize: 12,
          ),
        ),
        const SizedBox(height: 24),
        // 投屏控制面板
        Expanded(
          child: Center(
            child: CastControlPanel(
              isCasting: castState.isCasting,
              connectionState: castState.connectionState,
              pcDeviceName: pcName,
              onStartCast: () {
                // 直接开始投屏（已绑定设备）
                if (pcName != null) {
                  // 使用已绑定设备的 UUID
                  final deviceState = ref.read(deviceProvider);
                  if (deviceState.pairedDevices.isNotEmpty) {
                    castNotifier.startCasting(
                      deviceState.pairedDevices.first.deviceUuid,
                    );
                  }
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
