import 'dart:math';

////// 通用扩展方法集合
/// DateTime 扩展、文件大小格式化、字符串工具等。

/// DateTime 扩展：中文时间描述
extension DateTimeExtension on DateTime {
  /// 返回中文时间描述，如 "刚刚"、"5分钟前"、"昨天 14:30"
  String timeAgo() {
    final now = DateTime.now();
    final diff = now.difference(this);

    if (diff.inSeconds < 60) {
      return '刚刚';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes}分钟前';
    } else if (diff.inHours < 24) {
      return '${diff.inHours}小时前';
    } else if (diff.inDays == 1) {
      return '昨天 ${_formatTime()}';
    } else if (diff.inDays < 7) {
      return '${diff.inDays}天前';
    } else {
      return '$year-${month.toString().padLeft(2, '0')}-${day.toString().padLeft(2, '0')}';
    }
  }

  /// 格式化 HH:mm
  String _formatTime() {
    return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
  }

  /// 格式化时间部分 HH:mm
  String formatTime() => _formatTime();
}

/// int 扩展：文件大小格式化
extension FileSizeExtension on int {
  /// 返回可读的文件大小，如 "1.2 MB"、"3.5 GB"
  String fileSize() {
    if (this < 1024) {
      return '$this B';
    } else if (this < 1024 * 1024) {
      return '${(this / 1024).toStringAsFixed(1)} KB';
    } else if (this < 1024 * 1024 * 1024) {
      return '${(this / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(this / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}

/// String 扩展：验证和截断
extension StringExtension on String {
  /// 简单 UUID 格式校验
  bool isValidUuid() {
    final uuidRegex = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    );
    return uuidRegex.hasMatch(this);
  }

  /// 截断字符串到指定长度，超出部分用 "..." 替代
  String truncate(int maxLength) {
    if (length <= maxLength) return this;
    return '${substring(0, min(maxLength, length))}...';
  }
}
