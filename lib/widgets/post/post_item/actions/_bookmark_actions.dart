part of '../post_item.dart';

// ignore_for_file: invalid_use_of_protected_member

/// 书签操作
extension _BookmarkActions on _PostItemState {
  /// 切换书签状态
  Future<void> _toggleBookmark() async {
    if (_isBookmarking) return;

    HapticFeedback.lightImpact();
    setState(() => _isBookmarking = true);

    try {
      if (_isBookmarked) {
        // 取消书签 - 优先使用本地保存的 ID，否则使用 Post 模型中的 ID
        final bookmarkId = _bookmarkId ?? widget.post.bookmarkId;
        if (bookmarkId != null) {
          await _service.deleteBookmark(bookmarkId);
          if (mounted) {
            setState(() {
              _isBookmarked = false;
              _bookmarkId = null;
            });
            ToastService.showSuccess('已取消书签');
          }
        } else {
          ToastService.showError('无法取消书签：缺少书签 ID');
        }
      } else {
        // 添加书签
        final bookmarkId = await _service.bookmarkPost(widget.post.id);
        if (mounted) {
          setState(() {
            _isBookmarked = true;
            _bookmarkId = bookmarkId;
          });
          ToastService.showSuccess('已添加书签');
        }
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
    } finally {
      if (mounted) {
        setState(() => _isBookmarking = false);
      }
    }
  }
}
