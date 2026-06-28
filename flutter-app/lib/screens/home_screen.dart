import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_provider.dart';
import '../providers/message_provider.dart';
import '../services/local_storage.dart';
import '../services/local_storage.dart';
import '../models/device.dart';
import '../utils/extensions.dart';

/// 首页 — 设备状态、已绑定 PC 列表、连接码绑定入口
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Timer? _deviceRefreshTimer;

  @override
  void initState() {
    super.initState();
    // 先尝试获取已有设备信息，仅当设备未注册时才注册
    Future.microtask(() async {
      final notifier = ref.read(deviceProvider.notifier);
      final storage = LocalStorage.instance;

      // 首次安装：没有 UUID 则直接注册，避免 fetchDeviceInfo 吞掉异常
      final uuid = storage.getDeviceUuid();
      if (uuid == null || uuid.isEmpty) {
        // 等待 500ms 确保网络初始化完成
        await Future.delayed(const Duration(milliseconds: 500));
        await notifier.registerDevice();
        return;
      }

      try {
        await notifier.fetchDeviceInfo();
        await notifier.fetchDeviceList();
      } catch (_) {
        // 设备未注册或网络不通，尝试注册
        await notifier.registerDevice();
      }
    });
    // 启动消息监听（被动接收PC端连接邀请），App启动时就开始监听
    Future.microtask(() async {
      await ref.read(messageProvider.notifier).startListening();
    });
    // 每 60 秒刷新一次设备在线状态，保持与服务器同步
    _deviceRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      ref.read(deviceProvider.notifier).fetchDeviceList();
    });
  }

  @override
  void dispose() {
    _deviceRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceState = ref.watch(deviceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Cast Hub'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      drawer: null, // 首页不需要抽屉，功能入口在主界面
      body: RefreshIndicator(
        onRefresh: () async {
          await ref.read(deviceProvider.notifier).fetchDeviceInfo();
          await ref.read(deviceProvider.notifier).fetchDeviceList();
        },
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // 设备状态卡片
            _buildDeviceCard(theme, deviceState),

            // 连接失败提示（任何时候错误都显示）
            if (deviceState.error != null)
              _buildNetworkTip(theme),

            const SizedBox(height: 24),

            // 已绑定 PC 列表
            _buildPairedDevicesSection(theme, deviceState),
            const SizedBox(height: 24),

            // 功能入口
            Text('功能', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildFeatureCard(
              context,
              icon: Icons.chat_bubble_outline,
              title: 'AI 对话',
              subtitle: '与 AI 助手进行对话',
              route: '/chat',
            ),
            const SizedBox(height: 12),
            _buildFeatureCard(
              context,
              icon: Icons.cast,
              title: '投屏',
              subtitle: '将屏幕投射到 PC 端',
              route: '/cast',
            ),
            const SizedBox(height: 12),
            _buildFeatureCard(
              context,
              icon: Icons.message_outlined,
              title: '消息',
              subtitle: '发送消息和文件到 PC',
              route: '/message',
              badgeCount: ref.watch(messageProvider).unreadCount,
            ),
            const SizedBox(height: 12),
            _buildFeatureCard(
              context,
              icon: Icons.network_ping,
              title: '网络工具',
              subtitle: 'Ping 测试 · 查看本机 IP',
              route: '/network-tools',
            ),
          ],
        ),
      ),
      // FAB: 输入连接码
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final result = await Navigator.pushNamed(context, '/scan');
          // 绑定成功后刷新设备列表
          if (result == true) {
            ref.read(deviceProvider.notifier).fetchDeviceList();
          }
        },
        icon: const Icon(Icons.link),
        label: const Text('输入连接码'),
      ),
    );
  }

  /// 设备状态卡片
  Widget _buildDeviceCard(ThemeData theme, DeviceState state) {
    if (state.isLoading && state.device == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text('正在注册设备...', style: theme.textTheme.bodyMedium),
              ],
            ),
          ),
        ),
      );
    }

    final device = state.device;
    final isOnline = device?.isOnline() ?? false;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  device?.platform == 'ios' ? Icons.phone_iphone : Icons.phone_android,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                if (device != null)
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: isOnline ? Colors.green : Colors.grey,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              device?.deviceName ?? '未注册',
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            if (device != null && !state.hasPairedDevice) ...[
              Text(
                '输入 PC 端连接码完成设备绑定',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
            if (state.hasPairedDevice)
              Text(
                '已绑定 ${state.pairedDevices.length} 台设备',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            if (state.error != null) ...[
              const SizedBox(height: 8),
              Text(
                state.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 网络连接失败提示卡片
  Widget _buildNetworkTip(ThemeData theme) {
    final storage = LocalStorage.instance;
    final serverUrl = storage.getServerUrl();
    return Card(
      color: theme.colorScheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wifi_off, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Text('无法连接到服务器', style: TextStyle(color: theme.colorScheme.error, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '当前地址: $serverUrl\n请确保手机和 PC 在同一局域网，然后在设置中修改为 PC 的 IP 地址',
              style: TextStyle(color: theme.colorScheme.onErrorContainer, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      ref.read(deviceProvider.notifier).registerDevice();
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => Navigator.pushNamed(context, '/settings'),
                    icon: const Icon(Icons.settings, size: 18),
                    label: const Text('设置服务器'),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 已绑定 PC 列表
  Widget _buildPairedDevicesSection(ThemeData theme, DeviceState state) {
    if (!state.hasPairedDevice) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('已绑定设备', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        ...state.pairedDevices.map((device) => Card(
              child: ListTile(
                leading: Icon(
                  Icons.computer,
                  color: device.isOnline() ? Colors.green : Colors.grey,
                ),
                title: Text(device.deviceName),
                subtitle: Text(
                  device.isOnline() ? '在线' : '离线 — ${device.lastSeenAt.timeAgo()}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  _showDeviceDetail(device);
                },
              ),
            )),
      ],
    );
  }

  void _showDeviceDetail(Device device) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(device.deviceName),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailRow('平台', device.platform),
            _detailRow('UUID', device.deviceUuid.truncate(30)),
            _detailRow('状态', device.isOnline() ? '在线' : '离线'),
            _detailRow('最后活跃', device.lastSeenAt.timeAgo()),
          ],
        ),
        actions: [
          // 解除绑定按钮
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _confirmUnbind(device);
            },
            child: const Text('解除绑定', style: TextStyle(color: Colors.red)),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 确认解除绑定对话框
  void _confirmUnbind(Device device) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认解除绑定'),
        content: Text('确定要解除与「${device.deviceName}」的绑定吗？\n\n解除后需要重新输入连接码绑定才能恢复连接。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(deviceProvider.notifier).unbindDevice(device.deviceUuid);
            },
            child: const Text('确定解除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              '$label:',
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildFeatureCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String route,
    int badgeCount = 0,
  }) {
    final theme = Theme.of(context);

    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        leading: Icon(icon, size: 32, color: theme.colorScheme.primary),
        title: Row(
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            if (badgeCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badgeCount > 99 ? '99+' : badgeCount.toString(),
                  style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.pushNamed(context, route),
      ),
    );
  }
}
