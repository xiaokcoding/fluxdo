import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/topic.dart';
import '../../../providers/discourse_providers.dart';
import '../../../services/discourse/discourse_service.dart';
import '../../../services/toast_service.dart';

/// 话题投票按钮组件
class TopicVoteButton extends ConsumerStatefulWidget {
  final TopicDetail topic;
  final void Function(int voteCount, bool userVoted)? onVoteChanged;

  const TopicVoteButton({
    super.key,
    required this.topic,
    this.onVoteChanged,
  });

  @override
  ConsumerState<TopicVoteButton> createState() => _TopicVoteButtonState();
}

class _TopicVoteButtonState extends ConsumerState<TopicVoteButton> {
  bool _isLoading = false;
  bool _userVoted = false;
  int _voteCount = 0;

  @override
  void initState() {
    super.initState();
    _userVoted = widget.topic.userVoted;
    _voteCount = widget.topic.voteCount;
  }

  @override
  void didUpdateWidget(TopicVoteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topic.id != widget.topic.id || 
        oldWidget.topic.userVoted != widget.topic.userVoted ||
        oldWidget.topic.voteCount != widget.topic.voteCount) {
      _userVoted = widget.topic.userVoted;
      _voteCount = widget.topic.voteCount;
    }
  }

  Future<void> _handleVote() async {
    final user = ref.read(currentUserProvider).value;
    if (user == null) {
      if (mounted) {
        ToastService.showInfo('请先登录');
      }
      return;
    }

    if (widget.topic.closed) {
      if (mounted) {
        ToastService.showInfo('话题已关闭，无法投票');
      }
      return;
    }

    if (_isLoading) return;

    setState(() => _isLoading = true);

    try {
      final service = DiscourseService();

      if (_userVoted) {
        // 取消投票
        final response = await service.unvoteTopicVote(widget.topic.id);
        if (mounted) {
          setState(() {
            _userVoted = false;
            _voteCount = response.voteCount;
            _isLoading = false;
          });
          
          widget.onVoteChanged?.call(response.voteCount, false);

          ToastService.showSuccess('已取消投票');
        }
      } else {
        // 投票
        final response = await service.voteTopicVote(widget.topic.id);
        if (mounted) {
          setState(() {
            _userVoted = true;
            _voteCount = response.voteCount;
            _isLoading = false;
          });
          
          widget.onVoteChanged?.call(response.voteCount, true);

          // 显示投票成功提示
          String message = '投票成功';
          if (response.votesLeft > 0) {
            message += '，剩余 ${response.votesLeft} 票';
          } else if (response.alert) {
            message = '投票成功，您的投票已用完';
          }

          ToastService.showSuccess(message);
        }
      }
    } catch (_) {
      // 错误已由 ErrorInterceptor 处理
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = ref.watch(currentUserProvider).value;

    // 如果话题不支持投票，不显示按钮
    if (!widget.topic.canVote) {
      return const SizedBox.shrink();
    }

    final bool isLoggedIn = user != null;
    final bool isClosed = widget.topic.closed;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _isLoading ? null : _handleVote,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: _userVoted
                ? theme.colorScheme.primary
                : theme.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: _userVoted
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outlineVariant,
              width: 1,
            ),
            boxShadow: _userVoted
                ? [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha:0.2),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isLoading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      _userVoted
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.primary,
                    ),
                  ),
                )
              else
                Icon(
                  _userVoted ? Icons.check_circle : Icons.arrow_upward_rounded,
                  size: 20,
                  color: _userVoted
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.primary,
                ),
              const SizedBox(width: 6),
              Text(
                _getButtonText(isLoggedIn, isClosed),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: _userVoted
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              if (_voteCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: const BoxConstraints(minWidth: 20),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: _userVoted
                        ? theme.colorScheme.onPrimary.withValues(alpha:0.2)
                        : theme.colorScheme.primary.withValues(alpha:0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '$_voteCount',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: _userVoted
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _getButtonText(bool isLoggedIn, bool isClosed) {
    if (!isLoggedIn) {
      return '投票';
    }
    if (isClosed) {
      return '已关闭';
    }
    if (_userVoted) {
      return '已投票';
    }
    return '投票';
  }
}
