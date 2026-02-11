import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import '../services/preloaded_data_service.dart';
import '../services/discourse/discourse_service.dart';
import '../utils/pagination_helper.dart';
import '../widgets/topic/topic_filter_sheet.dart';
import 'core_providers.dart';

enum TopicListFilter {
  latest,
  newTopics,
  unread,
  top,
  hot,
}

/// TopicListFilter 扩展方法
extension TopicListFilterX on TopicListFilter {
  /// 获取 API 请求所用的过滤器名称
  String get filterName {
    switch (this) {
      case TopicListFilter.latest:
        return 'latest';
      case TopicListFilter.newTopics:
        return 'new';
      case TopicListFilter.unread:
        return 'unread';
      case TopicListFilter.top:
        return 'top';
      case TopicListFilter.hot:
        return 'top/weekly';
    }
  }
}

/// 话题列表 Notifier (支持分页、静默刷新和筛选)
class TopicListNotifier extends AsyncNotifier<List<Topic>> {
  TopicListNotifier(this.arg);

  final TopicListFilter arg;

  int _page = 0;
  bool _hasMore = true;
  bool get hasMore => _hasMore;

  /// 分页助手
  static final _paginationHelper = PaginationHelpers.forTopics<Topic>(
    keyExtractor: (topic) => topic.id,
  );

  @override
  Future<List<Topic>> build() async {
    // 监听筛选条件变化
    final filter = ref.watch(topicFilterProvider);

    _page = 0;
    _hasMore = true;

    // 优化：如果是 latest 列表且没有筛选条件，优先同步使用预加载数据
    // 这样可以避免显示 loading 状态
    if (arg == TopicListFilter.latest && filter.isEmpty) {
      final preloadedService = PreloadedDataService();
      final preloadedData = preloadedService.getInitialTopicListSync();
      if (preloadedData != null) {
        final result = _paginationHelper.processRefresh(
          PaginationResult(items: preloadedData.topics, moreUrl: preloadedData.moreTopicsUrl),
        );
        _hasMore = result.hasMore;
        return result.items;
      }
      if (preloadedService.hasInitialTopicList) {
        final asyncPreloaded = await preloadedService.getInitialTopicList();
        if (asyncPreloaded != null) {
          final result = _paginationHelper.processRefresh(
            PaginationResult(items: asyncPreloaded.topics, moreUrl: asyncPreloaded.moreTopicsUrl),
          );
          _hasMore = result.hasMore;
          return result.items;
        }
      }
    }

    // 如果没有预加载数据，走正常的异步流程
    final service = ref.read(discourseServiceProvider);
    final response = await _fetchTopics(service, arg, 0, filter);

    final result = _paginationHelper.processRefresh(
      PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
    );
    _hasMore = result.hasMore;
    return result.items;
  }

  Future<TopicListResponse> _fetchTopics(
    DiscourseService service,
    TopicListFilter filter,
    int page,
    TopicFilterParams filterParams,
  ) {
    // 如果有筛选条件，使用 getFilteredTopics
    if (filterParams.isNotEmpty) {
      final filterName = _getFilterName(filter);
      return service.getFilteredTopics(
        filter: filterName,
        categoryId: filterParams.categoryId,
        categorySlug: filterParams.categorySlug,
        parentCategorySlug: filterParams.parentCategorySlug,
        tags: filterParams.tags.isNotEmpty ? filterParams.tags : null,
        page: page,
      );
    }

    // 无筛选条件，使用原有方法
    switch (filter) {
      case TopicListFilter.latest:
        return service.getLatestTopics(page: page);
      case TopicListFilter.newTopics:
        return service.getNewTopics(page: page);
      case TopicListFilter.unread:
        return service.getUnreadTopics(page: page);
      case TopicListFilter.top:
        return service.getTopTopics();
      case TopicListFilter.hot:
        return service.getHotTopics(page: page);
    }
  }

  String _getFilterName(TopicListFilter filter) => filter.filterName;

