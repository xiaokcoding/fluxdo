import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/topic.dart';
import 'core_providers.dart';

/// 话题详情参数
/// 使用 instanceId 确保每次打开页面都是独立的 provider 实例
/// 解决：打开话题 -> 点击用户 -> 再进入同一话题时应该是新的页面状态
class TopicDetailParams {
  final int topicId;
  final int? postNumber;
  /// 唯一实例 ID，确保每次打开页面都创建新的 provider 实例
  /// 默认为空字符串，用于 MessageBus 等不需要精确匹配的场景
  final String instanceId;

  const TopicDetailParams(this.topicId, {this.postNumber, this.instanceId = ''});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TopicDetailParams &&
          topicId == other.topicId &&
          instanceId == other.instanceId;

  @override
  int get hashCode => Object.hash(topicId, instanceId);
}

/// 话题详情 Notifier (支持双向加载)
class TopicDetailNotifier extends AsyncNotifier<TopicDetail> {
  TopicDetailNotifier(this.arg);
  final TopicDetailParams arg;

  bool _hasMoreAfter = true;
  bool _hasMoreBefore = true;
  bool _isLoadingPrevious = false;
  bool _isLoadingMore = false;
  String? _filter;  // 当前过滤模式（如 'summary' 表示热门回复）
  String? _usernameFilter;  // 当前用户名过滤（如只看题主）

  bool get hasMoreAfter => _hasMoreAfter;
  bool get hasMoreBefore => _hasMoreBefore;
  bool get isLoadingPrevious => _isLoadingPrevious;
  bool get isLoadingMore => _isLoadingMore;
  bool get isSummaryMode => _filter == 'summary';
  bool get isAuthorOnlyMode => _usernameFilter != null;
  bool get _isFilteredMode => _filter != null || _usernameFilter != null;

  @override
  Future<TopicDetail> build() async {
    print('[TopicDetailNotifier] build called with topicId=${arg.topicId}, postNumber=${arg.postNumber}');
    _hasMoreAfter = true;
    _hasMoreBefore = true;
    final service = ref.read(discourseServiceProvider);
    // 初始加载时传 trackVisit: true，记录用户访问
    final detail = await service.getTopicDetail(arg.topicId, postNumber: arg.postNumber, trackVisit: true);

    final posts = detail.postStream.posts;
    final stream = detail.postStream.stream;
    if (posts.isEmpty) {
      _hasMoreAfter = false;
      _hasMoreBefore = false;
    } else {
      final firstPostId = posts.first.id;
      final firstIndex = stream.indexOf(firstPostId);
      _hasMoreBefore = firstIndex > 0;

      final lastPostId = posts.last.id;
      final lastIndex = stream.indexOf(lastPostId);
      _hasMoreAfter = lastIndex < stream.length - 1;
    }

    return detail;
  }

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

      final posts = detail.postStream.posts;
      final stream = detail.postStream.stream;
      if (posts.isEmpty) {
        _hasMoreAfter = false;
        _hasMoreBefore = false;
      } else {
        final firstPostId = posts.first.id;
        final firstIndex = stream.indexOf(firstPostId);
        _hasMoreBefore = firstIndex > 0;

        final lastPostId = posts.last.id;
        final lastIndex = stream.indexOf(lastPostId);
        _hasMoreAfter = lastIndex < stream.length - 1;
      }

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

      final posts = detail.postStream.posts;
      final stream = detail.postStream.stream;
      if (posts.isEmpty) {
        _hasMoreAfter = false;
        _hasMoreBefore = false;
      } else {
        final firstPostId = posts.first.id;
        final firstIndex = stream.indexOf(firstPostId);
        _hasMoreBefore = firstIndex > 0;

        final lastPostId = posts.last.id;
        final lastIndex = stream.indexOf(lastPostId);
        _hasMoreAfter = lastIndex < stream.length - 1;
      }

