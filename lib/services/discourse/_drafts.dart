part of 'discourse_service.dart';

/// 草稿相关 API
mixin _DraftsMixin on _DiscourseServiceBase {
  /// 获取草稿列表
  Future<DraftListResponse> getDrafts({int offset = 0, int limit = 20}) async {
    try {
      final response = await _dio.get(
        '/drafts.json',
        queryParameters: {
          'offset': offset,
          'limit': limit,
        },
      );
      return DraftListResponse.fromJson(response.data as Map<String, dynamic>);
    } on DioException catch (e) {
      _throwApiError(e);
    }
  }

  /// 获取指定草稿
  /// 返回 null 表示草稿不存在
  Future<Draft?> getDraft(String draftKey) async {
    try {
      final response = await _dio.get('/drafts/$draftKey.json');
      final data = response.data;
      if (data is Map<String, dynamic> && data.containsKey('draft')) {
        final draftData = data['draft'];
        if (draftData == null) return null;
        return Draft.fromJson({
          'draft_key': draftKey,
          'data': draftData,
          'draft_sequence': data['draft_sequence'] as int? ?? 0,
        });
      }
      return null;
    } on DioException catch (e) {
      // 404 表示草稿不存在
      if (e.response?.statusCode == 404) return null;
      _throwApiError(e);
    }
  }

  /// 保存草稿
  /// 返回新的序列号
  Future<int> saveDraft({
    required String draftKey,
    required DraftData data,
    int sequence = 0,
  }) async {
    try {
      final response = await _dio.post(
        '/drafts.json',
        data: {
          'draft_key': draftKey,
          'data': data.toJsonString(),
          'sequence': sequence,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final respData = response.data;
      if (respData is Map) {
        return respData['draft_sequence'] as int? ?? (sequence + 1);
      }
      return sequence + 1;
    } on DioException catch (e) {
      // 409 Conflict 表示序列号冲突，服务器返回最新序列号
      if (e.response?.statusCode == 409) {
        final respData = e.response?.data;
        if (respData is Map && respData['draft_sequence'] != null) {
          return respData['draft_sequence'] as int;
        }
      }
      _throwApiError(e);
    }
  }

  /// 删除草稿
  Future<void> deleteDraft(String draftKey, {int sequence = 0}) async {
    try {
      await _dio.delete(
        '/drafts/$draftKey.json',
        queryParameters: {'sequence': sequence},
      );
    } on DioException catch (e) {
      // 忽略 404（草稿已不存在）
      if (e.response?.statusCode == 404) return;
      _throwApiError(e);
    }
  }
}
