import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart' hide Badge;
import 'dart:async';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import '../models/topic.dart';
import '../models/topic_vote.dart';
import '../models/user.dart';
import '../models/user_action.dart';
import '../models/notification.dart';
import '../models/category.dart';
import '../models/search_result.dart';
import '../models/emoji.dart';
import '../models/badge.dart';
import '../models/tag_search_result.dart';
import '../models/mention_user.dart';

import '../constants.dart';
import '../providers/message_bus_providers.dart';
import 'network/cookie/cookie_sync_service.dart';
import 'network/cookie/cookie_jar_service.dart';
import 'cf_challenge_service.dart';
import 'network/discourse_dio.dart';
import 'preloaded_data_service.dart';
import 'auth_log_service.dart';

/// Linux.do API 服务
class DiscourseService {
  static const String baseUrl = AppConstants.baseUrl;
  static const String _usernameKey = 'linux_do_username';

  final Dio _dio;
  final FlutterSecureStorage _storage;
  final CookieSyncService _cookieSync = CookieSyncService();
  final CookieJarService _cookieJar = CookieJarService();
  final CfChallengeService _cfChallenge = CfChallengeService();

  String? _tToken; // 缓存，用于同步 getter isAuthenticated
  String? _username;
  bool _credentialsLoaded = false;
  bool _isLoggingOut = false;

  // 用户统计数据缓存
  UserSummary? _cachedUserSummary;
  DateTime? _userSummaryCacheTime;
  static const _summaryCacheDuration = Duration(minutes: 5);

  // 用户状态通知器
  final ValueNotifier<User?> currentUserNotifier = ValueNotifier<User?>(null);

  // 认证错误流（用于登录失效通知）
  final _authErrorController = StreamController<String>.broadcast();
  Stream<String> get authErrorStream => _authErrorController.stream;

  // 认证状态变化（登录/退出）
  final _authStateController = StreamController<void>.broadcast();
  Stream<void> get authStateStream => _authStateController.stream;

  // CF 验证流（用于通知需要验证）
  final _cfChallengeController = StreamController<void>.broadcast();
  Stream<void> get cfChallengeStream => _cfChallengeController.stream;

  /// 设置导航 context（用于弹出 CF 验证页面）
  void setNavigatorContext(BuildContext context) {
    _cfChallenge.setContext(context);
  }

  DiscourseService._internal()
      : _dio = DiscourseDio.create(
          defaultHeaders: {
            'Accept': 'application/json;q=0.9, text/plain;q=0.8, */*;q=0.5',
            'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
            'X-Requested-With': 'XMLHttpRequest',
          },
        ),
        _storage = const FlutterSecureStorage() {

    // 设置 PreloadedDataService 的登录失效回调
    PreloadedDataService().setAuthInvalidCallback(() {
      _handleAuthInvalid('登录已失效，请重新登录');
    });

    // 添加业务特定拦截器 (插入到最前面以确保优先执行 credential 加载)
    _dio.interceptors.insert(0, InterceptorsWrapper(
      onRequest: (options, handler) async {
        // 首次请求时加载存储的凭据
        if (!_credentialsLoaded) {
          await _loadStoredCredentials();
          _credentialsLoaded = true;
        }

        // 添加 Discourse 官方请求头
        if (_tToken != null && _tToken!.isNotEmpty) {
          // 标识已登录用户
          options.headers['Discourse-Logged-In'] = 'true';
          // 标识用户在线状态
          options.headers['Discourse-Present'] = 'true';
        }

        print('[DIO] ${options.method} ${options.uri}');
        handler.next(options);
      },
      onResponse: (response, handler) async {
        // 跳过图片下载等无需登录校验的请求
        final skipAuthCheck = response.requestOptions.extra['skipAuthCheck'] == true;
        
        // 检查官方的被动登出响应头（优先级最高）
        final loggedOut = response.headers.value('discourse-logged-out');
        if (!skipAuthCheck && loggedOut != null && loggedOut.isNotEmpty && !_isLoggingOut) {
          await AuthLogService().logAuthInvalid(
            source: 'response_header',
            reason: 'discourse-logged-out',
            extra: {
              'method': response.requestOptions.method,
              'url': response.requestOptions.uri.toString(),
              'statusCode': response.statusCode,
              'responseHeaders': response.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
              'requestHeaders': response.requestOptions.headers,
            },
          );
          await _handleAuthInvalid('登录已失效，请重新登录');
          return handler.next(response);
        }

        // Token 由 CookieManager 自动处理，此处仅更新内存缓存
        final tToken = await _cookieJar.getTToken();
        if (tToken != null && tToken.isNotEmpty) {
          _tToken = tToken;
        }

        // 从响应头提取用户名（如果有）
        final username = response.headers.value('x-discourse-username');
        if (username != null && username.isNotEmpty && username != _username) {
          _username = username;
          _storage.write(key: _usernameKey, value: username);
        }

        print('[DIO] ${response.statusCode} ${response.requestOptions.uri}');
        handler.next(response);
      },
      onError: (error, handler) async {
        final skipAuthCheck = error.requestOptions.extra['skipAuthCheck'] == true;
        final data = error.response?.data;
        print('[DIO] Error: ${error.response?.statusCode}');

        // 检查官方的被动登出响应头（优先级最高）
        final loggedOut = error.response?.headers.value('discourse-logged-out');
        if (!skipAuthCheck && loggedOut != null && loggedOut.isNotEmpty && !_isLoggingOut) {
          await AuthLogService().logAuthInvalid(
            source: 'error_response_header',
            reason: 'discourse-logged-out',
            extra: {
              'method': error.requestOptions.method,
              'url': error.requestOptions.uri.toString(),
              'statusCode': error.response?.statusCode,
              'responseHeaders': error.response?.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
              'requestHeaders': error.requestOptions.headers,
              'errorMessage': error.message,
            },
          );
          await _handleAuthInvalid('登录已失效，请重新登录');
          return handler.next(error);
        }

        // 业务层面的登录失效处理
        if (!skipAuthCheck && data is Map && data['error_type'] == 'not_logged_in') {
          await AuthLogService().logAuthInvalid(
            source: 'error_response',
            reason: data['error_type']?.toString() ?? 'not_logged_in',
            extra: {
              'method': error.requestOptions.method,
              'url': error.requestOptions.uri.toString(),
              'statusCode': error.response?.statusCode,
              'errors': data['errors'],
              'responseHeaders': error.response?.headers.map.map((k, v) => MapEntry(k, v.join(', '))),
              'requestHeaders': error.requestOptions.headers,
              'errorMessage': error.message,
            },
          );
          final message = (data['errors'] as List?)?.first?.toString() ?? '登录已失效，请重新登录';
          await _handleAuthInvalid(message);
        }

        handler.next(error);
      },
    ));
  }

  static final DiscourseService _instance = DiscourseService._internal();
  factory DiscourseService() => _instance;

