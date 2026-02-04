import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../utils/error_utils.dart';

/// 通用错误页面组件
/// 显示语义化的错误提示，并提供查看详情和重试功能
class ErrorView extends StatelessWidget {
  const ErrorView({
    super.key,
    required this.error,
    this.stackTrace,
    this.onRetry,
    this.icon,
    this.iconSize = 48,
    this.title,
    this.showDetails = true,
  });

  /// 错误对象
  final Object error;

  /// 堆栈跟踪（可选）
  final StackTrace? stackTrace;

  /// 重试回调
  final VoidCallback? onRetry;

  /// 自定义图标
  final IconData? icon;

  /// 图标大小
  final double iconSize;

  /// 自定义标题（默认为"加载失败"）
  final String? title;

  /// 是否显示"查看详情"按钮
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final friendlyMessage = ErrorUtils.getFriendlyMessage(error);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? Icons.error_outline,
              size: iconSize,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              title ?? '加载失败',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              friendlyMessage,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (onRetry != null)
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试'),
                  ),
                if (showDetails)
                  OutlinedButton.icon(
                    onPressed: () => _showErrorDetails(context),
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: const Text('查看详情'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showErrorDetails(BuildContext context) {
    final details = ErrorUtils.getErrorDetails(error, stackTrace);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => ErrorDetailsSheet(details: details),
    );
  }
}

/// 错误详情底部弹窗
class ErrorDetailsSheet extends StatelessWidget {
  const ErrorDetailsSheet({
    super.key,
    required this.details,
  });

  final String details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Column(
        children: [
          // 顶部栏
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.bug_report_outlined,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Text(
                  '错误详情',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 20),
                  tooltip: '复制',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: details));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制到剪贴板'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          // 内容
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                details,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Sliver 版本的错误视图（用于 CustomScrollView）
class SliverErrorView extends StatelessWidget {
  const SliverErrorView({
    super.key,
    required this.error,
    this.stackTrace,
    this.onRetry,
    this.icon,
    this.iconSize = 48,
    this.title,
    this.showDetails = true,
  });

  final Object error;
  final StackTrace? stackTrace;
  final VoidCallback? onRetry;
  final IconData? icon;
  final double iconSize;
  final String? title;
  final bool showDetails;

  @override
  Widget build(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: ErrorView(
        error: error,
        stackTrace: stackTrace,
        onRetry: onRetry,
        icon: icon,
        iconSize: iconSize,
        title: title,
        showDetails: showDetails,
      ),
    );
  }
}
