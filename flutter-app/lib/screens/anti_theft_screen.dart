import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/anti_theft_provider.dart';

/// 设备防盗页
///
/// 对设备持有者**完全可见**：展示当前被远程触发的行为（响铃 / 位置共享 /
/// 丢失模式），提供一键停止入口，并列出所有远程指令的操作日志。
class AntiTheftScreen extends ConsumerWidget {
  const AntiTheftScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final state = ref.watch(antiTheftProvider);
    final notifier = ref.read(antiTheftProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: const Text('设备防盗')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 合规说明
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withOpacity(0.4),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.verified_user_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '仅已配对的 PC 可下发指令。所有远程操作都会在此显示，'
                    '并可在下方随时停止。',
                    style: TextStyle(fontSize: 12.5, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // 当前状态
          _sectionTitle('当前状态'),
          const SizedBox(height: 8),
          _statusCard(context, state),
          const SizedBox(height: 16),

          // 停止控制
          _sectionTitle('停止控制'),
          const SizedBox(height: 8),
          _controlButtons(context, state, notifier),
          if (state.lastError != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(state.lastError!,
                  style: TextStyle(color: Colors.red.shade700, fontSize: 12.5)),
            ),
          ],
          const SizedBox(height: 24),

          // 操作日志
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _sectionTitle('操作日志'),
              TextButton(
                onPressed:
                    state.logs.isEmpty ? null : () => notifier.clearLogs(),
                child: const Text('清空', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _logsList(context, state),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    );
  }

  Widget _statusCard(BuildContext context, AntiTheftState state) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          children: [
            _statusRow('响铃中', state.alarmRinging,
                state.alarmRinging ? '正在播放铃声' : '未在响铃'),
            const Divider(height: 1),
            _statusRow('位置共享中', state.locationSharing,
                state.locationSharing ? '前台通知可见，周期上报' : '未共享位置'),
            const Divider(height: 1),
            _statusRow('丢失模式', state.lostMode,
                state.lostMode ? '设备已标记为丢失' : '正常'),
          ],
        ),
      ),
    );
  }

  Widget _statusRow(String label, bool active, String subtitle) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        active ? Icons.radio_button_checked : Icons.radio_button_off,
        color: active ? Colors.orange : Colors.grey,
      ),
      title: Text(label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: active
          ? const Chip(
              label: Text('进行中', style: TextStyle(fontSize: 11)),
              backgroundColor: Color(0xFFFFF3E0),
            )
          : null,
    );
  }

  Widget _controlButtons(
    BuildContext context,
    AntiTheftState state,
    AntiTheftNotifier notifier,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.alarmRinging)
          ElevatedButton.icon(
            onPressed: () => notifier.stopAlarm(),
            icon: const Icon(Icons.alarm_off),
            label: const Text('停止响铃'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
          ),
        if (state.alarmRinging) const SizedBox(height: 8),
        if (state.locationSharing)
          ElevatedButton.icon(
            onPressed: () => notifier.stopLocationTrack(),
            icon: const Icon(Icons.location_off),
            label: const Text('停止共享位置'),
          ),
        if (state.locationSharing) const SizedBox(height: 8),
        if (state.lostMode)
          ElevatedButton.icon(
            onPressed: () => notifier.exitLostMode(),
            icon: const Icon(Icons.lock_open),
            label: const Text('解除丢失模式'),
          ),
        if (state.lostMode) const SizedBox(height: 8),
        if (!state.isIdle)
          OutlinedButton.icon(
            onPressed: () => notifier.stopAll(),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('全部停止'),
          ),
        if (state.isIdle)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '当前没有被远程触发的行为',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _logsList(BuildContext context, AntiTheftState state) {
    if (state.logs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text('暂无操作记录',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
        ),
      );
    }
    return Card(
      child: ListView.separated(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: state.logs.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, i) {
          final log = state.logs[i];
          final time = DateTime.tryParse(log['timestamp'] as String? ?? '');
          final source = (log['sourceDeviceUuid'] as String? ?? '');
          final sourceShort =
              source.length >= 8 ? '${source.substring(0, 8)}…' : source;
          return ListTile(
            dense: true,
            title: Text(log['note'] as String? ?? '',
                style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              '${_fmt(time)} · 来源 ${sourceShort.isEmpty ? "本机" : sourceShort}',
              style: const TextStyle(fontSize: 11, color: Colors.black45),
            ),
          );
        },
      ),
    );
  }

  String _fmt(DateTime? t) {
    if (t == null) return '未知时间';
    return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

/// 丢失模式覆盖层
///
/// 设备被标记为丢失后全屏展示，提示拾到者联系机主，并提供解除入口。
/// 这是 App 级锁定（非系统锁屏）：不做静默锁定，用户始终知情。
class LostModeOverlay extends StatelessWidget {
  const LostModeOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.88),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 64, color: Colors.orange),
              const SizedBox(height: 16),
              const Text(
                '此设备已被标记为丢失',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const Text(
                '如果你不是机主，请联系机主归还设备。'
                '机主可在本页解除丢失模式。',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.pushNamed(context, '/anti-theft'),
                child: const Text('查看详情 / 解除'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
