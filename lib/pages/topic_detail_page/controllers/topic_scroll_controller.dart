import 'package:flutter/material.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import '../../../models/topic.dart';

/// 话题详情页滚动状态
class TopicScrollState {
  final bool showBackToTop;
  final bool showBottomBar;
  final bool hasInitialScrolled;
  final bool isPositioned;
  final int? jumpTargetPostNumber;
  final int? initialCenterPostNumber;
  final int? currentPostNumber;

  const TopicScrollState({
    this.showBackToTop = false,
    this.showBottomBar = false,
    this.hasInitialScrolled = false,
    this.isPositioned = false,
    this.jumpTargetPostNumber,
    this.initialCenterPostNumber,
    this.currentPostNumber,
  });

  TopicScrollState copyWith({
    bool? showBackToTop,
    bool? showBottomBar,
    bool? hasInitialScrolled,
    bool? isPositioned,
    int? jumpTargetPostNumber,
    int? initialCenterPostNumber,
    int? currentPostNumber,
    bool clearJumpTarget = false,
    bool clearInitialCenter = false,
  }) {
    return TopicScrollState(
      showBackToTop: showBackToTop ?? this.showBackToTop,
      showBottomBar: showBottomBar ?? this.showBottomBar,
      hasInitialScrolled: hasInitialScrolled ?? this.hasInitialScrolled,
      isPositioned: isPositioned ?? this.isPositioned,
      jumpTargetPostNumber: clearJumpTarget ? null : (jumpTargetPostNumber ?? this.jumpTargetPostNumber),
      initialCenterPostNumber: clearInitialCenter ? null : (initialCenterPostNumber ?? this.initialCenterPostNumber),
      currentPostNumber: currentPostNumber ?? this.currentPostNumber,
    );
  }
}

/// 话题详情页滚动控制器
/// 负责管理滚动状态、加载更多、初始定位等逻辑
class TopicScrollController extends ChangeNotifier {
  final AutoScrollController scrollController;
  final VoidCallback? onScrolled;

  TopicScrollState _state;
  double _accumulatedScrollDelta = 0;

  /// 底部栏显示状态 ValueNotifier（用于隔离 UI 更新）
  final ValueNotifier<bool> showBottomBarNotifier = ValueNotifier<bool>(false);

  /// 定位完成状态 ValueNotifier（用于隔离 UI 更新）
  final ValueNotifier<bool> isPositionedNotifier = ValueNotifier<bool>(false);

  TopicScrollController({
    required this.scrollController,
    this.onScrolled,
    int? initialPostNumber,
  }) : _state = TopicScrollState(
          currentPostNumber: initialPostNumber,
          jumpTargetPostNumber: initialPostNumber,
        );

  /// 当前滚动状态
  TopicScrollState get state => _state;

  /// 是否显示回到顶部按钮
  bool get showBackToTop => _state.showBackToTop;

  /// 是否显示底部操作栏
  bool get showBottomBar => _state.showBottomBar;

  /// 是否已完成初始定位
  bool get hasInitialScrolled => _state.hasInitialScrolled;

  /// 是否已定位完成（用于控制显示）
  bool get isPositioned => _state.isPositioned;

  /// 跳转目标帖子号
  int? get jumpTargetPostNumber => _state.jumpTargetPostNumber;

  /// 初始加载时的第一个帖子号，用于确定 centerKey 位置
  int? get initialCenterPostNumber => _state.initialCenterPostNumber;

  /// 当前加载的起始帖子号
  int? get currentPostNumber => _state.currentPostNumber;

  /// 更新状态
  void _updateState(TopicScrollState newState) {
    if (_state != newState) {
      // 同步 ValueNotifier 状态
      if (_state.showBottomBar != newState.showBottomBar) {
        showBottomBarNotifier.value = newState.showBottomBar;
      }
      if (_state.isPositioned != newState.isPositioned) {
        isPositionedNotifier.value = newState.isPositioned;
      }
      _state = newState;
      notifyListeners();
    }
  }

  /// 处理滚动事件
  void handleScroll() {
    onScrolled?.call();

    // 控制回到顶部按钮显示
    final shouldShowBackToTop = scrollController.hasClients &&
        scrollController.position.pixels > 300;
    if (shouldShowBackToTop != _state.showBackToTop) {
      _updateState(_state.copyWith(showBackToTop: shouldShowBackToTop));
    }
  }

  /// 处理滚动通知，精确检测用户主动滚动
  bool handleScrollNotification(ScrollNotification notification) {
    // 只处理主列表的滚动（depth == 0），忽略嵌套滚动视图（如代码块）
    if (notification.depth != 0) {
      return false;
    }

    // 使用 ScrollUpdateNotification 检测实际滚动量
    // 只处理用户拖动产生的滚动（dragDetails 不为 null）
    if (notification is ScrollUpdateNotification && notification.dragDetails != null) {
      final delta = notification.scrollDelta ?? 0;

      // 累积滚动量，方向相反时重置
      if ((_accumulatedScrollDelta > 0 && delta < 0) ||
          (_accumulatedScrollDelta < 0 && delta > 0)) {
        _accumulatedScrollDelta = delta;
      } else {
        _accumulatedScrollDelta += delta;
      }

      // 只有累积滚动量超过阈值才改变状态
      const threshold = 50.0;
      if (_accumulatedScrollDelta < -threshold && !_state.showBottomBar) {
        // 向上滚动超过阈值，显示底部栏
        _state = _state.copyWith(showBottomBar: true);
        showBottomBarNotifier.value = true;
        _accumulatedScrollDelta = 0;
      } else if (_accumulatedScrollDelta > threshold && _state.showBottomBar) {
        // 向下滚动超过阈值，隐藏底部栏
        _state = _state.copyWith(showBottomBar: false);
        showBottomBarNotifier.value = false;
        _accumulatedScrollDelta = 0;
      }
    }

    // 滚动结束时重置累积量
    if (notification is ScrollEndNotification) {
      _accumulatedScrollDelta = 0;
    }

    return false; // 不阻止通知继续传递
  }

