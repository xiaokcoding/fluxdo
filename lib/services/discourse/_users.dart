part of 'discourse_service.dart';

/// 用户相关
mixin _UsersMixin on _DiscourseServiceBase {
  /// 获取缓存的用户名
  Future<String?> getUsername() async {
    if (_username != null && _username!.isNotEmpty) return _username;

    _username = await _storage.read(key: DiscourseService._usernameKey);
    if (_username != null && _username!.isNotEmpty) return _username;

    try {
      final preloaded = PreloadedDataService();
      final currentUser = await preloaded.getCurrentUser();
      if (currentUser != null && currentUser['username'] != null) {
        _username = currentUser['username'] as String;
        await _storage.write(key: DiscourseService._usernameKey, value: _username!);
        return _username;
      }
    } catch (e) {
      debugPrint('[DIO] Failed to get username from preloaded: $e');
    }

    return null;
  }

  /// 获取用户信息
  Future<User> getUser(String username) async {
    final response = await _dio.get('/u/$username.json');
    final data = response.data as Map<String, dynamic>;
    return User.fromJson(data['user'] ?? data);
  }

  /// 从预加载数据获取当前用户
  Future<User?> getPreloadedCurrentUser() async {
    try {
      final preloaded = PreloadedDataService();
      final currentUserData = await preloaded.getCurrentUser();
      if (currentUserData != null) {
        final user = User.fromJson(currentUserData);
        currentUserNotifier.value = user;
        if (user.username.isNotEmpty) {
          _username = user.username;
          await _storage.write(key: DiscourseService._usernameKey, value: _username!);
        }
        return user;
      }
    } catch (e) {
      debugPrint('[DiscourseService] getPreloadedCurrentUser failed: $e');
    }
    return null;
  }

  /// 获取当前用户信息
  Future<User?> getCurrentUser() async {
    final username = await getUsername();
    if (username == null) return null;

    try {
      final user = await getUser(username);
      currentUserNotifier.value = user;
      return user;
    } catch (e) {
      debugPrint('[DiscourseService] getCurrentUser failed: $e');
      return null;
    }
  }

  /// 获取用户统计数据（带缓存）
  Future<UserSummary> getUserSummary(String username, {bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _cachedUserSummary != null &&
        _userSummaryCacheTime != null &&
        DateTime.now().difference(_userSummaryCacheTime!) < DiscourseService._summaryCacheDuration) {
      return _cachedUserSummary!;
    }

    final response = await _dio.get('/users/$username/summary.json');
    final summary = UserSummary.fromJson(response.data);

    _cachedUserSummary = summary;
    _userSummaryCacheTime = DateTime.now();

    return summary;
  }

  /// 预加载用户统计数据
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

  /// 获取用户动态
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

  /// 获取用户回应列表
  Future<UserReactionsResponse> getUserReactions(String username, {int? beforeReactionUserId}) async {
    final queryParams = <String, dynamic>{
      'username': username,
    };
    if (beforeReactionUserId != null) {
      queryParams['before_reaction_user_id'] = beforeReactionUserId;
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

  /// 关注用户
  Future<void> followUser(String username) async {
    try {
      await _dio.put('/follow/$username');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消关注用户
  Future<void> unfollowUser(String username) async {
    try {
      await _dio.delete('/follow/$username');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取用户浏览历史
  Future<TopicListResponse> getBrowsingHistory({int page = 0}) async {
    final response = await _dio.get(
      '/read.json',
      queryParameters: page > 0 ? {'page': page} : null,
    );
    return TopicListResponse.fromJson(response.data);
  }

  /// 获取用户个人书签
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

  /// 获取用户创建的话题
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

  /// 获取用户徽章列表
  Future<BadgeDetailResponse> getUserBadges({required String username}) async {
    final response = await _dio.get(
      '/user-badges/${username.toLowerCase()}.json',
      queryParameters: {'grouped': 'true'},
    );
    return BadgeDetailResponse.fromJson(response.data);
  }

  /// 获取徽章信息
  Future<Badge> getBadge({required int badgeId}) async {
    final response = await _dio.get('/badges/$badgeId.json');
    final badgeData = response.data['badge'] as Map<String, dynamic>;
    return Badge.fromJson(badgeData);
  }

  /// 获取徽章的所有获得者
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
}
