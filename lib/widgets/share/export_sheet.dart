import 'package:flutter/material.dart';
import '../../models/topic.dart';
import '../../services/toast_service.dart';
import '../../utils/export_utils.dart';

/// 导出选项 Sheet
class ExportSheet extends StatefulWidget {
  /// 话题详情
  final TopicDetail detail;

  const ExportSheet({
    super.key,
    required this.detail,
  });

  /// 显示导出 Sheet
  static Future<void> show(BuildContext context, TopicDetail detail) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => ExportSheet(detail: detail),
    );
  }

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  ExportScope _scope = ExportScope.firstPostOnly;
  ExportFormat _format = ExportFormat.markdown;
  bool _isExporting = false;
  int _progress = 0;
  int _total = 0;

  /// 获取话题的总帖子数
  int get _totalPostsCount => widget.detail.postStream.stream.length;

  /// 判断 Markdown 导出是否会被限制
  bool get _willBeLimited =>
      _format == ExportFormat.markdown &&
      _scope == ExportScope.allPosts &&
      _totalPostsCount > ExportUtils.maxMarkdownPosts;

  Future<void> _export() async {
    if (_isExporting) return;
    setState(() {
      _isExporting = true;
      _progress = 0;
      _total = 0;
    });

    try {
      await ExportUtils.exportTopic(
        detail: widget.detail,
        scope: _scope,
        format: _format,
        onProgress: (current, total) {
          if (mounted) {
            setState(() {
              _progress = current;
              _total = total;
            });
          }
        },
      );
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ToastService.showError('导出失败: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 顶部拖动条
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // 标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '导出文章',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

            const SizedBox(height: 20),

            // 导出范围选择
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '导出范围',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ExportScope>(
                segments: const [
                  ButtonSegment(
                    value: ExportScope.firstPostOnly,
                    label: Text('仅主帖'),
                    icon: Icon(Icons.article_outlined),
                  ),
                  ButtonSegment(
                    value: ExportScope.allPosts,
                    label: Text('全部'),
                    icon: Icon(Icons.forum_outlined),
                  ),
                ],
                selected: {_scope},
                onSelectionChanged: (selected) {
                  setState(() => _scope = selected.first);
                },
              ),
            ),

            const SizedBox(height: 20),

            // 导出格式选择
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                '导出格式',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<ExportFormat>(
                segments: const [
                  ButtonSegment(
                    value: ExportFormat.markdown,
                    label: Text('MD'),
                    icon: Icon(Icons.code),
                  ),
                  ButtonSegment(
                    value: ExportFormat.html,
                    label: Text('HTML'),
                    icon: Icon(Icons.html),
                  ),
                ],
                selected: {_format},
                onSelectionChanged: (selected) {
                  setState(() => _format = selected.first);
                },
              ),
            ),

            // Markdown 限制提示
            if (_willBeLimited) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Markdown 格式最多导出前 ${ExportUtils.maxMarkdownPosts} 条帖子',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),

            // 导出按钮
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: _isExporting ? null : _export,
                icon: _isExporting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.download),
                label: Text(_isExporting
                    ? (_total > 0 ? '导出中 ($_progress/$_total)' : '导出中...')
                    : '导出'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),

            SizedBox(height: 16 + bottomPadding),
          ],
        ),
      ),
    );
  }
}