  CookieSyncService get cookieSync => _cookieSync;
  bool get isAuthenticated => _tToken != null && _tToken!.isNotEmpty;

  Future<void> _handleAuthInvalid(String message) async {
    if (_isLoggingOut) return;
    _isLoggingOut = true;
    await logout(callApi: false, refreshPreload: true);
    _isLoggingOut = false;
    _authErrorController.add(message);
  }

  /// 初始化时从 CookieJar 加载 token 和从存储加载用户名
  Future<void> _loadStoredCredentials() async {
    _tToken = await _cookieJar.getTToken();
    _username = await _storage.read(key: _usernameKey);
  }

  /// 检查是否已登录
  Future<bool> isLoggedIn() async {
    final tToken = await _cookieJar.getTToken();
    if (tToken == null || tToken.isEmpty) return false;
    _tToken = tToken;
    _username = await _storage.read(key: _usernameKey);
    return true;
  }

  /// 保存登录 Token（使用 CookieJarService）
  Future<void> saveTokens({required String tToken, String? cfClearance}) async {
    _tToken = tToken;
    await _cookieJar.setTToken(tToken);
    if (cfClearance != null) {
      await _cookieJar.setCfClearance(cfClearance);
    }
    _credentialsLoaded = false;
    await PreloadedDataService().refresh();
    _authStateController.add(null);
  }

  /// 保存登录 Token（兼容旧方法）
  Future<void> saveToken(String tToken) async {
    await saveTokens(tToken: tToken);
  }

  /// 保存用户名
  Future<void> saveUsername(String username) async {
    _username = username;
    await _storage.write(key: _usernameKey, value: username);
  }

  /// 登出
  Future<void> logout({bool callApi = true, bool refreshPreload = true}) async {
    if (callApi) {
      final usernameForLogout = _username ?? await _storage.read(key: _usernameKey);
      try {
        if (usernameForLogout != null && usernameForLogout.isNotEmpty) {
          await _dio.delete('/session/$usernameForLogout');
        }
      } catch (e) {
        debugPrint('[DiscourseService] Logout API failed: $e');
      }
    }

    _tToken = null;
    _username = null;
    _cachedUserSummary = null;
    _userSummaryCacheTime = null;
    await _storage.delete(key: _usernameKey);
    currentUserNotifier.value = null;
    await _cookieSync.reset();
    _credentialsLoaded = false;

    // 重置预加载数据缓存
    PreloadedDataService().reset();

    // 清空所有 Cookie
    await _cookieJar.clearAll();

    // 退出后刷新预加载数据（游客态）
    if (refreshPreload) {
      await PreloadedDataService().refresh();
    }
    _authStateController.add(null);
  }

