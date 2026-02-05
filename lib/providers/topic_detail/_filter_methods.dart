part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 过滤模式相关方法
extension FilterMethods on TopicDetailNotifier {
  /// 切换到热门回复模式
  Future<void> showTopReplies() async {
    if (_filter == 'summary') return;
    _filter = 'summary';
    _usernameFilter = null;
    await _reloadWithFilter();
  }

  /// 切换到只看题主模式
  Future<void> showAuthorOnly(String username) async {
    if (_usernameFilter == username) return;
    _usernameFilter = username;
    _filter = null;
    await _reloadWithFilter();
  }

  /// 取消过滤，显示全部回复
  Future<void> cancelFilter() async {
    if (_filter == null && _usernameFilter == null) return;
    _filter = null;
    _usernameFilter = null;
    await _reloadWithFilter();
  }

  /// 取消过滤并跳转到指定帖子
  Future<void> cancelFilterAndReloadWithPostNumber(int postNumber) async {
    _filter = null;
    _usernameFilter = null;
    state = const AsyncValue.loading();
    _hasMoreAfter = true;
    _hasMoreBefore = true;

    await Future.delayed(Duration.zero);

    state = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return detail;
    });
  }

  /// 使用当前 filter 重新加载数据
  Future<void> _reloadWithFilter() async {
    state = const AsyncValue.loading();
    _hasMoreAfter = true;
    _hasMoreBefore = true;

    state = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(arg.topicId, filter: _filter, usernameFilters: _usernameFilter);

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return detail;
    });
  }

  /// 过滤模式下根据 stream ID 加载更多帖子
  Future<void> _loadMoreByStreamIds() async {
    _isLoadingMore = true;

    try {
      // ignore: invalid_use_of_internal_member
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      state = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final lastPostId = currentPosts.last.id;
        final lastIndex = stream.indexOf(lastPostId);

        if (lastIndex == -1 || lastIndex >= stream.length - 1) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final nextIds = stream.sublist(
          lastIndex + 1,
          (lastIndex + 21).clamp(0, stream.length),
        );

        if (nextIds.isEmpty) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPosts(arg.topicId, nextIds);

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        mergedPosts.sort((a, b) => stream.indexOf(a.id).compareTo(stream.indexOf(b.id)));

        final newLastId = mergedPosts.last.id;
        final newLastIndex = stream.indexOf(newLastId);
        _hasMoreAfter = newLastIndex < stream.length - 1;

        return currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: stream),
        );
      });
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 过滤模式下根据 stream ID 加载更早的帖子
  Future<void> _loadPreviousByStreamIds() async {
    _isLoadingPrevious = true;

    try {
      // ignore: invalid_use_of_internal_member
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      state = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final firstPostId = currentPosts.first.id;
        final firstIndex = stream.indexOf(firstPostId);

        if (firstIndex <= 0) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final start = (firstIndex - 20).clamp(0, firstIndex);
        final prevIds = stream.sublist(start, firstIndex);

        if (prevIds.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPosts(arg.topicId, prevIds);

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        mergedPosts.sort((a, b) => stream.indexOf(a.id).compareTo(stream.indexOf(b.id)));

        final newFirstId = mergedPosts.first.id;
        final newFirstIndex = stream.indexOf(newFirstId);
        _hasMoreBefore = newFirstIndex > 0;

        return currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: stream),
        );
      });
    } finally {
      _isLoadingPrevious = false;
    }
  }
}
