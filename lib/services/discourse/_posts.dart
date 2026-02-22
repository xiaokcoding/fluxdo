part of 'discourse_service.dart';

/// 帖子相关
mixin _PostsMixin on _DiscourseServiceBase {
  /// 创建回复
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

      if (respData is Map && respData.containsKey('post') && respData['post'] != null) {
        return Post.fromJson(respData['post'] as Map<String, dynamic>);
      }

      if (respData is Map && respData['id'] != null) {
        return Post.fromJson(respData as Map<String, dynamic>);
      }

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

  /// 点赞帖子
  Future<void> likePost(int postId) async {
    try {
      await _dio.post(
        '/post_actions',
        data: {'id': postId, 'post_action_type_id': 2},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消点赞
  Future<void> unlikePost(int postId) async {
    try {
      await _dio.delete(
        '/post_actions/$postId',
        queryParameters: {'post_action_type_id': 2},
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 切换回应
  Future<Map<String, dynamic>> toggleReaction(int postId, String reaction) async {
    try {
      final response = await _dio.put(
        '/discourse-reactions/posts/$postId/custom-reactions/$reaction/toggle.json',
      );
      final data = response.data as Map<String, dynamic>;
      return {
        'reactions': (data['reactions'] as List?)
            ?.map((e) => PostReaction.fromJson(e as Map<String, dynamic>))
            .toList() ?? [],
        'currentUserReaction': data['current_user_reaction'] != null
            ? PostReaction.fromJson(data['current_user_reaction'] as Map<String, dynamic>)
            : null,
      };
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取帖子的回复历史
  Future<List<Post>> getPostReplyHistory(int postId) async {
    final response = await _dio.get('/posts/$postId/reply-history');
    final data = response.data as List<dynamic>;
    return data.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 获取帖子的回复列表
  Future<List<Post>> getPostReplies(int postId, {int after = 1}) async {
    final response = await _dio.get(
      '/posts/$postId/replies',
      queryParameters: {'after': after},
    );
    final data = response.data as List<dynamic>;
    return data.map((e) => Post.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// 获取单个帖子完整数据（用于 MessageBus 刷新）
  Future<Post> getPost(int postId) async {
    final response = await _dio.get('/posts/$postId.json');
    final data = response.data as Map<String, dynamic>;
    return Post.fromJson(data);
  }

  /// 获取帖子原始内容
  Future<String?> getPostRaw(int postId) async {
    try {
      final response = await _dio.get('/posts/$postId.json');
      final data = response.data as Map<String, dynamic>?;
      return data?['raw'] as String?;
    } catch (e) {
      debugPrint('[DiscourseService] getPostRaw failed: $e');
      return null;
    }
  }

  /// 更新帖子内容
  Future<Post> updatePost({
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
      throw Exception('更新帖子失败：响应格式异常');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 添加话题书签
  Future<int> bookmarkTopic(int topicId, {String? name, DateTime? reminderAt}) async {
    try {
      final data = <String, dynamic>{
        'bookmarkable_id': topicId,
        'bookmarkable_type': 'Topic',
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
      throw Exception('添加书签失败：响应格式异常');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 添加帖子书签
  Future<int> bookmarkPost(int postId, {String? name, DateTime? reminderAt}) async {
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
      throw Exception('添加书签失败：响应格式异常');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 删除书签
  Future<void> deleteBookmark(int bookmarkId) async {
    try {
      await _dio.delete('/bookmarks/$bookmarkId.json');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 举报帖子
  Future<void> flagPost(int postId, int flagTypeId, {String? message}) async {
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
    } on DioException catch (e) {
      _throwApiError(e);
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
      return FlagType.defaultTypes;
    } catch (e) {
      debugPrint('[DiscourseService] getFlagTypes failed: $e');
      return FlagType.defaultTypes;
    }
  }

  /// 接受答案
  Future<Map<String, dynamic>> acceptAnswer(int postId) async {
    try {
      final response = await _dio.post(
        '/solution/accept',
        data: {'id': postId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      return response.data as Map<String, dynamic>;
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 取消接受答案
  Future<void> unacceptAnswer(int postId) async {
    try {
      await _dio.post(
        '/solution/unaccept',
        data: {'id': postId},
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 删除帖子
  Future<void> deletePost(int postId) async {
    try {
      await _dio.delete('/posts/$postId.json');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 恢复已删除的帖子
  Future<void> recoverPost(int postId) async {
    try {
      await _dio.put('/posts/$postId/recover.json');
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取帖子回应人列表
  Future<List<ReactionUsersGroup>> getReactionUsers(int postId) async {
    final response = await _dio.get(
      '/discourse-reactions/posts/$postId/reactions-users.json',
    );
    final data = response.data as Map<String, dynamic>;
    final list = data['reaction_users'] as List? ?? [];
    return list
        .map((e) => ReactionUsersGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 追踪链接点击
  void trackClick({
    required String url,
    required int postId,
    required int topicId,
  }) {
    _dio.post(
      '/clicks/track',
      data: {
        'url': url,
        'post_id': postId,
        'topic_id': topicId,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    ).catchError((e) {
      debugPrint('[DiscourseService] trackClick failed: $e');
      return Response(requestOptions: RequestOptions());
    });
  }
}