      return detail;
    });
  }

  /// 过滤模式下根据 stream ID 加载更多帖子
  Future<void> _loadMoreByStreamIds() async {
    _isLoadingMore = true;

    try {
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      state = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        // 找到已加载的最后一个帖子在 stream 中的位置
        final lastPostId = currentPosts.last.id;
        final lastIndex = stream.indexOf(lastPostId);

        if (lastIndex == -1 || lastIndex >= stream.length - 1) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        // 获取下一批帖子 ID（最多 20 个）
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

        // 合并帖子
        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        mergedPosts.sort((a, b) => stream.indexOf(a.id).compareTo(stream.indexOf(b.id)));

        // 检查是否还有更多
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
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      state = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;
        final stream = currentDetail.postStream.stream;

        if (currentPosts.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        // 找到已加载的第一个帖子在 stream 中的位置
        final firstPostId = currentPosts.first.id;
        final firstIndex = stream.indexOf(firstPostId);

        if (firstIndex <= 0) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        // 获取上一批帖子 ID（最多 20 个）
        final start = (firstIndex - 20).clamp(0, firstIndex);
        final prevIds = stream.sublist(start, firstIndex);

        if (prevIds.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final service = ref.read(discourseServiceProvider);
        final newPostStream = await service.getPosts(arg.topicId, prevIds);

        // 合并帖子
        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        mergedPosts.sort((a, b) => stream.indexOf(a.id).compareTo(stream.indexOf(b.id)));

        // 检查是否还有更多
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
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      state = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;

        if (currentPosts.isEmpty) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final firstPostNumber = currentPosts.first.postNumber;
        if (firstPostNumber <= 1) {
          _hasMoreBefore = false;
          return currentDetail;
        }

        final service = ref.read(discourseServiceProvider);
        // 使用 posts.json 接口，向上加载（asc: false）
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: firstPostNumber,
          asc: false,
        );

        // 合并帖子：新加载的 + 当前的（去重）
        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...newPosts, ...currentPosts];
        mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

        // 合并 stream：将新帖子的 ID 添加到 stream 中（向前插入）
        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts.map((p) => p.id).where((id) => !existingStreamIds.contains(id)).toList();
        final mergedStream = [...newPostIds, ...currentStream];

        _hasMoreBefore = mergedPosts.first.postNumber > 1;

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

    // 过滤模式下使用 stream ID 加载
    if (_isFilteredMode) {
      await _loadMoreByStreamIds();
      return;
    }
    _isLoadingMore = true;

    try {
      state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

      state = await AsyncValue.guard(() async {
        final currentDetail = state.requireValue;
        final currentPosts = currentDetail.postStream.posts;

        if (currentPosts.isEmpty) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final lastPostNumber = currentPosts.last.postNumber;
        if (lastPostNumber >= currentDetail.postsCount) {
          _hasMoreAfter = false;
          return currentDetail;
        }

        final service = ref.read(discourseServiceProvider);
        // 使用 posts.json 接口，向下加载（asc: true）
        final newPostStream = await service.getPostsByNumber(
          arg.topicId,
          postNumber: lastPostNumber,
          asc: true,
        );

        // 合并帖子：当前的 + 新加载的（去重）
        final existingIds = currentPosts.map((p) => p.id).toSet();
        final newPosts = newPostStream.posts.where((p) => !existingIds.contains(p.id)).toList();
        final mergedPosts = [...currentPosts, ...newPosts];
        mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

        // 合并 stream：将新帖子的 ID 添加到 stream 中（向后追加）
        final currentStream = currentDetail.postStream.stream;
        final existingStreamIds = currentStream.toSet();
        final newPostIds = newPosts.map((p) => p.id).where((id) => !existingStreamIds.contains(id)).toList();
        final mergedStream = [...currentStream, ...newPostIds];

        _hasMoreAfter = mergedPosts.last.postNumber < currentDetail.postsCount;

        return currentDetail.copyWith(
          postStream: PostStream(posts: mergedPosts, stream: mergedStream),
        );
      });
    } finally {
      _isLoadingMore = false;
    }
  }

  /// 加载新回复（用于 MessageBus 实时更新）
  /// 只有当已加载到最后一页时才会执行
  Future<void> loadNewReplies() async {
    // 只检查是否正在加载，移除 _hasMoreAfter 检查
    if (state.isLoading) return;

    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    if (currentPosts.isEmpty) return;

    final lastPostNumber = currentPosts.last.postNumber;

    // 通过比较最后一个帖子号和总帖子数来判断是否在底部
    // 这样即使 _hasMoreAfter 被重置也不影响判断
    if (lastPostNumber < currentDetail.postsCount) {
      // 还有更多帖子未加载到，说明不在底部，不执行新回复加载
      return;
    }

    // 从最后一个帖子往后加载
    final targetPostNumber = lastPostNumber + 1;
    
    try {
      final service = ref.read(discourseServiceProvider);
      final newDetail = await service.getTopicDetail(arg.topicId, postNumber: targetPostNumber);
      
      // 如果没有新帖子
      if (newDetail.postStream.posts.isEmpty) return;
      
      // 合并帖子
      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = newDetail.postStream.posts.where((p) => !existingIds.contains(p.id)).toList();
      
      if (newPosts.isEmpty) return;
      
      final mergedPosts = [...currentPosts, ...newPosts];
      mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));
      
      // 合并 stream：将新帖子的 ID 添加到 stream 中
      final currentStream = currentDetail.postStream.stream;
      final existingStreamIds = currentStream.toSet();
      final newPostIds = newPosts.map((p) => p.id).where((id) => !existingStreamIds.contains(id)).toList();
      final mergedStream = [...currentStream, ...newPostIds];
      
      _hasMoreAfter = mergedPosts.last.postNumber < newDetail.postsCount;
      
      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: newDetail.postsCount,
        postStream: PostStream(posts: mergedPosts, stream: mergedStream),
        canVote: newDetail.canVote,
        voteCount: newDetail.voteCount,
        userVoted: newDetail.userVoted,
      ));
    } catch (e) {
      print('[TopicDetail] 加载新回复失败: $e');
    }
  }

  /// 刷新单个帖子（用于 MessageBus revised/rebaked 消息）
  Future<void> refreshPost(int postId, {bool preserveCooked = false}) async {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    try {
      final service = ref.read(discourseServiceProvider);
      final postNumber = currentPosts[index].postNumber;
      final newDetail = await service.getTopicDetail(arg.topicId, postNumber: postNumber);
      
      // 找到更新后的帖子
      final updatedPost = newDetail.postStream.posts.firstWhere(
        (p) => p.id == postId,
        orElse: () => currentPosts[index],
      );
      
      // 如果需要保留 cooked（如 acted 类型），则只更新其他字段
      final finalPost = preserveCooked 
          ? Post(
              id: updatedPost.id,
              name: updatedPost.name,
              username: updatedPost.username,
              avatarTemplate: updatedPost.avatarTemplate,
              cooked: currentPosts[index].cooked, // 保留原 cooked
              postNumber: updatedPost.postNumber,
              postType: updatedPost.postType,
              updatedAt: updatedPost.updatedAt,
              createdAt: updatedPost.createdAt,
              likeCount: updatedPost.likeCount,
              replyCount: updatedPost.replyCount,
              replyToPostNumber: updatedPost.replyToPostNumber,
              replyToUser: updatedPost.replyToUser,
              scoreHidden: updatedPost.scoreHidden,
              canEdit: updatedPost.canEdit,
              canDelete: updatedPost.canDelete,
              canRecover: updatedPost.canRecover,
              canWiki: updatedPost.canWiki,
              bookmarked: updatedPost.bookmarked,
              read: currentPosts[index].read, // 保留原 read 状态
              actionsSummary: updatedPost.actionsSummary,
              linkCounts: updatedPost.linkCounts,
              reactions: updatedPost.reactions,
              currentUserReaction: updatedPost.currentUserReaction,
            )
          : updatedPost;
      
      final newPosts = [...currentPosts];
      newPosts[index] = finalPost;
      
      state = AsyncValue.data(currentDetail.copyWith(
        postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream),
      ));
    } catch (e) {
      print('[TopicDetail] 刷新帖子 $postId 失败: $e');
    }
  }

  /// 从列表中移除帖子（用于 MessageBus destroyed 消息）
  void removePost(int postId) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final newPosts = currentPosts.where((p) => p.id != postId).toList();
    
    if (newPosts.length == currentPosts.length) return; // 没有变化

    state = AsyncValue.data(currentDetail.copyWith(
      postsCount: currentDetail.postsCount - 1,
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream),
    ));
  }

  /// 标记帖子被删除（用于 MessageBus deleted 消息）
  /// 对于软删除，通常只是标记状态而不是移除
  void markPostDeleted(int postId) {
    // 对于软删除，我们可以刷新该帖子来获取最新状态
    refreshPost(postId);
  }

  /// 标记帖子已恢复（用于 MessageBus recovered 消息）
  void markPostRecovered(int postId) {
    // 刷新该帖子来获取最新状态
    refreshPost(postId);
  }

  /// 更新帖子点赞数（用于 MessageBus liked/unliked 消息）
  void updatePostLikes(int postId, {int? likesCount}) {
    if (likesCount == null) {
      // 如果没有提供点赞数，刷新整个帖子
      refreshPost(postId, preserveCooked: true);
      return;
    }
    
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final oldPost = currentPosts[index];
    
    // 只更新 likeCount
    final updatedPost = Post(
      id: oldPost.id,
      name: oldPost.name,
      username: oldPost.username,
      avatarTemplate: oldPost.avatarTemplate,
      cooked: oldPost.cooked,
      postNumber: oldPost.postNumber,
      postType: oldPost.postType,
      updatedAt: oldPost.updatedAt,
      createdAt: oldPost.createdAt,
      likeCount: likesCount,
      replyCount: oldPost.replyCount,
      replyToPostNumber: oldPost.replyToPostNumber,
      replyToUser: oldPost.replyToUser,
      scoreHidden: oldPost.scoreHidden,
      canEdit: oldPost.canEdit,
      canDelete: oldPost.canDelete,
      canRecover: oldPost.canRecover,
      canWiki: oldPost.canWiki,
      bookmarked: oldPost.bookmarked,
      read: oldPost.read,
      actionsSummary: oldPost.actionsSummary,
      linkCounts: oldPost.linkCounts,
      reactions: oldPost.reactions,
      currentUserReaction: oldPost.currentUserReaction,
    );
    
    final newPosts = [...currentPosts];
    newPosts[index] = updatedPost;

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream),
    ));
  }

  /// 更新单个帖子的点赞/回应状态
  void updatePostReaction(int postId, List<PostReaction> reactions, PostReaction? currentUserReaction) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == postId);
    if (index == -1) return;

    final oldPost = currentPosts[index];

    // 创建新的 Post 对象，只更新 reactions 和 currentUserReaction
    final updatedPost = Post(
      id: oldPost.id,
      name: oldPost.name,
      username: oldPost.username,
      avatarTemplate: oldPost.avatarTemplate,
      cooked: oldPost.cooked,
      postNumber: oldPost.postNumber,
      postType: oldPost.postType,
      updatedAt: oldPost.updatedAt,
      createdAt: oldPost.createdAt,
      likeCount: oldPost.likeCount,
      replyCount: oldPost.replyCount,
      replyToPostNumber: oldPost.replyToPostNumber,
      replyToUser: oldPost.replyToUser,
      scoreHidden: oldPost.scoreHidden,
      canEdit: oldPost.canEdit,
      canDelete: oldPost.canDelete,
      canRecover: oldPost.canRecover,
      canWiki: oldPost.canWiki,
      bookmarked: oldPost.bookmarked,
      read: oldPost.read,
      actionsSummary: oldPost.actionsSummary,
      linkCounts: oldPost.linkCounts,
      // 更新这两个字段
      reactions: reactions,
      currentUserReaction: currentUserReaction,
    );

    final newPosts = [...currentPosts];
    newPosts[index] = updatedPost;

    // 更新 state
    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(
        posts: newPosts,
        stream: currentDetail.postStream.stream,
      ),
    ));
  }

  /// 更新帖子的解决方案状态
  void updatePostSolution(int postId, bool accepted) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final newPosts = <Post>[];

    for (final post in currentPosts) {
      if (post.id == postId) {
        // 更新目标帖子的状态
        newPosts.add(Post(
          id: post.id,
          name: post.name,
          username: post.username,
          avatarTemplate: post.avatarTemplate,
          animatedAvatar: post.animatedAvatar,
          cooked: post.cooked,
          postNumber: post.postNumber,
          postType: post.postType,
          updatedAt: post.updatedAt,
          createdAt: post.createdAt,
          likeCount: post.likeCount,
          replyCount: post.replyCount,
          replyToPostNumber: post.replyToPostNumber,
          replyToUser: post.replyToUser,
          scoreHidden: post.scoreHidden,
          canEdit: post.canEdit,
          canDelete: post.canDelete,
          canRecover: post.canRecover,
          canWiki: post.canWiki,
          bookmarked: post.bookmarked,
          bookmarkId: post.bookmarkId,
          read: post.read,
          actionsSummary: post.actionsSummary,
          linkCounts: post.linkCounts,
          reactions: post.reactions,
          currentUserReaction: post.currentUserReaction,
          polls: post.polls,
          pollsVotes: post.pollsVotes,
          actionCode: post.actionCode,
          actionCodeWho: post.actionCodeWho,
          actionCodePath: post.actionCodePath,
          flairUrl: post.flairUrl,
          flairName: post.flairName,
          flairBgColor: post.flairBgColor,
          flairColor: post.flairColor,
          flairGroupId: post.flairGroupId,
          mentionedUsers: post.mentionedUsers,
          acceptedAnswer: accepted,
          canAcceptAnswer: post.canAcceptAnswer,
          canUnacceptAnswer: accepted, // 如果已采纳，则可以取消
        ));
      } else if (accepted && post.acceptedAnswer) {
        // 如果是新采纳，清除其他帖子的已采纳状态
        newPosts.add(Post(
          id: post.id,
          name: post.name,
          username: post.username,
          avatarTemplate: post.avatarTemplate,
          animatedAvatar: post.animatedAvatar,
          cooked: post.cooked,
          postNumber: post.postNumber,
          postType: post.postType,
          updatedAt: post.updatedAt,
          createdAt: post.createdAt,
          likeCount: post.likeCount,
          replyCount: post.replyCount,
          replyToPostNumber: post.replyToPostNumber,
          replyToUser: post.replyToUser,
          scoreHidden: post.scoreHidden,
          canEdit: post.canEdit,
          canDelete: post.canDelete,
          canRecover: post.canRecover,
          canWiki: post.canWiki,
          bookmarked: post.bookmarked,
          bookmarkId: post.bookmarkId,
          read: post.read,
          actionsSummary: post.actionsSummary,
          linkCounts: post.linkCounts,
          reactions: post.reactions,
          currentUserReaction: post.currentUserReaction,
          polls: post.polls,
          pollsVotes: post.pollsVotes,
          actionCode: post.actionCode,
          actionCodeWho: post.actionCodeWho,
          actionCodePath: post.actionCodePath,
          flairUrl: post.flairUrl,
          flairName: post.flairName,
          flairBgColor: post.flairBgColor,
          flairColor: post.flairColor,
          flairGroupId: post.flairGroupId,
          mentionedUsers: post.mentionedUsers,
          acceptedAnswer: false,
          canAcceptAnswer: post.canAcceptAnswer,
          canUnacceptAnswer: false,
        ));
      } else {
        newPosts.add(post);
      }
    }

    // 查找被采纳帖子的 postNumber
    int? acceptedPostNumber;
    if (accepted) {
      final acceptedPost = newPosts.firstWhere((p) => p.id == postId);
      acceptedPostNumber = acceptedPost.postNumber;
    }

    // 更新话题的已解决状态
    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(
        posts: newPosts,
        stream: currentDetail.postStream.stream,
      ),
      hasAcceptedAnswer: accepted,
      acceptedAnswerPostNumber: acceptedPostNumber,
    ));
  }

  /// 更新话题投票状态
  void updateTopicVote(int newVoteCount, bool userVoted) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    state = AsyncValue.data(currentDetail.copyWith(
      voteCount: newVoteCount,
      userVoted: userVoted,
    ));
  }

  /// 更新话题订阅级别
  Future<void> updateNotificationLevel(TopicNotificationLevel level) async {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    try {
      await ref.read(discourseServiceProvider).setTopicNotificationLevel(
        currentDetail.id,
        level,
      );

      // 更新本地状态
      state = AsyncValue.data(currentDetail.copyWith(notificationLevel: level));
    } catch (e) {
      print('[TopicDetail] 更新订阅级别失败: $e');
      rethrow;
    }
  }

  /// 使用新的起始帖子号重新加载数据
  /// 用于跳转到不在当前列表中的帖子
  Future<void> reloadWithPostNumber(int postNumber) async {
    state = const AsyncValue.loading();
    _hasMoreAfter = true;
    _hasMoreBefore = true;

    // 等待一帧，确保 loading 状态被渲染
    await Future.delayed(Duration.zero);

    state = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
      );

      final posts = detail.postStream.posts;
      final stream = detail.postStream.stream;
      if (posts.isEmpty) {
        _hasMoreAfter = false;
        _hasMoreBefore = false;
      } else {
        final firstPostId = posts.first.id;
        final firstIndex = stream.indexOf(firstPostId);
        _hasMoreBefore = firstIndex > 0;

        final lastPostId = posts.last.id;
        final lastIndex = stream.indexOf(lastPostId);
        _hasMoreAfter = lastIndex < stream.length - 1;
      }

      return detail;
    });
  }

  /// 刷新当前话题详情（保持列表可见）
  Future<void> refreshWithPostNumber(int postNumber) async {
    if (state.isLoading) return;

    state = const AsyncLoading<TopicDetail>().copyWithPrevious(state);

    state = await AsyncValue.guard(() async {
      final service = ref.read(discourseServiceProvider);
      final detail = await service.getTopicDetail(
        arg.topicId,
        postNumber: _isFilteredMode ? null : postNumber,
        filter: _filter,
        usernameFilters: _usernameFilter,
      );

      final posts = detail.postStream.posts;
      final stream = detail.postStream.stream;
      if (posts.isEmpty) {
        _hasMoreAfter = false;
        _hasMoreBefore = false;
      } else {
        final firstPostId = posts.first.id;
        final firstIndex = stream.indexOf(firstPostId);
        _hasMoreBefore = firstIndex > 0;

        final lastPostId = posts.last.id;
        final lastIndex = stream.indexOf(lastPostId);
        _hasMoreAfter = lastIndex < stream.length - 1;
      }

      return detail;
    });
  }

  /// 加载指定楼层的帖子（用于跳转）
  /// 返回加载后该帖子在列表中的索引，如果失败返回 -1
  Future<int> loadPostNumber(int postNumber) async {
    final currentDetail = state.value;
    if (currentDetail == null) return -1;

    final currentPosts = currentDetail.postStream.posts;

    // 先检查是否已加载
    final existingIndex = currentPosts.indexWhere((p) => p.postNumber == postNumber);
    if (existingIndex != -1) return existingIndex;

    try {
      final service = ref.read(discourseServiceProvider);
      final newDetail = await service.getTopicDetail(arg.topicId, postNumber: postNumber);

      // 合并帖子
      final existingIds = currentPosts.map((p) => p.id).toSet();
      final newPosts = newDetail.postStream.posts.where((p) => !existingIds.contains(p.id)).toList();
      final mergedPosts = [...currentPosts, ...newPosts];
      mergedPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      // 更新边界状态
      _hasMoreBefore = mergedPosts.first.postNumber > 1;
      _hasMoreAfter = mergedPosts.last.postNumber < currentDetail.postsCount;

      state = AsyncValue.data(currentDetail.copyWith(
        postStream: PostStream(posts: mergedPosts, stream: currentDetail.postStream.stream),
      ));

      // 返回目标帖子的索引
      return mergedPosts.indexWhere((p) => p.postNumber == postNumber);
    } catch (e) {
      print('[TopicDetail] 加载帖子 #$postNumber 失败: $e');
      return -1;
    }
  }

  /// 添加新创建的帖子到列表（用于回复后直接更新）
  /// 返回 true 表示帖子已添加到视图，false 表示只更新了 stream
  bool addPost(Post post) {
    final currentDetail = state.value;
    if (currentDetail == null) return false;

    final currentPosts = currentDetail.postStream.posts;

    // 检查是否已存在
    if (currentPosts.any((p) => p.id == post.id)) return true;

    // 更新 stream（始终添加）
    final newStream = [...currentDetail.postStream.stream];
    if (!newStream.contains(post.id)) {
      newStream.add(post.id);
    }

    // 只有在用户已加载到底部时才添加到视图
    if (!_hasMoreAfter) {
      // 添加新帖子并排序
      final newPosts = [...currentPosts, post];
      newPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      // 更新帖子总数
      final newPostsCount = currentDetail.postsCount + 1;

      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: newPostsCount,
        postStream: PostStream(posts: newPosts, stream: newStream),
      ));
      return true;
    } else {
      // 用户不在底部：只更新 stream 和帖子总数，不添加到视图
      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: currentDetail.postsCount + 1,
        postStream: PostStream(posts: currentPosts, stream: newStream),
      ));
      return false;
    }
  }

  /// 更新话题信息（用于编辑话题后直接更新）
  void updateTopicInfo({
    String? title,
    int? categoryId,
    List<String>? tags,
    Post? firstPost,
  }) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    // 如果首贴也被编辑，更新 postStream 中的首贴
    PostStream? updatedPostStream;
    if (firstPost != null) {
      final currentPosts = currentDetail.postStream.posts;
      final index = currentPosts.indexWhere((p) => p.id == firstPost.id);
      if (index != -1) {
        final newPosts = [...currentPosts];
        newPosts[index] = firstPost;
        updatedPostStream = PostStream(posts: newPosts, stream: currentDetail.postStream.stream);
      }
    }

    state = AsyncValue.data(currentDetail.copyWith(
      title: title ?? currentDetail.title,
      categoryId: categoryId ?? currentDetail.categoryId,
      tags: tags != null ? tags.map((name) => Tag(name: name)).toList() : currentDetail.tags,
      postStream: updatedPostStream ?? currentDetail.postStream,
    ));
  }

  /// 更新已存在的帖子（用于编辑后直接更新）
  void updatePost(Post post) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final index = currentPosts.indexWhere((p) => p.id == post.id);
    if (index == -1) return;

    final newPosts = [...currentPosts];
    newPosts[index] = post;

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream),
    ));
  }
}

final topicDetailProvider = AsyncNotifierProvider.family.autoDispose<TopicDetailNotifier, TopicDetail, TopicDetailParams>(
  TopicDetailNotifier.new,
);

/// 话题 AI 摘要 Provider
/// 使用 autoDispose 在页面销毁时自动清理
/// family 参数为话题 ID
final topicSummaryProvider = FutureProvider.autoDispose
    .family<TopicSummary?, int>((ref, topicId) async {
  final service = ref.read(discourseServiceProvider);
  return service.getTopicSummary(topicId);
});
