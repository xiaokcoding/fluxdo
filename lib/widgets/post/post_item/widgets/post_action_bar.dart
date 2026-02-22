import 'package:flutter/material.dart';
import '../../../../constants.dart';
import '../../../../models/topic.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/emoji_handler.dart';

/// 获取 emoji 图片 URL
String _getEmojiUrl(String emojiName) {
  final url = EmojiHandler().getEmojiUrl(emojiName);
  if (url != null) return url;
  return '${AppConstants.baseUrl}/images/emoji/twitter/$emojiName.png?v=12';
}

/// 帖子底部操作栏
class PostActionBar extends StatelessWidget {
  final Post post;
  final bool isGuest;
  final bool isOwnPost;
  final bool isLiking;
  final List<PostReaction> reactions;
  final PostReaction? currentUserReaction;
  final GlobalKey likeButtonKey;
  final List<Post> replies;
  final ValueNotifier<bool> isLoadingRepliesNotifier;
  final ValueNotifier<bool> showRepliesNotifier;
  final VoidCallback onToggleLike;
  final VoidCallback onShowReactionPicker;
  final void Function(String? reactionId) onShowReactionUsers;
  final VoidCallback? onReply;
  final VoidCallback onShowMoreMenu;
  final VoidCallback onToggleReplies;

  const PostActionBar({
    super.key,
    required this.post,
    required this.isGuest,
    required this.isOwnPost,
    required this.isLiking,
    required this.reactions,
    required this.currentUserReaction,
    required this.likeButtonKey,
    required this.replies,
    required this.isLoadingRepliesNotifier,
    required this.showRepliesNotifier,
    required this.onToggleLike,
    required this.onShowReactionPicker,
    required this.onShowReactionUsers,
    this.onReply,
    required this.onShowMoreMenu,
    required this.onToggleReplies,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        // 回复数按钮
        if (post.replyCount > 0)
          ValueListenableBuilder<bool>(
            valueListenable: isLoadingRepliesNotifier,
            builder: (context, isLoadingReplies, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: showRepliesNotifier,
                builder: (context, showReplies, _) {
                  return GestureDetector(
                    onTap: isLoadingReplies ? null : onToggleReplies,
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: showReplies
                            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: showReplies
                              ? theme.colorScheme.primary.withValues(alpha: 0.2)
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isLoadingReplies && replies.isEmpty)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else ...[
                            Icon(
                              Icons.chat_bubble_outline_rounded,
                              size: 15,
                              color: showReplies
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${post.replyCount}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: showReplies
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              showReplies ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                              size: 18,
                              color: showReplies
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),

        const Spacer(),
        if (!isGuest) ...[
          // 回应和赞
          // 左右两个 GestureDetector 是兄弟关系（非嵌套），避免手势竞争
          if (!isOwnPost || reactions.isNotEmpty)
            Container(
              key: likeButtonKey,
              height: 36,
              decoration: BoxDecoration(
                color: currentUserReaction != null
                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: currentUserReaction != null
                      ? theme.colorScheme.primary.withValues(alpha: 0.2)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 左侧区域：回应表情 + 数量 → 查看回应人
                  // 父级兜底 → 全部 tab，子级每个 emoji → 对应 tab
                  if (reactions.isNotEmpty)
                    GestureDetector(
                      onTap: () => onShowReactionUsers(null),
                      onLongPress: isOwnPost ? null : onShowReactionPicker,
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        height: 36,
                        padding: const EdgeInsets.only(left: 12),
                        alignment: Alignment.center,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (!(reactions.length == 1 && reactions.first.id == 'heart'))
                              ...reactions.take(3).map((reaction) => GestureDetector(
                                onTap: () => onShowReactionUsers(reaction.id),
                                behavior: HitTestBehavior.opaque,
                                child: Container(
                                  height: 36,
                                  padding: const EdgeInsets.symmetric(horizontal: 2),
                                  alignment: Alignment.center,
                                  child: Image(
                                    image: discourseImageProvider(_getEmojiUrl(reaction.id)),
                                    width: 16,
                                    height: 16,
                                  ),
                                ),
                              )),
                            if (!(reactions.length == 1 && reactions.first.id == 'heart'))
                              const SizedBox(width: 4),
                            Text(
                              '${reactions.fold(0, (sum, r) => sum + r.count)}',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: currentUserReaction != null
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                        ),
                      ),
                    ),

                  // 右侧区域：点赞/回应图标 → 点赞/取消
                  GestureDetector(
                    onTap: isOwnPost ? null : (isLiking ? null : onToggleLike),
                    onLongPress: isOwnPost ? null : onShowReactionPicker,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      height: 36,
                      padding: EdgeInsets.only(
                        left: reactions.isNotEmpty ? 0 : 12,
                        right: 12,
                      ),
                      alignment: Alignment.center,
                      child: currentUserReaction != null
                          ? Image(
                              image: discourseImageProvider(_getEmojiUrl(currentUserReaction!.id)),
                              width: 20,
                              height: 20,
                            )
                          : Icon(
                              Icons.favorite_border,
                              size: 20,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(width: 8),

          // 回复按钮
          GestureDetector(
            onTap: onReply,
            child: Container(
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.reply,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '回复',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(width: 8),

        // 更多按钮
        GestureDetector(
          onTap: onShowMoreMenu,
          child: Container(
            height: 36,
            width: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.more_horiz,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
