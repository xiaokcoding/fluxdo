import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/topics_page.dart';
import 'pages/profile_page.dart';
import 'pages/create_topic_page.dart';
import 'pages/topic_detail_page/topic_detail_page.dart';
import 'providers/discourse_providers.dart';
import 'providers/message_bus_providers.dart';
import 'providers/app_state_refresher.dart';
import 'services/discourse_cache_manager.dart';
import 'services/highlighter_service.dart';
import 'services/discourse_service.dart';
import 'services/network/cookie/cookie_sync_service.dart';
import 'services/network/cookie/cookie_jar_service.dart';
import 'services/network/adapters/cronet_fallback_service.dart';
import 'services/local_notification_service.dart';
import 'services/preloaded_data_service.dart';
import 'services/network/doh/network_settings_service.dart';
import 'services/network/doh_proxy/proxy_certificate.dart';
import 'services/network_logger.dart';
import 'services/update_service.dart';
import 'services/update_checker_helper.dart';
import 'models/user.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'providers/theme_provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'widgets/preheat_gate.dart';
import 'widgets/onboarding_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化语法高亮服务（同步调用）
  HighlighterService.instance.initialize();

  // 初始化 SharedPreferences
  final prefs = await SharedPreferences.getInstance();

  // 初始化调试日志（写入到文档目录）
  await NetworkLogger.init();

  // 初始化代理 CA 证书（非 Android 平台）
  await ProxyCertificate.initialize();

  // 初始化 Cronet 降级服务
  await CronetFallbackService.instance.initialize(prefs);

  // 初始化网络设置（DoH/代理）
  await NetworkSettingsService.instance.initialize(prefs);

  // 初始化 CookieJar（持久化 Cookie 管理）
  await CookieJarService().initialize();

  // 初始化 Cookie 同步服务（CSRF token 等）
  await CookieSyncService().init();

  // 初始化本地通知服务（请求权限）
  LocalNotificationService().initialize();

  runApp(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
    ],
    child: const MainApp(),
  ));
}

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeState = ref.watch(themeProvider);

    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        ColorScheme lightScheme;
        ColorScheme darkScheme;

        if (themeState.useDynamicColor && lightDynamic != null && darkDynamic != null) {
          // Optimization: Use standard ColorScheme.fromSeed with the dynamic primary color
          // This ensures better contrast and consistency than using the raw OEM scheme
          lightScheme = ColorScheme.fromSeed(
            seedColor: lightDynamic.primary,
            brightness: Brightness.light,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: darkDynamic.primary,
            brightness: Brightness.dark,
          );
        } else {
          lightScheme = ColorScheme.fromSeed(
            seedColor: themeState.seedColor,
            brightness: Brightness.light,
          );
          darkScheme = ColorScheme.fromSeed(
            seedColor: themeState.seedColor,
            brightness: Brightness.dark,
          );
        }

        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'FluxDO',
          // 配置中文本地化
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [
            Locale('zh', 'CN'), // 简体中文
            Locale('en', 'US'), // 英文
          ],
          themeMode: themeState.mode,
          theme: ThemeData(
            colorScheme: lightScheme,
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: darkScheme,
            useMaterial3: true,
          ),
          home: const OnboardingGate(
            child: PreheatGate(child: MainPage()),
          ),
        );
      },
    );
  }
}

class MainPage extends ConsumerStatefulWidget {
  const MainPage({super.key});

  @override
  ConsumerState<MainPage> createState() => _MainPageState();
}

class _MainPageState extends ConsumerState<MainPage> {
  int _currentIndex = 0;
  ProviderSubscription<AsyncValue<String>>? _authErrorSub;
  ProviderSubscription<AsyncValue<void>>? _authStateSub;
  ProviderSubscription<AsyncValue<User?>>? _currentUserSub;
  bool _messageBusInitialized = false;
  int? _lastTappedIndex;
  DateTime? _lastTapTime;

