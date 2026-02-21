import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/search_filter.dart';
import '../models/topic.dart';
import '../providers/discourse_providers.dart';
import '../providers/user_content_search_provider.dart';
import '../widgets/search/searchable_app_bar.dart';
import '../widgets/search/user_content_search_view.dart';
import '../widgets/topic/topic_item_builder.dart';
import '../widgets/topic/topic_list_skeleton.dart';
import '../providers/preferences_provider.dart';
import '../widgets/common/error_view.dart';
import 'topic_detail_page/topic_detail_page.dart';

/// 浏览历史页面
class BrowsingHistoryPage extends ConsumerStatefulWidget {
  const BrowsingHistoryPage({super.key});

  @override
  ConsumerState<BrowsingHistoryPage> createState() => _BrowsingHistoryPageState();
}

class _BrowsingHistoryPageState extends ConsumerState<BrowsingHistoryPage> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    // 清理搜索状态，防止重新进入时仍处于搜索模式
    ref.read(userContentSearchProvider(SearchInType.seen).notifier).exitSearchMode();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(browsingHistoryProvider.notifier).loadMore();
    }
  }

  Future<void> _onRefresh() async {
    await ref.read(browsingHistoryProvider.notifier).refresh();
  }

  void _onItemTap(Topic topic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          scrollToPostNumber: topic.lastReadPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(browsingHistoryProvider);
    final searchState = ref.watch(userContentSearchProvider(SearchInType.seen));

    return PopScope(
      canPop: !searchState.isSearchMode,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          // 搜索模式下按返回键，退出搜索而不是退出页面
          ref.read(userContentSearchProvider(SearchInType.seen).notifier).exitSearchMode();
        }
      },
      child: Scaffold(
        appBar: SearchableAppBar(
          title: '浏览历史',
          isSearchMode: searchState.isSearchMode,
          onSearchPressed: () => ref
              .read(userContentSearchProvider(SearchInType.seen).notifier)
              .enterSearchMode(),
          onCloseSearch: () => ref
              .read(userContentSearchProvider(SearchInType.seen).notifier)
              .exitSearchMode(),
          onSearch: (query) => ref
              .read(userContentSearchProvider(SearchInType.seen).notifier)
              .search(query),
          showFilterButton: searchState.isSearchMode,
          filterActive: searchState.filter.isNotEmpty,
          onFilterPressed: () =>
              showSearchFilterPanel(context, ref, SearchInType.seen),
          searchHint: '在浏览历史中搜索...',
        ),
        body: Stack(
          children: [
            // 使用 Offstage 保持列表存在但在搜索模式下隐藏，保留滚动位置
            Offstage(
              offstage: searchState.isSearchMode,
              child: _buildTopicList(historyAsync),
            ),
            if (searchState.isSearchMode)
              const UserContentSearchView(
                inType: SearchInType.seen,
                emptySearchHint: '输入关键词搜索浏览历史',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopicList(AsyncValue<List<Topic>> historyAsync) {
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: historyAsync.when(
        data: (topics) {
          if (topics.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('暂无浏览历史', style: TextStyle(color: Colors.grey)),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            itemCount: topics.length + 1,
            itemBuilder: (context, index) {
              if (index == topics.length) {
                final hasMore = ref.read(browsingHistoryProvider.notifier).hasMore;
                if (!hasMore) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(
                      child: Text(
                        '没有更多了',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  );
                }
                if (historyAsync.isLoading) {
                  return const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return const SizedBox();
              }

              final topic = topics[index];
              final enableLongPress = ref.watch(preferencesProvider).longPressPreview;
              return buildTopicItem(
                context: context,
                topic: topic,
                isSelected: false,
                onTap: () => _onItemTap(topic),
                enableLongPress: enableLongPress,
              );
            },
          );
        },
        loading: () => const TopicListSkeleton(),
        error: (error, stack) => ErrorView(
          error: error,
          stackTrace: stack,
          onRetry: _onRefresh,
        ),
      ),
    );
  }
}
