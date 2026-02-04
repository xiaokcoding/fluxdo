import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_riverpod/legacy.dart';
import '../models/topic.dart';
import '../widgets/topic/topic_card.dart';
import '../providers/discourse_providers.dart';
import '../providers/message_bus_providers.dart';
import '../providers/selected_topic_provider.dart';
import 'webview_login_page.dart';
import 'topic_detail_page/topic_detail_page.dart';
import 'search_page.dart';
import '../widgets/common/notification_icon_button.dart';
import '../widgets/topic/topic_filter_sheet.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../widgets/topic/topic_preview_dialog.dart';
import '../providers/app_state_refresher.dart';
import '../providers/preferences_provider.dart';
import '../utils/responsive.dart';
import '../widgets/layout/master_detail_layout.dart';
import '../widgets/common/error_view.dart';
import '../widgets/common/loading_dialog.dart';

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

/// 帖子列表页面 - 支持多 Tab (最新、新、未读、排行榜、热门)
class TopicsPage extends ConsumerStatefulWidget {
  const TopicsPage({super.key});

  @override
  ConsumerState<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends ConsumerState<TopicsPage> with TickerProviderStateMixin {
  late TabController _tabController;
  List<TopicListFilter> _filters = [];
  final Map<TopicListFilter, GlobalKey<_TopicListState>> _listKeys = {};
  int _currentTabIndex = 0;

  @override
  void initState() {
    super.initState();
    final isLoggedIn = ref.read(currentUserProvider).value != null;
    _filters = _buildFilters(isLoggedIn: isLoggedIn);
    _tabController = TabController(length: _filters.length, vsync: this);
    _tabController.addListener(_handleTabChange);
    _initListKeys();
  }

  void _initListKeys() {
    for (final filter in _filters) {
      _listKeys[filter] = GlobalKey<_TopicListState>();
    }
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    super.dispose();
  }

  void _handleTabChange() {
    if (_currentTabIndex == _tabController.index) return;
    setState(() => _currentTabIndex = _tabController.index);
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

      // 等待用户数据和话题列表加载
      try {
        await Future.wait([
          ref.read(currentUserProvider.future),
          ref.read(topicListProvider(TopicListFilter.latest).future),
        ]).timeout(const Duration(seconds: 10));
      } catch (_) {
        // 超时或错误时继续
      }

      if (mounted) {
        LoadingDialog.hide(context);
      }
    }
  }

  List<TopicListFilter> _buildFilters({required bool isLoggedIn}) {
    if (isLoggedIn) {
      return [
        TopicListFilter.latest,
        TopicListFilter.newTopics,
        TopicListFilter.unread,
        TopicListFilter.top,
        TopicListFilter.hot,
      ];
    }
    return [
      TopicListFilter.latest,
      TopicListFilter.newTopics,
      TopicListFilter.top,
      TopicListFilter.hot,
    ];
  }

  List<String> _buildTitles(List<TopicListFilter> filters) {
    return filters.map((filter) {
      switch (filter) {
        case TopicListFilter.latest:
          return '最新';
        case TopicListFilter.newTopics:
          return '新';
        case TopicListFilter.unread:
          return '未读';
        case TopicListFilter.top:
          return '排行榜';
        case TopicListFilter.hot:
          return '热门';
      }
    }).toList();
  }

