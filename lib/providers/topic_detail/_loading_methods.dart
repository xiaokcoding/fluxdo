part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 加载相关方法
extension LoadingMethods on TopicDetailNotifier {
  /// 加载更早的帖子（向上滚动）
  Future<void> loadPrevious() async {
    if (_isFilteredMode) {
      if (!_hasMoreBefore || state.isLoading || _isLoadingPrevious) return;
      await _loadPreviousByStreamIds();
      return;
    }
    if (!_hasMoreBefore || state.isLoading || _isLoadingPrevious) return;
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

        final firstPostNumber = currentPosts.first.postNumber;
        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: firstPostNumber,
          asc: false,
        );

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...newPosts, ...currentPosts];
        mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts.map((p) => p.id).where((id) => !existingStreamIds.contains(id)).toList();
        final mergedStream = [...newPostIds, ...currentStream];

        final newFirstId = mergedPosts.first.id;
        final newFirstIndex = mergedStream.indexOf(newFirstId);
        _hasMoreBefore = newFirstIndex > 0;

        return currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: mergedStream),
        );
      });
    } finally {
      _isLoadingPrevious = false;
    }
  }

  /// 加载更多回复（向下滚动）
  Future<void> loadMore() async {
    if (!_hasMoreAfter || state.isLoading || _isLoadingMore) return;

    if (_isFilteredMode) {
      await _loadMoreByStreamIds();
      return;
    }
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

        final lastPostNumber = currentPosts.last.postNumber;
        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: lastPostNumber,
          asc: true,
        );

        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts.map((p) => p.id).where((id) => !existingStreamIds.contains(id)).toList();
        final mergedStream = [...currentStream, ...newPostIds];

        final newLastId = mergedPosts.last.id;
        final newLastIndex = mergedStream.indexOf(newLastId);
        _hasMoreAfter = newLastIndex < mergedStream.length - 1;

        return currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: mergedStream),
        );
      });
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 加载新回复（用于 MessageBus 实时更新）
  Future<void> loadNewReplies() async {
    if (state.isLoading) return;

    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    if (currentPosts.isEmpty) return;

    final lastPostNumber = currentPosts.last.postNumber;

    if (lastPostNumber < currentDetail.postsCount) {
      return;
    }

    final targetPostNumber = lastPostNumber + 1;

    try {
      final service = ref.read(discourseServiceProvider);
      final newDetail = await service.getTopicDetail(arg.topicId, postNumber: targetPostNumber);

      if (newDetail.postStream.posts.isEmpty) return;

      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = newDetail.postStream.posts.where((p) => !existingIds.contains(p.id)).toList();

      if (newPosts.isEmpty) return;

      final mergedPosts = [...currentPosts, ...newPosts];
      mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      final mergedStream = newDetail.postStream.stream;

      _updateBoundaryState(mergedPosts, mergedStream);

      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: newDetail.postsCount,
        postStream: PostStream(posts: mergedPosts, stream: mergedStream),
        canVote: newDetail.canVote,
        voteCount: newDetail.voteCount,
        userVoted: newDetail.userVoted,
      ));
    } catch (e) {
      debugPrint('[TopicDetail] 加载新回复失败: $e');
    }
  }

  /// 使用新的起始帖子号重新加载数据
  Future<void> reloadWithPostNumber(int postNumber) async {
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

  /// 刷新当前话题详情（保持列表可见）
  Future<void> refreshWithPostNumber(int postNumber) async {
    if (state.isLoading) return;

    // ignore: invalid_use_of_internal_member
    state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

    state = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: _isFilteredMode ? null : postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
      );

      _updateBoundaryState(detail.postStream.posts, detail.postStream.stream);

      return detail;
    });
  }

  /// 加载指定楼层的帖子（用于跳转）
  Future<int> loadPostNumber(int postNumber) async {
    final currentDetail = state.value;
    if (currentDetail == null) return -1;

    final currentPosts = currentDetail.postStream.posts;

    final existingIndex = currentPosts.indexWhere((p) => p.postNumber == postNumber);
    if (existingIndex != -1) return existingIndex;

    try {
      final service = ref.read(discourseServiceProvider);
      final newDetail = await service.getTopicDetail(arg.topicId, postNumber: postNumber);

      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = newDetail.postStream.posts.where((p) => !existingIds.contains(p.id)).toList();
      final mergedPosts = [...currentPosts, ...newPosts];
      mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      final currentStream = currentDetail.postStream.stream;
      final newStream = newDetail.postStream.stream;
      final existingStreamIds = currentStream.toSet();
      final newStreamIds = newStream.where((id) => !existingStreamIds.contains(id)).toList();
      final mergedStream = [...currentStream, ...newStreamIds];

      _updateBoundaryState(mergedPosts, mergedStream);

      state = AsyncValue.data(currentDetail.copyWith(
        postStream: PostStream(posts: mergedPosts, stream: mergedStream),
      ));

      return mergedPosts.indexWhere((p) => p.postNumber == postNumber);
    } catch (e) {
      debugPrint('[TopicDetail] 加载帖子 #$postNumber 失败: $e');
      return -1;
    }
  }
}
