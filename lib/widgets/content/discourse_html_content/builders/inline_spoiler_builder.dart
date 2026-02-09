import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'inline_decorator_builder.dart' show isCodeMarkerStyle;
import 'scan_boundary.dart';
import 'spoiler_particles.dart';

/// 用于标记 spoiler 的特殊字体名称
const String spoilerMarkerFont = '_SpoilerMarker_';

/// 检查样式是否是 spoiler 标记
bool isSpoilerMarkerStyle(TextStyle? style) {
  if (style == null) return false;

  // 检查 fontFamily 和 fontFamilyFallback
  final fontFamily = style.fontFamily ?? '';
  if (fontFamily.contains(spoilerMarkerFont)) return true;

  final fallback = style.fontFamilyFallback ?? [];
  for (final f in fallback) {
    if (f.contains(spoilerMarkerFont)) return true;
  }
  return false;
}

/// 内联 Spoiler 覆盖层 Widget
class SpoilerOverlay extends StatefulWidget {
  final Widget child;
  final Set<String> revealedSpoilers;
  final void Function(String id)? onReveal;

  const SpoilerOverlay({
    super.key,
    required this.child,
    required this.revealedSpoilers,
    this.onReveal,
  });

  @override
  State<SpoilerOverlay> createState() => SpoilerOverlayState();
}

