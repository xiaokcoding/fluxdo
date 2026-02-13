import 'dart:async';

import 'package:flutter/material.dart';

import 'local_notification_service.dart';

/// Toast 类型
enum ToastType { success, error, info }

/// 全局 Toast 服务（基于 Overlay，显示在屏幕顶部）
class ToastService {
  static OverlayEntry? _currentEntry;
  static Timer? _dismissTimer;
  static AnimationController? _currentController;

  /// 显示 Toast
  static void show(
    String message, {
    ToastType type = ToastType.info,
    Duration duration = const Duration(seconds: 3),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) return;

    // 移除旧 Toast
    _dismiss(animate: false);

    late final AnimationController controller;
    late final OverlayEntry entry;

    // 用 OverlayEntry 的 builder 获取 TickerProvider
    entry = OverlayEntry(
      builder: (context) {
        return _ToastWidget(
          message: message,
          type: type,
          actionLabel: actionLabel,
          onAction: onAction,
          onControllerCreated: (c) {
            controller = c;
            _currentController = c;
            controller.forward();
          },
          onDismiss: () => _dismiss(animate: true),
        );
      },
    );

    _currentEntry = entry;
    overlay.insert(entry);

    // 自动消失
    _dismissTimer = Timer(duration, () => _dismiss(animate: true));
  }

  /// 显示成功提示
  static void showSuccess(String message) {
    show(message, type: ToastType.success);
  }

  /// 显示错误提示
  static void showError(String message) {
    show(message, type: ToastType.error);
  }

  /// 显示信息提示
  static void showInfo(String message) {
    show(message, type: ToastType.info);
  }

  static void _dismiss({required bool animate}) {
    _dismissTimer?.cancel();
    _dismissTimer = null;

    if (animate && _currentController != null) {
      final controller = _currentController!;
      final entry = _currentEntry;
      _currentEntry = null;
      _currentController = null;
      controller.reverse().then((_) {
        entry?.remove();
        controller.dispose();
      });
    } else {
      _currentController?.dispose();
      _currentController = null;
      _currentEntry?.remove();
      _currentEntry = null;
    }
  }
}

/// Toast 内容组件
class _ToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final String? actionLabel;
  final VoidCallback? onAction;
  final void Function(AnimationController) onControllerCreated;
  final VoidCallback onDismiss;

  const _ToastWidget({
    required this.message,
    required this.type,
    this.actionLabel,
    this.onAction,
    required this.onControllerCreated,
    required this.onDismiss,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  double _dragOffset = 0;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    widget.onControllerCreated(_controller);
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_dismissing) return;
    // 只允许向上拖动
    setState(() {
      _dragOffset = (_dragOffset + details.delta.dy).clamp(-double.infinity, 0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_dismissing) return;
    // 向上拖动超过 40px 或速度足够快则消失
    if (_dragOffset < -40 || details.velocity.pixelsPerSecond.dy < -200) {
      _dismissing = true;
      widget.onDismiss();
    } else {
      // 弹回原位
      setState(() => _dragOffset = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mediaQuery = MediaQuery.of(context);

    final (icon, iconColor) = switch (widget.type) {
      ToastType.success => (Icons.check_circle_rounded, Colors.green),
      ToastType.error => (Icons.error_rounded, colorScheme.error),
      ToastType.info => (Icons.info_rounded, colorScheme.primary),
    };

    return Positioned(
      top: mediaQuery.padding.top + 8,
      left: 16,
      right: 16,
      child: SlideTransition(
        position: _slideAnimation,
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Transform.translate(
            offset: Offset(0, _dragOffset),
            child: Opacity(
              // 拖动时逐渐变透明
              opacity: (_dragOffset < 0)
                  ? (1.0 + _dragOffset / 120).clamp(0.0, 1.0)
                  : 1.0,
              child: GestureDetector(
                onVerticalDragUpdate: _onVerticalDragUpdate,
                onVerticalDragEnd: _onVerticalDragEnd,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(12),
                  color: colorScheme.inverseSurface,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Icon(icon, color: iconColor, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.message,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: colorScheme.onInverseSurface,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.actionLabel != null) ...[
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () {
                              widget.onAction?.call();
                              widget.onDismiss();
                            },
                            style: TextButton.styleFrom(
                              foregroundColor: colorScheme.inversePrimary,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Text(widget.actionLabel!),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
