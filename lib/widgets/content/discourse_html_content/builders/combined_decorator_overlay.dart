import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'scan_boundary.dart';
import 'inline_decorator_common.dart';
import 'inline_code_painter.dart';
import 'inline_spoiler_painter.dart';

// 导出公共 API
export 'inline_decorator_common.dart';

/// 合并的内联装饰覆盖层
/// 一次扫描同时处理内联代码背景和 spoiler 粒子效果
class CombinedDecoratorOverlay extends StatefulWidget {
  final Widget child;
  final Set<String> revealedSpoilers;
  final void Function(String id)? onReveal;

  const CombinedDecoratorOverlay({
    super.key,
    required this.child,
    required this.revealedSpoilers,
    this.onReveal,
  });

  @override
  State<CombinedDecoratorOverlay> createState() => _CombinedDecoratorOverlayState();
}

class _CombinedDecoratorOverlayState extends State<CombinedDecoratorOverlay>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;

  // 内联代码组（每组是一个 code 元素的多行矩形）
  List<List<Rect>> _codeGroups = [];

  // Spoiler 组（每组可能包含多行）
  List<SpoilerGroup> _spoilerGroups = [];

  bool _hasScanned = false;
  bool _needsRescan = false;
  int _scanDelayCounter = 0;

  @override
  void initState() {
    super.initState();
    _scheduleScan();
  }

  void _scheduleScan() {
    _ticker ??= createTicker(_onTick);
    if (!_ticker!.isActive) {
      _ticker!.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastElapsed).inMilliseconds.toDouble();
    _lastElapsed = elapsed;

    // 扫描阶段
    if (!_hasScanned || _needsRescan) {
      _scanDelayCounter++;
      // 等待 2 帧确保 RenderTree 完成布局
      if (_scanDelayCounter >= 2) {
        _scan();
        _hasScanned = true;
        _needsRescan = false;
        _scanDelayCounter = 0;

        // 扫描完成后，如果没有活跃的 spoiler，停止 Ticker
        if (!_hasActiveSpoilers()) {
          _ticker?.stop();
        }
        // 扫描完成后始终 setState，确保 UI 立即更新
        setState(() {});
      }
      return;
    }

    // 动画阶段：更新 spoiler 粒子
    if (!_hasActiveSpoilers()) {
      _ticker?.stop();
      return;
    }

    if (dtMs > 0 && dtMs < 100) {
      for (final group in _spoilerGroups) {
        if (!group.isRevealed) {
          group.particleSystem.update(dtMs);
        }
      }
      setState(() {});
    }
  }

  bool _hasActiveSpoilers() {
    for (final group in _spoilerGroups) {
      if (!group.isRevealed) return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(CombinedDecoratorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      _needsRescan = true;
      _scanDelayCounter = 0;
      _scheduleScan();
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  /// 一次扫描同时收集 code 和 spoiler 的位置
  void _scan() {
    final renderObject = context.findRenderObject();
    if (renderObject == null) return;

    final newCodeGroups = <List<Rect>>[];
    final spoilerTempRects = <_TempRect>[];

    _visitRenderObject(renderObject, Offset.zero, newCodeGroups, spoilerTempRects);

    // 处理 code groups
    _codeGroups = newCodeGroups;

    // 处理 spoiler groups
    final newSpoilerGroups = _buildSpoilerGroups(spoilerTempRects);
    for (final group in newSpoilerGroups) {
      if (widget.revealedSpoilers.contains(group.id)) {
        group.isRevealed = true;
      } else {
        group.particleSystem.initForRects(group.rects.map((r) => r.rect).toList());
      }
    }
    _spoilerGroups = newSpoilerGroups;
  }

  void _visitRenderObject(
    RenderObject renderObject,
    Offset parentOffset,
    List<List<Rect>> codeGroups,
    List<_TempRect> spoilerRects,
  ) {
    // 遇到扫描边界时停止
    if (renderObject is RenderScanBoundary) {
      return;
    }

    if (renderObject is RenderParagraph) {
      _extractFromParagraph(renderObject, parentOffset, codeGroups, spoilerRects);
    }

    renderObject.visitChildren((child) {
      Offset childOffset = parentOffset;
      if (child is RenderBox && renderObject is RenderBox) {
        final parentData = child.parentData;
        if (parentData is BoxParentData) {
          childOffset = parentOffset + parentData.offset;
        }
      }
      _visitRenderObject(child, childOffset, codeGroups, spoilerRects);
    });
  }

  void _extractFromParagraph(
    RenderParagraph paragraph,
    Offset offset,
    List<List<Rect>> codeGroups,
    List<_TempRect> spoilerRects,
  ) {
    final text = paragraph.text;
    _visitInlineSpan(
      text,
      paragraph,
      offset,
      0,
      null,
      false,
      null,
      codeGroups,
      spoilerRects,
    );
  }

  /// 遍历 InlineSpan 树，同时收集 code 和 spoiler
  (int, String?) _visitInlineSpan(
    InlineSpan span,
    RenderParagraph paragraph,
    Offset offset,
    int charIndex,
    TextStyle? parentStyle,
    bool parentIsSpoiler,
    String? currentSpoilerId,
    List<List<Rect>> codeGroups,
    List<_TempRect> spoilerRects,
  ) {
    if (span is TextSpan) {
      final effectiveStyle = parentStyle?.merge(span.style) ?? span.style;
      final textLength = span.text?.length ?? 0;

      // 检测标记
      final isCode = isCodeMarkerStyle(effectiveStyle);
      final hasSpoilerMarker = isSpoilerMarkerStyle(effectiveStyle);
      final inSpoiler = hasSpoilerMarker || parentIsSpoiler;

      // 决定 spoiler ID
      String? spoilerId = currentSpoilerId;
      if (inSpoiler && spoilerId == null) {
        spoilerId = 'spoiler_${charIndex}_${paragraph.hashCode}';
      }

      if (textLength > 0) {
        try {
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: charIndex, extentOffset: charIndex + textLength),
          );

          // 收集 code rects
          if (isCode) {
            final rects = <Rect>[];
            for (final box in boxes) {
              final rect = Rect.fromLTRB(
                offset.dx + box.left,
                offset.dy + box.top,
                offset.dx + box.right,
                offset.dy + box.bottom,
              );
              if (rect.width > 0 && rect.height > 0) {
                rects.add(rect);
              }
            }
            if (rects.isNotEmpty) {
              codeGroups.add(rects);
            }
          }

          // 收集 spoiler rects
          if (inSpoiler) {
            const codeHPadding = 3.5;
            const codeVPadding = 1.5;

            for (final box in boxes) {
              var rect = Rect.fromLTRB(
                offset.dx + box.left,
                offset.dy + box.top,
                offset.dx + box.right,
                offset.dy + box.bottom,
              );

              // 如果同时是 code，扩展范围以覆盖 code 背景的 padding
              if (isCode) {
                rect = Rect.fromLTRB(
                  rect.left - codeHPadding,
                  rect.top - codeVPadding,
                  rect.right + codeHPadding,
                  rect.bottom + codeVPadding,
                );
              }

              if (rect.width > 0 && rect.height > 0) {
                spoilerRects.add(_TempRect(rect: rect, groupId: spoilerId!));
              }
            }
          }
        } catch (e) {
          // 忽略错误
        }
      }

      charIndex += textLength;

      if (span.children != null) {
        String? childSpoilerId = spoilerId;
        for (final child in span.children!) {
          final result = _visitInlineSpan(
            child,
            paragraph,
            offset,
            charIndex,
            effectiveStyle,
            inSpoiler,
            childSpoilerId,
            codeGroups,
            spoilerRects,
          );
          charIndex = result.$1;
          if (result.$2 != null) {
            childSpoilerId = result.$2;
            spoilerId ??= result.$2;
          }
        }
      }

      return (charIndex, spoilerId);
    } else if (span is WidgetSpan) {
      return (charIndex + 1, currentSpoilerId);
    }

    return (charIndex, currentSpoilerId);
  }

  List<SpoilerGroup> _buildSpoilerGroups(List<_TempRect> tempRects) {
    final Map<String, List<SpoilerRect>> groupMap = {};

    for (final temp in tempRects) {
      groupMap.putIfAbsent(temp.groupId, () => []).add(
        SpoilerRect(rect: temp.rect),
      );
    }

    final groups = <SpoilerGroup>[];
    for (final entry in groupMap.entries) {
      final normalizedRects = normalizeRowHeights(entry.value);
      groups.add(SpoilerGroup(id: entry.key, rects: normalizedRects));
    }
    return groups;
  }

  void _handleTap(Offset position) {
    for (final group in _spoilerGroups) {
      if (!group.isRevealed && group.containsPoint(position)) {
        group.isRevealed = true;
        widget.onReveal?.call(group.id);
        setState(() {});
        break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = theme.scaffoldBackgroundColor;

    final activeGroups = _spoilerGroups.where((g) => !g.isRevealed).toList();
    final hasCodeBackground = _codeGroups.isNotEmpty;
    final hasSpoilerOverlay = activeGroups.isNotEmpty;

    return GestureDetector(
      onTapDown: hasSpoilerOverlay ? (details) => _handleTap(details.localPosition) : null,
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          // Code 背景层（最底层）
          if (hasCodeBackground)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipRect(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0.0, end: 1.0),
                    duration: const Duration(milliseconds: 150),
                    builder: (context, opacity, child) => Opacity(
                      opacity: opacity,
                      child: child,
                    ),
                    child: CustomPaint(
                      painter: InlineCodePainter(
                        groups: _codeGroups,
                        isDark: isDark,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // 内容层
          widget.child,
          // Spoiler 粒子层（最顶层）
          if (hasSpoilerOverlay)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipRect(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: InlineSpoilerPainter(
                        groups: activeGroups,
                        isDark: isDark,
                        backgroundColor: backgroundColor,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 临时区域数据（扫描时使用）
class _TempRect {
  final Rect rect;
  final String groupId;
  _TempRect({required this.rect, required this.groupId});
}