  void _syncTabsIfNeeded(bool isLoggedIn) {
    final desiredFilters = _buildFilters(isLoggedIn: isLoggedIn);
    if (listEquals(desiredFilters, _filters)) return;

    final currentIndex = _tabController.index;
    _tabController.removeListener(_handleTabChange);
    _tabController.dispose();
    _filters = desiredFilters;
    _listKeys.clear();
    _initListKeys();
    _tabController = TabController(length: _filters.length, vsync: this);
    _tabController.addListener(_handleTabChange);
    _currentTabIndex = currentIndex < _filters.length ? currentIndex : 0;
    _tabController.index = _currentTabIndex;
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
                    builder: (_) => TopicDetailPage(topicId: id),
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

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final isLoggedIn = ref.watch(currentUserProvider).value != null;
    _syncTabsIfNeeded(isLoggedIn);
    final titles = _buildTitles(_filters);
    final showSearchBar = ref.watch(topBarVisibleProvider);

    // 监听滚动到顶部的通知
    ref.listen(scrollToTopProvider, (previous, next) {
      final currentFilter = _filters[_tabController.index];
      _listKeys[currentFilter]?.currentState?.scrollToTop();
    });

    return Column(
      children: [
        // 搜索栏：下滑消失，上滑显示
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOutCubic,
          height: showSearchBar ? topPadding + 56 : topPadding,
          child: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            padding: EdgeInsets.only(top: topPadding + 8, left: 16, right: 16, bottom: 8),
            child: AnimatedOpacity(
              opacity: showSearchBar ? 1 : 0,
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
                          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha:0.5),
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
        // TabBar：固定显示，点击时恢复顶栏和底栏
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
                  child: TabBar(
                    controller: _tabController,
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: titles.map((t) => Tab(text: t)).toList(),
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold),
                    unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.normal),
                    dividerColor: Colors.transparent,
                  ),
                ),
                // 筛选按钮
                _FilterButton(),
              ],
            ),
          ),
        ),
        // 当前筛选条件
        const ActiveFiltersBar(),
        // 列表内容
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              for (var i = 0; i < _filters.length; i++)
                _TopicList(
                  key: _listKeys[_filters[i]],
                  filter: _filters[i],
                  isActive: (i - _currentTabIndex).abs() <= 1,
                  onLoginRequired: _goToLogin,
                  onScrollDirectionChanged: _onScrollDirectionChanged,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TopicList extends ConsumerStatefulWidget {
  final TopicListFilter filter;
  final bool isActive;
  final VoidCallback onLoginRequired;
  final ValueChanged<ScrollDirection> onScrollDirectionChanged;

  const _TopicList({
    super.key,
    required this.filter,
    required this.isActive,
    required this.onLoginRequired,
    required this.onScrollDirectionChanged,
  });

  @override
  ConsumerState<_TopicList> createState() => _TopicListState();
}

class _TopicListState extends ConsumerState<_TopicList> with AutomaticKeepAliveClientMixin {
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingNewTopics = false;
  bool _readyToBuild = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _readyToBuild = true);
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 加载更多
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200) {
      ref.read(topicListProvider(widget.filter).notifier).loadMore();
    }
    // 滚动方向
    final direction = _scrollController.position.userScrollDirection;
    if (direction != ScrollDirection.idle) {
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

    // 双栏可用：使用 Master-Detail 模式
    if (canShowDetailPane) {
      ref.read(selectedTopicProvider.notifier).select(
        topicId: topic.id,
        initialTitle: topic.title,
        scrollToPostNumber: topic.lastReadPostNumber,
      );
      return;
    }

    // 单栏：跳转页面
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          initialTitle: topic.title,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.isActive) {
      return const SizedBox.expand();
    }
    if (!_readyToBuild) {
      return const SizedBox.expand();
    }

    final currentUserAsync = ref.watch(currentUserProvider);
    final user = currentUserAsync.value;
    final selectedTopicId = ref.watch(selectedTopicProvider).topicId;

    if (user == null && !currentUserAsync.isLoading &&
        (widget.filter == TopicListFilter.newTopics || widget.filter == TopicListFilter.unread)) {
      return _buildLoginPrompt();
    }

    final topicsAsync = ref.watch(topicListProvider(widget.filter));
    
    return topicsAsync.when(
      data: (topics) {
        if (topics.isEmpty) {
           return RefreshIndicator(
             onRefresh: () => ref.refresh(topicListProvider(widget.filter).future),
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
        final hasNewTopics = widget.filter == TopicListFilter.latest && incomingState.hasIncoming;
        final newTopicCount = incomingState.incomingCount;
        final offset = hasNewTopics ? 1 : 0;

        return RefreshIndicator(
          onRefresh: () async {
             await ref.read(topicListProvider(widget.filter).notifier).silentRefresh();
             if (widget.filter == TopicListFilter.latest) {
               ref.read(latestChannelProvider.notifier).clearNewTopics();
             }
          },
          child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: topics.length + offset + 1,
            itemBuilder: (context, index) {
              Widget child;

              if (hasNewTopics && index == 0) {
                child = _buildNewTopicIndicator(context, newTopicCount);
              } else {
                final topicIndex = index - offset;
                if (topicIndex >= topics.length) {
                  child = Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Center(
                      child: ref.watch(topicListProvider(widget.filter).notifier).hasMore
                          ? const CircularProgressIndicator()
                          : const Text('没有更多了', style: TextStyle(color: Colors.grey)),
                    ),
                  );
                } else {
                  final topic = topics[topicIndex];
                  final isSelected = topic.id == selectedTopicId;
                  final enableLongPress = ref.watch(preferencesProvider).longPressPreview;
                  if (topic.pinned) {
                    child = CompactTopicCard(
                      topic: topic,
                      onTap: () => _openTopic(topic),
                      onLongPress: enableLongPress
                          ? () => TopicPreviewDialog.show(
                                context,
                                topic: topic,
                                onOpen: () => _openTopic(topic),
                              )
                          : null,
                      isSelected: isSelected,
                    );
                  } else {
                    child = TopicCard(
                      topic: topic,
                      onTap: () => _openTopic(topic),
                      onLongPress: enableLongPress
                          ? () => TopicPreviewDialog.show(
                                context,
                                topic: topic,
                                onOpen: () => _openTopic(topic),
                              )
                          : null,
                      isSelected: isSelected,
                    );
                  }
                }
              }

              // 大屏上限制内容宽度
              if (!Responsive.isMobile(context)) {
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: Breakpoints.maxContentWidth),
                    child: child,
                  ),
                );
              }
              return child;
            },
          ),
        );
      },
      loading: () => const TopicListSkeleton(),
      error: (error, stack) => ErrorView(
        error: error,
        stackTrace: stack,
        onRetry: () => ref.refresh(topicListProvider(widget.filter)),
      ),
    );
  }

  Widget _buildNewTopicIndicator(BuildContext context, int count) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha:0.2),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _isLoadingNewTopics ? null : () async {
            setState(() {
              _isLoadingNewTopics = true;
            });
            try {
              await ref.read(topicListProvider(widget.filter).notifier).silentRefresh();
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

  Widget _buildLoginPrompt() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lock_person,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '需要登录',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '登录后查看此类话题',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: widget.onLoginRequired,
              icon: const Icon(Icons.login),
              label: const Text('登录'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}


/// 筛选按钮
class _FilterButton extends ConsumerWidget {
  const _FilterButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(topicFilterProvider);
    final hasFilter = filter.isNotEmpty;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(right: 16, left: 8),
      child: Material(
        color: hasFilter ? colorScheme.primaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () {
            showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              backgroundColor: Colors.transparent,
              builder: (_) => const TopicFilterSheet(),
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hasFilter ? Icons.filter_alt : Icons.filter_alt_outlined,
                  size: 20,
                  color: hasFilter ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
                ),
                if (hasFilter) ...[
                  const SizedBox(width: 4),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
