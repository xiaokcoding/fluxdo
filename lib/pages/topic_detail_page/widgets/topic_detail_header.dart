import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../../constants.dart';
import '../../../models/topic.dart';
import '../../../models/category.dart';
import '../../../providers/discourse_providers.dart';
import '../../../utils/font_awesome_helper.dart';
import '../../../services/discourse_cache_manager.dart';
import '../../../widgets/topic/topic_summary_widget.dart';
import '../../../widgets/common/emoji_text.dart';
import '../../../utils/time_utils.dart';
import '../../../utils/number_utils.dart';
import '../../../widgets/topic/topic_notification_button.dart';
import 'topic_vote_button.dart';

/// 话题详情页头部组件
class TopicDetailHeader extends ConsumerWidget {
  final TopicDetail detail;
  final GlobalKey? headerKey;
  final void Function(int, bool)? onVoteChanged;
  final void Function(TopicNotificationLevel)? onNotificationLevelChanged;

  const TopicDetailHeader({
    super.key,
    required this.detail,
    this.headerKey,
    this.onVoteChanged,
    this.onNotificationLevelChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // 获取分类信息
    final categoryMap = ref.watch(categoryMapProvider).value;
    final category = categoryMap?[detail.categoryId];

    IconData? faIcon;
    String? logoUrl;

    if (category != null) {
      faIcon = FontAwesomeHelper.getIcon(category.icon);
      logoUrl = category.uploadedLogo;

      if (faIcon == null && (logoUrl == null || logoUrl.isEmpty) && category.parentCategoryId != null) {
        final parent = categoryMap?[category.parentCategoryId];
        faIcon = FontAwesomeHelper.getIcon(parent?.icon);
        logoUrl = parent?.uploadedLogo;
      }
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withOpacity(0.3),
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          SelectableText.rich(
            TextSpan(
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                height: 1.4,
                letterSpacing: 0.2,
              ),
              children: [
                if (detail.closed)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.lock_rounded,
                        size: 20,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                if (detail.hasAcceptedAnswer)
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(
                        Icons.check_box,
                        size: 20,
                        color: Colors.green,
                      ),
                    ),
                  ),
                ...EmojiText.buildEmojiSpans(context, detail.title, theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  height: 1.4,
                )),
              ],
            ),
            key: headerKey,
          ),

          const SizedBox(height: 16),
          
          // 分类与标签
          if (category != null || (detail.tags != null && detail.tags!.isNotEmpty)) ...[
            Wrap(
              spacing: 6,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // 分类 Badge
                if (category != null)
                  _buildCategoryBadge(theme, category, faIcon, logoUrl),

                // 标签 Badges
                if (detail.tags != null)
                  ...detail.tags!.map((tag) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: theme.colorScheme.outlineVariant.withOpacity(0.3),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      tag.name,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )),
              ],
            ),
            const SizedBox(height: 16),
          ],
          
          // Metadata Row (Replies, Views, Date, Vote Button)
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    _buildMetadataItem(
                      context,
                      Icons.chat_bubble_outline_rounded,
                      '${detail.postsCount - 1}',
                      label: '回复'
                    ),
                    _buildMetadataItem(
                      context,
                      Icons.visibility_outlined,
                      NumberUtils.formatCount(detail.views),
                      label: '浏览'
                    ),
                    _buildMetadataItem(
                      context,
                      Icons.schedule_rounded,
                      TimeUtils.formatRelativeTime(detail.createdAt),
                    ),
                  ],
                ),
              ),
              // 投票按钮
              TopicVoteButton(
                topic: detail,
                onVoteChanged: onVoteChanged,
              ),
              const SizedBox(width: 8),
              // 订阅按钮
              TopicNotificationButton(
                level: detail.notificationLevel,
                onChanged: onNotificationLevelChanged,
                style: TopicNotificationButtonStyle.chip,
              ),
            ],
          ),

          // AI 摘要
          const SizedBox(height: 16),
          CollapsibleTopicSummary(
            topicId: detail.id,
            topicDetail: detail,  // 传入话题详情以检查 summarizable
          ),
        ],
      ),
    );
  }

  Widget _buildMetadataItem(BuildContext context, IconData icon, String text, {String? label}) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant.withOpacity(0.7),
        ),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withOpacity(0.8),
            fontWeight: FontWeight.w500,
          ),
        ),
        if (label != null) ...[
          const SizedBox(width: 2),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withOpacity(0.5),
            ),
          ),
        ],
      ],
    );
  }


  Widget _buildCategoryBadge(
    ThemeData theme,
    Category category,
    IconData? faIcon,
    String? logoUrl,
  ) {
    final categoryColor = _parseColor(category.color);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: categoryColor.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: categoryColor.withOpacity(0.2),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (faIcon != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FaIcon(
                faIcon,
                size: 11,
                color: categoryColor,
              ),
            )
          else if (logoUrl != null && logoUrl.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Image(
                image: discourseImageProvider(
                  logoUrl.startsWith('http')
                      ? logoUrl
                      : '${AppConstants.baseUrl}$logoUrl',
                ),
                width: 12,
                height: 12,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return _buildCategoryDot(category);
                },
              ),
            )
          else ...[
            _buildCategoryDot(category),
            const SizedBox(width: 6),
          ],
          Text(
            category.name,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryDot(Category category) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: _parseColor(category.color),
        shape: BoxShape.circle,
      ),
    );
  }

  Color _parseColor(String hex) {
    hex = hex.replaceAll('#', '');
    if (hex.length == 6) {
      return Color(int.parse('0xFF$hex'));
    }
    return Colors.grey;
  }
}