  /// 刷新列表
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(() async {
      _page = 0;
      _hasMore = true;
      final service = ref.read(discourseServiceProvider);
      final filterParams = ref.read(topicFilterProvider);
      final response = await _fetchTopics(service, arg, 0, filterParams);

      final result = _paginationHelper.processRefresh(
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
      );
      _hasMore = result.hasMore;
      return result.items;
    });
  }

  /// 静默刷新
  Future<void> silentRefresh() async {
    final service = ref.read(discourseServiceProvider);
    final filterParams = ref.read(topicFilterProvider);
    try {
      final response = await _fetchTopics(service, arg, 0, filterParams);
      _page = 0;

      final result = _paginationHelper.processRefresh(
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
      );
      _hasMore = result.hasMore;
      state = AsyncValue.data(result.items);
    } catch (e) {
      debugPrint('Silent refresh failed: $e');
    }
  }

  /// 加载更多
  Future<void> loadMore() async {
    if (!_hasMore || state.isLoading) return;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<List<Topic>>().copyWithPrevious(state);

    state = await AsyncValue.guard(() async {
      final currentTopics = state.requireValue;
      final nextPage = _page + 1;

      final service = ref.read(discourseServiceProvider);
      final filterParams = ref.read(topicFilterProvider);
      final response = await _fetchTopics(service, arg, nextPage, filterParams);

      final currentState = PaginationState(items: currentTopics);
      final result = _paginationHelper.processLoadMore(
        currentState,
        PaginationResult(items: response.topics, moreUrl: response.moreTopicsUrl),
      );

      _hasMore = result.hasMore;
      if (result.items.length > currentTopics.length) {
        _page = nextPage;
      }
      return result.items;
    });
  }

  /// 刷新单条话题状态（用于 MessageBus 更新）
  Future<void> refreshTopic(int topicId) async {
    final currentTopics = state.value;
    if (currentTopics == null) return;

    final existingIndex = currentTopics.indexWhere((t) => t.id == topicId);
    if (existingIndex == -1) {
      return;
    }
    final existingTopic = currentTopics[existingIndex];

    try {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(topicId);

      final updatedTopic = Topic(
        id: detail.id,
        title: detail.title,
        slug: detail.slug,
        categoryId: detail.categoryId.toString(),
        postsCount: detail.postsCount,
        replyCount: detail.postsCount > 0 ? detail.postsCount - 1 : 0,
        views: existingTopic.views,
        likeCount: existingTopic.likeCount,
        lastPostedAt: existingTopic.lastPostedAt,
        pinned: existingTopic.pinned,
        tags: detail.tags ?? existingTopic.tags,
        posters: existingTopic.posters,
        unseen: false,
        unread: 0,
        lastReadPostNumber: detail.postsCount,
        highestPostNumber: detail.postsCount,
        lastPosterUsername: detail.postStream.posts.isNotEmpty
            ? detail.postStream.posts.last.username
            : existingTopic.lastPosterUsername,
      );

      final newList = currentTopics.map((t) {
        return t.id == topicId ? updatedTopic : t;
      }).toList();

      state = AsyncValue.data(newList);
    } catch (e) {
      debugPrint('[TopicList] 刷新话题 $topicId 失败: $e');
    }
  }

  void updateSeen(int topicId, int highestSeen) {
    final topics = state.value;
    if (topics == null) return;

    final index = topics.indexWhere((t) => t.id == topicId);
    if (index == -1) return;

    final topic = topics[index];
    final currentRead = topic.lastReadPostNumber ?? 0;

    if (highestSeen <= currentRead) return;

    final newUnread = (topic.highestPostNumber - highestSeen).clamp(0, topic.highestPostNumber);

    final updated = Topic(
      id: topic.id,
      title: topic.title,
      slug: topic.slug,
      postsCount: topic.postsCount,
      replyCount: topic.replyCount,
      views: topic.views,
      likeCount: topic.likeCount,
      excerpt: topic.excerpt,
      createdAt: topic.createdAt,
      lastPostedAt: topic.lastPostedAt,
      lastPosterUsername: topic.lastPosterUsername,
      categoryId: topic.categoryId,
      pinned: topic.pinned,
      visible: topic.visible,
      closed: topic.closed,
      archived: topic.archived,
      tags: topic.tags,
      posters: topic.posters,
      unseen: false,
      unread: newUnread,
      newPosts: 0,
      lastReadPostNumber: highestSeen,
      highestPostNumber: topic.highestPostNumber,
    );

    final newList = [...topics];
    newList[index] = updated;
    state = AsyncValue.data(newList);
  }
}

final topicListProvider = AsyncNotifierProvider.family<TopicListNotifier, List<Topic>, TopicListFilter>(
  TopicListNotifier.new,
);

/// 热门话题 Provider
final topTopicsProvider = FutureProvider<TopicListResponse>((ref) async {
  final service = ref.watch(discourseServiceProvider);
  return service.getTopTopics();
});