  /// 找到中心点位置（初始加载的第一个帖子）
  int findCenterPostIndex(List<Post> posts) {
    if (_state.initialCenterPostNumber == null || posts.isEmpty) return 0;
    for (int i = 0; i < posts.length; i++) {
      if (posts[i].postNumber >= _state.initialCenterPostNumber!) {
        return i;
      }
    }
    return 0;
  }

  /// 滚动到指定帖子
  Future<void> scrollToPost(int postNumber, List<Post> posts) async {
    final postIndex = posts.indexWhere((p) => p.postNumber == postNumber);
    if (postIndex == -1) return;

    await scrollController.scrollToIndex(
      postIndex,
      preferPosition: AutoScrollPosition.begin,
      duration: const Duration(milliseconds: 1),
    );
  }

  /// 回到顶部
  Future<void> scrollToTop() async {
    if (!scrollController.hasClients) return;

    scrollController.animateTo(
      scrollController.position.minScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 如果在底部则自动滚动到最底部
  void scrollToBottomIfNeeded() {
    if (!scrollController.hasClients) return;

    final position = scrollController.position;
    final isAtBottom = position.pixels >= position.maxScrollExtent - 10;

    if (isAtBottom && position.pixels > 0) {
      scrollController.animateTo(
        position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// 检查是否需要加载更多
  bool shouldLoadPrevious(bool hasMoreBefore, bool isLoadingPrevious) {
    if (!scrollController.hasClients) return false;
    final position = scrollController.position;
    final isOverscrollingTop = position.pixels < position.minScrollExtent;
    return !isOverscrollingTop &&
        position.pixels <= position.minScrollExtent + 200 &&
        hasMoreBefore &&
        !isLoadingPrevious;
  }

  /// 检查是否需要加载更多（向下）
  bool shouldLoadMore(bool hasMoreAfter, bool isLoadingMore) {
    if (!scrollController.hasClients) return false;
    final position = scrollController.position;
    return position.pixels >= position.maxScrollExtent - 500 &&
        hasMoreAfter &&
        !isLoadingMore;
  }

  /// 准备跳转到帖子（重新加载数据）
  void prepareJumpToPost(int postNumber) {
    _updateState(TopicScrollState(
      showBackToTop: _state.showBackToTop,
      showBottomBar: _state.showBottomBar,
      hasInitialScrolled: false,
      isPositioned: false,
      jumpTargetPostNumber: postNumber,
      initialCenterPostNumber: null,
      currentPostNumber: postNumber,
    ));
    // isPositionedNotifier 已在 _updateState 中同步
  }

  /// 准备刷新
  void prepareRefresh(int anchorPostNumber, {bool skipHighlight = false}) {
    _updateState(TopicScrollState(
      showBackToTop: _state.showBackToTop,
      showBottomBar: _state.showBottomBar,
      hasInitialScrolled: false,
      isPositioned: _state.isPositioned,
      jumpTargetPostNumber: anchorPostNumber,
      initialCenterPostNumber: null,
      currentPostNumber: anchorPostNumber,
    ));
  }

  /// 标记初始滚动完成
  void markInitialScrolled(int firstPostNumber) {
    _updateState(_state.copyWith(
      hasInitialScrolled: true,
      initialCenterPostNumber: firstPostNumber,
    ));
  }

  /// 标记定位完成
  void markPositioned() {
    if (!_state.isPositioned) {
      _state = _state.copyWith(isPositioned: true);
      isPositionedNotifier.value = true;
    }
  }

  /// 清除跳转目标
  void clearJumpTarget() {
    _updateState(_state.copyWith(clearJumpTarget: true));
  }

  /// 检查帖子是否已渲染
  bool isPostRendered(int postIndex) {
    return scrollController.tagMap.containsKey(postIndex);
  }

  /// 本地跳转到帖子（不重新请求，仅重置视图中心）
  void jumpToPostLocally(int postNumber, {int? anchorPostNumber}) {
    _updateState(_state.copyWith(
      hasInitialScrolled: false,
      isPositioned: false,
      jumpTargetPostNumber: postNumber,
      initialCenterPostNumber: anchorPostNumber ?? postNumber,
      currentPostNumber: postNumber,
    ));
    // isPositionedNotifier 已在 _updateState 中同步
  }

  @override
  void dispose() {
    showBottomBarNotifier.dispose();
    isPositionedNotifier.dispose();
    scrollController.dispose();
    super.dispose();
  }
}
