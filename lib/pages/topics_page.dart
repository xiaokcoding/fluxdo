import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import '../models/topic.dart';
import '../models/category.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus_providers.dart';
import '../providers/selected_topic_provider.dart';
import '../providers/pinned_categories_provider.dart';
import '../providers/topic_sort_provider.dart';
import 'webview_login_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/topic/topic_filter_sheet.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/sort_and_tags_bar.dart';
import '../widgets/topic/sort_dropdown.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_notification_button.dart';
import '../widgets/topic/category_tab_manager_sheet.dart';
import '../widgets/common/tag_selection_sheet.dart';
import '../providers/app_state_refresher.dart';
import '../providers/preferences_provider.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/loading_dialog.dart';
import '../widgets/common/fading_edge_scroll_view.dart';

class ScrollToTopNotifier extends StateNotifier<int> {
  ScrollToTopNotifier() : super(0);

  void trigger() => state++;
}

final scrollToTopProvider = StateNotifierProvider<ScrollToTopNotifier, int>((ref) {
  return ScrollToTopNotifier();
});

/// 底栏可见性状态（滚动时自动隐藏）
final bottomNavVisibleProvider = StateProvider<bool>((ref) => true);

/// 顶栏可见性状态（滚动时自动隐藏）
final topBarVisibleProvider = StateProvider<bool>((ref) => true);

/// 帖子列表页面 - 分类 Tab + 排序下拉 + 标签 Chips
class TopicsPage extends ConsumerStatefulWidget {
  const TopicsPage({super.key});

