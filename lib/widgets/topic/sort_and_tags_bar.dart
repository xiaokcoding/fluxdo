import 'package:flutter/material.dart';
import '../../providers/topic_list_provider.dart';
import '../common/topic_badges.dart';
import 'sort_dropdown.dart';

/// 排序选项定义
const sortOptions = [
  (TopicListFilter.latest, '最新'),
  (TopicListFilter.newTopics, '新'),
  (TopicListFilter.unread, '未读'),
  (TopicListFilter.top, '排行榜'),
  (TopicListFilter.hot, '热门'),
];

/// 获取排序模式的显示名称
String sortLabel(TopicListFilter sort) {
  for (final option in sortOptions) {
    if (option.$1 == sort) return option.$2;
  }
  return '最新';
}

/// 排序下拉 + 标签 chips（固定在 Tab 和列表之间）
///
/// 纯 callback-based，不再内部读写任何 provider。
class SortAndTagsBar extends StatelessWidget {
  final TopicListFilter currentSort;
  final bool isLoggedIn;
  final ValueChanged<TopicListFilter> onSortChanged;
  final List<String> selectedTags;
  final ValueChanged<String> onTagRemoved;
  final VoidCallback onAddTag;
  final Widget? trailing;

  const SortAndTagsBar({
    super.key,
    required this.currentSort,
    required this.isLoggedIn,
    required this.onSortChanged,
    required this.selectedTags,
    required this.onTagRemoved,
    required this.onAddTag,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          // 排序下拉
          SortDropdown(
            currentSort: currentSort,
            isLoggedIn: isLoggedIn,
            onSortChanged: onSortChanged,
          ),
          const SizedBox(width: 8),
          // 标签区域
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // 已选标签 chips
                  ...selectedTags.map((tag) => Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: RemovableTagBadge(
                      name: tag,
                      onDeleted: () => onTagRemoved(tag),
                      size: const BadgeSize(
                        padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        radius: 6,
                        iconSize: 12,
                        fontSize: 12,
                      ),
                    ),
                  )),
                  // 添加标签按钮
                  _AddTagButton(
                    colorScheme: colorScheme,
                    onTap: onAddTag,
                  ),
                ],
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _AddTagButton extends StatelessWidget {
  final ColorScheme colorScheme;
  final VoidCallback onTap;

  const _AddTagButton({
    required this.colorScheme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 14, color: colorScheme.onSurfaceVariant),
            const SizedBox(width: 2),
            Icon(Icons.label_outline, size: 14, color: colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
