import 'dart:async';
import 'package:flutter/foundation.dart';
import '../../../services/screen_track.dart';

/// 帖子可见性追踪器
/// 负责追踪屏幕上可见的帖子并更新阅读进度
class PostVisibilityTracker extends ChangeNotifier {
  final ScreenTrack screenTrack;
  final void Function(int streamIndex)? onStreamIndexChanged;

  /// 当前可见的帖子号集合
  final Set<int> _visiblePostNumbers = {};
  final Set<int> _readPostNumbers = {};

  /// 当前可见的最顶部帖子的 stream 索引（1-based）
  int _currentVisibleStreamIndex = 1;

  Timer? _screenTrackThrottleTimer;
  bool _trackEnabled;

  PostVisibilityTracker({
    required this.screenTrack,
    required bool trackEnabled,
    this.onStreamIndexChanged,
  }) : _trackEnabled = trackEnabled;

  /// 当前可见的帖子号集合（只读）
  Set<int> get visiblePostNumbers => Set.unmodifiable(_visiblePostNumbers);

  /// 当前可见的最顶部帖子的 stream 索引
  int get currentVisibleStreamIndex => _currentVisibleStreamIndex;

  /// 是否启用追踪
  bool get trackEnabled => _trackEnabled;
  set trackEnabled(bool value) {
    if (_trackEnabled != value) {
      _trackEnabled = value;
      if (!_trackEnabled) {
        screenTrack.stop();
      }
    }
  }

  /// 获取可见帖子中最小的帖子号
  int? get topVisiblePostNumber {
    if (_visiblePostNumbers.isEmpty) return null;
    return _visiblePostNumbers.reduce((a, b) => a < b ? a : b);
  }

  /// 帖子可见性变化回调
  void onPostVisibilityChanged(int postNumber, bool isVisible) {
    if (isVisible) {
      _visiblePostNumbers.add(postNumber);
    } else {
      _visiblePostNumbers.remove(postNumber);
    }
    _throttledUpdateScreenTrack();
  }

  void setReadPostNumbers(Set<int> readPostNumbers) {
    if (setEquals(_readPostNumbers, readPostNumbers)) return;
    _readPostNumbers
      ..clear()
      ..addAll(readPostNumbers);
    _throttledUpdateScreenTrack();
  }

  /// 节流更新 ScreenTrack
  void _throttledUpdateScreenTrack() {
    if (_screenTrackThrottleTimer?.isActive ?? false) return;
    _screenTrackThrottleTimer = Timer(const Duration(milliseconds: 100), () {
      if (_trackEnabled) {
        final readOnscreen = _visiblePostNumbers.intersection(_readPostNumbers);
        screenTrack.setOnscreen(_visiblePostNumbers, readOnscreen: readOnscreen);
      }
      // 更新当前可见帖子的 stream 索引
      if (_visiblePostNumbers.isNotEmpty) {
        final topPostNumber = _visiblePostNumbers.reduce((a, b) => a < b ? a : b);
        onStreamIndexChanged?.call(topPostNumber);
      }
    });
  }

  /// 更新 stream 索引
  void updateStreamIndex(int newIndex) {
    if (newIndex != _currentVisibleStreamIndex) {
      _currentVisibleStreamIndex = newIndex;
      notifyListeners();
    }
  }

  /// 获取刷新时的锚点帖子号
  int getRefreshAnchorPostNumber(int? fallbackPostNumber) {
    if (_visiblePostNumbers.isNotEmpty) {
      return _visiblePostNumbers.reduce((a, b) => a < b ? a : b);
    }
    return fallbackPostNumber ?? 1;
  }

  @override
  void dispose() {
    _screenTrackThrottleTimer?.cancel();
    super.dispose();
  }
}
