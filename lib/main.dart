import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'pages/topics_page.dart';
import 'pages/topics_screen.dart';
import 'pages/profile_page.dart';
import 'providers/discourse_providers.dart';
import 'providers/message_bus_providers.dart';
import 'services/discourse/discourse_service.dart';
import 'providers/app_state_refresher.dart';
import 'services/highlighter_service.dart';
import 'widgets/common/smart_avatar.dart';
import 'services/network/cookie/cookie_sync_service.dart';
import 'services/network/cookie/cookie_jar_service.dart';
import 'services/network/adapters/cronet_fallback_service.dart';
import 'services/local_notification_service.dart';
import 'services/toast_service.dart';
import 'services/preloaded_data_service.dart';
import 'services/network/doh/network_settings_service.dart';
import 'services/network/proxy/proxy_settings_service.dart';
import 'services/network/doh_proxy/proxy_certificate.dart';
import 'services/cf_challenge_logger.dart';
import 'services/update_service.dart';
import 'services/update_checker_helper.dart';
import 'services/deep_link_service.dart';
import 'models/user.dart';
import 'constants.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'providers/theme_provider.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'widgets/preheat_gate.dart';
import 'widgets/onboarding_gate.dart';
import 'widgets/layout/adaptive_scaffold.dart';
import 'widgets/layout/adaptive_navigation.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 桌面平台初始化 window_manager（用于视频全屏等窗口控制）
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
  }

  // 初始化 User-Agent（获取 WebView UA 并移除 wv 标识）
  await AppConstants.initUserAgent();

  // 初始化语法高亮服务（预热 Isolate Worker 和字体）
  HighlighterService.instance.initialize(); // 不需要 await，后台初始化

  // 初始化 SharedPreferences
  final prefs = await SharedPreferences.getInstance();

  // 初始化 CF 验证日志（仅开发者模式启用）
  await CfChallengeLogger.setEnabled(prefs.getBool('developer_mode') ?? false);

  // 初始化代理 CA 证书（非 Android 平台）
  await ProxyCertificate.initialize();

  // 初始化 Cronet 降级服务
  await CronetFallbackService.instance.initialize(prefs);

  // 初始化网络设置（DoH/代理）
  await NetworkSettingsService.instance.initialize(prefs);

  // 初始化 HTTP 代理设置
  await ProxySettingsService.instance.initialize(prefs);

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
          scaffoldMessengerKey: scaffoldMessengerKey,
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
  ProviderSubscription<void>? _messageBusSub;
  bool _messageBusInitialized = false;
  int? _lastTappedIndex;
  DateTime? _lastTapTime;

  final List<Widget> _pages = const [
    TopicsScreen(),
    ProfilePage(),
  ];

  @override
  void initState() {
    super.initState();

    // 设置导航 context（用于 CF 验证弹窗）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DiscourseService().setNavigatorContext(context);
      PreloadedDataService().setNavigatorContext(context);

      // 初始化 Deep Link 服务
      DeepLinkService.instance.initialize(context);

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
    _currentUserSub = ref.listenManual<AsyncValue<User?>>(
      currentUserProvider,
      (_, next) {
        final user = next.value;
        if (user != null && !_messageBusInitialized) {
          _messageBusInitialized = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _messageBusSub?.close();
            _messageBusSub = ref.listenManual<void>(messageBusInitProvider, (_, _) {});
          });
        } else if (user == null) {
          _messageBusInitialized = false;
          _messageBusSub?.close();
          _messageBusSub = null;
        }
      },
      fireImmediately: true,
    );
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
        ref.read(bottomNavVisibleProvider.notifier).state = true;
      }
      _lastTappedIndex = null;
      _lastTapTime = null;
    } else {
      _lastTappedIndex = index;
      _lastTapTime = now;
      if (index != _currentIndex) {
        // 切换 tab 时重置底栏可见性
        ref.read(bottomNavVisibleProvider.notifier).state = true;
        setState(() => _currentIndex = index);
      }
    }
  }

  @override
  void dispose() {
    _authErrorSub?.close();
    _authStateSub?.close();
    _currentUserSub?.close();
    _messageBusSub?.close();
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

    // 首页的 FAB 由 TopicsScreen 内部处理，避免切换时闪烁
    return AdaptiveScaffold(
      selectedIndex: _currentIndex,
      onDestinationSelected: _onDestinationSelected,
      destinations: _buildDestinations(user),
      body: _pages[_currentIndex],
    );
  }

  List<AdaptiveDestination> _buildDestinations(User? user) {
    final avatarUrl = user?.getAvatarUrl();
    final hasAvatar = avatarUrl != null && avatarUrl.isNotEmpty;
    final avatarWidget = hasAvatar
        ? SmartAvatar(
            imageUrl: avatarUrl,
            radius: 12,
            fallbackText: user?.username,
          )
        : null;

    return [
      const AdaptiveDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: '首页',
      ),
      AdaptiveDestination(
        icon: avatarWidget ?? const Icon(Icons.person_outline),
        selectedIcon: avatarWidget ?? const Icon(Icons.person),
        label: '我的',
      ),
    ];
  }
}
