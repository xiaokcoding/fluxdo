part of '../post_item.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 删除/恢复/解决方案操作
extension _PostManageActions on _PostItemState {
  /// 切换解决方案状态
  Future<void> _toggleSolution() async {
    if (_isTogglingAnswer) return;

    HapticFeedback.lightImpact();
    setState(() => _isTogglingAnswer = true);

    try {
      if (_isAcceptedAnswer) {
        // 取消采纳
        await _service.unacceptAnswer(widget.post.id);
        if (mounted) {
          setState(() => _isAcceptedAnswer = false);
          widget.onSolutionChanged?.call(widget.post.id, false);
          ToastService.showSuccess('已取消采纳');
        }
      } else {
        // 采纳答案
        await _service.acceptAnswer(widget.post.id);
        if (mounted) {
          setState(() => _isAcceptedAnswer = true);
          widget.onSolutionChanged?.call(widget.post.id, true);
          ToastService.showSuccess('已采纳为解决方案');
        }
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isTogglingAnswer = false);
      }
    }
  }

  /// 删除帖子
  Future<void> _deletePost() async {
    if (_isDeleting) return;

    HapticFeedback.lightImpact();
    setState(() => _isDeleting = true);

    try {
      await _service.deletePost(widget.post.id);
      if (mounted) {
        ToastService.showSuccess('已删除');
        _refreshPostInProvider();
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  /// 恢复已删除的帖子
  Future<void> _recoverPost() async {
    if (_isDeleting) return;

    HapticFeedback.lightImpact();
    setState(() => _isDeleting = true);

    try {
      await _service.recoverPost(widget.post.id);
      if (mounted) {
        ToastService.showSuccess('已恢复');
        _refreshPostInProvider();
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isDeleting = false);
      }
    }
  }

  /// 刷新帖子状态到 Provider
  void _refreshPostInProvider() {
    widget.onRefreshPost?.call(widget.post.id);
  }
}
