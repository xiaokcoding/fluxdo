import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/notification.dart';
import '../providers/discourse_providers.dart';

import 'topic_detail_page/topic_detail_page.dart';
import 'user_profile_page.dart';
import 'badge_page.dart';
import '../widgets/common/emoji_text.dart';
import '../widgets/common/smart_avatar.dart';
import '../widgets/notification/notification_list_skeleton.dart';
import '../widgets/common/error_view.dart';
import '../utils/time_utils.dart';

/// 通知列表页面
class NotificationsPage extends ConsumerStatefulWidget {
  const NotificationsPage({super.key});

  @override
  ConsumerState<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends ConsumerState<NotificationsPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(notificationListProvider.notifier).loadMore();
    }
  }

  Future<void> _onRefresh() async {
    await ref.read(notificationListProvider.notifier).refresh();
  }

  void _onNotificationTap(DiscourseNotification notification) async {
    // 如果通知未读，先标记为已读
    if (!notification.read) {
      // 立即更新本地状态，让 UI 显示为已读
      ref.read(notificationListProvider.notifier).markAsRead(notification.id);

      // 异步发送标记已读请求（不等待结果）
      ref.read(discourseServiceProvider).markNotificationRead(notification.id).catchError((e) {
        debugPrint('标记通知已读失败: $e');
      });
    }

    // 根据通知类型决定跳转逻辑
    if (!mounted) return;

    switch (notification.notificationType) {
      case NotificationType.inviteeAccepted:
      case NotificationType.following:
        // 跳转到用户页
        if (notification.username != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => UserProfilePage(username: notification.username!),
            ),
          );
        }
        break;

      case NotificationType.grantedBadge:
        // 跳转到徽章页面
        if (notification.data.badgeId != null) {
          final currentUser = ref.read(currentUserProvider).value;
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => BadgePage(
                badgeId: notification.data.badgeId!,
                badgeSlug: notification.data.badgeSlug,
                username: currentUser?.username,
              ),
            ),
          );
        }
        break;

      case NotificationType.membershipRequestAccepted:
        // 群组通知暂时不跳转（需要群组页面）
        break;

      default:
        // 大部分通知：如果有 topicId，跳转到话题详情
        if (notification.topicId != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => TopicDetailPage(
                topicId: notification.topicId!,
                scrollToPostNumber: notification.postNumber,
              ),
            ),
          );
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final notificationsAsync = ref.watch(notificationListProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('通知'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.done_all),
            onPressed: () => ref.read(notificationListProvider.notifier).markAllAsRead(),
            tooltip: '全部标为已读',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        child: notificationsAsync.when(
          data: (notifications) {
            if (notifications.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.notifications_none, size: 64, color: Colors.grey),
                    SizedBox(height: 16),
                    Text('暂无通知', style: TextStyle(color: Colors.grey)),
                  ],
                ),
              );
            }

            return ListView.builder(
              controller: _scrollController,
              itemCount: notifications.length,
              itemBuilder: (context, index) {
                final notification = notifications[index];
                return _NotificationItem(
                  notification: notification,
                  onTap: () => _onNotificationTap(notification),
                );
              },
            );
          },
          loading: () => const NotificationListSkeleton(),
          error: (error, stack) => ErrorView(
            error: error,
            stackTrace: stack,
            onRetry: _onRefresh,
          ),
        ),
      ),
    );
  }
}

class _NotificationItem extends StatelessWidget {
  final DiscourseNotification notification;
  final VoidCallback onTap;

  const _NotificationItem({
    required this.notification,
    required this.onTap,
  });