class SpoilerOverlayState extends State<SpoilerOverlay>
    with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  Duration _lastElapsed = Duration.zero;

  // Spoiler 组（每组可能包含多行）
  List<_SpoilerGroup> _groups = [];

  bool _hasScanned = false;
  bool _needsRescan = false;
  int _scanDelayCounter = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final dtMs = (elapsed - _lastElapsed).inMilliseconds.toDouble();
    _lastElapsed = elapsed;

    if (!_hasScanned || _needsRescan) {
      _scanDelayCounter++;
      // 等待 2 帧确保 RenderTree 完成布局
      if (_scanDelayCounter >= 2) {
        _scanForSpoilers();
        _hasScanned = true;
        _needsRescan = false;
        // 扫描完成后，如果没有未揭示的 spoiler，停止 Ticker 节省性能
        if (!_hasActiveSpoilers()) {
          _ticker?.stop();
        }
      }
      return;
    }

    // 检查是否还有未揭示的 spoiler 需要动画
    if (!_hasActiveSpoilers()) {
      _ticker?.stop();
      return;
    }

    if (dtMs > 0 && dtMs < 100) {
      for (final group in _groups) {
        if (!group.isRevealed) {
          group.particleSystem.update(dtMs);
        }
      }
      setState(() {});
    }
  }

  /// 检查是否有未揭示的 spoiler
  bool _hasActiveSpoilers() {
    if (_groups.isEmpty) return false;
    for (final group in _groups) {
      if (!group.isRevealed) return true;
    }
    return false;
  }

  @override
  void didUpdateWidget(SpoilerOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      // 标记需要重新扫描，但不清空旧数据，避免闪烁
      _needsRescan = true;
      _scanDelayCounter = 0;
      // 重新启动 Ticker 以进行扫描
      if (_ticker != null && !_ticker!.isActive) {
        _ticker!.start();
      }
    }
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _scanForSpoilers() {
    final renderObject = context.findRenderObject();
    if (renderObject == null) return;

    // 临时收集所有区域
    final List<_TempRect> tempRects = [];
    _visitRenderObject(renderObject, Offset.zero, tempRects);

    // 将相邻的区域合并为组（同一个 spoiler 可能跨多行）
    final newGroups = _buildGroups(tempRects);

    // 初始化粒子并标记已揭示的组
    for (final group in newGroups) {
      if (widget.revealedSpoilers.contains(group.id)) {
        group.isRevealed = true;
      } else {
        group.particleSystem.initForRects(group.rects.map((r) => r.rect).toList());
      }
    }

    // 扫描完成后一次性替换，避免闪烁
    _groups = newGroups;
  }

  void _visitRenderObject(RenderObject renderObject, Offset parentOffset, List<_TempRect> tempRects) {
    // 遇到扫描边界时停止向下遍历（由内部 overlay 处理）
    if (renderObject is RenderScanBoundary) {
      return;
    }

    if (renderObject is RenderParagraph) {
      _extractSpoilerRects(renderObject, parentOffset, tempRects);
    }

    renderObject.visitChildren((child) {
      Offset childOffset = parentOffset;
      if (child is RenderBox && renderObject is RenderBox) {
        final parentData = child.parentData;
        if (parentData is BoxParentData) {
          childOffset = parentOffset + parentData.offset;
        }
      }
      _visitRenderObject(child, childOffset, tempRects);
    });
  }

  void _extractSpoilerRects(RenderParagraph paragraph, Offset offset, List<_TempRect> tempRects) {
    final text = paragraph.text;
    _visitInlineSpan(text, paragraph, offset, 0, null, false, null, tempRects);
    // 返回值不需要使用
  }

  /// 遍历 InlineSpan 树，收集 spoiler 区域
  /// [parentIsSpoiler] 父级是否已经是 spoiler
  /// [currentSpoilerId] 当前所属的 spoiler group ID
  /// 返回 (charIndex, spoilerId) - spoilerId 用于 siblings 共享
  (int, String?) _visitInlineSpan(
    InlineSpan span,
    RenderParagraph paragraph,
    Offset offset,
    int charIndex,
    TextStyle? parentStyle,
    bool parentIsSpoiler,
    String? currentSpoilerId,
    List<_TempRect> tempRects,
  ) {
    if (span is TextSpan) {
      final effectiveStyle = parentStyle?.merge(span.style) ?? span.style;
      final textLength = span.text?.length ?? 0;

      // 检测当前样式是否有 spoiler 标记
      final hasSpoilerMarker = isSpoilerMarkerStyle(effectiveStyle);

      // 是否在 spoiler 内（当前有标记，或者父级已在 spoiler 内）
      final inSpoiler = hasSpoilerMarker || parentIsSpoiler;

      // 决定 spoiler ID
      String? spoilerId = currentSpoilerId;
      if (inSpoiler && spoilerId == null) {
        // 新进入一个 spoiler 区域，生成新的 group ID
        spoilerId = 'spoiler_${charIndex}_${paragraph.hashCode}';
      }

      if (textLength > 0 && inSpoiler) {
        // 检测是否同时是内联代码（code 背景会有 padding 扩展）
        final isCode = isCodeMarkerStyle(effectiveStyle);
        const codeHPadding = 3.5; // 与 _InlineCodePainter 的 hPadding 一致
        const codeVPadding = 1.5; // 与 _InlineCodePainter 的 vPadding 一致

        try {
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: charIndex, extentOffset: charIndex + textLength),
          );

          for (final box in boxes) {
            var rect = Rect.fromLTRB(
              offset.dx + box.left,
              offset.dy + box.top,
              offset.dx + box.right,
              offset.dy + box.bottom,
            );

            // 如果是 code，扩展范围以覆盖 code 背景的 padding
            if (isCode) {
              rect = Rect.fromLTRB(
                rect.left - codeHPadding,
                rect.top - codeVPadding,
                rect.right + codeHPadding,
                rect.bottom + codeVPadding,
              );
            }

            if (rect.width > 0 && rect.height > 0) {
              tempRects.add(_TempRect(
                rect: rect,
                groupId: spoilerId!,
              ));
            }
          }
        } catch (e) {
          // 忽略错误
        }
      }

      charIndex += textLength;

      if (span.children != null) {
        // 在遍历 children 时保持 spoilerId 的持续性
        String? childSpoilerId = spoilerId;
        for (final child in span.children!) {
          final result = _visitInlineSpan(
            child,
            paragraph,
            offset,
            charIndex,
            effectiveStyle,
            inSpoiler,         // 传递是否在 spoiler 内
            childSpoilerId,    // 传递当前的 spoiler ID
            tempRects,
          );
          charIndex = result.$1;
          // 如果 child 进入了 spoiler，更新 spoilerId 供后续 siblings 使用
          if (result.$2 != null) {
            childSpoilerId = result.$2;
            // 也更新当前的 spoilerId，用于返回
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

  /// 将临时区域按 groupId 分组，并归一化同行高度
  List<_SpoilerGroup> _buildGroups(List<_TempRect> tempRects) {
    final Map<String, List<_SpoilerRect>> groupMap = {};

    for (final temp in tempRects) {
      groupMap.putIfAbsent(temp.groupId, () => []).add(
        _SpoilerRect(rect: temp.rect),
      );
    }

    final groups = <_SpoilerGroup>[];
    for (final entry in groupMap.entries) {
      // 对同一 group 内的 rects 进行同行高度归一化
      final normalizedRects = _normalizeRowHeights(entry.value);
      groups.add(_SpoilerGroup(
        id: entry.key,
        rects: normalizedRects,
      ));
    }
    return groups;
  }

  /// 归一化同行的 rect 高度
  /// 将同一行内的所有 rect 统一为该行的最大高度
  List<_SpoilerRect> _normalizeRowHeights(List<_SpoilerRect> rects) {
    if (rects.isEmpty) return rects;

    // 按行分组（垂直方向有重叠的视为同一行）
    final List<List<_SpoilerRect>> rows = [];

    for (final rect in rects) {
      bool addedToRow = false;
      for (final row in rows) {
        // 检查是否与该行的任意 rect 在垂直方向有重叠
        for (final existing in row) {
          if (_verticalOverlap(rect.rect, existing.rect)) {
            row.add(rect);
            addedToRow = true;
            break;
          }
        }
        if (addedToRow) break;
      }
      if (!addedToRow) {
        rows.add([rect]);
      }
    }

    // 对每行进行高度归一化
    final List<_SpoilerRect> result = [];
    for (final row in rows) {
      // 找出该行的最小 top 和最大 bottom
      double minTop = row.first.rect.top;
      double maxBottom = row.first.rect.bottom;
      for (final rect in row) {
        if (rect.rect.top < minTop) minTop = rect.rect.top;
        if (rect.rect.bottom > maxBottom) maxBottom = rect.rect.bottom;
      }

      // 用统一的 top 和 bottom 创建新的 rect
      for (final rect in row) {
        result.add(_SpoilerRect(
          rect: Rect.fromLTRB(rect.rect.left, minTop, rect.rect.right, maxBottom),
        ));
      }
    }

    return result;
  }

  /// 检查两个 rect 在垂直方向是否有重叠
  bool _verticalOverlap(Rect a, Rect b) {
    return a.top < b.bottom && a.bottom > b.top;
  }

  void _handleTap(Offset position) {
    for (final group in _groups) {
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
    // 使用页面背景色，让 spoiler 背景融为一体
    final backgroundColor = theme.scaffoldBackgroundColor;

    final activeGroups = _groups.where((g) => !g.isRevealed).toList();

    return GestureDetector(
      onTapDown: (details) => _handleTap(details.localPosition),
      behavior: HitTestBehavior.translucent,
      child: Stack(
        children: [
          widget.child,
          if (activeGroups.isNotEmpty)
            Positioned.fill(
              child: IgnorePointer(
                child: ClipRect(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _InlineSpoilerPainter(
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

/// 临时区域数据
class _TempRect {
  final Rect rect;
  final String groupId;

  _TempRect({required this.rect, required this.groupId});
}

/// Spoiler 区域
class _SpoilerRect {
  final Rect rect;

  _SpoilerRect({required this.rect});
}

/// Spoiler 组（一个 spoiler 可能跨多行）
class _SpoilerGroup {
  final String id;
  final List<_SpoilerRect> rects;
  final SpoilerParticleSystem particleSystem = SpoilerParticleSystem();
  bool isRevealed = false;

  _SpoilerGroup({required this.id, required this.rects});

  /// 检查点是否在任意区域内
  bool containsPoint(Offset point) {
    for (final r in rects) {
      if (r.rect.contains(point)) return true;
    }
    return false;
  }
}

/// 内联 Spoiler 绘制器
class _InlineSpoilerPainter extends CustomPainter {
  final List<_SpoilerGroup> groups;
  final bool isDark;
  final Color backgroundColor;

  static const alphaLevels = [0.3, 0.6, 1.0];

  _InlineSpoilerPainter({
    required this.groups,
    required this.isDark,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final baseColor = isDark ? Colors.white : Colors.grey.shade800;
    final paint = Paint()..style = PaintingStyle.fill;

    for (final group in groups) {
      // 为每个区域绘制背景和粒子
      for (final spoilerRect in group.rects) {
        final rect = spoilerRect.rect;
        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));

        // 保存画布状态，设置裁剪区域
        canvas.save();
        canvas.clipRRect(rrect);

        // 绘制背景
        paint.color = backgroundColor;
        canvas.drawRRect(rrect, paint);

        // 绘制属于这个区域的粒子
        for (final p in group.particleSystem.particles) {
          if (p.boundingRect == rect) {
            paint.color = baseColor.withValues(alpha: alphaLevels[p.alphaType] * p.life);
            final radius = p.alphaType == 0 ? 0.7 : 0.6;
            canvas.drawCircle(Offset(p.x, p.y), radius, paint);
          }
        }

        // 恢复画布状态
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(_InlineSpoilerPainter oldDelegate) => true;
}

/// 获取 spoiler 的 CSS 样式
Map<String, String> getSpoilerStyles() {
  return {
    'font-family': '$spoilerMarkerFont, inherit',
  };
}
