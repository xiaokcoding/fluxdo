import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../../constants.dart';
import '../../../../utils/layout_lock.dart';

/// iframe 属性解析结果
class IframeAttributes {
  final String src;
  final double? width;
  final double? height;
  final Set<String>? sandbox;
  final Set<String> allow;
  final bool allowFullscreen;
  final String? referrerPolicy;
  final bool lazyLoad;
  final String? title;

  IframeAttributes({
    required this.src,
    this.width,
    this.height,
    this.sandbox,
    this.allow = const {},
    this.allowFullscreen = false,
    this.referrerPolicy,
    this.lazyLoad = false,
    this.title,
  });

  /// 从 HTML element 解析 iframe 属性
  factory IframeAttributes.fromElement(dynamic element) {
    final attrs = element.attributes;

    // src 属性
    final src = (attrs['src'] as String?) ??
        (attrs['data-src'] as String?) ??
        '';

    // 宽高属性
    final width = double.tryParse(attrs['width'] as String? ?? '');
    final height = double.tryParse(attrs['height'] as String? ?? '');

    // sandbox 属性
    final sandboxAttr = attrs['sandbox'] as String?;
    final sandbox = sandboxAttr?.split(RegExp(r'\s+')).toSet();

    // allow 属性 (Permissions Policy)
    final allowAttr = attrs['allow'] as String?;
    final allow = allowAttr
            ?.split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toSet() ??
        {};

    // allowfullscreen 属性
    final allowFullscreen = attrs.containsKey('allowfullscreen') ||
        attrs['allowfullscreen'] == 'true' ||
        attrs['allowfullscreen'] == '' ||
        allow.any((p) => p.startsWith('fullscreen'));

    // referrerpolicy 属性
    final referrerPolicy = attrs['referrerpolicy'] as String?;

    // loading 属性
    final loadingAttr = attrs['loading'] as String?;
    final lazyLoad = loadingAttr == 'lazy';

    // title 属性
    final title = attrs['title'] as String?;

    return IframeAttributes(
      src: src,
      width: width,
      height: height,
      sandbox: sandbox,
      allow: allow,
      allowFullscreen: allowFullscreen,
      referrerPolicy: referrerPolicy,
      lazyLoad: lazyLoad,
      title: title,
    );
  }

  /// 是否允许脚本执行
  bool get allowScripts => sandbox == null || sandbox!.contains('allow-scripts');

  /// 是否允许自动播放
  bool get allowAutoplay => allow.any((p) => p.startsWith('autoplay'));

  /// 是否允许加密媒体
  bool get allowEncryptedMedia =>
      allow.any((p) => p.startsWith('encrypted-media'));

  /// 计算宽高比
  double get aspectRatio {
    if (width != null && width! > 0 && height != null && height! > 0) {
      return width! / height!;
    }
    return 16 / 9; // 默认 16:9
  }

  /// 获取完整 URL
  String get fullUrl {
    if (src.startsWith('/') && !src.startsWith('//')) {
      return '${AppConstants.baseUrl}$src';
    }
    return src;
  }
}

/// 构建 iframe Widget
Widget? buildIframe({
  required BuildContext context,
  required dynamic element,
}) {
  // Web 平台不处理，让 flutter_widget_from_html 处理
  if (kIsWeb) return null;

  final attrs = IframeAttributes.fromElement(element);

  if (attrs.src.isEmpty) {
    return const SizedBox.shrink();
  }

  return IframeWidget(attributes: attrs);
}

/// iframe Widget
class IframeWidget extends StatefulWidget {
  final IframeAttributes attributes;

  const IframeWidget({
    super.key,
    required this.attributes,
  });

  @override
  State<IframeWidget> createState() => _IframeWidgetState();
}

class _IframeWidgetState extends State<IframeWidget> {
  bool _isLoaded = false;
  bool _hasError = false;
  bool _didLockLayout = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _unlockLayoutIfNeeded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final attrs = widget.attributes;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: AspectRatio(
        aspectRatio: attrs.aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Stack(
            children: [
              // WebView
              InAppWebView(
                initialUrlRequest: URLRequest(url: WebUri(attrs.fullUrl)),
                initialSettings: _buildSettings(attrs),
                onEnterFullscreen: (controller) {
                  _lockLayout();
                },
                onExitFullscreen: (controller) {
                  _unlockLayoutIfNeeded();
                },
                onLoadStart: (controller, url) {
                  if (mounted) {
                    setState(() {
                      _isLoaded = false;
                      _hasError = false;
                    });
                  }
                },
                onLoadStop: (controller, url) {
                  if (mounted) {
                    setState(() => _isLoaded = true);
                  }
                },
                onReceivedError: (controller, request, error) {
                  // 只有主框架加载失败才显示错误
                  // 忽略子资源（JS、图片、视频海报等）的加载错误
                  if (mounted && request.isForMainFrame == true) {
                    setState(() => _hasError = true);
                  }
                },
              ),
              // 加载指示器
              if (!_isLoaded && !_hasError)
                Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Center(
                    child: CircularProgressIndicator(),
                  ),
                ),
              // 错误状态
              if (_hasError)
                Container(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '加载失败',
                          style: TextStyle(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  InAppWebViewSettings _buildSettings(IframeAttributes attrs) {
    return InAppWebViewSettings(
      // JavaScript
      javaScriptEnabled: attrs.allowScripts,

      // 媒体播放
      mediaPlaybackRequiresUserGesture: !attrs.allowAutoplay,
      allowsInlineMediaPlayback: true,

      // 全屏
      iframeAllowFullscreen: attrs.allowFullscreen,

      // 外观
      transparentBackground: true,

      // 安全
      javaScriptCanOpenWindowsAutomatically: false,

      // 性能
      useHybridComposition: true,

      // 引用策略
      preferredContentMode: UserPreferredContentMode.RECOMMENDED,
    );
  }

  void _lockLayout() {
    if (_didLockLayout) return;
    _didLockLayout = true;
    LayoutLock.acquire();
  }

  void _unlockLayoutIfNeeded() {
    if (!_didLockLayout) return;
    _didLockLayout = false;
    LayoutLock.release();
  }
}
