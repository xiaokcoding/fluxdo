import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'inline_spoiler_builder.dart' show spoilerMarkerFont;
import 'scan_boundary.dart';

/// 用于标记内联代码的特殊字体名称
const String _codeMarkerFont = '_InlineCode_';

/// 检查样式是否是内联代码
bool isCodeMarkerStyle(TextStyle? style) {
  if (style == null) return false;

  // 检查 fontFamily 和 fontFamilyFallback
  final fontFamily = style.fontFamily ?? '';
  final fallback = style.fontFamilyFallback ?? [];

  if (fontFamily.contains(_codeMarkerFont)) return true;
  for (final f in fallback) {
    if (f.contains(_codeMarkerFont)) return true;
  }
  return false;
}

/// 获取内联代码的 CSS 样式
Map<String, String> getInlineCodeStyles(bool isDark, {bool isInSpoiler = false}) {
  // 如果在 spoiler 内，需要同时包含 spoiler 标记
  final fontFamily = isInSpoiler
      ? '$spoilerMarkerFont, $_codeMarkerFont, FiraCode, monospace'
      : '$_codeMarkerFont, FiraCode, monospace';
  return {
    'font-family': fontFamily,
    'background-color': '#00000000', // 透明背景，由 overlay 绘制
    'color': isDark ? '#b0b0b0' : '#666666',
    'font-size': '0.85em',
  };
}

/// 构建 click-count Widget（直接 WidgetSpan 渲染）
Widget buildClickCountWidget({
  required String count,
  required bool isDark,
}) {
  final bgColor = isDark ? const Color(0xFF3a3d47) : const Color(0xFFe8ebef);
  final textColor = isDark ? const Color(0xFF9ca3af) : const Color(0xFF6b7280);

  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: bgColor,
      borderRadius: BorderRadius.circular(10),
    ),
    child: Text(
      count,
      style: TextStyle(
        color: textColor,
        fontSize: 10,
      ),
    ),
  );
}

/// 内联代码背景覆盖层 Widget
class InlineDecoratorOverlay extends StatefulWidget {
  final Widget child;

  const InlineDecoratorOverlay({
    super.key,
    required this.child,
  });

  @override
  State<InlineDecoratorOverlay> createState() => _InlineDecoratorOverlayState();
}

class _InlineDecoratorOverlayState extends State<InlineDecoratorOverlay> {
  // 内联代码组列表（每组是一个 code 元素的多行矩形）
  List<List<Rect>> _codeGroups = [];
  bool _hasScanned = false;
  bool _needsRescan = false;

  @override
  void didUpdateWidget(InlineDecoratorOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {
      // 标记需要重新扫描，但不清空旧数据，避免闪烁
      _needsRescan = true;
    }
  }

  void _scanForCodeRects() {
    // 先扫描到临时列表，扫描完成后再替换，避免闪烁
    final newGroups = <List<Rect>>[];

    final renderObject = context.findRenderObject();
    if (renderObject == null) return;

    _visitRenderObject(renderObject, Offset.zero, newGroups);

    // 扫描完成后一次性替换
    _codeGroups = newGroups;
  }

  void _visitRenderObject(RenderObject renderObject, Offset parentOffset, List<List<Rect>> groups) {
    // 遇到扫描边界时停止向下遍历（由内部 overlay 处理）
    if (renderObject is RenderScanBoundary) {
      return;
    }

    if (renderObject is RenderParagraph) {
      _extractCodeRects(renderObject, parentOffset, groups);
    }

    renderObject.visitChildren((child) {
      Offset childOffset = parentOffset;
      if (child is RenderBox && renderObject is RenderBox) {
        final parentData = child.parentData;
        if (parentData is BoxParentData) {
          childOffset = parentOffset + parentData.offset;
        }
      }
      _visitRenderObject(child, childOffset, groups);
    });
  }

  void _extractCodeRects(RenderParagraph paragraph, Offset offset, List<List<Rect>> groups) {
    final text = paragraph.text;
    _visitInlineSpan(text, paragraph, offset, 0, null, groups);
  }