  @override
  ConsumerState<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends ConsumerState<TopicsPage> with TickerProviderStateMixin {
  late TabController _tabController;
  int _tabLength = 1; // 初始只有"全部"
  int _currentTabIndex = 0;
  final GlobalKey<_TopicListState> _listKey = GlobalKey<_TopicListState>();

  /// 本地通知级别覆盖（categoryId -> level），用于设置后立即回显
  final Map<int, int> _notificationLevelOverrides = {};

  @override
  void initState() {
    super.initState();
    final pinnedIds = ref.read(pinnedCategoriesProvider);
    _tabLength = 1 + pinnedIds.length;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (_tabController.indexIsChanging) return;
    if (_currentTabIndex == _tabController.index) return;
    _currentTabIndex = _tabController.index;
    _applyTabCategory();
  }

  /// 根据当前 tab index 更新 topicFilterProvider 的分类
  void _applyTabCategory() {
    if (_currentTabIndex == 0) {
      ref.read(topicFilterProvider.notifier).setCategory(null);
    } else {
      final pinnedIds = ref.read(pinnedCategoriesProvider);
      final categoryMapValue = ref.read(categoryMapProvider).value;
      if (categoryMapValue != null && _currentTabIndex - 1 < pinnedIds.length) {
        final categoryId = pinnedIds[_currentTabIndex - 1];
        final category = categoryMapValue[categoryId];
        if (category != null) {
          ref.read(topicFilterProvider.notifier).setCategory(category);
        }
      }
    }
  }

  /// 检测 pinnedCategories 变化，重建 TabController
  void _syncTabsIfNeeded(List<int> pinnedIds) {
    final desiredLength = 1 + pinnedIds.length;
    if (desiredLength == _tabLength) return;

    final oldIndex = _tabController.index;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _tabLength = desiredLength;
    _tabController = TabController(length: _tabLength, vsync: this);
    _tabController.addListener(_handleTabChange);
    _currentTabIndex = oldIndex < _tabLength ? oldIndex : 0;
    _tabController.index = _currentTabIndex;
  }

  void _onScrollDirectionChanged(ScrollDirection direction) {
    final isVisible = ref.read(topBarVisibleProvider);
    if (direction == ScrollDirection.forward && !isVisible) {
      ref.read(topBarVisibleProvider.notifier).state = true;
      ref.read(bottomNavVisibleProvider.notifier).state = true;
    } else if (direction == ScrollDirection.reverse && isVisible) {
      ref.read(topBarVisibleProvider.notifier).state = false;
      ref.read(bottomNavVisibleProvider.notifier).state = false;
    }
  }

  Future<void> _goToLogin() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const WebViewLoginPage()),
    );
    if (result == true && mounted) {
      LoadingDialog.show(context, message: '加载数据...');

      AppStateRefresher.refreshAll(ref);

      try {
        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(topicListProvider(TopicListFilter.latest).future),
        ]).timeout(const Duration(seconds: 10));
      } catch (_) {}

      if (mounted) {
        LoadingDialog.hide(context);
      }
    }
  }

  void _showTopicIdDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('跳转到话题'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '话题 ID',
            hintText: '例如: 1095754',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final id = int.tryParse(controller.text.trim());
              Navigator.pop(context);
              if (id != null) {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => TopicDetailPage(
                      topicId: id,
                      autoSwitchToMasterDetail: true,
                    ),
                  ),
                );
              }
            },
            child: const Text('跳转'),
          ),
        ],
      ),
    );
  }

  void _openCategoryManager() async {
    final categoryId = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CategoryTabManagerSheet(),
    );

    // 如果返回了 category ID，切换到对应的 Tab
    if (categoryId != null && mounted) {
      final pinnedIds = ref.read(pinnedCategoriesProvider);
      final tabIndex = pinnedIds.indexOf(categoryId);
      if (tabIndex >= 0) {
        _tabController.animateTo(tabIndex + 1); // +1 因为"全部"在 index 0
      }
    }
  }

  Future<void> _openTagSelection() async {
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
        maxTags: 99,
      ),
    );

    if (result != null && mounted) {
      ref.read(topicFilterProvider.notifier).setTags(result);
    }
  }

  /// 获取当前选中分类 Tab 对应的 Category（仅非"全部"时返回）
  Category? _getCurrentCategory(List<int> pinnedIds, Map<int, Category>? categoryMap) {
    if (_currentTabIndex == 0 || categoryMap == null) return null;
    if (_currentTabIndex - 1 >= pinnedIds.length) return null;
    final categoryId = pinnedIds[_currentTabIndex - 1];
    return categoryMap[categoryId];
  }

  /// 构建排序栏右侧的订阅按钮（仅选中分类 Tab 时显示）
  Widget? _buildTrailing(Category? category, bool isLoggedIn) {
    if (category == null || !isLoggedIn) return null;
    // 优先使用本地覆盖值，否则取服务端返回值
    final effectiveLevel = _notificationLevelOverrides[category.id]
        ?? category.notificationLevel;
    final level = CategoryNotificationLevel.fromValue(effectiveLevel);
    return CategoryNotificationButton(
      level: level,
      onChanged: (newLevel) async {
        final oldLevel = effectiveLevel;
        // 乐观更新
        setState(() => _notificationLevelOverrides[category.id] = newLevel.value);
        try {
          final service = ref.read(discourseServiceProvider);
          await service.setCategoryNotificationLevel(category.id, newLevel.value);
        } catch (_) {
          // 失败时回退
          if (mounted) {
            setState(() {
              if (oldLevel != null) {
                _notificationLevelOverrides[category.id] = oldLevel;
              } else {
                _notificationLevelOverrides.remove(category.id);
              }
            });
          }
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    final showBar = ref.watch(topBarVisibleProvider);
    final pinnedIds = ref.watch(pinnedCategoriesProvider);
    final categoryMapAsync = ref.watch(categoryMapProvider);
    final currentSort = ref.watch(topicSortProvider);
    final filter = ref.watch(topicFilterProvider);

    _syncTabsIfNeeded(pinnedIds);

    final currentCategory = _getCurrentCategory(pinnedIds, categoryMapAsync.value);

    // 监听滚动到顶部的通知
    ref.listen(scrollToTopProvider, (previous, next) {
      _listKey.currentState?.scrollToTop();
    });

    return Column(
      children: [
        // 搜索栏：滚动时隐藏
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          height: showBar ? topPadding + 56 : topPadding,
          child: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            padding: EdgeInsets.only(top: topPadding + 8, left: 16, right: 16, bottom: 8),
            child: AnimatedOpacity(
              opacity: showBar ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SearchPage()),
                      ),
                      child: Container(
                        height: 40,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.search,
                              size: 20,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '搜索话题...',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  fontSize: 14,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (isLoggedIn) const NotificationIconButton(),
                  if (kDebugMode)
                    IconButton(
                      icon: const Icon(Icons.bug_report),
                      onPressed: () => _showTopicIdDialog(context),
                      tooltip: '调试：跳转话题',
                    ),
                ],
              ),
            ),
          ),
        ),
        // 分类 Tab 行（始终可见）
        GestureDetector(
          onTap: () {
            ref.read(topBarVisibleProvider.notifier).state = true;
            ref.read(bottomNavVisibleProvider.notifier).state = true;
          },
          child: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Row(
              children: [
                Expanded(
                  child: FadingEdgeScrollView(
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: _buildCategoryTabs(pinnedIds, categoryMapAsync.value ?? {}),
                      labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                      unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal),
                      dividerColor: Colors.transparent,
                      onTap: (index) {
                        if (index == _currentTabIndex) {
                          _listKey.currentState?.scrollToTop();
                        }
                      },
                    ),
                  ),
                ),
                // 排序栏隐藏时，显示排序快捷按钮
                if (!showBar)
                  SortDropdown(
                    currentSort: currentSort,
                    isLoggedIn: isLoggedIn,
                    onSortChanged: (sort) {
                      ref.read(topicSortProvider.notifier).state = sort;
                    },
                    style: SortDropdownStyle.compact,
                  ),
                // 分类浏览按钮
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: IconButton(
                    icon: const Icon(Icons.segment, size: 20),
                    onPressed: _openCategoryManager,
                    tooltip: '浏览分类',
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
        ),
        // 排序+标签栏：固定在 Tab 和列表之间，滚动时隐藏
        AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          child: showBar
              ? SortAndTagsBar(
                  currentSort: currentSort,
                  isLoggedIn: isLoggedIn,
                  onSortChanged: (sort) {
                    ref.read(topicSortProvider.notifier).state = sort;
                  },
                  selectedTags: filter.tags,
                  onTagRemoved: (tag) {
                    ref.read(topicFilterProvider.notifier).removeTag(tag);
                  },
                  onAddTag: _openTagSelection,
                  trailing: _buildTrailing(currentCategory, isLoggedIn),
                )
              : const SizedBox.shrink(),
        ),
        // 列表区域
        Expanded(
          child: _TopicList(
            key: _listKey,
            onLoginRequired: _goToLogin,
            onScrollDirectionChanged: _onScrollDirectionChanged,
          ),
        ),
      ],
    );
  }

  /// 构建分类 Tab 列表
  List<Tab> _buildCategoryTabs(List<int> pinnedIds, Map<int, Category> categoryMap) {
    final tabs = <Tab>[const Tab(text: '全部')];
    for (final id in pinnedIds) {
      final category = categoryMap[id];
      if (category != null) {
        tabs.add(Tab(text: category.name));
      } else {
        tabs.add(Tab(text: '...'));
      }
    }
    return tabs;
  }

}

