import 'package:flutter/material.dart';

import '../../utils/constants.dart';

/// 侧边抽屉导航
///
/// 包含 5 个主要导航项：首页、对话、投屏、文件、设置。
class AppDrawer extends StatelessWidget {
  final String currentRoute;

  const AppDrawer({
    super.key,
    this.currentRoute = '/',
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            // 头部
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.hub,
                    size: 40,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    AppConstants.appName,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '跨设备 AI 协作平台',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // 导航项
            _NavItem(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home,
              label: '首页',
              isSelected: currentRoute == '/',
              onTap: () => _navigate(context, '/'),
            ),
            _NavItem(
              icon: Icons.chat_bubble_outline,
              selectedIcon: Icons.chat_bubble,
              label: '对话',
              isSelected: currentRoute == '/chat',
              onTap: () => _navigate(context, '/chat'),
            ),
            _NavItem(
              icon: Icons.screen_share_outlined,
              selectedIcon: Icons.screen_share,
              label: '投屏',
              isSelected: currentRoute == '/cast',
              onTap: () => _navigate(context, '/cast'),
            ),
            _NavItem(
              icon: Icons.folder_outlined,
              selectedIcon: Icons.folder,
              label: '文件传输',
              isSelected: currentRoute == '/file',
              onTap: () => _navigate(context, '/file'),
            ),
            _NavItem(
              icon: Icons.settings_outlined,
              selectedIcon: Icons.settings,
              label: '设置',
              isSelected: currentRoute == '/settings',
              onTap: () => _navigate(context, '/settings'),
            ),

            const Spacer(),

            // 底部版本信息
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'v${AppConstants.appVersion}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _navigate(BuildContext context, String route) {
    if (route == currentRoute) {
      Navigator.pop(context); // 关闭抽屉
      return;
    }
    Navigator.pop(context);
    Navigator.pushReplacementNamed(context, route);
  }
}

/// 单个导航项
class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: isSelected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
          : Colors.transparent,
      borderRadius: const BorderRadius.horizontal(
        right: Radius.circular(28),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.horizontal(
          right: Radius.circular(28),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(
                isSelected ? selectedIcon : icon,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 16),
              Text(
                label,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
