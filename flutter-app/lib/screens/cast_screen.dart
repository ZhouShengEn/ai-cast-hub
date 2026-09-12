import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _CastScreenState extends ConsumerState<CastScreen>
    with WidgetsBindingObserver {
  /// 无障碍服务真实状态：unknown | enabled | settings_only | disabled
  String _accessibilityState = 'unknown';
  bool _checkingAccessibility = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 进入页面时刷新设备列表，并重置投屏状态为非投屏中
    Future.microtask(() {
      ref.read(deviceProvider.notifier).fetchDeviceList();
      final castState = ref.read(castProvider);
      // 如果投屏连接已断开但状态未重置，强制重置
      if (castState.connectionState == 'disconnected' && castState.isCasting) {
        ref.read(castProvider.notifier).stopCasting();
      }
      _refreshAccessibilityStatus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统设置页返回 App 时自动重新检测无障碍状态并刷新 UI
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshAccessibilityStatus();
    }
  }

  /// 重新检测无障碍服务是否真正生效
  Future<void> _refreshAccessibilityStatus() async {
    if (_checkingAccessibility) return;
    if (!mounted) return;
    setState(() => _checkingAccessibility = true);
    try {
      final s = await RemoteControlService().accessibilityState();
      if (!mounted) return;
      setState(() => _accessibilityState = s);
    } catch (_) {
      if (mounted) setState(() => _accessibilityState = 'unknown');
    } finally {
      if (mounted) setState(() => _checkingAccessibility = false);
    }
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

  /// 无障碍服务状态卡片
  ///
  /// 三态必须与「能否真正派发手势」一致：
  ///  - enabled        实例已绑定，远程控制可用
  ///  - settings_only  设置里开着但实例未绑定（未生效）→ 引导关闭再重新打开
  ///  - disabled       未开启 → 一键跳转系统设置并定位到本 App
  Widget _buildAccessibilityCard(ThemeData theme) {
    final Color color;
    final IconData icon;
    final String title;
    final String desc;
    switch (_accessibilityState) {
      case 'enabled':
        color = Colors.green;
        icon = Icons.check_circle;
        title = '无障碍服务：已生效';
        desc = 'Web 端可远程触控手机';
      case 'settings_only':
        color = Colors.orange;
        icon = Icons.warning_amber_rounded;
        title = '无障碍服务：已开启但未生效';
        desc = '请到「设置 → 无障碍」把 AI-Cast-Hub 关闭再重新打开一次';
      case 'disabled':
        color = Colors.redAccent;
        icon = Icons.error_outline;
        title = '无障碍服务：未开启';
        desc = '未开启时只能投屏，Web 端无法远程触控';
      default:
        color = Colors.grey;
        icon = Icons.help_outline;
        title = '无障碍服务：检测中…';
        desc = '正在确认服务是否真正可用';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
                if (_checkingAccessibility)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              desc,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            // 用 Wrap 替代 Row：两个按钮在窄屏会自动换行，避免横向溢出
            // （之前固定 Row 在卡片内宽度不足时右溢 34px）。
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: () async {
                    await RemoteControlService().openAccessibilitySettings();
                  },
                  icon: const Icon(Icons.settings_accessibility, size: 18),
                  label: const Text('前往开启无障碍模式'),
                ),
                OutlinedButton.icon(
                  onPressed: _refreshAccessibilityStatus,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('重新检测'),
                ),
              ],
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
        // 无障碍服务状态 + 前往开启入口（远程触控的唯一前置条件）
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: _buildAccessibilityCard(theme),
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
                  // ---- 开始投屏 ----
                  //
                  // 关键区分：**投屏本身不依赖无障碍服务**，MediaProjection 采集与推流
                  // 跟 AccessibilityService 毫无关系；只有「Web 端远程触控」依赖它。
                  //
                  // 检测改用「或」判定：服务实例已绑定(connected) 或 设置里已开启(settingsEnabled)。
                  // 取「或」而非「仅 settingsEnabled」的原因：部分国行 ROM（小米/OPPO/华为等）
                  // 的 getEnabledAccessibilityServiceList 不可靠、Settings.Secure 也无读取权限，
                  // 导致 settingsEnabled 恒为 false；但只要服务真的启用，系统必会绑定实例，
                  // 用 instance != null 判定最稳。之前只用 settingsEnabled 拦截，正是「明明开了
                  // 却一直提示去开启」的根因。
                  //
                  // 兜底策略：两者都检测不到时，只引导一次（SharedPreferences 记忆），
                  // 之后不再反复阻断，直接开始投屏（远程触控可能不可用，仅给非阻断提示）。
                  final remote = RemoteControlService();
                  final serviceUsable = await remote.checkServiceEnabled();
                  final connected = await remote.checkServiceConnected();

                  if (!serviceUsable) {
                    final guidedBefore = await _accessibilityGuidedOnce();
                    if (!guidedBefore) {
                      // 记录「已引导过」，保证以后即使仍检测不到也只放行进、不再弹窗
                      await _markAccessibilityGuided();
                      final goSettings = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('需要开启无障碍服务'),
                          content: const Text(
                            '投屏的远程控制功能需要无障碍服务。'
                            '请前往「设置 → 无障碍」开启 AI Cast Hub 的无障碍权限。',
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
                      await remote.openAccessibilitySettings();
                      // 从设置返回后【不自动启动投屏】—— 需用户手动再点一次，
                      // 避免用户还在系统设置页时 App 已在后台偷偷拉起 MediaProjection 授权。
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请在开启无障碍服务后，再次点击「开始投屏」')),
                        );
                      }
                      return;
                    }

                    // 兜底：已引导过仍检测不到 → 直接投屏，不再反复引导
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            '未能确认无障碍服务状态：本次仍可直接投屏，'
                            '但 Web 端远程触控可能不可用。',
                          ),
                          duration: Duration(seconds: 5),
                        ),
                      );
                    }
                  } else if (!connected && mounted) {
                    // 设置里已开启但实例尚未绑定到本进程：不阻断投屏，仅提示远程触控可能无效
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          '无障碍服务已开启但尚未生效：本次可以正常投屏，'
                          '但 Web 端远程触控可能无效。如需使用，请到「设置 → 无障碍」'
                          '把 AI Cast Hub 关闭再重新打开一次。',
                        ),
                        duration: Duration(seconds: 5),
                      ),
                    );
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

  /// 无障碍服务引导是否「已经引导过一次」。
  ///
  /// 用于兜底：检测不到无障碍服务时只弹一次引导窗，之后即便仍检测不到也直接放行投屏，
  /// 不再反复打断用户（部分国行 ROM 检测接口不可靠，但投屏本身不需要它）。
  static const String _kAccessibilityGuided = 'accessibility_guided_once';
  Future<bool> _accessibilityGuidedOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kAccessibilityGuided) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 记录「已引导过一次」，下次检测不到时不再弹窗。
  Future<void> _markAccessibilityGuided() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAccessibilityGuided, true);
    } catch (_) {
      // 持久化失败不影响本次投屏，仅失去「只引导一次」的记忆
    }
  }
}