/// 话题列表（共用一个，根据 topicSortProvider + topicFilterProvider 获取数据）
class _TopicList extends ConsumerStatefulWidget {
  final VoidCallback onLoginRequired;
  final ValueChanged<ScrollDirection> onScrollDirectionChanged;

  const _TopicList({
    super.key,
    required this.onLoginRequired,
    required this.onScrollDirectionChanged,
  });

  @override
  ConsumerState<_TopicList> createState() => _TopicListState();
}

class _TopicListState extends ConsumerState<_TopicList> {
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingNewTopics = false;

  static const double _scrollDirectionThreshold = 30.0;
  double _lastDirectionChangeOffset = 0.0;
  ScrollDirection _lastTriggeredDirection = ScrollDirection.idle;

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
    final currentSort = ref.read(topicSortProvider);
    // 加载更多
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      ref.read(topicListProvider(currentSort).notifier).loadMore();
    }
    // 滚动方向
    final direction = _scrollController.position.userScrollDirection;
    if (direction == ScrollDirection.idle) return;

    final currentOffset = _scrollController.position.pixels;
    final scrollDelta = (currentOffset - _lastDirectionChangeOffset).abs();

    if (scrollDelta >= _scrollDirectionThreshold && direction != _lastTriggeredDirection) {
      _lastDirectionChangeOffset = currentOffset;
      _lastTriggeredDirection = direction;
      widget.onScrollDirectionChanged(direction);
    }
  }

  void scrollToTop() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _openTopic(Topic topic) {
    final canShowDetailPane = MasterDetailLayout.canShowBothPanesFor(context);

    if (canShowDetailPane) {
      ref.read(selectedTopicProvider.notifier).select(
        topicId: topic.id,
        initialTitle: topic.title,
        scrollToPostNumber: topic.lastReadPostNumber,
      );
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
          autoSwitchToMasterDetail: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentSort = ref.watch(topicSortProvider);
    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;
    final topicsAsync = ref.watch(topicListProvider(currentSort));

    return topicsAsync.when(
      data: (topics) {
        if (topics.isEmpty) {
          return RefreshIndicator(
            onRefresh: () => ref.refresh(topicListProvider(currentSort).future),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 100),
                Center(child: Text('没有相关话题')),
              ],
            ),
          );
        }

        final incomingState = ref.watch(latestChannelProvider);
        final hasNewTopics = currentSort == TopicListFilter.latest && incomingState.hasIncoming;
        final newTopicCount = incomingState.incomingCount;
        final newTopicOffset = hasNewTopics ? 1 : 0;

        return RefreshIndicator(
          onRefresh: () async {
            await ref.read(topicListProvider(currentSort).notifier).silentRefresh();
            if (currentSort == TopicListFilter.latest) {
              ref.read(latestChannelProvider.notifier).clearNewTopics();
            }
          },
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: topics.length + newTopicOffset + 1,
            itemBuilder: (context, index) {
              if (hasNewTopics && index == 0) {
                return _buildNewTopicIndicator(context, newTopicCount, currentSort);
              }

              final topicIndex = index - newTopicOffset;
              if (topicIndex >= topics.length) {
                return Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Center(
                    child: ref.watch(topicListProvider(currentSort).notifier).hasMore
                        ? const CircularProgressIndicator()
                        : const Text('没有更多了', style: TextStyle(color: Colors.grey)),
                  ),
                );
              }

              final topic = topics[topicIndex];
              final enableLongPress = ref.watch(preferencesProvider).longPressPreview;

              return buildTopicItem(
                context: context,
                topic: topic,
                isSelected: topic.id == selectedTopicId,
                onTap: () => _openTopic(topic),
                enableLongPress: enableLongPress,
              );
            },
          ),
        );
      },
      loading: () => const TopicListSkeleton(),
      error: (error, stack) => ErrorView(
        error: error,
        stackTrace: stack,
        onRetry: () => ref.refresh(topicListProvider(currentSort)),
      ),
    );
  }

  Widget _buildNewTopicIndicator(BuildContext context, int count, TopicListFilter currentSort) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isLoadingNewTopics ? null : () async {
            setState(() {
              _isLoadingNewTopics = true;
            });
            try {
              await ref.read(topicListProvider(currentSort).notifier).silentRefresh();
              ref.read(latestChannelProvider.notifier).clearNewTopics();

              if (mounted) {
                _scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            } finally {
              if (mounted) {
                setState(() {
                  _isLoadingNewTopics = false;
                });
              }
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _isLoadingNewTopics
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.arrow_upward,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '有 $count 条新话题，点击刷新',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
