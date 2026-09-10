import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/cast_provider.dart';
import '../providers/device_provider.dart';
import '../services/remote_control_service.dart';
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
    // 进入页面时刷新设备列表，并重置投屏状态为非投屏中
    Future.microtask(() {
      ref.read(deviceProvider.notifier).fetchDeviceList();
      final castState = ref.read(castProvider);
      // 如果投屏连接已断开但状态未重置，强制重置
      if (castState.connectionState == 'disconnected' && castState.isCasting) {
        ref.read(castProvider.notifier).stopCasting();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final castState = ref.watch(castProvider);
    final deviceState = ref.watch(deviceProvider);
    final castNotifier = ref.read(castProvider.notifier);

    final theme = Theme.of(context);

    // 获取第一个已绑定 PC 名称和在线状态
    final firstDevice = deviceState.pairedDevices.isNotEmpty
        ? deviceState.pairedDevices.first
        : null;
    final pcName = firstDevice?.deviceName;
    final pcOnline = firstDevice?.isOnline() ?? false;

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
          : _buildControlView(castState, castNotifier, pcName, pcOnline, theme),
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
    bool pcOnline,
    ThemeData theme,
  ) {
    return Column(
      children: [
        const SizedBox(height: 16),
        // 已绑定的 PC 信息（显示实际在线状态）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
            child: ListTile(
              leading: Icon(Icons.computer,
                color: pcOnline ? Colors.green : Colors.grey,
              ),
              title: Text(pcName ?? 'PC 设备'),
              subtitle: Text(pcOnline ? '已绑定 · 可投屏' : '已离线'),
              trailing: Icon(Icons.cast_connected,
                color: pcOnline ? Colors.green : Colors.grey,
              ),
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
          child: SingleChildScrollView(
            child: CastControlPanel(
              isCasting: castState.isCasting,
              connectionState: castState.connectionState,
              pcDeviceName: pcName,
              captureMode: castState.captureMode,
              frontCamera: castState.frontCamera,
              withAudio: castState.withAudio,
              onSwitchToScreen: () => castNotifier.setScreenMode(),
              onSwitchToCamera: () => castNotifier.setCameraMode(),
              onToggleCamera: () => castNotifier.toggleCamera(),
              onToggleAudio: () => castNotifier.toggleAudio(),
              onStartCast: () async {
                if (pcName == null) return;
                if (!pcOnline) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('PC 设备已离线，无法开始投屏')),
                  );
                  return;
                }

                final isCameraMode = castState.captureMode == 'camera';

                // 权限校验严格分流：摄像模式与投屏模式不再共用一套判断。
                if (isCameraMode) {
                  // ---- 传输摄像：完全不依赖无障碍服务，只校验摄像头权限 ----
                  final granted = await _ensureCameraPermission();
                  if (!granted) return;
                } else {
                  // ---- 开始投屏：远程触控依赖无障碍服务，必须先确保可用 ----
                  // 用 checkServiceConnected 而非宽松的 checkServiceEnabled：
                  // 后者「设置里开着」也会返回 true，但实例未绑定时手势根本派发不出去。
                  final connected = await RemoteControlService().checkServiceConnected();
                  if (!connected) {
                    final settingsOn = await RemoteControlService().isEnabledInSettings();
                    final goSettings = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('需要开启无障碍服务'),
                        content: Text(
                          settingsOn
                              ? '无障碍服务已在设置中开启，但尚未生效（常见于服务被系统回收或配置更新后）。'
                                '请前往「设置 → 无障碍」把 AI Cast Hub 关闭再重新打开一次。'
                              : '投屏的远程控制功能需要无障碍服务。请前往「设置 → 无障碍」开启 AI Cast Hub 的无障碍权限。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('去设置'),
                          ),
                        ],
                      ),
                    );
                    if (goSettings != true) return;
                    await RemoteControlService().openAccessibilitySettings();
                    // 从设置返回后【不自动启动投屏】—— 需用户手动再点一次「开始投屏」，
                    // 避免用户在系统设置页时 App 已在后台偷偷拉起 MediaProjection 授权。
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('请在开启无障碍服务后，再次点击「开始投屏」')),
                      );
                    }
                    return;
                  }
                }

                final deviceState = ref.read(deviceProvider);
                if (deviceState.pairedDevices.isNotEmpty) {
                  try {
                    await castNotifier.startCasting(
                      deviceState.pairedDevices.first.deviceUuid,
                    );
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('投屏失败: $e'),
                          backgroundColor: Theme.of(context).colorScheme.error,
                        ),
                      );
                    }
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

  /// 传输摄像专用权限校验：只管摄像头，完全不涉及无障碍服务。
  ///
  /// 与「开始投屏」的权限逻辑彻底分离——摄像采集推流依赖 MediaProjection/相机，
  /// 不需要 AccessibilityService，若沿用投屏那套检测会误导用户去开一个用不上的权限。
  ///
  /// 返回 true 表示已获授权可继续；false 表示被拒绝且已给出引导。
  Future<bool> _ensureCameraPermission() async {
    final status = await Permission.camera.status;
    if (status.isGranted) return true;

    final requested = await Permission.camera.request();
    if (requested.isGranted) return true;

    if (!mounted) return false;
    final permanentlyDenied = requested.isPermanentlyDenied;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          permanentlyDenied
              ? '摄像头权限被永久拒绝，请在系统设置中开启后重试'
              : '需要摄像头权限才能传输摄像',
        ),
      ),
    );
    // 永久拒绝时系统不再弹框，只能引导用户去设置页手动开启
    if (permanentlyDenied) {
      await openAppSettings();
    }
    return false;
  }
}