  Future<TopicListResponse> getLatestTopics({int page = 0}) async {
    // 首页（page=0）优先使用预加载数据
    if (page == 0) {
      final preloaded = PreloadedDataService();
      final preloadedList = await preloaded.getInitialTopicList();
      if (preloadedList != null) {
        return preloadedList;
      }
    }

    final response = await _dio.get(
      '/latest.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取话题列表（支持分类和标签筛选）
  /// [filter] 筛选类型: latest, new, unread, top
  /// [categoryId] 分类 ID
  /// [categorySlug] 分类 slug
  /// [parentCategorySlug] 父分类 slug（用于子分类）
  /// [tags] 标签列表
  /// [page] 分页
  Future<TopicListResponse> getFilteredTopics({
    required String filter,
    int? categoryId,
    String? categorySlug,
    String? parentCategorySlug,
    List<String>? tags,
    int page = 0,
  }) async {
    String path;
    final queryParams = <String, dynamic>{};

    if (page > 0) {
      queryParams['page'] = page;
    }

    // 添加标签参数
    if (tags != null && tags.isNotEmpty) {
      queryParams['tags'] = tags.join(',');
    }

    // 构建请求路径
    if (categoryId != null && categorySlug != null) {
      // 按分类筛选
      if (parentCategorySlug != null) {
        // 子分类: /c/{parentSlug}/{childSlug}/{childId}/l/{filter}.json
        path = '/c/$parentCategorySlug/$categorySlug/$categoryId/l/$filter.json';
      } else {
        // 父分类: /c/{slug}/{id}/l/{filter}.json
        path = '/c/$categorySlug/$categoryId/l/$filter.json';
      }
    } else if (tags != null && tags.isNotEmpty) {
      // 仅按标签筛选: /tag/{tag}.json 或 /tags/intersection/{tag1}/{tag2}.json
      if (tags.length == 1) {
        path = '/tag/${tags.first}/l/$filter.json';
        queryParams.remove('tags'); // 路径中已包含标签
      } else {
        // 多个标签使用 intersection
        path = '/tags/intersection/${tags.join('/')}/l/$filter.json';
        queryParams.remove('tags');
      }
    } else {
      // 无筛选条件
      path = '/$filter.json';
    }

    final response = await _dio.get(path, queryParameters: queryParams.isNotEmpty ? queryParams : null);
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取"新"话题 (未读过的新话题)
  Future<TopicListResponse> getNewTopics({int page = 0}) async {
    final response = await _dio.get(
      '/new.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取"未读"话题 (有新回复的话题)
  Future<TopicListResponse> getUnreadTopics({int page = 0}) async {
    final response = await _dio.get(
      '/unread.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取"热门"话题
  Future<TopicListResponse> getHotTopics({int page = 0}) async {
    final response = await _dio.get(
      '/hot.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取话题详情 (包含 initial posts 和 stream IDs)
  /// [postNumber] 可选，从指定帖子位置开始加载
  /// [trackVisit] 是否记录访问（仅在用户主动访问时传 true）
  /// [filter] 可选，过滤模式（如 'summary' 表示热门回复）
  /// [usernameFilters] 可选，按用户名过滤帖子（如只看题主）
  Future<TopicDetail> getTopicDetail(int id, {int? postNumber, bool trackVisit = false, String? filter, String? usernameFilters}) async {
    final path = postNumber != null ? '/t/$id/$postNumber.json' : '/t/$id.json';
    final queryParams = <String, dynamic>{};
    if (trackVisit) {
      queryParams['track_visit'] = true;
    }
    if (filter != null) {
      queryParams['filter'] = filter;
    }
    if (usernameFilters != null) {
      queryParams['username_filters'] = usernameFilters;
    }
    final response = await _dio.get(
      path,
      queryParameters: queryParams.isNotEmpty ? queryParams : null,
    );
    return TopicDetail.fromJson(response.data);
  }

  /// 批量获取帖子内容 (by IDs)
  Future<PostStream> getPosts(int topicId, List<int> postIds) async {
    final response = await _dio.get(
      '/t/$topicId/posts.json',
      queryParameters: {
        'post_ids[]': postIds,
      },
    );
    final data = response.data as Map<String, dynamic>;
    if (data.containsKey('post_stream')) {
      return PostStream.fromJson(data['post_stream'] as Map<String, dynamic>);
    }
    return PostStream.fromJson(data);
  }

  /// 按帖子编号获取帖子（用于滚动加载）
  /// [postNumber] 起始帖子编号
  /// [asc] true 向下加载（更新的帖子），false 向上加载（更早的帖子）
  Future<PostStream> getPostsByNumber(int topicId, {required int postNumber, required bool asc}) async {
    final response = await _dio.get(
      '/t/$topicId/posts.json',
      queryParameters: {
        'post_number': postNumber,
        'asc': asc,
      },
    );
    final data = response.data as Map<String, dynamic>;
    if (data.containsKey('post_stream')) {
      return PostStream.fromJson(data['post_stream'] as Map<String, dynamic>);
    }
    return PostStream.fromJson(data);
  }

  Future<TopicListResponse> getTopTopics() async {
    final response = await _dio.get('/top.json');
    return TopicListResponse.fromJson(response.data);
  }

  Future<TopicListResponse> getCategoryTopics(String categorySlug) async {
    final response = await _dio.get('/c/$categorySlug.json');
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取站点信息（包含所有分类）
  /// 优先使用预加载数据，避免额外 API 请求
  Future<List<Category>> getCategories() async {
    // 优先从预加载数据获取
    final preloaded = PreloadedDataService();
    final preloadedCategories = await preloaded.getCategories();
    if (preloadedCategories != null && preloadedCategories.isNotEmpty) {
      return preloadedCategories;
    }

    // 降级：发起 API 请求
    final response = await _dio.get('/site.json');
    final site = SiteResponse.fromJson(response.data);
    return site.categories;
  }

  /// 获取站点热门标签
  /// 返回标签名列表，如果站点禁用标签则返回空列表
  /// 优先使用预加载数据
  Future<List<String>> getTags() async {
    // 优先从预加载数据获取
    final preloaded = PreloadedDataService();
    final preloadedTags = await preloaded.getTopTags();
    if (preloadedTags != null) {
      return preloadedTags;
    }

    // 降级：发起 API 请求
    try {
      final response = await _dio.get('/site.json');
      final data = response.data as Map<String, dynamic>;

      // 检查是否支持标签
      final canTagTopics = data['can_tag_topics'] as bool? ?? false;
      if (!canTagTopics) return [];

      // 获取热门标签
      final topTags = data['top_tags'] as List?;
      if (topTags == null) return [];

      // 兼容新旧格式：如果是对象则取 name 字段，如果是字符串则直接用
      return topTags.map((t) {
        if (t is Map<String, dynamic>) {
          return t['name'] as String? ?? '';
        }
        return t.toString();
      }).where((name) => name.isNotEmpty).toList();
    } catch (e) {
      print('[DiscourseService] getTags failed: $e');
      return [];
    }
  }

  /// 搜索标签（根据分类过滤）
  /// [query] 搜索词（可选）
  /// [categoryId] 分类 ID（可选，用于联动过滤）
  /// [selectedTags] 已选中的标签（避免重复选择）
  /// [limit] 返回数量限制，默认 8
  Future<TagSearchResult> searchTags({
    String query = '',
    int? categoryId,
    List<String>? selectedTags,
    int? limit,
  }) async {
    try {
      final queryParams = <String, dynamic>{
        'q': query,
        'filterForInput': true,
      };
      if (limit != null) {
        queryParams['limit'] = limit;
      }
      if (categoryId != null) {
        queryParams['categoryId'] = categoryId;
      }
      if (selectedTags != null && selectedTags.isNotEmpty) {
        queryParams['selected_tags'] = selectedTags;
      }

      final response = await _dio.get('/tags/filter/search', queryParameters: queryParams);
      return TagSearchResult.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      print('[DiscourseService] searchTags failed: $e');
      return TagSearchResult(results: []);
    }
  }

  /// 检查站点是否支持标签功能
  /// 优先使用预加载数据
  Future<bool> canTagTopics() async {
    // 优先从预加载数据获取
    final preloaded = PreloadedDataService();
    final canTag = await preloaded.canTagTopics();
    if (canTag != null) {
      return canTag;
    }

    // 降级：发起 API 请求
    try {
      final response = await _dio.get('/site.json');
      final data = response.data as Map<String, dynamic>;
      return data['can_tag_topics'] as bool? ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 获取话题标题最小长度
  Future<int> getMinTopicTitleLength() async {
    return PreloadedDataService().getMinTopicTitleLength();
  }

  /// 获取私信标题最小长度
  Future<int> getMinPmTitleLength() async {
    return PreloadedDataService().getMinPmTitleLength();
  }

  /// 获取首贴内容最小长度
  Future<int> getMinFirstPostLength() async {
    return PreloadedDataService().getMinFirstPostLength();
  }

  /// 获取私信内容最小长度
  Future<int> getMinPmPostLength() async {
    return PreloadedDataService().getMinPmPostLength();
  }

  /// 搜索用户（用于 @提及自动补全）
  /// [term] 搜索词
  /// [topicId] 话题 ID（可选，用于优先显示参与者）
  /// [categoryId] 分类 ID（可选）
  /// [includeGroups] 是否包含群组（默认 true）
  /// [limit] 结果数量限制（默认 6）
  Future<MentionSearchResult> searchUsers({
    required String term,
    int? topicId,
    int? categoryId,
    bool includeGroups = true,
    int limit = 6,
  }) async {
    try {
      final queryParams = <String, dynamic>{
        'term': term,
        'include_groups': includeGroups,
        'limit': limit,
      };
      if (topicId != null) {
        queryParams['topic_id'] = topicId;
      }
      if (categoryId != null) {
        queryParams['category_id'] = categoryId;
      }

      final response = await _dio.get('/u/search/users', queryParameters: queryParams);
      return MentionSearchResult.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      print('[DiscourseService] searchUsers failed: $e');
      return const MentionSearchResult(users: [], groups: []);
    }
  }

  /// 验证 @ 提及的用户/群组是否有效
  /// [names] 用户名/群组名列表
  /// 返回验证结果，包含有效用户、无效用户、群组等信息
  Future<MentionCheckResult> checkMentions(List<String> names) async {
    if (names.isEmpty) {
      return const MentionCheckResult();
    }
    try {
      final response = await _dio.get(
        '/composer/mentions',
        queryParameters: {
          'names[]': names,
        },
      );
      return MentionCheckResult.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      print('[DiscourseService] checkMentions failed: $e');
      return const MentionCheckResult();
    }
  }

  /// 获取可用的回应表情列表（从预加载数据）
  Future<List<String>> getEnabledReactions() async {
    final preloaded = PreloadedDataService();
    return preloaded.getEnabledReactions();
  }

  /// 获取缓存的用户名，如果没有则从预加载数据或存储获取
  Future<String?> getUsername() async {
    if (_username != null && _username!.isNotEmpty) return _username;

    _username = await _storage.read(key: _usernameKey);
    if (_username != null && _username!.isNotEmpty) return _username;

    // 优先从预加载数据获取（避免 429）
    try {
      final preloaded = PreloadedDataService();
      final currentUser = await preloaded.getCurrentUser();
      if (currentUser != null && currentUser['username'] != null) {
        _username = currentUser['username'] as String;
        await _storage.write(key: _usernameKey, value: _username!);
        return _username;
      }
    } catch (e) {
      print('[DIO] Failed to get username from preloaded: $e');
    }

    return null;
  }

  /// 获取用户信息（/u/{username}.json）
  Future<User> getUser(String username) async {
    final response = await _dio.get('/u/$username.json');
    final data = response.data as Map<String, dynamic>;
    return User.fromJson(data['user'] ?? data);
  }

  /// 从预加载数据获取当前用户（包含通知计数）
  Future<User?> getPreloadedCurrentUser() async {
    try {
      final preloaded = PreloadedDataService();
      final currentUserData = await preloaded.getCurrentUser();
      if (currentUserData != null) {
        final user = User.fromJson(currentUserData);
        currentUserNotifier.value = user;
        // 同时保存用户名
        if (user.username.isNotEmpty) {
          _username = user.username;
          await _storage.write(key: _usernameKey, value: _username!);
        }
        return user;
      }
    } catch (e) {
      print('[DiscourseService] getPreloadedCurrentUser failed: $e');
    }
    return null;
  }

  /// 获取当前用户信息（总是请求最新数据）
  Future<User?> getCurrentUser() async {
    final username = await getUsername();
    if (username == null) return null;

    try {
      final user = await getUser(username);
      currentUserNotifier.value = user;
      return user;
    } catch (e) {
      print('[DiscourseService] getCurrentUser failed: $e');
      return null;
    }
  }

  /// 获取用户统计数据（带缓存）
  /// forceRefresh: 强制刷新，忽略缓存
  Future<UserSummary> getUserSummary(String username, {bool forceRefresh = false}) async {
    // 检查缓存是否有效
    if (!forceRefresh &&
        _cachedUserSummary != null &&
        _userSummaryCacheTime != null &&
        DateTime.now().difference(_userSummaryCacheTime!) < _summaryCacheDuration) {
      return _cachedUserSummary!;
    }

    final response = await _dio.get('/users/$username/summary.json');
    final summary = UserSummary.fromJson(response.data);

    // 更新缓存
    _cachedUserSummary = summary;
    _userSummaryCacheTime = DateTime.now();

    return summary;
  }

  /// 预加载用户统计数据（启动时后台调用）
  Future<void> preloadUserSummary() async {
    if (_username == null || _username!.isEmpty) {
      await _loadStoredCredentials();
    }
    if (_username != null && _username!.isNotEmpty) {
      try {
        await getUserSummary(_username!, forceRefresh: true);
        debugPrint('[DiscourseService] UserSummary preloaded');
      } catch (e) {
        debugPrint('[DiscourseService] Preload UserSummary failed: $e');
      }
    }
  }
  
  /// 获取预加载的话题追踪频道元数据（MessageBus 初始 message ID）
  Future<Map<String, dynamic>?> getPreloadedTopicTrackingMeta() async {
    final preloaded = PreloadedDataService();
    return preloaded.getTopicTrackingStateMeta();
  }


  /// 获取图片请求头（User-Agent 和 Cookies）
  Future<Map<String, String>> getHeaders() async {
    final headers = <String, String>{
      'User-Agent': AppConstants.userAgent,
    };

    final cookies = await _cookieJar.getCookieHeader();
    if (cookies != null && cookies.isNotEmpty) {
      headers['Cookie'] = cookies;
    }

    return headers;
  }

  /// 下载图片（使用 WebView 适配器绕过 Cloudflare）
  Future<Uint8List?> downloadImage(String url) async {
    try {
      final response = await _dio.get(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          extra: {
            'skipCsrf': true,      // 跳过 CSRF token
            'skipAuthCheck': true,  // 跳过登录状态校验
          },
        ),
      );

      // 验证响应数据
      if (response.data is! List<int>) {
        debugPrint('[DiscourseService] Invalid response data type for image: $url');
        return null;
      }

      final bytes = Uint8List.fromList(response.data);

      // 验证数据不为空
      if (bytes.isEmpty) {
        debugPrint('[DiscourseService] Empty image data: $url');
        return null;
      }

      // 验证 Content-Type 是否是图片类型
      final contentType = response.headers.value('content-type')?.toLowerCase();
      if (contentType != null && !contentType.startsWith('image/')) {
        debugPrint('[DiscourseService] Invalid content-type for image: $contentType, url: $url');
        return null;
      }

      // 简单验证图片格式（检查文件头）
      if (!_isValidImageData(bytes)) {
        debugPrint('[DiscourseService] Invalid image data (magic bytes check failed): $url');
        return null;
      }

      return bytes;
    } catch (e) {
      debugPrint('[DiscourseService] Download image failed: $e, url: $url');
      return null;
    }
  }

  /// 验证图片数据是否有效（通过检查文件头魔数）
  bool _isValidImageData(Uint8List bytes) {
    if (bytes.length < 4) return false;

    // PNG: 89 50 4E 47
    if (bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47) {
      return true;
    }

    // JPEG: FF D8 FF
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) {
      return true;
    }

    // GIF: 47 49 46 38
    if (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return true;
    }

    // WebP: 52 49 46 46 (RIFF)
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50) {
      return true;
    }

    // BMP: 42 4D
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return true;
    }

    // ICO: 00 00 01 00
    if (bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0x01 && bytes[3] == 0x00) {
      return true;
    }

    return false;
  }

  /// 上报帖子阅读时间 (topics/timings)
  Future<int?> topicsTimings({
    required int topicId,
    required int topicTime,
    required Map<int, int> timings,
  }) async {
    try {
      if (!isAuthenticated) return null;
      final data = <String, dynamic>{
        'topic_id': topicId,
        'topic_time': topicTime,
      };
      timings.forEach((k, v) => data['timings[$k]'] = v);

      final response = await _dio.post(
        '/topics/timings',
        data: data,
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          extra: {'isSilent': true},
        ),
      );
      return response.statusCode;
    } on DioException catch (e) {
      print('[DiscourseService] topicsTimings failed: ${e.response?.statusCode}');
      return e.response?.statusCode;
    }
  }

  /// 获取通知列表
  Future<NotificationListResponse> getNotifications({int? offset}) async {
    final queryParams = <String, dynamic>{
      'limit': 30,
      'recent': true,
      'bump_last_seen_reviewable': true,
    };
    if (offset != null) {
      queryParams['offset'] = offset;
    }
    
    final response = await _dio.get(
      '/notifications',
      queryParameters: queryParams,
    );
    return NotificationListResponse.fromJson(response.data);
  }

  /// 标记所有通知为已读
  Future<void> markAllNotificationsRead() async {
    await _dio.put('/notifications/mark-read');
  }

  /// 标记单条通知为已读
  Future<void> markNotificationRead(int id) async {
    await _dio.put('/notifications/mark-read', data: {'id': id});
  }

  /// 搜索帖子/用户
  /// [query] 搜索关键词，支持高级语法如 @username, #category, tags: 等
  /// [page] 分页，从 1 开始
  Future<SearchResult> search({
    required String query,
    int page = 1,
  }) async {
    final response = await _dio.get(
      '/search.json',
      queryParameters: {
        'q': query,
        if (page > 1) 'page': page,
      },
    );
    return SearchResult.fromJson(response.data);
  }

  /// 获取用户浏览历史 (read topics)
  Future<TopicListResponse> getBrowsingHistory({int page = 0}) async {
    final response = await _dio.get(
      '/read.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户徽章列表
  /// [username] 必需，用户名
  Future<BadgeDetailResponse> getUserBadges({required String username}) async {
    final response = await _dio.get(
      '/user-badges/${username.toLowerCase()}.json',
      queryParameters: {'grouped': 'true'},
    );

    return BadgeDetailResponse.fromJson(response.data);
  }

  /// 获取徽章信息
  /// [badgeId] 必需，徽章ID
  Future<Badge> getBadge({required int badgeId}) async {
    final response = await _dio.get('/badges/$badgeId.json');
    final badgeData = response.data['badge'] as Map<String, dynamic>;
    return Badge.fromJson(badgeData);
  }

  /// 获取徽章的所有获得者
  /// [badgeId] 必需，徽章ID
  /// [username] 可选，筛选特定用户
  Future<BadgeDetailResponse> getBadgeUsers({required int badgeId, String? username}) async {
    final queryParams = <String, dynamic>{'badge_id': badgeId};
    if (username != null) {
      queryParams['username'] = username;
    }

    final response = await _dio.get(
      '/user_badges.json',
      queryParameters: queryParams,
    );

    return BadgeDetailResponse.fromJson(response.data);
  }

  /// 获取首页书签 tab (bookmarks)
  Future<TopicListResponse> getBookmarks({int page = 0}) async {
    final response = await _dio.get(
      '/bookmarks.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户个人书签 (u/{username}/bookmarks)
  Future<TopicListResponse> getUserBookmarks({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception('未登录或无法获取用户名');
    }
    final response = await _dio.get(
      '/u/$username/bookmarks.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户创建的话题 (topics/created-by/{username})
  Future<TopicListResponse> getUserCreatedTopics({int page = 0}) async {
    final username = await getUsername();
    if (username == null) {
      throw Exception('未登录或无法获取用户名');
    }
    final response = await _dio.get(
      '/topics/created-by/$username.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户动态（user_actions）
  /// [filter] 筛选类型: 1=点赞, 2=被点赞, 4=创建话题, 5=回复
  Future<UserActionResponse> getUserActions(String username, {int? filter, int offset = 0}) async {
    final queryParams = <String, dynamic>{
      'username': username,
      'offset': offset,
    };
    if (filter != null) {
      queryParams['filter'] = filter.toString();
    }
    final response = await _dio.get('/user_actions.json', queryParameters: queryParams);
    return UserActionResponse.fromJson(response.data);
  }

  /// 获取用户回应列表（discourse-reactions 插件）
  Future<UserReactionsResponse> getUserReactions(String username, {int? beforePostId}) async {
    final queryParams = <String, dynamic>{
      'username': username,
    };
    if (beforePostId != null) {
      queryParams['before_post_id'] = beforePostId;
    }
    final response = await _dio.get('/discourse-reactions/posts/reactions.json', queryParameters: queryParams);
    return UserReactionsResponse.fromJson(response.data);
  }

  /// 获取用户关注列表
  Future<List<FollowUser>> getFollowing(String username) async {
    final response = await _dio.get('/u/$username/follow/following');
    return (response.data as List).map((json) => FollowUser.fromJson(json)).toList();
  }

  /// 获取用户粉丝列表
  Future<List<FollowUser>> getFollowers(String username) async {
    final response = await _dio.get('/u/$username/follow/followers');
    return (response.data as List).map((json) => FollowUser.fromJson(json)).toList();
  }

  /// 上传图片
  /// [filePath] 图片文件路径
  /// 返回上传后的图片 URL (short_url 或 url)
  Future<String> uploadImage(String filePath) async {
    try {
      final fileName = filePath.split('/').last;
      
      final formData = FormData.fromMap({
        'upload_type': 'composer',
        'synchronous': true,
        'file': await MultipartFile.fromFile(filePath, filename: fileName),
      });

      final response = await _dio.post(
        '/uploads.json',
        queryParameters: {'client_id': MessageBusService().clientId},
        data: formData,
      );

      final data = response.data;
      // 优先返回 short_url，如果没有则返回 url
      if (data is Map) {
        if (data['short_url'] != null) {
          return data['short_url'];
        }
        if (data['url'] != null) {
          return data['url'];
        }
      }
      
      throw Exception('上传响应中未包含 URL');
    } on DioException catch (e) {
      print('[DiscourseService] Upload image failed: $e');
      if (e.response?.statusCode == 413) {
        throw Exception('图片文件过大，请压缩后重试');
      }
      if (e.response?.statusCode == 422) {
        final data = e.response?.data;
        if (data is Map && data['errors'] != null) {
          throw Exception((data['errors'] as List).join('\n'));
        }
        throw Exception('图片格式不支持或不符合要求');
      }
      rethrow;
    } catch (e) {
      print('[DiscourseService] Upload image failed: $e');
      rethrow;
    }
  }

  /// 创建话题
  /// 返回创建的话题 ID
  Future<int> createTopic({
    required String title,
    required String raw,
    required int categoryId,
    List<String>? tags,
  }) async {
    try {
      final data = <String, dynamic>{
        'title': title,
        'raw': raw,
        'category': categoryId,
        'archetype': 'regular',
      };
      
      // 添加标签（如果有）
      if (tags != null && tags.isNotEmpty) {
        data['tags[]'] = tags;
      }

      final response = await _dio.post(
        '/posts.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;
      // Discourse 响应格式：
      // 成功: { action: 'create_post', post: { topic_id: ... }, success: true }
      // 或直接返回 post 对象: { id: ..., topic_id: ... }
      
      // 情况1: 标准创建响应
      if (respData is Map && respData.containsKey('post') && respData['post']['topic_id'] != null) {
        return respData['post']['topic_id'] as int;
      }
      
      // 情况2: 直接返回 post 对象
      if (respData is Map && respData['topic_id'] != null) {
        return respData['topic_id'] as int;
      }
      
      // 情况3: 明确失败
      if (respData is Map && respData['success'] == false) {
        throw Exception(respData['errors']?.toString() ?? '创建话题失败');
      }
      
      throw Exception('未知响应格式');
    } on DioException catch (e) {
      if (e.response?.data != null && e.response!.data is Map) {
        final data = e.response!.data as Map;
        if (data['errors'] != null) {
          throw Exception((data['errors'] as List).join('\n'));
        }
      }
      rethrow;
    }
  }

  /// 设置话题订阅级别
  /// [topicId] 话题 ID
  /// [level] 订阅级别
  Future<void> setTopicNotificationLevel(int topicId, TopicNotificationLevel level) async {
    await _dio.post(
      '/t/$topicId/notifications',
      data: {'notification_level': level.value},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  /// 创建回复
  /// [topicId] 话题 ID
  /// [raw] 回复内容（Markdown）
  /// [replyToPostNumber] 可选，回复的帖子编号（不填则直接回复话题）
  /// 返回创建的 Post 对象
  Future<Post> createReply({
    required int topicId,
    required String raw,
    int? replyToPostNumber,
  }) async {
    try {
      final data = <String, dynamic>{
        'topic_id': topicId,
        'raw': raw,
      };

      if (replyToPostNumber != null) {
        data['reply_to_post_number'] = replyToPostNumber;
      }

      final response = await _dio.post(
        '/posts.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;

      // 情况1: 标准创建响应
      if (respData is Map && respData.containsKey('post') && respData['post'] != null) {
        return Post.fromJson(respData['post'] as Map<String, dynamic>);
      }

      // 情况2: 直接返回 post 对象
      if (respData is Map && respData['id'] != null) {
        return Post.fromJson(respData as Map<String, dynamic>);
      }

      // 情况3: 明确失败
      if (respData is Map && respData['success'] == false) {
        throw Exception(respData['errors']?.toString() ?? '回复失败');
      }

      throw Exception('未知响应格式');
    } on DioException catch (e) {
      if (e.response?.data != null && e.response!.data is Map) {
        final data = e.response!.data as Map;
        if (data['errors'] != null) {
          throw Exception((data['errors'] as List).join('\n'));
        }
      }
      rethrow;
    }
  }

  /// 获取话题回复 presence 状态
  /// 返回 {users: [...], messageId: int}
  Future<PresenceResponse> getPresence(int topicId) async {
    final response = await _dio.get(
      '/presence/get',
      queryParameters: {
        'channels[]': '/discourse-presence/reply/$topicId',
      },
    );
    return PresenceResponse.fromJson(response.data, topicId);
  }

  /// 更新 Presence 状态 (正在输入/离开)
  /// [presentChannels] 当前所在的频道列表
  /// [leaveChannels] 要离开的频道列表
  Future<void> updatePresence({
    List<String>? presentChannels,
    List<String>? leaveChannels,
  }) async {
    if (!isAuthenticated) return;
    
    final clientId = MessageBusService().clientId;
    final data = <String, dynamic>{
      'client_id': clientId,
    };
    
    if (presentChannels != null && presentChannels.isNotEmpty) {
      data['present_channels[]'] = presentChannels;
    }
    if (leaveChannels != null && leaveChannels.isNotEmpty) {
      data['leave_channels[]'] = leaveChannels;
    }
    
    try {
      await _dio.post(
        '/presence/update',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      debugPrint('[DiscourseService] updatePresence failed: ${e.response?.statusCode}');
    }
  }


  /// 点赞帖子
  /// 返回 true 表示成功
  Future<bool> likePost(int postId) async {
    try {
      await _dio.post(
        '/post_actions',
        data: {'id': postId, 'post_action_type_id': 2},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return true;
    } catch (e) {
      print('[DiscourseService] likePost failed: $e');
      return false;
    }
  }

  /// 取消点赞
  Future<bool> unlikePost(int postId) async {
    try {
      await _dio.delete(
        '/post_actions/$postId',
        queryParameters: {'post_action_type_id': 2},
      );
      return true;
    } catch (e) {
      print('[DiscourseService] unlikePost failed: $e');
      return false;
    }
  }

  /// 切换回应（添加/移除表情）
  /// 返回更新后的数据 {reactions, currentUserReaction}
  Future<Map<String, dynamic>?> toggleReaction(int postId, String reaction) async {
    try {
      final response = await _dio.put(
        '/discourse-reactions/posts/$postId/custom-reactions/$reaction/toggle.json',
      );
      final data = response.data as Map<String, dynamic>?;
      if (data != null) {
        return {
          'reactions': (data['reactions'] as List?)
              ?.map((e) => PostReaction.fromJson(e as Map<String, dynamic>))
              .toList() ?? [],
          'currentUserReaction': data['current_user_reaction'] != null
              ? PostReaction.fromJson(data['current_user_reaction'] as Map<String, dynamic>)
              : null,
        };
      }
      return null;
    } catch (e) {
      print('[DiscourseService] toggleReaction failed: $e');
      return null;
    }
  }

  /// 获取帖子的回复历史（被回复的帖子链）
  /// [postId] 帖子 ID（不是 postNumber）
  Future<List<Post>> getPostReplyHistory(int postId) async {
    final response = await _dio.get('/posts/$postId/reply-history');
    final data = response.data as List<dynamic>;
    return data.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 获取帖子的回复列表
  /// [postId] 帖子 ID（不是 postNumber）
  /// [after] 从指定 postNumber 之后开始加载
  Future<List<Post>> getPostReplies(int postId, {int after = 1}) async {
    final response = await _dio.get(
      '/posts/$postId/replies',
      queryParameters: {'after': after},
    );
    final data = response.data as List<dynamic>;
    return data.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 获取所有表情列表
  Future<Map<String, List<Emoji>>> getEmojis() async {
    try {
      final response = await _dio.get('/emojis.json');
      final data = response.data as Map<String, dynamic>;
      
      final Map<String, List<Emoji>> emojiGroups = {};
      
      data.forEach((group, emojis) {
        if (emojis is List) {
          emojiGroups[group] = emojis
              .map((e) => Emoji.fromJson(e as Map<String, dynamic>))
              .toList();
        }
      });
      
      return emojiGroups;
    } catch (e) {
      if (e is DioException) {
        throw _handleDioError(e);
      }
      rethrow;
    }
  }

  // Helper handling Dio error
  Exception _handleDioError(DioException error) {
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return TimeoutException(error.message);
    }
    if (error.response != null) {
      final statusCode = error.response!.statusCode;
      final errorMessage = error.response!.data.toString();
      return Exception('HTTP $statusCode: $errorMessage');
    }
    return Exception(error.message ?? 'Unknown Dio error');
  }

  // URL 缓存
  final Map<String, String> _urlCache = {};

  /// 批量解析 short_url
  /// 返回解析后的 Upload 对象列表
  Future<List<Map<String, dynamic>>> lookupUrls(List<String> shortUrls) async {
    // 过滤掉已缓存的
    final missingUrls = shortUrls.where((url) => !_urlCache.containsKey(url)).toList();
    
    // 如果全部命中缓存，直接返回构建的结果（为了简单起见，这里实际上不需要构造完整列表，
    // 因为调用方 resolveShortUrl 只关心单个。为了通用性，批量接口可以留着）
    if (missingUrls.isEmpty) return [];

    try {
      final response = await _dio.post(
        '/uploads/lookup-urls',
        data: {'short_urls': missingUrls},
      );
      
      final List<dynamic> uploads = response.data;
      final result = <Map<String, dynamic>>[];

      for (final item in uploads) {
        if (item is Map<String, dynamic>) {
          result.add(item);
          // 更新缓存
          if (item['short_url'] != null && item['url'] != null) {
            _urlCache[item['short_url']] = item['url'];
          }
        }
      }
      return result;
    } catch (e) {
      print('[DiscourseService] lookupUrls failed: $e');
      return [];
    }
  }

  /// 解析单个 short_url
  /// 如果缓存中有则直接返回，否则发起请求
  Future<String?> resolveShortUrl(String shortUrl) async {
    if (!shortUrl.startsWith('upload://')) return shortUrl;

    if (_urlCache.containsKey(shortUrl)) {
      return _urlCache[shortUrl];
    }

    await lookupUrls([shortUrl]);
    return _urlCache[shortUrl];
  }

  /// 获取话题 AI 摘要
  /// [topicId] 话题 ID
  /// [skipAgeCheck] 是否跳过缓存时间检查（强制获取最新摘要）
  /// 返回 TopicSummary 或 null（如果不支持摘要功能）
  Future<TopicSummary?> getTopicSummary(int topicId, {bool skipAgeCheck = false}) async {
    try {
      final queryParams = <String, dynamic>{};
      if (skipAgeCheck) {
        queryParams['skip_age_check'] = 'true';
      }

      final response = await _dio.get(
        '/discourse-ai/summarization/t/$topicId',
        queryParameters: queryParams.isNotEmpty ? queryParams : null,
      );

      // API 响应数据被包装在 ai_topic_summary 键下
      final data = response.data;
      if (data is Map && data['ai_topic_summary'] != null) {
        return TopicSummary.fromJson(data['ai_topic_summary'] as Map<String, dynamic>);
      }
      return null;
    } on DioException catch (e) {
      // 404 表示该话题不支持摘要或摘要功能未启用
      if (e.response?.statusCode == 404) {
        return null;
      }
      // 403 表示没有权限查看摘要
      if (e.response?.statusCode == 403) {
        return null;
      }
      print('[DiscourseService] getTopicSummary failed: $e');
      rethrow;
    }
  }

  /// 创建私信
  /// [targetUsernames] 收件人用户名列表
  /// [title] 私信标题
  /// [raw] 私信内容（Markdown）
  /// 返回创建的话题 ID
  Future<int> createPrivateMessage({
    required List<String> targetUsernames,
    required String title,
    required String raw,
  }) async {
    try {
      final data = <String, dynamic>{
        'title': title,
        'raw': raw,
        'archetype': 'private_message',
        'target_recipients': targetUsernames.join(','),
      };

      final response = await _dio.post(
        '/posts.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;

      // 情况1: 标准创建响应
      if (respData is Map && respData.containsKey('post') && respData['post']['topic_id'] != null) {
        return respData['post']['topic_id'] as int;
      }

      // 情况2: 直接返回 post 对象
      if (respData is Map && respData['topic_id'] != null) {
        return respData['topic_id'] as int;
      }

      // 情况3: 明确失败
      if (respData is Map && respData['success'] == false) {
        throw Exception(respData['errors']?.toString() ?? '发送私信失败');
      }

      throw Exception('未知响应格式');
    } on DioException catch (e) {
      if (e.response?.data != null && e.response!.data is Map) {
        final data = e.response!.data as Map;
        if (data['errors'] != null) {
          throw Exception((data['errors'] as List).join('\n'));
        }
      }
      rethrow;
    }
  }

  /// 关注用户 (discourse-follow 插件)
  /// 返回 true 表示成功
  Future<bool> followUser(String username) async {
    try {
      await _dio.put('/follow/$username');
      return true;
    } catch (e) {
      print('[DiscourseService] followUser failed: $e');
      return false;
    }
  }

  /// 取消关注用户 (discourse-follow 插件)
  /// 返回 true 表示成功
  Future<bool> unfollowUser(String username) async {
    try {
      await _dio.delete('/follow/$username');
      return true;
    } catch (e) {
      print('[DiscourseService] unfollowUser failed: $e');
      return false;
    }
  }

  /// 添加帖子书签
  /// [postId] 帖子 ID
  /// [name] 书签名称（可选）
  /// [reminderAt] 提醒时间（可选）
  /// 返回书签 ID，失败返回 null
  Future<int?> bookmarkPost(int postId, {String? name, DateTime? reminderAt}) async {
    try {
      final data = <String, dynamic>{
        'bookmarkable_id': postId,
        'bookmarkable_type': 'Post',
      };
      if (name != null && name.isNotEmpty) {
        data['name'] = name;
      }
      if (reminderAt != null) {
        data['reminder_at'] = reminderAt.toUtc().toIso8601String();
      }

      final response = await _dio.post(
        '/bookmarks.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;
      if (respData is Map && respData['id'] != null) {
        return respData['id'] as int;
      }
      return null;
    } catch (e) {
      print('[DiscourseService] bookmarkPost failed: $e');
      return null;
    }
  }

  /// 删除书签
  /// [bookmarkId] 书签 ID
  /// 返回 true 表示成功
  Future<bool> deleteBookmark(int bookmarkId) async {
    try {
      await _dio.delete('/bookmarks/$bookmarkId.json');
      return true;
    } catch (e) {
      print('[DiscourseService] deleteBookmark failed: $e');
      return false;
    }
  }

  /// 举报帖子
  /// [postId] 帖子 ID
  /// [flagTypeId] 举报类型 ID (3=离题, 4=不当内容, 7=通知版主, 8=垃圾信息)
  /// [message] 举报说明（可选，通知版主时建议填写）
  /// 返回 true 表示成功
  Future<bool> flagPost(int postId, int flagTypeId, {String? message}) async {
    try {
      final data = <String, dynamic>{
        'id': postId,
        'post_action_type_id': flagTypeId,
      };
      if (message != null && message.isNotEmpty) {
        data['message'] = message;
      }

      await _dio.post(
        '/post_actions',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return true;
    } catch (e) {
      print('[DiscourseService] flagPost failed: $e');
      return false;
    }
  }

  /// 获取可用的举报类型
  Future<List<FlagType>> getFlagTypes() async {
    try {
      final response = await _dio.get('/post_action_types.json');
      final data = response.data;
      if (data is Map && data['post_action_types'] != null) {
        return (data['post_action_types'] as List)
            .map((e) => FlagType.fromJson(e as Map<String, dynamic>))
            .where((f) => f.isFlag)
            .toList();
      }
      // 返回默认的举报类型
      return FlagType.defaultTypes;
    } catch (e) {
      print('[DiscourseService] getFlagTypes failed: $e');
      return FlagType.defaultTypes;
    }
  }

  /// 投票
  Future<Poll?> votePoll({
    required int postId,
    required String pollName,
    required List<String> options,
  }) async {
    try {
      final data = {
        'post_id': postId,
        'poll_name': pollName,
      };

      // 添加 options[] 数组参数
      for (int i = 0; i < options.length; i++) {
        data['options[]'] = options[i];
      }

      final response = await _dio.put(
        '/polls/vote',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      if (response.data is Map && response.data['poll'] != null) {
        return Poll.fromJson(response.data['poll'] as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('[DiscourseService] votePoll failed: $e');
      rethrow;
    }
  }

  /// 撤销投票
  Future<Poll?> removeVote({
    required int postId,
    required String pollName,
  }) async {
    try {
      final response = await _dio.delete(
        '/polls/vote',
        data: {
          'post_id': postId,
          'poll_name': pollName,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      if (response.data is Map && response.data['poll'] != null) {
        return Poll.fromJson(response.data['poll'] as Map<String, dynamic>);
      }
      return null;
    } catch (e) {
      print('[DiscourseService] removeVote failed: $e');
      rethrow;
    }
  }

  /// 话题投票
  /// [topicId] 话题 ID
  /// 返回投票响应数据
  Future<VoteResponse> voteTopicVote(int topicId) async {
    try {
      final response = await _dio.post(
        '/voting/vote',
        data: {'topic_id': topicId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return VoteResponse.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      print('[DiscourseService] voteTopicVote failed: $e');
      rethrow;
    }
  }

  /// 取消话题投票
  /// [topicId] 话题 ID
  /// 返回投票响应数据
  Future<VoteResponse> unvoteTopicVote(int topicId) async {
    try {
      final response = await _dio.post(
        '/voting/unvote',
        data: {'topic_id': topicId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return VoteResponse.fromJson(response.data as Map<String, dynamic>);
    } catch (e) {
      print('[DiscourseService] unvoteTopicVote failed: $e');
      rethrow;
    }
  }

  /// 获取话题投票用户列表
  /// [topicId] 话题 ID
  /// 返回投票用户列表
  Future<List<VotedUser>> getTopicVoteWho(int topicId) async {
    try {
      final response = await _dio.get(
        '/voting/who',
        queryParameters: {'topic_id': topicId},
      );
      if (response.data is List) {
        return (response.data as List)
            .map((e) => VotedUser.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return [];
    } catch (e) {
      print('[DiscourseService] getTopicVoteWho failed: $e');
      return [];
    }
  }

  /// 更新话题元数据（标题、分类、标签）
  /// [topicId] 话题 ID
  /// [title] 新标题（可选）
  /// [categoryId] 新分类 ID（可选）
  /// [tags] 新标签列表（可选）
  Future<void> updateTopic({
    required int topicId,
    String? title,
    int? categoryId,
    List<String>? tags,
  }) async {
    final data = <String, dynamic>{};
    if (title != null) data['title'] = title;
    if (categoryId != null) data['category_id'] = categoryId;
    if (tags != null) data['tags[]'] = tags;

    await _dio.put(
      '/t/-/$topicId.json',
      data: data,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
  }

  /// 获取帖子原始内容（Markdown）
  /// [postId] 帖子 ID
  /// 返回帖子的 raw 内容
  Future<String?> getPostRaw(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId.json');
      final data = response.data as Map<String, dynamic>?;
      return data?['raw'] as String?;
    } catch (e) {
      print('[DiscourseService] getPostRaw failed: $e');
      return null;
    }
  }

  /// 更新帖子内容
  /// [postId] 帖子 ID
  /// [raw] 新的 Markdown 内容
  /// [editReason] 编辑理由（可选）
  /// 返回更新后的 Post 对象，失败返回 null
  Future<Post?> updatePost({
    required int postId,
    required String raw,
    String? editReason,
  }) async {
    try {
      final data = <String, dynamic>{
        'post[raw]': raw,
      };
      if (editReason != null && editReason.isNotEmpty) {
        data['post[edit_reason]'] = editReason;
      }

      final response = await _dio.put(
        '/posts/$postId.json',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

      final respData = response.data;
      if (respData is Map && respData['post'] != null) {
        return Post.fromJson(respData['post'] as Map<String, dynamic>);
      }
      return null;
    } on DioException catch (e) {
      if (e.response?.data != null && e.response!.data is Map) {
        final data = e.response!.data as Map;
        if (data['errors'] != null) {
          throw Exception((data['errors'] as List).join('\n'));
        }
      }
      rethrow;
    }
  }

  /// 追踪链接点击
  ///
  /// 向服务器报告链接点击，用于统计分析。
  /// 使用 fire-and-forget 模式，不等待响应。
  ///
  /// [url] 被点击的链接 URL
  /// [postId] 包含该链接的帖子 ID
  /// [topicId] 包含该链接的话题 ID
  void trackClick({
    required String url,
    required int postId,
    required int topicId,
  }) {
    // 使用 fire-and-forget 模式，不阻塞用户操作
    _dio.post(
      '/clicks/track',
      data: {
        'url': url,
        'post_id': postId,
        'topic_id': topicId,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    ).catchError((e) {
      // 静默处理错误，追踪失败不影响用户体验
      debugPrint('[DiscourseService] trackClick failed: $e');
      return Response(requestOptions: RequestOptions());
    });
  }

  /// 接受答案（标记帖子为问题的解决方案）
  ///
  /// [postId] 帖子 ID
  /// 返回接受答案的信息，失败返回 null
  Future<Map<String, dynamic>?> acceptAnswer(int postId) async {
    try {
      final response = await _dio.post(
        '/solution/accept',
        data: {'id': postId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return response.data as Map<String, dynamic>?;
    } catch (e) {
      print('[DiscourseService] acceptAnswer failed: $e');
      return null;
    }
  }

  /// 取消接受答案
  ///
  /// [postId] 帖子 ID
  /// 返回 true 表示成功
  Future<bool> unacceptAnswer(int postId) async {
    try {
      await _dio.post(
        '/solution/unaccept',
        data: {'id': postId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return true;
    } catch (e) {
      print('[DiscourseService] unacceptAnswer failed: $e');
      return false;
    }
  }

  /// 删除帖子
  ///
  /// [postId] 帖子 ID
  /// 返回 true 表示成功
  Future<bool> deletePost(int postId) async {
    try {
      await _dio.delete('/posts/$postId.json');
      return true;
    } catch (e) {
      print('[DiscourseService] deletePost failed: $e');
      return false;
    }
  }

  /// 恢复已删除的帖子
  ///
  /// [postId] 帖子 ID
  /// 返回 true 表示成功
  Future<bool> recoverPost(int postId) async {
    try {
      await _dio.put('/posts/$postId/recover.json');
      return true;
    } catch (e) {
      print('[DiscourseService] recoverPost failed: $e');
      return false;
    }
  }
}
