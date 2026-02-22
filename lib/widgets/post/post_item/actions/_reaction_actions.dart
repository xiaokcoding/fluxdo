part of '../post_item.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 回应/点赞操作
extension _ReactionActions on _PostItemState {
  /// 将点赞状态同步到 Provider
  void _syncReactionToProvider(List<PostReaction> reactions, PostReaction? currentUserReaction) {
    final params = TopicDetailParams(widget.topicId);

    try {
      ref.read(topicDetailProvider(params).notifier)
         .updatePostReaction(widget.post.id, reactions, currentUserReaction);
    } catch (e) {
      debugPrint('[PostItem] 同步点赞状态到 Provider 失败: $e');
    }
  }

  /// 点赞（使用 heart 回应）或取消当前回应
  Future<void> _toggleLike() async {
    if (_isLiking) return;

    HapticFeedback.lightImpact();

    setState(() => _isLiking = true);

    try {
      final reactionId = _currentUserReaction?.id ?? 'heart';
      final result = await _service.toggleReaction(widget.post.id, reactionId);
      if (mounted) {
        setState(() {
          _reactions = result['reactions'] as List<PostReaction>;
          _currentUserReaction = result['currentUserReaction'] as PostReaction?;
        });

        _syncReactionToProvider(result['reactions'] as List<PostReaction>, result['currentUserReaction'] as PostReaction?);
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) setState(() => _isLiking = false);
    }
  }

  /// 显示回应选择器
  void _showReactionPicker(BuildContext context, ThemeData theme) async {
    HapticFeedback.mediumImpact();

    final reactions = await _service.getEnabledReactions();
    if (!mounted || reactions.isEmpty) return;

    PostReactionPicker.show(
      // ignore: use_build_context_synchronously
      context: context,
      theme: theme,
      likeButtonKey: _likeButtonKey,
      reactions: reactions,
      currentUserReaction: _currentUserReaction,
      onReactionSelected: _toggleReaction,
    );
  }

  /// 显示回应人列表
  void _showReactionUsers(BuildContext context, {String? reactionId}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => PostReactionUsersSheet(
        postId: widget.post.id,
        initialReactionId: reactionId,
      ),
    );
  }

  /// 切换回应
  Future<void> _toggleReaction(String reactionId) async {
    try {
      final result = await _service.toggleReaction(widget.post.id, reactionId);
      if (!mounted) return;

      setState(() {
        _reactions = result['reactions'] as List<PostReaction>;
        _currentUserReaction = result['currentUserReaction'] as PostReaction?;
      });

      _syncReactionToProvider(result['reactions'] as List<PostReaction>, result['currentUserReaction'] as PostReaction?);
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    }
  }
}
