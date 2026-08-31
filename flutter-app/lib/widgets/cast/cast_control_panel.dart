import 'package:flutter/material.dart';

/// 投屏控制面板
///
/// 显示开始/停止投屏按钮、捕获模式选择（屏幕/摄像）、
/// 摄像头前后切换、连接状态和投屏质量选择。
class CastControlPanel extends StatelessWidget {
  final bool isCasting;
  final String connectionState; // 'connecting' | 'connected' | 'disconnected'
  final String? pcDeviceName;
  final String? castQuality; // 'high' | 'medium' | 'low'
  final String captureMode; // 'screen' | 'camera'
  final bool frontCamera; // true=前置, false=后置
  /// 摄像头模式下是否同步手机声音到 Web 端
  final bool withAudio;
  final VoidCallback onStartCast;
  final VoidCallback onStopCast;
  final ValueChanged<String>? onQualityChanged;
  final VoidCallback? onSwitchToScreen;
  final VoidCallback? onSwitchToCamera;
  final VoidCallback? onToggleCamera;
  final VoidCallback? onToggleAudio;

  const CastControlPanel({
    super.key,
    this.isCasting = false,
    this.connectionState = 'disconnected',
    this.pcDeviceName,
    this.castQuality = 'high',
    this.captureMode = 'screen',
    this.frontCamera = true,
    this.withAudio = true,
    required this.onStartCast,
    required this.onStopCast,
    this.onQualityChanged,
    this.onSwitchToScreen,
    this.onSwitchToCamera,
    this.onToggleCamera,
    this.onToggleAudio,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 投屏状态图标
            Icon(
              captureMode == 'camera' ? Icons.camera_alt : Icons.cast,
              size: 64,
              color: isCasting
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),

            // 状态文字
            if (isCasting) ...[
              Text(
                captureMode == 'camera'
                    ? '正在传输手机摄像${pcDeviceName != null ? '到 $pcDeviceName' : ''}'
                    : '正在投屏${pcDeviceName != null ? '到 $pcDeviceName' : ''}',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 8),
              _buildConnectionStatus(theme, connectionState),
            ] else ...[
              Text(
                captureMode == 'camera' ? '手机摄像' : '准备投屏',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                captureMode == 'camera'
                    ? '将手机摄像头画面传输到 PC'
                    : '点击下方按钮开始将屏幕投射到 PC',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],

            const SizedBox(height: 20),

            // 捕获模式选择（仅在非投屏中可切换）
            if (!isCasting) ...[
              _buildCaptureModeSelector(theme),
              const SizedBox(height: 12),

              // 摄像头模式下显示前后切换与声音同步开关
              if (captureMode == 'camera') ...[
                _buildCameraToggle(theme),
                const SizedBox(height: 12),
                _buildAudioToggle(theme),
                const SizedBox(height: 12),
              ],
            ],

            // 投屏质量选择
            if (!isCasting && captureMode == 'screen') ...[
              _buildQualitySelector(theme),
              const SizedBox(height: 16),
            ],

            // 摄像头模式下已有摄像头切换
            if (!isCasting && captureMode == 'screen') ...[
              const SizedBox(height: 8),
            ],

            // 开始/停止按钮
            SizedBox(
              width: double.infinity,
              height: 48,
              child: isCasting
                  ? FilledButton.icon(
                      onPressed: onStopCast,
                      icon: const Icon(Icons.stop),
                      label: const Text('停止投屏'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: onStartCast,
                      icon: Icon(
                        captureMode == 'camera'
                            ? Icons.camera_alt
                            : Icons.screen_share,
                      ),
                      label: Text(
                        captureMode == 'camera' ? '开始传输摄像' : '开始投屏',
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCaptureModeSelector(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: _buildModeChip(
            theme: theme,
            icon: Icons.screen_share,
            label: '投屏',
            selected: captureMode == 'screen',
            onTap: onSwitchToScreen,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildModeChip(
            theme: theme,
            icon: Icons.camera_alt,
            label: '手机摄像',
            selected: captureMode == 'camera',
            onTap: onSwitchToCamera,
          ),
        ),
      ],
    );
  }

  Widget _buildModeChip({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required bool selected,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: selected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraToggle(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.camera_front,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Text('前置摄像头', style: theme.textTheme.bodySmall),
        const SizedBox(width: 8),
        Switch(
          value: !frontCamera, // false=前置, true=后置
          onChanged: (_) => onToggleCamera?.call(),
        ),
        const SizedBox(width: 8),
        Text('后置摄像头', style: theme.textTheme.bodySmall),
        const SizedBox(width: 8),
        Icon(
          Icons.camera_rear,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ],
    );
  }

  /// 声音同步开关 — 控制手机麦克风音频是否随画面一起传到 Web 端
  Widget _buildAudioToggle(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          withAudio ? Icons.mic : Icons.mic_off,
          size: 20,
          color: withAudio ? theme.colorScheme.primary : theme.colorScheme.outline,
        ),
        const SizedBox(width: 8),
        Text('同步手机声音', style: theme.textTheme.bodySmall),
        const SizedBox(width: 8),
        Switch(
          value: withAudio,
          onChanged: (_) => onToggleAudio?.call(),
        ),
      ],
    );
  }

  Widget _buildConnectionStatus(ThemeData theme, String state) {
    Color color;
    String text;

    switch (state) {
      case 'connecting':
        color = Colors.orange;
        text = '连接中...';
        break;
      case 'connected':
        color = Colors.green;
        text = '已连接';
        break;
      default:
        color = Colors.grey;
        text = '未连接';
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(color: color),
        ),
      ],
    );
  }

  Widget _buildQualitySelector(ThemeData theme) {
    const qualities = [
      {'value': 'high', 'label': '高画质', 'desc': '1080p'},
      {'value': 'medium', 'label': '中等', 'desc': '720p'},
      {'value': 'low', 'label': '低画质', 'desc': '480p'},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('投屏质量', style: theme.textTheme.labelLarge),
        const SizedBox(height: 8),
        Row(
          children: qualities.map((q) {
            final isSelected = q['value'] == castQuality;
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Column(
                    children: [
                      Text(q['label']!),
                      Text(
                        q['desc']!,
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                  selected: isSelected,
                  onSelected: (_) => onQualityChanged?.call(q['value']!),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