  int _visitInlineSpan(
    InlineSpan span,
    RenderParagraph paragraph,
    Offset offset,
    int charIndex,
    TextStyle? parentStyle,
    List<List<Rect>> groups,
  ) {
    if (span is TextSpan) {
      final effectiveStyle = parentStyle?.merge(span.style) ?? span.style;
      final textLength = span.text?.length ?? 0;

      // 检测内联代码
      if (textLength > 0 && isCodeMarkerStyle(effectiveStyle)) {
        try {
          final boxes = paragraph.getBoxesForSelection(
            TextSelection(baseOffset: charIndex, extentOffset: charIndex + textLength),
          );

          // 收集同一个 code 元素的所有矩形作为一组
          // 过滤掉过窄的 rect（换行时单独留在行尾/行首的 thin space）
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
            groups.add(rects);
          }
        } catch (e) {
          // 忽略错误
        }
      }

      charIndex += textLength;

      if (span.children != null) {
        for (final child in span.children!) {
          charIndex = _visitInlineSpan(child, paragraph, offset, charIndex, effectiveStyle, groups);
        }
      }
    } else if (span is WidgetSpan) {
      charIndex += 1;
    }

    return charIndex;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Stack(
      children: [
        // 背景层在下面（ClipRect 防止溢出）
        // 使用 AnimatedOpacity 平滑过渡，避免闪烁
        if (_codeGroups.isNotEmpty)
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
                    painter: _InlineCodePainter(
                      groups: _codeGroups,
                      isDark: isDark,
                    ),
                  ),
                ),
              ),
            ),
          ),
        // 内容层在上面
        Builder(
          builder: (context) {
            // 首次构建或需要重新扫描时延迟扫描
            if (!_hasScanned || _needsRescan) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  _scanForCodeRects();
                  _hasScanned = true;
                  _needsRescan = false;
                  setState(() {});
                }
              });
            }
            return widget.child;
          },
        ),
      ],
    );
  }
}

/// 内联代码背景绘制器
class _InlineCodePainter extends CustomPainter {
  final List<List<Rect>> groups;
  final bool isDark;
  // 缓存 groups 的 hashCode 用于比较
  final int _groupsHash;

  _InlineCodePainter({
    required this.groups,
    required this.isDark,
  }) : _groupsHash = Object.hashAll(groups.map((g) => Object.hashAll(g)));

  @override
  void paint(Canvas canvas, Size size) {
    final bgColor = isDark ? const Color(0xFF3a3a3a) : const Color(0xFFe8e8e8);
    const radius = 3.0;
    const hPadding = 3.5; // 匹配外部 \u00A0 的宽度
    const vPadding = 1.5; // 垂直内边距（CSS line-height 对内联 code 无效，改用绘制扩展）

    final paint = Paint()
      ..style = PaintingStyle.fill
      ..color = bgColor;

    for (final group in groups) {
      // 按行分组（垂直方向有重叠的视为同一行）
      final rows = <List<Rect>>[];
      for (final rect in group) {
        bool added = false;
        for (final row in rows) {
          if (rect.top < row.first.bottom && rect.bottom > row.first.top) {
            row.add(rect);
            added = true;
            break;
          }
        }
        if (!added) {
          rows.add([rect]);
        }
      }

      final rowCount = rows.length;
      for (int i = 0; i < rowCount; i++) {
        final row = rows[i];
        // 单行内按左边位置排序
        row.sort((a, b) => a.left.compareTo(b.left));

        final isFirst = i == 0;
        final isLast = i == rowCount - 1;

        // 合并同行所有 rect 为一个完整区域，加上内边距
        final merged = Rect.fromLTRB(
          row.first.left - hPadding,
          row.map((r) => r.top).reduce((a, b) => a < b ? a : b) - vPadding,
          row.last.right + hPadding,
          row.map((r) => r.bottom).reduce((a, b) => a > b ? a : b) + vPadding,
        );

        // 第一行左圆角，最后一行右圆角，中间直角
        final Radius leftRadius = isFirst ? const Radius.circular(radius) : Radius.zero;
        final Radius rightRadius = isLast ? const Radius.circular(radius) : Radius.zero;

        final rrect = RRect.fromRectAndCorners(
          merged,
          topLeft: leftRadius,
          bottomLeft: leftRadius,
          topRight: rightRadius,
          bottomRight: rightRadius,
        );
        canvas.drawRRect(rrect, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_InlineCodePainter oldDelegate) {
    return isDark != oldDelegate.isDark || _groupsHash != oldDelegate._groupsHash;
  }
}
