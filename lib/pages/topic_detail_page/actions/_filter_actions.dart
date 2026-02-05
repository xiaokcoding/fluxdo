part of '../topic_detail_page.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 过滤模式相关方法
extension _FilterActions on _TopicDetailPageState {
  bool _detailHasTargetPost(TopicDetail detail, {int? postNumber, int? postId}) {
    if (postId != null) {
      if (detail.postStream.stream.contains(postId)) return true;
      if (detail.postStream.posts.any((p) => p.id == postId)) return true;
    }
    if (postNumber != null) {
      if (detail.postStream.posts.any((p) => p.postNumber == postNumber)) return true;
    }
    return false;
  }

  Future<void> _reloadWithFilterFallback({required int postNumber, int? postId}) async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);
    final wasSummaryMode = notifier.isSummaryMode;
    final wasAuthorOnlyMode = notifier.isAuthorOnlyMode;

    setState(() => _isSwitchingMode = true);
    _controller.resetVisibility();

    try {
      await notifier.reloadWithPostNumber(postNumber);
      if (!mounted) return;

      final detail = ref.read(topicDetailProvider(params)).value;
      final hasTarget = detail != null && _detailHasTargetPost(detail, postNumber: postNumber, postId: postId);
      final shouldFallback = detail != null && _shouldFallbackFilter(detail, wasSummaryMode, wasAuthorOnlyMode);
      if (!hasTarget || shouldFallback) {
        _controller.resetVisibility();
        _controller.prepareJumpToPost(postNumber);
        await notifier.cancelFilterAndReloadWithPostNumber(postNumber);
      }
    } finally {
      if (mounted) setState(() => _isSwitchingMode = false);
    }
  }

  bool _shouldFallbackFilter(TopicDetail detail, bool wasSummaryMode, bool wasAuthorOnlyMode) {
    if (wasSummaryMode) {
      if (!detail.hasSummary) return true;
      if (detail.postsCount > 0 && detail.postStream.stream.length >= detail.postsCount) {
        return true;
      }
    }

    if (wasAuthorOnlyMode) {
      final author = detail.createdBy?.username;
      if (author == null || author.isEmpty) return true;
      final hasOtherUsers = detail.postStream.posts.any((p) => p.username != author);
      if (hasOtherUsers) return true;
    }

    return false;
  }

  Future<void> _handleShowTopReplies() async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    setState(() => _isSwitchingMode = true);

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    await notifier.showTopReplies();

    if (mounted) {
      setState(() => _isSwitchingMode = false);
    }
  }

  Future<void> _handleCancelFilter() async {
    final params = _params;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    setState(() => _isSwitchingMode = true);

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    await notifier.cancelFilter();

    if (mounted) {
      setState(() => _isSwitchingMode = false);
    }
  }

  Future<void> _handleShowAuthorOnly() async {
    final params = _params;
    final detail = ref.read(topicDetailProvider(params)).value;
    final notifier = ref.read(topicDetailProvider(params).notifier);

    final authorUsername = detail?.createdBy?.username;
    if (authorUsername == null || authorUsername.isEmpty) return;

    setState(() => _isSwitchingMode = true);

    _controller.prepareJumpToPost(1);
    _controller.skipNextJumpHighlight = true;
    _controller.resetVisibility();

    await notifier.showAuthorOnly(authorUsername);

    if (mounted) {
      setState(() => _isSwitchingMode = false);
    }
  }
}
