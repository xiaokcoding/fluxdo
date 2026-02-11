import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../models/category.dart';
import '../../providers/discourse_providers.dart';
import '../../utils/font_awesome_helper.dart';
import '../../services/discourse_cache_manager.dart';
import '../../constants.dart';
import '../../utils/tag_icon_list.dart';
import '../common/topic_badges.dart';
import '../common/tag_selection_sheet.dart';

/// 话题筛选条件
class TopicFilterParams {
  final int? categoryId;
  final String? categorySlug;
  final String? categoryName;
  final String? parentCategorySlug;
  final List<String> tags;

  const TopicFilterParams({
    this.categoryId,
    this.categorySlug,
    this.categoryName,
    this.parentCategorySlug,
    this.tags = const [],
  });

  bool get isEmpty => categoryId == null && tags.isEmpty;
  bool get isNotEmpty => !isEmpty;

  TopicFilterParams copyWith({
    int? categoryId,
    String? categorySlug,
    String? categoryName,
    String? parentCategorySlug,
    List<String>? tags,
    bool clearCategory = false,
  }) {
    return TopicFilterParams(
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      categorySlug: clearCategory ? null : (categorySlug ?? this.categorySlug),
      categoryName: clearCategory ? null : (categoryName ?? this.categoryName),
      parentCategorySlug: clearCategory ? null : (parentCategorySlug ?? this.parentCategorySlug),
      tags: tags ?? this.tags,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicFilterParams &&
          categoryId == other.categoryId &&
          _listEquals(tags, other.tags);

  @override
  int get hashCode => Object.hash(categoryId, Object.hashAll(tags));

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 筛选状态 Notifier
class TopicFilterNotifier extends Notifier<TopicFilterParams> {
  @override
  TopicFilterParams build() => const TopicFilterParams();

  void setCategory(Category? category) {
    final oldCategoryId = state.categoryId;

    if (category == null) {
      // 分类变化时清空标签
      if (oldCategoryId != null) {
        state = const TopicFilterParams();
      } else {
        state = state.copyWith(clearCategory: true);
      }
    } else {
      String? parentSlug;

      // 如果有父分类，查找父分类的 slug
      if (category.parentCategoryId != null) {
        final categoryMap = ref.read(categoryMapProvider).value;
        if (categoryMap != null) {
          final parentCategory = categoryMap[category.parentCategoryId];
          parentSlug = parentCategory?.slug;
        }
      }

      // 分类变化时清空标签
      final shouldClearTags = category.id != oldCategoryId;

      state = state.copyWith(
        categoryId: category.id,
        categorySlug: category.slug,
        categoryName: category.name,
        parentCategorySlug: parentSlug,
        tags: shouldClearTags ? [] : null,
      );
      ref.read(activeCategorySlugsProvider.notifier).add(category.slug);
    }
  }

  void toggleTag(String tag) {
    final newTags = List<String>.from(state.tags);
    if (newTags.contains(tag)) {
      newTags.remove(tag);
    } else {
      newTags.add(tag);
    }
    state = state.copyWith(tags: newTags);
  }

  void removeTag(String tag) {
    state = state.copyWith(tags: state.tags.where((t) => t != tag).toList());
  }

  void setTags(List<String> tags) {
    state = state.copyWith(tags: tags);
  }

  void clearAll() {
    state = const TopicFilterParams();
  }
}

final topicFilterProvider =
    NotifierProvider<TopicFilterNotifier, TopicFilterParams>(
        () => TopicFilterNotifier());

/// 筛选面板 BottomSheet
class TopicFilterSheet extends ConsumerStatefulWidget {
  const TopicFilterSheet({super.key});

  @override
  ConsumerState<TopicFilterSheet> createState() => _TopicFilterSheetState();
}

class _TopicFilterSheetState extends ConsumerState<TopicFilterSheet> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// 打开标签搜索弹框
  Future<void> _openTagSearchSheet() async {
    final filter = ref.read(topicFilterProvider);
    final tagsAsync = ref.read(tagsProvider);
    final availableTags = tagsAsync.when(
      data: (tags) => tags,
      loading: () => <String>[],
      error: (e, s) => <String>[],
    );

    final result = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => TagSelectionSheet(
        availableTags: availableTags,
        selectedTags: filter.tags,
        maxTags: 99, // 筛选场景不限制标签数量
      ),
    );

    if (result != null && mounted) {
      ref.read(topicFilterProvider.notifier).setTags(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(topicFilterProvider);
    final categoriesAsync = ref.watch(categoriesProvider);
    final tagsAsync = ref.watch(tagsProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 顶部拖动柄
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 12),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.outlineVariant.withValues(alpha:0.5),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // 标题栏
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '筛选',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // 保持占位避免抖动
                Visibility(
                  visible: filter.isNotEmpty,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: TextButton(
                    onPressed: filter.isNotEmpty
                        ? () => ref.read(topicFilterProvider.notifier).clearAll()
                        : null,
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.error,
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('重置'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          
          // 内容区域
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              children: [                
                // 分类选择
                Text(
                  '分类',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                categoriesAsync.when(
                  data: (categories) => _buildCategoryGrid(
                    context,
                    ref,
                    categories,
                    filter.categoryId,
                  ),
                  loading: () => const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  ),
                  error: (e, _) => Center(child: Text('加载分类失败: $e')),
                ),
                
                const SizedBox(height: 24),

                // 标签选择
                Row(
                  children: [
                    Text(
                      '标签',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _openTagSearchSheet,
                      icon: const Icon(Icons.search, size: 18),
                      label: const Text('搜索更多'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 标签列表（热门标签 + 已选的非热门标签）
                tagsAsync.when(
                  data: (hotTags) {
                    // 找出已选但不在热门中的标签
                    final extraSelectedTags = filter.tags
                        .where((t) => !hotTags.contains(t))
                        .toList();

                    if (hotTags.isEmpty && extraSelectedTags.isEmpty) {
                      return Text(
                        '暂无热门标签',
                        style: TextStyle(color: colorScheme.outline),
                      );
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 已选的非热门标签（如果有）
                        if (extraSelectedTags.isNotEmpty) ...[
                          Text(
                            '已选标签',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildTagWrap(context, ref, extraSelectedTags, filter.tags),
                          const SizedBox(height: 16),
                        ],
                        // 热门标签
                        if (hotTags.isNotEmpty) ...[
                          Text(
                            '热门标签',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          _buildTagWrap(context, ref, hotTags, filter.tags),
                        ],
                      ],
                    );
                  },
                  loading: () => const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Text('加载标签失败: $e'),
                ),
              ],
            ),
          ),
          
          // 底部确认按钮区域
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('完成', style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryGrid(
    BuildContext context,
    WidgetRef ref,
    List<Category> categories,
    int? selectedId,
  ) {
    // 1. 数据预处理
    // 顶级分类
    final topCategories = categories
        .where((c) => c.parentCategoryId == null)
        .toList();
    
    // 父类ID -> 子类列表 映射
    final Map<int, List<Category>> subcategoryMap = {};
    for (final category in categories) {
      if (category.parentCategoryId != null) {
        subcategoryMap.putIfAbsent(category.parentCategoryId!, () => []);
        subcategoryMap[category.parentCategoryId]!.add(category);
      }
    }

    // 分离 "孤立父类" (无子类) 和 "组合父类" (有子类)
    final List<Category> isolatedParents = [];
    final List<Category> groupParents = [];

    for (final parent in topCategories) {
      if (subcategoryMap.containsKey(parent.id) && subcategoryMap[parent.id]!.isNotEmpty) {
        groupParents.add(parent);
      } else {
        isolatedParents.add(parent);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. 顶部区域："全部" + 孤立父类
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
             // "全部" 选项
            _CategoryFilterItem(
              name: '全部',
              color: Colors.grey,
              isSelected: selectedId == null,
              onTap: () => ref.read(topicFilterProvider.notifier).setCategory(null),
              isAll: true,
            ),
            ...isolatedParents.map((category) {
              final isSelected = selectedId == category.id;
              final categoryColor = _parseColor(category.color);
              return _CategoryFilterItem(
                name: category.name,
                color: categoryColor,
                isSelected: isSelected,
                category: category,
                onTap: () {
                  ref.read(topicFilterProvider.notifier).setCategory(
                        isSelected ? null : category,
                      );
                },
              );
            }),
          ],
        ),

        if (groupParents.isNotEmpty)
          const SizedBox(height: 16),

        // 2. 分组区域：有子分类的父类
        ...groupParents.map((parent) {
          final subcategories = subcategoryMap[parent.id]!;
          final isParentSelected = selectedId == parent.id;
          final parentColor = _parseColor(parent.color);

          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 父分类标题
                _CategoryFilterItem(
                  name: parent.name,
                  color: parentColor,
                  isSelected: isParentSelected,
                  category: parent,
                  onTap: () {
                    ref.read(topicFilterProvider.notifier).setCategory(
                          isParentSelected ? null : parent,
                        );
                  },
                ),
                const SizedBox(height: 8),
                
                // 子分类列表 (带左侧边框线作为引导)
                IntrinsicHeight(
                  child: Row(
                    children: [
                      // 左侧引导线
                      Container(
                        width: 2,
                        margin: const EdgeInsets.only(left: 12, right: 12, top: 4, bottom: 4),
                        decoration: BoxDecoration(
                           color: parentColor.withValues(alpha:0.3),
                           borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      // 子分类 Wrap
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: subcategories.map((sub) {
                             final isSubSelected = selectedId == sub.id;
                             final subColor = _parseColor(sub.color);
                             return _CategoryFilterItem(
                               name: sub.name,
                               color: subColor,
                               isSelected: isSubSelected,
                               category: sub,
                               isSubcategory: true, // 标记为子分类，主要用于内部样式微调（如需要）
                               onTap: () {
                                 ref.read(topicFilterProvider.notifier).setCategory(
                                       isSubSelected ? null : sub,
                                     );
                               },
                             );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildTagWrap(
    BuildContext context,
    WidgetRef ref,
    List<String> allTags,
    List<String> selectedTags,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: allTags.map((tag) {
        final isSelected = selectedTags.contains(tag);
        final tagInfo = TagIconList.get(tag);

        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              ref.read(topicFilterProvider.notifier).toggleTag(tag);
            },
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? colorScheme.primaryContainer
                    : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? colorScheme.primary.withValues(alpha: 0.5)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 固定图标区域宽度，避免切换时抖动
                  if (tagInfo != null || isSelected)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: Center(
                          child: isSelected
                              ? Icon(
                                  Icons.check,
                                  size: 14,
                                  color: colorScheme.primary,
                                )
                              : FaIcon(
                                  tagInfo!.icon,
                                  size: 12,
                                  color: tagInfo.color,
                                ),
                        ),
                      ),
                    ),
                  Text(
                    tag,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Color _parseColor(String hex) {
    try {
      return Color(int.parse('FF$hex', radix: 16));
    } catch (e) {
      return Colors.grey;
    }
  }
}

class _CategoryFilterItem extends StatelessWidget {
  final String name;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;
  final bool isAll;
  final Category? category;
  final bool isSubcategory;

  const _CategoryFilterItem({
    required this.name,
    required this.color,
    required this.isSelected,
    required this.onTap,
    this.isAll = false,
    this.category,
    this.isSubcategory = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    // 图标逻辑
    IconData? faIcon;
    String? logoUrl;
    
    if (category != null) {
      faIcon = FontAwesomeHelper.getIcon(category!.icon);
      logoUrl = category!.uploadedLogo;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: EdgeInsets.only(
            left: isSubcategory ? 6 : 10,
            right: 10,
            top: 6,
            bottom: 6,
          ),
          decoration: BoxDecoration(
            color: isSelected 
                ? color.withValues(alpha:0.15) 
                : color.withValues(alpha:0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected
                  ? color
                  : color.withValues(alpha:0.2),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isAll)
                 Icon(Icons.all_inclusive, size: 12, color: theme.colorScheme.onSurface)
              else if (faIcon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FaIcon(
                    faIcon,
                    size: 12,
                    color: color,
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
                      return _buildDot();
                    },
                  ),
                )
              else if (category?.readRestricted ?? false)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Icon(Icons.lock, size: 12, color: color),
                )
              else
                 _buildDot(),

              if (!isAll && (faIcon != null || (logoUrl != null && logoUrl.isNotEmpty) || (category?.readRestricted ?? false)))
                 const SizedBox.shrink()
              else if (!isAll)
                 const SizedBox(width: 6)
              else if (isAll)
                 const SizedBox(width: 6),

              Text(
                name,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                  fontSize: isSubcategory ? 12 : null, // 子分类字体稍小
                ),
              ),
              if (isSelected) ...[
                const SizedBox(width: 6),
                Icon(Icons.check, size: 14, color: color),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDot() {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 当前筛选条件显示条
class ActiveFiltersBar extends ConsumerWidget {
  const ActiveFiltersBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(topicFilterProvider);
    final colorScheme = Theme.of(context).colorScheme;
    
    // 使用 AnimatedSize 实现显示/隐藏动画
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      child: filter.isEmpty
        ? const SizedBox.shrink()
        : Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainer.withValues(alpha:0.5),
              border: Border(
                bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha:0.2)),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.filter_list, size: 14, color: colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      '当前筛选',
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () => ref.read(topicFilterProvider.notifier).clearAll(),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(
                          '清除全部',
                          style: TextStyle(fontSize: 12, color: colorScheme.error),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      // 分类筛选
                      if (filter.categoryId != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: RemovableCategoryBadge(
                            name: filter.categoryName ?? '分类',
                            onDeleted: () => ref.read(topicFilterProvider.notifier).setCategory(null),
                            size: const BadgeSize(
                              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              radius: 8,
                              iconSize: 12,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      // 标签筛选
                      ...filter.tags.map((tag) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: RemovableTagBadge(
                              name: tag,
                              onDeleted: () => ref.read(topicFilterProvider.notifier).removeTag(tag),
                              size: const BadgeSize(
                                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                radius: 8,
                                iconSize: 12,
                                fontSize: 12,
                              ),
                            ),
                          )),
                    ],
                  ),
                ),
              ],
            ),
          ),
    );
  }
  
}
