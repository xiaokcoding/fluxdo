import '../utils/url_helper.dart';

/// 用户数据模型
class User {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;
  final String? animatedAvatar; // 动画头像（GIF）
  final int trustLevel;
  final String? bio;
  final String? bioCooked;
  final String? bioRaw;

  // 背景图
  final String? cardBackgroundUploadUrl;
  final String? profileBackgroundUploadUrl;

  // 通知计数字段（从 session/current.json 或 MessageBus 获取）
  final int unreadNotifications;
  final int unreadHighPriorityNotifications;
  final int allUnreadNotificationsCount;
  final int seenNotificationId;
  final int notificationChannelPosition;

  // 用户状态
  final UserStatus? status;

  // 时间信息
  final DateTime? lastPostedAt;
  final DateTime? lastSeenAt;
  final DateTime? createdAt;
  final String? location;
  final String? website;
  final String? websiteName;

  // Flair 徽章
  final String? flairUrl;
  final String? flairName;
  final String? flairBgColor;
  final String? flairColor;
  final int? flairGroupId;

  // 关注相关 (discourse-follow 插件)
  final bool? canFollow;           // 是否可以关注该用户
  final bool? isFollowed;          // 当前用户是否已关注该用户
  final int? totalFollowers;       // 粉丝数
  final int? totalFollowing;       // 关注数

  // 私信相关
  final bool? canSendPrivateMessages;        // 当前用户是否可以发送私信
  final bool? canSendPrivateMessageToUser;   // 是否可以给该用户发私信

  // 积分相关
  final int? gamificationScore;

  User({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
    this.animatedAvatar,
    required this.trustLevel,
    this.bio,
    this.bioCooked,
    this.bioRaw,
    this.cardBackgroundUploadUrl,
    this.profileBackgroundUploadUrl,
    this.unreadNotifications = 0,
    this.unreadHighPriorityNotifications = 0,
    this.allUnreadNotificationsCount = 0,
    this.seenNotificationId = 0,
    this.notificationChannelPosition = -1,
    this.status,
    this.lastPostedAt,
    this.lastSeenAt,
    this.createdAt,
    this.location,
    this.website,
    this.websiteName,
    this.flairUrl,
    this.flairName,
    this.flairBgColor,
    this.flairColor,
    this.flairGroupId,
    this.canFollow,
    this.isFollowed,
    this.totalFollowers,
    this.totalFollowing,
    this.canSendPrivateMessages,
    this.canSendPrivateMessageToUser,
    this.gamificationScore,
  });

  User copyWith({
    int? unreadNotifications,
    int? unreadHighPriorityNotifications,
    int? allUnreadNotificationsCount,
    int? seenNotificationId,
    int? notificationChannelPosition,
  }) {
    return User(
      id: id,
      username: username,
      name: name,
      avatarTemplate: avatarTemplate,
      animatedAvatar: animatedAvatar,
      trustLevel: trustLevel,
      bio: bio,
      bioCooked: bioCooked,
      bioRaw: bioRaw,
      cardBackgroundUploadUrl: cardBackgroundUploadUrl,
      profileBackgroundUploadUrl: profileBackgroundUploadUrl,
      unreadNotifications: unreadNotifications ?? this.unreadNotifications,
      unreadHighPriorityNotifications:
          unreadHighPriorityNotifications ?? this.unreadHighPriorityNotifications,
      allUnreadNotificationsCount:
          allUnreadNotificationsCount ?? this.allUnreadNotificationsCount,
      seenNotificationId: seenNotificationId ?? this.seenNotificationId,
      notificationChannelPosition:
          notificationChannelPosition ?? this.notificationChannelPosition,
      status: status,
      lastPostedAt: lastPostedAt,
      lastSeenAt: lastSeenAt,
      createdAt: createdAt,
      location: location,
      website: website,
      websiteName: websiteName,
      flairUrl: flairUrl,
      flairName: flairName,
      flairBgColor: flairBgColor,
      flairColor: flairColor,
      flairGroupId: flairGroupId,
      canFollow: canFollow,
      isFollowed: isFollowed,
      totalFollowers: totalFollowers,
      totalFollowing: totalFollowing,
      canSendPrivateMessages: canSendPrivateMessages,
      canSendPrivateMessageToUser: canSendPrivateMessageToUser,
      gamificationScore: gamificationScore,
    );
  }

