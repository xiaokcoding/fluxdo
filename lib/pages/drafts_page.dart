import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/draft.dart';
import '../providers/discourse_providers.dart';
import '../services/discourse/discourse_service.dart';
import '../widgets/common/skeleton.dart';
import '../widgets/common/error_view.dart';
import '../widgets/post/reply_sheet.dart';
import '../utils/time_utils.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'create_topic_page.dart';

/// 草稿列表 Provider
final draftsProvider = FutureProvider.autoDispose<List<Draft>>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  final response = await service.getDrafts();
  return response.drafts;
});

/// 草稿列表页面
class DraftsPage extends ConsumerStatefulWidget {
  const DraftsPage({super.key});

  @override
  ConsumerState<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends ConsumerState<DraftsPage> {
  @override
  Widget build(BuildContext context) {
    final draftsAsync = ref.watch(draftsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('我的草稿')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(draftsProvider);
          await ref.read(draftsProvider.future);
        },
        child: draftsAsync.when(
          data: (drafts) {
            if (drafts.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.drafts_outlined, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('暂无草稿', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              );
            }

            return ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: drafts.length,
              itemBuilder: (context, index) {
                final draft = drafts[index];
                return _DraftCard(
                  draft: draft,
                  onTap: () => _onDraftTap(draft),
                  onDelete: () => _onDraftDelete(draft),
                );
              },
            );
          },
          loading: () => const _DraftsListSkeleton(),
          error: (error, stack) => ErrorView(
            error: error,
            stackTrace: stack,
            onRetry: () => ref.invalidate(draftsProvider),
          ),
        ),
      ),
    );
  }

  /// 点击草稿
  Future<void> _onDraftTap(Draft draft) async {
    final draftKey = draft.draftKey;

    if (draftKey == Draft.newTopicKey) {
      // 新话题草稿：进入创建话题页面
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const CreateTopicPage()),
      );
    } else if (draftKey == Draft.newPrivateMessageKey) {
      // 私信草稿：直接弹出回复框
      final recipients = draft.data.recipients;
      if (recipients != null && recipients.isNotEmpty) {
        await showReplySheet(
          context: context,
          targetUsername: recipients.first,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('私信草稿数据不完整')),
        );
        return; // 不刷新
      }
    } else if (draftKey.startsWith('topic_')) {
      // 解析话题 ID 和帖子编号
      int? topicId;
      int? replyToPostNumber;

      if (draft.isPostReply) {
        // 帖子回复草稿：topic_{topicId}_post_{postNumber}
        final match = RegExp(r'^topic_(\d+)_post_(\d+)$').firstMatch(draftKey);
        if (match != null) {
          topicId = int.tryParse(match.group(1)!);
          replyToPostNumber = int.tryParse(match.group(2)!);
        }
      } else {
        // 话题回复草稿：topic_{topicId}
        topicId = draft.topicId ?? int.tryParse(draftKey.replaceFirst('topic_', ''));
      }

      if (topicId != null) {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TopicDetailPage(
              topicId: topicId!,
              scrollToPostNumber: replyToPostNumber, // 跳转到对应帖子
              autoOpenReply: true,
              autoReplyToPostNumber: replyToPostNumber,
            ),
          ),
        );
      } else {
        return; // 不刷新
      }
    } else {
      return; // 不刷新
    }

    // 返回后刷新草稿列表
    if (mounted) {
      ref.invalidate(draftsProvider);
    }
  }

  /// 删除草稿
  Future<void> _onDraftDelete(Draft draft) async {
    final confirm = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        bool isDeleting = false;
        return StatefulBuilder(
          builder: (dialogContext, setState) => AlertDialog(
            title: const Text('删除草稿'),
            content: const Text('确定要删除这个草稿吗？'),
            actions: [
              TextButton(
                onPressed: isDeleting ? null : () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: isDeleting
                    ? null
                    : () async {
                        setState(() => isDeleting = true);
                        try {
                          await DiscourseService().deleteDraft(
                            draft.draftKey,
                            sequence: draft.sequence,
                          );
                          if (dialogContext.mounted) Navigator.pop(dialogContext, true);
                        } catch (e) {
                          if (dialogContext.mounted) {
                            setState(() => isDeleting = false);
                            ScaffoldMessenger.of(dialogContext).showSnackBar(
                              SnackBar(content: Text('删除失败: $e')),
                            );
                          }
                        }
                      },
                child: isDeleting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('删除'),
              ),
            ],
          ),
        );
      },
    );

    if (confirm == true && mounted) {
      ref.invalidate(draftsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('草稿已删除')),
      );
    }
  }
}

/// 草稿卡片
class _DraftCard extends StatelessWidget {
  final Draft draft;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _DraftCard({
    required this.draft,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = draft.data;

    // 确定草稿类型
    String typeLabel;
    IconData typeIcon;

    if (draft.draftKey == Draft.newTopicKey) {
      typeLabel = '新话题';
      typeIcon = Icons.add_circle_outline;
    } else if (draft.draftKey == Draft.newPrivateMessageKey) {
      typeLabel = '私信';
      typeIcon = Icons.mail_outline;
    } else if (draft.draftKey.startsWith('topic_')) {
      // 区分回复话题和回复帖子
      if (data.replyToPostNumber != null && data.replyToPostNumber! > 0) {
        typeLabel = '回复 #${data.replyToPostNumber}';
      } else {
        typeLabel = '回复';
      }
      typeIcon = Icons.reply_outlined;
    } else {
      typeLabel = '草稿';
      typeIcon = Icons.drafts_outlined;
    }

    // 使用 displayTitle 获取标题
    final title = draft.displayTitle;
    final content = data.reply;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 类型标签、时间和删除按钮
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          typeIcon,
                          size: 14,
                          color: theme.colorScheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          typeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 更新时间
                  if (draft.updatedAt != null)
                    Text(
                      TimeUtils.formatRelativeTime(draft.updatedAt!),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: theme.colorScheme.error,
                    ),
                    onPressed: onDelete,
                    visualDensity: VisualDensity.compact,
                    tooltip: '删除草稿',
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 标题
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              // 内容预览
              if (content != null && content.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 草稿列表骨架屏
class _DraftsListSkeleton extends StatelessWidget {
  const _DraftsListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Skeleton(
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: 5,
        itemBuilder: (context, index) => const _DraftCardSkeleton(),
      ),
    );
  }
}

/// 单个草稿卡片骨架屏
class _DraftCardSkeleton extends StatelessWidget {
  const _DraftCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 类型标签和时间
            Row(
              children: [
                SkeletonBox(width: 60, height: 22, borderRadius: 6),
                const SizedBox(width: 8),
                SkeletonBox(width: 50, height: 14),
                const Spacer(),
                SkeletonBox(width: 24, height: 24, borderRadius: 12),
              ],
            ),
            const SizedBox(height: 12),
            // 标题
            SkeletonBox(width: double.infinity, height: 18),
            const SizedBox(height: 8),
            // 内容预览
            SkeletonBox(width: double.infinity, height: 14),
            const SizedBox(height: 4),
            SkeletonBox(width: 200, height: 14),
          ],
        ),
      ),
    );
  }
}
