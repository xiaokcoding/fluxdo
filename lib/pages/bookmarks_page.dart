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

/// 我的书签页面
class BookmarksPage extends ConsumerStatefulWidget {
  const BookmarksPage({super.key});

  @override
  ConsumerState<BookmarksPage> createState() => _BookmarksPageState();
}

class _BookmarksPageState extends ConsumerState<BookmarksPage> {
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
    ref.read(userContentSearchProvider(SearchInType.bookmarks).notifier).exitSearchMode();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(bookmarksProvider.notifier).loadMore();
    }
  }

  Future<void> _onRefresh() async {
    await ref.read(bookmarksProvider.notifier).refresh();
  }

  void _onItemTap(Topic topic) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TopicDetailPage(
          topicId: topic.id,
          // 帖子书签跳转到被书签的帖子，话题书签使用最后阅读位置
          scrollToPostNumber: topic.bookmarkedPostNumber ?? topic.lastReadPostNumber,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bookmarksAsync = ref.watch(bookmarksProvider);
    final searchState = ref.watch(userContentSearchProvider(SearchInType.bookmarks));

    return PopScope(
      canPop: !searchState.isSearchMode,
      onPopInvokedWithResult: (bool didPop, dynamic result) {
        if (!didPop) {
          // 搜索模式下按返回键，退出搜索而不是退出页面
          ref.read(userContentSearchProvider(SearchInType.bookmarks).notifier).exitSearchMode();
        }
      },
      child: Scaffold(
        appBar: SearchableAppBar(
          title: '我的书签',
          isSearchMode: searchState.isSearchMode,
          onSearchPressed: () => ref
              .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
              .enterSearchMode(),
          onCloseSearch: () => ref
              .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
              .exitSearchMode(),
          onSearch: (query) => ref
              .read(userContentSearchProvider(SearchInType.bookmarks).notifier)
              .search(query),
          showFilterButton: searchState.isSearchMode,
          filterActive: searchState.filter.isNotEmpty,
          onFilterPressed: () =>
              showSearchFilterPanel(context, ref, SearchInType.bookmarks),
          searchHint: '在书签中搜索...',
        ),
        body: Stack(
          children: [
            // 使用 Offstage 保持列表存在但在搜索模式下隐藏，保留滚动位置
            Offstage(
              offstage: searchState.isSearchMode,
              child: _buildTopicList(bookmarksAsync),
            ),
            if (searchState.isSearchMode)
              const UserContentSearchView(
                inType: SearchInType.bookmarks,
                emptySearchHint: '输入关键词搜索书签',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopicList(AsyncValue<List<Topic>> bookmarksAsync) {
    return RefreshIndicator(
      onRefresh: _onRefresh,
      child: bookmarksAsync.when(
        data: (topics) {
          if (topics.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.bookmark_border, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('暂无书签', style: TextStyle(color: Colors.grey)),
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
                final hasMore = ref.read(bookmarksProvider.notifier).hasMore;
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
                if (bookmarksAsync.isLoading) {
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
