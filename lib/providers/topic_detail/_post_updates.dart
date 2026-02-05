part of '../topic_detail_provider.dart';

// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

/// 帖子和话题更新相关方法
extension PostUpdateMethods on TopicDetailNotifier {
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

      final updatedPost = newDetail.postStream.posts.firstWhere(
        (p) => p.id == postId,
        orElse: () => currentPosts[index],
      );

      final finalPost = preserveCooked
          ? updatedPost.copyWith(
              cooked: currentPosts[index].cooked,
              read: currentPosts[index].read,
            )
          : updatedPost;

      final newPosts = [...currentPosts];
      newPosts[index] = finalPost;

      state = AsyncValue.data(currentDetail.copyWith(
        postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream),
      ));
    } catch (e) {
      debugPrint('[TopicDetail] 刷新帖子 $postId 失败: $e');
    }
  }

  /// 从列表中移除帖子（用于 MessageBus destroyed 消息）
  void removePost(int postId) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final newPosts = currentPosts.where((p) => p.id != postId).toList();

    if (newPosts.length == currentPosts.length) return;

    state = AsyncValue.data(currentDetail.copyWith(
      postsCount: currentDetail.postsCount - 1,
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream),
    ));
  }

  /// 标记帖子被删除（用于 MessageBus deleted 消息）
  void markPostDeleted(int postId) {
    refreshPost(postId);
  }

  /// 标记帖子已恢复（用于 MessageBus recovered 消息）
  void markPostRecovered(int postId) {
    refreshPost(postId);
  }

  /// 更新帖子点赞数（用于 MessageBus liked/unliked 消息）
  void updatePostLikes(int postId, {int? likesCount}) {
    if (likesCount == null) {
      refreshPost(postId, preserveCooked: true);
      return;
    }
    _updatePostById(postId, (post) => post.copyWith(likeCount: likesCount));
  }

  /// 更新单个帖子的点赞/回应状态
  void updatePostReaction(int postId, List<PostReaction> reactions, PostReaction? currentUserReaction) {
    _updatePostById(postId, (post) => post.copyWith(
      reactions: reactions,
      currentUserReaction: currentUserReaction,
    ));
  }

  /// 更新帖子的解决方案状态
  void updatePostSolution(int postId, bool accepted) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

    final currentPosts = currentDetail.postStream.posts;
    final newPosts = currentPosts.map((post) {
      if (post.id == postId) {
        return post.copyWith(
          acceptedAnswer: accepted,
          canUnacceptAnswer: accepted,
        );
      } else if (accepted && post.acceptedAnswer) {
        return post.copyWith(
          acceptedAnswer: false,
          canUnacceptAnswer: false,
        );
      }
      return post;
    }).toList();

    int? acceptedPostNumber;
    if (accepted) {
      final acceptedPost = newPosts.firstWhere((p) => p.id == postId);
      acceptedPostNumber = acceptedPost.postNumber;
    }

    state = AsyncValue.data(currentDetail.copyWith(
      postStream: PostStream(posts: newPosts, stream: currentDetail.postStream.stream),
      hasAcceptedAnswer: accepted,
      acceptedAnswerPostNumber: acceptedPostNumber,
    ));
  }

  /// 添加新创建的帖子到列表（用于回复后直接更新）
  bool addPost(Post post) {
    final currentDetail = state.value;
    if (currentDetail == null) return false;

    final currentPosts = currentDetail.postStream.posts;

    if (currentPosts.any((p) => p.id == post.id)) return true;

    final newStream = [...currentDetail.postStream.stream];
    if (!newStream.contains(post.id)) {
      newStream.add(post.id);
    }

    if (!_hasMoreAfter) {
      final newPosts = [...currentPosts, post];
      newPosts.sort((a, b) => a.postNumber.compareTo(b.postNumber));

      final newPostsCount = currentDetail.postsCount + 1;

      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: newPostsCount,
        postStream: PostStream(posts: newPosts, stream: newStream),
      ));
      return true;
    } else {
      state = AsyncValue.data(currentDetail.copyWith(
        postsCount: currentDetail.postsCount + 1,
        postStream: PostStream(posts: currentPosts, stream: newStream),
      ));
      return false;
    }
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

  /// 更新话题信息（用于编辑话题后直接更新）
  void updateTopicInfo({
    String? title,
    int? categoryId,
    List<String>? tags,
    Post? firstPost,
  }) {
    final currentDetail = state.value;
    if (currentDetail == null) return;

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

      state = AsyncValue.data(currentDetail.copyWith(notificationLevel: level));
    } catch (e) {
      debugPrint('[TopicDetail] 更新订阅级别失败: $e');
      rethrow;
    }
  }
}