  IconData _getNotificationIcon() {
    switch (notification.notificationType) {
      case NotificationType.mentioned:
        return Icons.alternate_email;
      case NotificationType.replied:
        return Icons.reply;
      case NotificationType.quoted:
        return Icons.format_quote;
      case NotificationType.liked:
      case NotificationType.likedConsolidated:
        return Icons.favorite;
      case NotificationType.reaction:
        return Icons.thumb_up; // 或者使用具体的 reaction 图标如果数据支持
      case NotificationType.privateMessage:
      case NotificationType.invitedToPrivateMessage:
        return Icons.mail;
      case NotificationType.posted:
        return Icons.post_add;
      case NotificationType.grantedBadge:
        return Icons.military_tech;
      case NotificationType.linked:
        return Icons.link;
      case NotificationType.bookmarkReminder:
        return Icons.bookmark;
      case NotificationType.groupMentioned:
        return Icons.group;
      case NotificationType.watchingFirstPost:
        return Icons.visibility;
      case NotificationType.following:
      case NotificationType.followingCreatedTopic:
      case NotificationType.followingReplied:
        return Icons.person_add;
      case NotificationType.watchingCategoryOrTag:
        return Icons.label;
      case NotificationType.newFeatures:
        return Icons.new_releases;
      case NotificationType.adminProblems:
        return Icons.warning;
      case NotificationType.linkedConsolidated:
        return Icons.link;
      case NotificationType.chatWatchedThread:
        return Icons.chat_bubble;
      case NotificationType.invitedToTopic:
        return Icons.mail_outline;
      case NotificationType.inviteeAccepted:
        return Icons.check_circle;
      case NotificationType.movedPost:
        return Icons.drive_file_move;
      case NotificationType.topicReminder:
        return Icons.alarm;
      case NotificationType.eventReminder:
      case NotificationType.eventInvitation:
        return Icons.event;
      case NotificationType.chatMention:
      case NotificationType.chatMessage:
      case NotificationType.chatInvitation:
      case NotificationType.chatGroupMention:
      case NotificationType.chatQuotedPost:
        return Icons.chat;
      case NotificationType.assignedTopic:
        return Icons.assignment;
      case NotificationType.questionAnswerUserCommented:
        return Icons.question_answer;
      case NotificationType.circlesActivity:
        return Icons.groups;
      default:
        return Icons.notifications;
    }
  }

  Color _getNotificationColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (notification.notificationType) {
      case NotificationType.liked:
      case NotificationType.likedConsolidated:
      case NotificationType.reaction:
        return Colors.red;
      case NotificationType.privateMessage:
      case NotificationType.invitedToPrivateMessage:
        return Colors.blue;
      case NotificationType.grantedBadge:
        return Colors.amber;
      case NotificationType.mentioned:
      case NotificationType.groupMentioned:
        return colorScheme.primary;
      case NotificationType.following:
      case NotificationType.followingCreatedTopic:
      case NotificationType.followingReplied:
        return Colors.green;
      case NotificationType.adminProblems:
        return Colors.red;
      case NotificationType.newFeatures:
        return Colors.purple;
      default:
        return colorScheme.onSurfaceVariant;
    }
  }



  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final iconColor = _getNotificationColor(context);
    final titleStyle = TextStyle(
      fontWeight: notification.read ? FontWeight.normal : FontWeight.w600,
    );

    return ListTile(
      leading: SizedBox(
        width: 48,
        height: 48,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // 底层：用户头像
            Align(
              alignment: Alignment.center,
              child: SmartAvatar(
                imageUrl: notification.getAvatarUrl().isNotEmpty
                    ? notification.getAvatarUrl()
                    : null,
                radius: 20,
                backgroundColor: colorScheme.surfaceContainerHighest,
              ),
            ),
            // 右上角：通知类型图标
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: notification.read
                      ? colorScheme.surfaceContainerHighest
                      : colorScheme.surface,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: colorScheme.surface,
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.1),
                      blurRadius: 2,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: Icon(
                  _getNotificationIcon(),
                  size: 14,
                  color: notification.read ? colorScheme.onSurfaceVariant : iconColor,
                ),
              ),
            ),
          ],
        ),
      ),
      title: Text.rich(
        TextSpan(
          children: EmojiText.buildEmojiSpans(
            context,
            notification.title,
            titleStyle,
          ),
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: titleStyle,
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(
              notification.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            TimeUtils.formatRelativeTime(notification.createdAt),
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ),
      onTap: onTap,
      // 未读通知显示圆点标记
      trailing: !notification.read
          ? Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: colorScheme.primary,
                shape: BoxShape.circle,
              ),
            )
          : null,
    );
  }
}
