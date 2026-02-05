import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/draft.dart';
import 'discourse/discourse_service.dart';

/// 草稿保存状态
enum DraftSaveStatus {
  idle, // 无操作
  pending, // 等待保存（防抖中）
  saving, // 正在保存
  saved, // 已保存
  error, // 保存失败
}

/// 草稿控制器
/// 负责自动保存草稿、防抖、序列号管理
class DraftController {
  final String draftKey;
  final DiscourseService _service;

  /// 防抖延迟时间
  static const _debounceDelay = Duration(seconds: 2);

  /// 当前序列号
  int _sequence = 0;
  int get sequence => _sequence;

  /// 上次保存的内容快照（用于检测变化）
  String? _lastSavedContent;
  String? _lastSavedTitle;

  /// 防抖定时器
  Timer? _debounceTimer;

  /// 保存状态
  final _statusNotifier = ValueNotifier<DraftSaveStatus>(DraftSaveStatus.idle);
  ValueNotifier<DraftSaveStatus> get statusNotifier => _statusNotifier;
  DraftSaveStatus get status => _statusNotifier.value;

  /// 编辑器打开时间戳（用于计算 composerTime）
  final DateTime _openedAt = DateTime.now();

  /// 是否已释放
  bool _disposed = false;

  DraftController({
    required this.draftKey,
    DiscourseService? service,
  }) : _service = service ?? DiscourseService();

  /// 加载现有草稿
  /// 返回草稿数据，如果不存在返回 null
  Future<Draft?> loadDraft() async {
    try {
      final draft = await _service.getDraft(draftKey);
      if (draft != null) {
        _sequence = draft.sequence;
        _lastSavedContent = draft.data.reply;
        _lastSavedTitle = draft.data.title;
      }
      return draft;
    } catch (e) {
      debugPrint('[DraftController] loadDraft failed: $e');
      return null;
    }
  }

  /// 从预加载的草稿同步状态
  /// 用于预加载场景：点击按钮时发起请求，打开编辑器后同步状态
  void syncFromPreloadedDraft(Draft draft) {
    _sequence = draft.sequence;
    _lastSavedContent = draft.data.reply;
    _lastSavedTitle = draft.data.title;
  }

  /// 触发自动保存（带防抖）
  void scheduleSave(DraftData data) {
    if (_disposed) return;

    // 没有内容时不保存
    if (!data.hasContent) return;

    // 检查内容是否有变化
    if (!_hasContentChanged(data)) return;

    _debounceTimer?.cancel();
    _statusNotifier.value = DraftSaveStatus.pending;

    _debounceTimer = Timer(_debounceDelay, () {
      _save(data);
    });
  }

  /// 立即保存（关闭时调用）
  Future<void> saveNow(DraftData data) async {
    if (_disposed) return;

    _debounceTimer?.cancel();

    // 没有内容时不保存
    if (!data.hasContent) return;

    // 如果没有内容变化，不需要保存
    if (!_hasContentChanged(data)) return;

    await _save(data);
  }

  /// 执行保存
  Future<void> _save(DraftData data) async {
    if (_disposed) return;

    // 添加编辑时长信息
    final composerTime = DateTime.now().difference(_openedAt).inMilliseconds;
    final dataWithTime = data.copyWith(composerTime: composerTime);

    _statusNotifier.value = DraftSaveStatus.saving;

    try {
      final newSequence = await _service.saveDraft(
        draftKey: draftKey,
        data: dataWithTime,
        sequence: _sequence,
      );
      _sequence = newSequence;
      _lastSavedContent = data.reply;
      _lastSavedTitle = data.title;
      if (!_disposed) {
        _statusNotifier.value = DraftSaveStatus.saved;
      }
    } catch (e) {
      debugPrint('[DraftController] save failed: $e');
      if (!_disposed) {
        _statusNotifier.value = DraftSaveStatus.error;
      }
    }
  }

  /// 删除草稿
  Future<void> deleteDraft() async {
    _debounceTimer?.cancel();
    try {
      await _service.deleteDraft(draftKey, sequence: _sequence);
    } catch (e) {
      debugPrint('[DraftController] deleteDraft failed: $e');
    }
  }

  /// 检查内容是否有变化
  bool _hasContentChanged(DraftData data) {
    return data.reply != _lastSavedContent || data.title != _lastSavedTitle;
  }

  /// 释放资源
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    _statusNotifier.dispose();
  }
}
