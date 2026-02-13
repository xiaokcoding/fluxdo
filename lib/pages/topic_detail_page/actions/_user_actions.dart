part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 用户操作相关方法
extension _UserActions on _TopicDetailPageState {
  Future<void> _handleRefresh() async {
    final params = _params;
    final detailAsync = ref.read(topicDetailProvider(params));
    if (detailAsync.isLoading) return;

    final detail = ref.read(topicDetailProvider(params)).value;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final anchorPostNumber = _controller.getRefreshAnchorPostNumber(
      detail?.postStream.posts.firstOrNull?.postNumber ?? _controller.currentPostNumber,
    );

    setState(() => _isRefreshing = true);
    await notifier.refreshWithPostNumber(anchorPostNumber);

    if (!mounted) return;
    setState(() => _isRefreshing = false);

    final updatedDetail = ref.read(topicDetailProvider(params)).value;
    if (updatedDetail == null) return;

    final isFiltered = notifier.isSummaryMode || notifier.isAuthorOnlyMode;
    final hasAnchor = updatedDetail.postStream.posts.any((p) => p.postNumber == anchorPostNumber);
    if (!isFiltered || hasAnchor) {
      _controller.prepareRefresh(anchorPostNumber, skipHighlight: true);
    } else {
      _controller.clearJumpTarget();
    }
  }

  Future<void> _handleReply(Post? replyToPost) async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;

    // 预加载草稿：在点击回复时就发起请求，利用 BottomSheet 动画时间并行加载
    final draftKey = Draft.replyKey(
      widget.topicId,
      replyToPostNumber: replyToPost?.postNumber,
    );
    final preloadedDraftFuture = DiscourseService().getDraft(draftKey);

    final newPost = await showReplySheet(
      context: context,
      topicId: widget.topicId,
      categoryId: detail?.categoryId,
      replyToPost: replyToPost,
      preloadedDraftFuture: preloadedDraftFuture,
    );

    if (newPost != null && mounted) {
      final addedToView = ref.read(topicDetailProvider(params).notifier).addPost(newPost);

      if (addedToView) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _scrollToPost(newPost.postNumber);
          }
        });
      } else {
        if (mounted) {
          ToastService.show(
            '回复已发送',
            type: ToastType.success,
            actionLabel: '查看',
            onAction: () => _scrollToPost(newPost.postNumber),
          );
        }
      }
    }
  }

  Future<void> _handleEdit(Post post) async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;

    final updatedPost = await showEditSheet(
      context: context,
      topicId: widget.topicId,
      post: post,
      categoryId: detail?.categoryId,
    );

    if (updatedPost != null && mounted) {
      ref.read(topicDetailProvider(params).notifier).updatePost(updatedPost);
    }
  }

  Future<void> _handleEditTopic() async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    final firstPost = detail.postStream.posts.where((p) => p.postNumber == 1).firstOrNull;
    final firstPostId = detail.postStream.stream.isNotEmpty ? detail.postStream.stream.first : null;

    final result = await Navigator.of(context).push<EditTopicResult>(
      MaterialPageRoute(
        builder: (context) => EditTopicPage(
          topicDetail: detail,
          firstPost: firstPost,
          firstPostId: firstPostId,
        ),
      ),
    );

    if (result != null && mounted) {
      ref.read(topicDetailProvider(params).notifier).updateTopicInfo(
        title: result.title,
        categoryId: result.categoryId,
        tags: result.tags,
        firstPost: result.updatedFirstPost,
      );
    }
  }

  void _handleVoteChanged(int newVoteCount, bool userVoted) {
    final params = _params;
    ref.read(topicDetailProvider(params).notifier).updateTopicVote(newVoteCount, userVoted);
  }

  void _handleSolutionChanged(int postId, bool accepted) {
    final params = _params;
    ref.read(topicDetailProvider(params).notifier).updatePostSolution(postId, accepted);
  }

  void _handleRefreshPost(int postId) {
    final params = _params;
    ref.read(topicDetailProvider(params).notifier).refreshPost(postId);
  }

  void _handleNotificationLevelChanged(TopicDetailNotifier notifier, TopicNotificationLevel level) async {
    try {
      await notifier.updateNotificationLevel(level);
      if (mounted) {
        ToastService.showSuccess('已设置为${level.label}');
      }
    } catch (e) {
      // 错误已由 ErrorInterceptor 处理
      debugPrint('[TopicDetail] 更新订阅级别失败: $e');
    }
  }

  void _shareTopic() {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/t/topic/${widget.topicId}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );
    SharePlus.instance.share(ShareParams(text: url));
  }

  Future<void> _openInBrowser() async {
    final user = ref.read(currentUserProvider).value;
    final username = user?.username ?? '';
    final prefs = ref.read(preferencesProvider);
    final url = ShareUtils.buildShareUrl(
      path: '/t/topic/${widget.topicId}',
      username: username,
      anonymousShare: prefs.anonymousShare,
    );

    final success = await launchInExternalBrowser(url);
    if (!success && mounted) {
      ToastService.showError('无法打开浏览器');
    }
  }

  void _shareAsImage() {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    // 尝试获取已加载的主帖，如果没有则传 null，ShareImagePreview 会自动获取
    final firstPost = detail.postStream.posts.where((p) => p.postNumber == 1).firstOrNull;
    ShareImagePreview.show(context, detail, post: firstPost);
  }

  void _sharePostAsImage(Post post) {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    ShareImagePreview.show(context, detail, post: post);
  }

  void _showExportSheet() {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    if (detail == null) return;

    ExportSheet.show(context, detail);
  }

  /// 处理帖子级别的 MessageBus 更新
  void _handlePostUpdate(TopicDetailNotifier notifier, PostUpdate update) {
    switch (update.type) {
      case TopicMessageType.created:
        notifier.loadNewReplies();
        break;
      case TopicMessageType.revised:
      case TopicMessageType.rebaked:
        notifier.refreshPost(update.postId, updatedAt: update.updatedAt);
        break;
      case TopicMessageType.acted:
        // acted 的 updated_at 是操作时间，不是帖子修改时间，不传 updatedAt 避免跳过刷新
        notifier.refreshPost(update.postId, preserveCooked: true);
        break;
      case TopicMessageType.deleted:
        notifier.markPostDeleted(update.postId);
        break;
      case TopicMessageType.destroyed:
        notifier.removePost(update.postId);
        break;
      case TopicMessageType.recovered:
        notifier.markPostRecovered(update.postId);
        break;
      case TopicMessageType.liked:
      case TopicMessageType.unliked:
        notifier.updatePostLikes(update.postId, likesCount: update.likesCount);
        break;
      default:
        break;
    }
  }

  /// 处理 reload_topic 消息
  void _handleReloadTopic(TopicDetailNotifier notifier, bool refreshStream) {
    final anchor = _controller.getRefreshAnchorPostNumber(widget.scrollToPostNumber);
    if (refreshStream) {
      notifier.refreshWithPostNumber(anchor);
    } else {
      notifier.reloadTopicMetadata();
    }
  }
}