  factory User.fromJson(Map<String, dynamic> json) {
    String? resolve(String? url) => url != null ? UrlHelper.resolveUrl(url) : null;
    
    // 简单的 HTML 图片路径修复
    String? fixHtml(String? html) {
      if (html == null) return null;
      // 替换 src="/... 为 src="https://linux.do/...
      return html.replaceAllMapped(
        RegExp(r'''src=["'](/[^"']+)["']'''), 
        (match) => 'src="${UrlHelper.resolveUrl(match.group(1)!)}"'
      );
    }

    return User(
      id: json['id'] as int? ?? 0,
      username: json['username'] as String? ?? '',
      name: json['name'] as String?,
      avatarTemplate: resolve(json['avatar_template'] as String?),
      animatedAvatar: resolve(json['animated_avatar'] as String?),
      trustLevel: json['trust_level'] as int? ?? 0,
      bio: fixHtml(json['bio_cooked'] as String?) ?? json['bio_excerpt'] as String? ?? json['bio_raw'] as String?,
      bioCooked: fixHtml(json['bio_cooked'] as String?),
      bioRaw: json['bio_raw'] as String?,
      cardBackgroundUploadUrl: resolve(json['card_background_upload_url'] as String?),
      profileBackgroundUploadUrl: resolve(json['profile_background_upload_url'] as String?),
      unreadNotifications: json['unread_notifications'] as int? ?? 0,
      unreadHighPriorityNotifications: json['unread_high_priority_notifications'] as int? ?? 0,
      allUnreadNotificationsCount: json['all_unread_notifications_count'] as int? ?? 0,
      seenNotificationId: json['seen_notification_id'] as int? ?? 0,
      notificationChannelPosition: json['notification_channel_position'] as int? ?? -1,
      status: json['status'] != null ? UserStatus.fromJson(json['status']) : null,
      lastPostedAt: json['last_posted_at'] != null ? DateTime.tryParse(json['last_posted_at']) : null,
      lastSeenAt: json['last_seen_at'] != null ? DateTime.tryParse(json['last_seen_at']) : null,
      createdAt: json['created_at'] != null ? DateTime.tryParse(json['created_at']) : null,
      location: json['location'] as String?,
      website: json['website'] as String?,
      websiteName: json['website_name'] as String?,
      flairUrl: resolve(json['flair_url'] as String?),
      flairName: json['flair_name'] as String?,
      flairBgColor: json['flair_bg_color'] as String?,
      flairColor: json['flair_color'] as String?,
      flairGroupId: json['flair_group_id'] as int?,
      canFollow: json['can_follow'] as bool?,
      isFollowed: json['is_followed'] as bool?,
      totalFollowers: json['total_followers'] as int?,
      totalFollowing: json['total_following'] as int?,
      canSendPrivateMessages: json['can_send_private_messages'] as bool?,
      canSendPrivateMessageToUser: json['can_send_private_message_to_user'] as bool?,
      gamificationScore: json['gamification_score'] as int?,
    );
  }

  /// 获取背景图 URL（优先 profile，其次 card）
  String? get backgroundUrl => profileBackgroundUploadUrl ?? cardBackgroundUploadUrl;

  /// 获取信任等级描述
  String get trustLevelString {
    switch (trustLevel) {
      case 0:
        return 'L0 新用户';
      case 1:
        return 'L1 基本用户';
      case 2:
        return 'L2 成员';
      case 3:
        return 'L3 活跃用户';
      case 4:
        return 'L4 领袖';
      default:
        return '等级 $trustLevel';
    }
  }
  