  final List<Widget> _pages = const [
    TopicsPage(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();

    // 设置导航 context（用于 CF 验证弹窗）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DiscourseService().setNavigatorContext(context);
      PreloadedDataService().setNavigatorContext(context);

      // 自动检查更新
      _autoCheckUpdate();
    });
    // 监听登录失效事件
    _authErrorSub = ref.listenManual<AsyncValue<String>>(authErrorProvider, (_, next) {
      next.whenData((message) => _handleAuthError(message));
    });
    _authStateSub = ref.listenManual<AsyncValue<void>>(authStateProvider, (_, next) {
      next.whenData((_) {
        if (mounted) {
          AppStateRefresher.refreshAll(ref);
        }
      });
    });
    _currentUserSub = ref.listenManual<AsyncValue<User?>>(currentUserProvider, (_, next) {
      final user = next.value;
      if (user != null && !_messageBusInitialized) {
        _messageBusInitialized = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(messageBusInitProvider);
        });
      } else if (user == null) {
        _messageBusInitialized = false;
      }
    });
  }

  Future<void> _autoCheckUpdate() async {
    final prefs = ref.read(sharedPreferencesProvider);
    final updateService = UpdateService(prefs: prefs);
    await UpdateCheckerHelper.checkUpdateOnStartup(context, updateService);
  }

  void _onDestinationSelected(int index) {
    final now = DateTime.now();
    final isDoubleTap = _lastTappedIndex == index &&
        _lastTapTime != null &&
        now.difference(_lastTapTime!).inMilliseconds < 300;

    if (isDoubleTap && index == _currentIndex) {
      // 双击当前 tab，滚动到顶部
      if (index == 0) {
        ref.read(scrollToTopProvider.notifier).trigger();
      }
      _lastTappedIndex = null;
      _lastTapTime = null;
    } else {
      _lastTappedIndex = index;
      _lastTapTime = now;
      if (index != _currentIndex) {
        setState(() => _currentIndex = index);
      }
    }
  }

  @override
  void dispose() {
    _authErrorSub?.close();
    _authStateSub?.close();
    _currentUserSub?.close();
    super.dispose();
  }

  Future<void> _handleAuthError(String message) async {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );

    if (mounted) {
      await AppStateRefresher.resetForLogout(ref);
    }
    if (mounted) {
      setState(() => _currentIndex = 0);
      Navigator.of(context).popUntil((route) => route.isFirst);
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听当前用户状态
    final currentUserAsync = ref.watch(currentUserProvider);
    final user = currentUserAsync.value;

    return Scaffold(
      // App bar removed, delegated to individual pages
      body: _pages[_currentIndex],
      floatingActionButton: (_currentIndex == 0 && user != null)
          ? FloatingActionButton(
              onPressed: () async {
                final topicId = await Navigator.push<int>(
                  context,
                  MaterialPageRoute(builder: (_) => const CreateTopicPage()),
                );
                if (topicId != null && context.mounted) {
                  // 刷新列表
                  for (final filter in TopicListFilter.values) {
                    ref.invalidate(topicListProvider(filter));
                  }
                  // 跳转到新话题
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TopicDetailPage(topicId: topicId),
                    ),
                  );
                }
              },
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: _onDestinationSelected,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '首页',
          ),
          NavigationDestination(
            icon: user?.getAvatarUrl() != null && user!.getAvatarUrl().isNotEmpty
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: CircleAvatar(
                      backgroundImage: discourseImageProvider(user.getAvatarUrl()),
                    ),
                  )
                : const Icon(Icons.person_outline),
            selectedIcon: user?.getAvatarUrl() != null && user!.getAvatarUrl().isNotEmpty
                ? SizedBox(
                    width: 24,
                    height: 24,
                    child: CircleAvatar(
                      backgroundImage: discourseImageProvider(user.getAvatarUrl()),
                    ),
                  )
                : const Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
