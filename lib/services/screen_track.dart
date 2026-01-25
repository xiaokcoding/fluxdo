import 'dart:async';
import 'discourse_service.dart';

/// 阅读时间上报成功后的回调
/// [topicId] 话题 ID
/// [postNumbers] 已上报的帖子编号集合
/// [highestSeen] 最高已读帖子编号
typedef OnTimingsSent = void Function(int topicId, Set<int> postNumbers, int highestSeen);

/// 帖子浏览时间追踪服务
class ScreenTrack {
  static const _flushInterval = Duration(seconds: 60);
  static const _tickInterval = Duration(seconds: 1);
  static const _pauseUnlessScrolled = Duration(minutes: 3);
  static const _maxTrackingTime = Duration(minutes: 6);
  static const _ajaxFailureDelays = [
    Duration(seconds: 5),
    Duration(seconds: 10),
    Duration(seconds: 20),
    Duration(seconds: 40),
  ];
  static const _allowedAjaxFailures = {405, 429, 500, 501, 502, 503, 504};

  final DiscourseService _service;
  final OnTimingsSent? onTimingsSent;

  int? _topicId;
  Timer? _tickTimer;
  DateTime? _lastTick;
  DateTime? _lastScrolled;
  Duration _lastFlush = Duration.zero;
  int _topicTime = 0;

  final Map<int, int> _timings = {};
  final Map<int, int> _totalTimings = {};
  final List<_ConsolidatedTiming> _consolidatedTimings = [];
  final Set<int> _readPosts = {};
  int _ajaxFailures = 0;
  DateTime? _blockSendingUntil;
  Set<int> _onscreen = {};
  Set<int> _readOnscreen = {};
  bool _inProgress = false;
  bool _hasFocus = true;

  ScreenTrack(this._service, {this.onTimingsSent});

  void start(int topicId) {
    if (_topicId != null && _topicId != topicId) {
      _tick();
      _flush();
    }
    _reset();
    _topicId = topicId;
    _tickTimer ??= Timer.periodic(_tickInterval, (_) => _tick());
  }

  void stop() {
    if (_topicId == null) return;
    _tick();
    _flush();
    _reset();
    _topicId = null;
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  void setOnscreen(Set<int> postNumbers, {Set<int>? readOnscreen}) {
    _onscreen = postNumbers;
    _readOnscreen = readOnscreen ?? {};
  }

  void scrolled() {
    _lastScrolled = DateTime.now();
  }

  void setHasFocus(bool hasFocus) {
    _hasFocus = hasFocus;
  }

  void _reset() {
    final now = DateTime.now();
    _lastTick = now;
    _lastScrolled = now;
    _lastFlush = Duration.zero;
    _timings.clear();
    _totalTimings.clear();
    _consolidatedTimings.clear();
    _topicTime = 0;
    _onscreen = {};
    _readOnscreen = {};
    _readPosts.clear();
    _inProgress = false;
    _ajaxFailures = 0;
    _blockSendingUntil = null;
  }

  void _tick() {
    final now = DateTime.now();

    // 长时间未滚动则暂停追踪
    final sinceScrolled = now.difference(_lastScrolled ?? now);
    if (sinceScrolled > _pauseUnlessScrolled) return;

    final diff = now.difference(_lastTick ?? now).inMilliseconds;
    _lastFlush += Duration(milliseconds: diff);
    _lastTick = now;

    // 检查是否需要立即上报（有新的未上报帖子）
    final rush = _timings.entries.any((e) =>
        e.value > 0 &&
        !_totalTimings.containsKey(e.key) &&
        !_readPosts.contains(e.key));

    if (!_inProgress && (_lastFlush > _flushInterval || rush)) {
      _flush();
    }

    if (!_inProgress) {
      _sendNextConsolidatedTiming();
    }

    if (!_hasFocus) return;

    _topicTime += diff;
    for (final postNumber in _onscreen) {
      _timings[postNumber] = (_timings[postNumber] ?? 0) + diff;
    }

    for (final postNumber in _readOnscreen) {
      _readPosts.add(postNumber);
    }
  }

  void _flush() {
    final topicId = _topicId;
    if (topicId == null) return;

    final newTimings = <int, int>{};
    for (final entry in _timings.entries) {
      final postNumber = entry.key;
      final time = entry.value;
      final totalTime = _totalTimings[postNumber] ?? 0;

      if (time > 0 && totalTime < _maxTrackingTime.inMilliseconds) {
        _totalTimings[postNumber] = totalTime + time;
        newTimings[postNumber] = time;
      }
      _timings[postNumber] = 0;
    }

    final highestSeen = newTimings.keys.fold<int>(0, (max, v) => v > max ? v : max);

    if (highestSeen > 0) {
      if (_service.isAuthenticated) {
        _consolidateTimings(newTimings, _topicTime, topicId);
        _sendNextConsolidatedTiming();
      }
      _topicTime = 0;
    }

    _lastFlush = Duration.zero;
  }

  void _consolidateTimings(Map<int, int> timings, int topicTime, int topicId) {
    final existingIndex = _consolidatedTimings.indexWhere((t) => t.topicId == topicId);
    if (existingIndex != -1) {
      final existing = _consolidatedTimings[existingIndex];
      existing.topicTime += topicTime;
      timings.forEach((postNumber, time) {
        existing.timings[postNumber] = (existing.timings[postNumber] ?? 0) + time;
      });
    } else {
      _consolidatedTimings.add(
        _ConsolidatedTiming(
          topicId: topicId,
          topicTime: topicTime,
          timings: Map<int, int>.from(timings),
        ),
      );
    }
  }

  Future<void> _sendNextConsolidatedTiming() async {
    if (_consolidatedTimings.isEmpty) return;
    if (_inProgress) return;
    if (!_service.isAuthenticated) return;
    if (_blockSendingUntil != null && _blockSendingUntil!.isAfter(DateTime.now())) {
      return;
    }

    _inProgress = true;
    final next = _consolidatedTimings.removeLast();
    try {
      final statusCode = await _service.topicsTimings(
        topicId: next.topicId,
        topicTime: next.topicTime,
        timings: next.timings,
      );
      
      // 上报成功后调用回调，同步本地状态
      if (statusCode != null && statusCode < 400) {
        _ajaxFailures = 0;
        if (next.timings.isNotEmpty && onTimingsSent != null) {
          final highestSeen = next.timings.keys.reduce((a, b) => a > b ? a : b);
          onTimingsSent!(next.topicId, next.timings.keys.toSet(), highestSeen);
        }
      } else {
        if (statusCode != null && _allowedAjaxFailures.contains(statusCode)) {
          final delayIndex = _ajaxFailures.clamp(0, _ajaxFailureDelays.length - 1);
          _ajaxFailures += 1;
          _blockSendingUntil = DateTime.now().add(_ajaxFailureDelays[delayIndex]);
          _consolidateTimings(next.timings, next.topicTime, next.topicId);
        }
      }
    } catch (e) {
      _consolidateTimings(next.timings, next.topicTime, next.topicId);
    } finally {
      _inProgress = false;
      _lastFlush = Duration.zero;
    }
  }
}

class _ConsolidatedTiming {
  _ConsolidatedTiming({
    required this.topicId,
    required this.topicTime,
    required this.timings,
  });

  final int topicId;
  int topicTime;
  final Map<int, int> timings;
}
