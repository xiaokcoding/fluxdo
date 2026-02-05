import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../utils/link_launcher.dart';
import '../constants.dart';
import '../services/network/cookie/cookie_jar_service.dart';
import '../services/webview_settings.dart';

/// 通用内置浏览器页面
class WebViewPage extends StatefulWidget {
  final String url;
  final String? title;
  final String? injectCss;

  const WebViewPage({
    super.key,
    required this.url,
    this.title,
    this.injectCss,
  });

  static Future<T?> open<T extends Object?>(BuildContext context, String url, {String? title, String? injectCss}) {
    return Navigator.push<T>(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewPage(url: url, title: title, injectCss: injectCss),
      ),
    );
  }

  @override
  State<WebViewPage> createState() => _WebViewPageState();
}

class _WebViewPageState extends State<WebViewPage> {
  InAppWebViewController? _controller;
  bool _isLoading = true;
  String _currentUrl = '';
  String _currentTitle = '';
  double _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;
  late final Future<void> _cookieSyncFuture;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.url;
    _currentTitle = widget.title ?? '';
    _cookieSyncFuture = _syncCookiesBeforeOpen();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _handleBackNavigation();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_currentTitle.isEmpty ? '浏览器' : _currentTitle),
          leading: IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '关闭',
          ),
          actions: [
            IconButton(
              icon: Icon(
                Icons.chevron_left_rounded,
                color: _canGoBack ? null : theme.disabledColor,
              ),
              onPressed: _canGoBack ? () => _controller?.goBack() : null,
              tooltip: '后退',
            ),
            IconButton(
              icon: Icon(
                Icons.chevron_right_rounded,
                color: _canGoForward ? null : theme.disabledColor,
              ),
              onPressed: _canGoForward ? () => _controller?.goForward() : null,
              tooltip: '前进',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () => _controller?.reload(),
              tooltip: '刷新',
            ),
            PopupMenuButton<String>(
              onSelected: _handleMenuAction,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'copy_url',
                  child: Row(
                    children: [
                      Icon(Icons.copy),
                      SizedBox(width: 8),
                      Text('复制链接'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'open_external',
                  child: Row(
                    children: [
                      Icon(Icons.open_in_browser),
                      SizedBox(width: 8),
                      Text('在外部浏览器打开'),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      body: FutureBuilder<void>(
        future: _cookieSyncFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          return Column(
            children: [
              if (_isLoading)
                LinearProgressIndicator(
                  value: _progress,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              Expanded(
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                  initialSettings: WebViewSettings.visible,
                  onWebViewCreated: (controller) => _controller = controller,
                  onLoadStart: (controller, url) {
                    setState(() {
                      _isLoading = true;
                      _currentUrl = url?.toString() ?? '';
                    });
                  },
                  onProgressChanged: (controller, progress) {
                    setState(() => _progress = progress / 100);
                  },
                  onLoadStop: (controller, url) async {
                    setState(() => _isLoading = false);
                    final title = await controller.getTitle();
                    final canGoBack = await controller.canGoBack();
                    final canGoForward = await controller.canGoForward();
                    final urlString = url?.toString();
                    setState(() {
                      _currentUrl = urlString ?? '';
                      _canGoBack = canGoBack;
                      _canGoForward = canGoForward;
                      if (title != null && title.isNotEmpty) {
                        _currentTitle = title;
                      }
                    });
                    if (urlString != null && _shouldSyncCookiesForUrl(urlString)) {
                      await CookieJarService().syncFromWebView();
                    }
                    if (widget.injectCss != null) {
                      await controller.injectCSSCode(source: widget.injectCss!);
                    }
                  },
                  onUpdateVisitedHistory: (controller, url, isReload) async {
                    final canGoBack = await controller.canGoBack();
                    final canGoForward = await controller.canGoForward();
                    final urlString = url?.toString();
                    setState(() {
                      _currentUrl = urlString ?? '';
                      _canGoBack = canGoBack;
                      _canGoForward = canGoForward;
                    });
                    if (urlString != null && _shouldSyncCookiesForUrl(urlString)) {
                      await CookieJarService().syncFromWebView();
                    }
                  },
                  onTitleChanged: (controller, title) {
                    if (title != null && title.isNotEmpty) {
                      setState(() => _currentTitle = title);
                    }
                  },
                ),
              ),
            ],
          );
        },
      ),
      ),
    );
  }

  Future<void> _syncCookiesBeforeOpen() async {
    await CookieJarService().syncToWebView();
  }

  bool _shouldSyncCookiesForUrl(String url) {
    final targetUri = Uri.tryParse(url);
    final baseUri = Uri.tryParse(AppConstants.baseUrl);
    if (targetUri == null || baseUri == null) return false;
    final targetHost = targetUri.host;
    final baseHost = baseUri.host;
    if (targetHost.isEmpty || baseHost.isEmpty) return false;
    return targetHost == baseHost || targetHost.endsWith('.$baseHost');
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'copy_url':
        _copyUrl();
        break;
      case 'open_external':
        _openInExternalBrowser();
        break;
    }
  }

  Future<void> _handleBackNavigation() async {
    final controller = _controller;
    if (controller == null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final canGoBack = await controller.canGoBack();
    if (canGoBack) {
      await controller.goBack();
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyUrl() async {
    if (_currentUrl.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: _currentUrl));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('链接已复制到剪贴板'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _openInExternalBrowser() async {
    if (_currentUrl.isEmpty) return;

    try {
      final success = await launchInExternalBrowser(_currentUrl);
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开外部浏览器')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败: $e')),
        );
      }
    }
  }
}