  /// 获取头像 URL，优先使用动画头像（GIF）
  String getAvatarUrl({int size = 120}) {
    // 优先使用动画头像
    if (animatedAvatar != null && animatedAvatar!.isNotEmpty) {
      if (animatedAvatar!.startsWith('http')) return animatedAvatar!;
      if (animatedAvatar!.startsWith('/')) return 'https://linux.do$animatedAvatar';
      return 'https://linux.do/$animatedAvatar';
    }
    if (avatarTemplate == null) return '';
    final template = avatarTemplate!.replaceAll('{size}', size.toString());
    if (template.startsWith('http')) return template;
    if (template.startsWith('/')) return 'https://linux.do$template';
    return 'https://linux.do/$template';
  }
}

/// 用户状态
class UserStatus {
  final String? description;
  final String? emoji;
  
  UserStatus({this.description, this.emoji});
  
  factory UserStatus.fromJson(Map<String, dynamic> json) {
    return UserStatus(
      description: json['description'] as String?,
      emoji: json['emoji'] as String?,
    );
  }
}

/// 用户统计数据
class UserSummary {
  final int daysVisited;
  final int postsReadCount;
  final int likesReceived;
  final int likesGiven;
  final int topicCount;
  final int postCount;
  final int timeRead; // 秒
  final int bookmarkCount;
  
  UserSummary({
    required this.daysVisited,
    required this.postsReadCount,
    required this.likesReceived,
    required this.likesGiven,
    required this.topicCount,
    required this.postCount,
    required this.timeRead,
    required this.bookmarkCount,
  });
  
  factory UserSummary.fromJson(Map<String, dynamic> json) {
    final summary = json['user_summary'] as Map<String, dynamic>? ?? {};
    return UserSummary(
      daysVisited: summary['days_visited'] as int? ?? 0,
      postsReadCount: summary['posts_read_count'] as int? ?? 0,
      likesReceived: summary['likes_received'] as int? ?? 0,
      likesGiven: summary['likes_given'] as int? ?? 0,
      topicCount: summary['topic_count'] as int? ?? 0,
      postCount: summary['post_count'] as int? ?? 0,
      timeRead: summary['time_read'] as int? ?? 0,
      bookmarkCount: summary['bookmark_count'] as int? ?? 0,
    );
  }
  
  /// 格式化阅读时间
  String get formattedTimeRead {
    final hours = timeRead ~/ 3600;
    if (hours > 0) return '${hours}h';
    final minutes = timeRead ~/ 60;
    return '${minutes}m';
  }
}

/// 当前用户信息（从 /session/current.json 获取）
class CurrentUser {
  final User user;
  final bool isLoggedIn;
  
  CurrentUser({required this.user, required this.isLoggedIn});
  
  factory CurrentUser.fromJson(Map<String, dynamic> json) {
    final currentUser = json['current_user'] as Map<String, dynamic>?;
    if (currentUser == null) {
      throw Exception('Not logged in');
    }
    return CurrentUser(
      user: User.fromJson(currentUser),
      isLoggedIn: true,
    );
  }
}

/// 关注/粉丝用户简化模型
class FollowUser {
  final int id;
  final String username;
  final String? name;
  final String? avatarTemplate;

  FollowUser({
    required this.id,
    required this.username,
    this.name,
    this.avatarTemplate,
  });

  factory FollowUser.fromJson(Map<String, dynamic> json) {
    return FollowUser(
      id: json['id'] as int,
      username: json['username'] as String,
      name: json['name'] as String?,
      avatarTemplate: json['avatar_template'] as String?,
    );
  }

  String getAvatarUrl({int size = 96}) {
    if (avatarTemplate == null) return '';
    final template = avatarTemplate!.replaceAll('{size}', size.toString());
    return template.startsWith('http') ? template : 'https://linux.do$template';
  }
}
