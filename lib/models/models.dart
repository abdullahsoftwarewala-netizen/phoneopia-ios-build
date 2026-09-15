import '../config/app_config.dart';
import '../utils/server_time.dart';

/// Detect Phoneopia AI bot from user fields, avatar path, or display name.
bool isPhoneopiaBot({
  User? user,
  String? username,
  String? avatar,
  String? name,
}) {
  if (user?.isAiBot == true) return true;
  if (username == 'phoneopia_ai') return true;
  if (user?.username == 'phoneopia_ai') return true;
  final av = avatar ?? user?.avatar ?? '';
  if (av.contains('bot-avatar')) return true;
  final n = (name ?? user?.displayName ?? '').toLowerCase();
  if (n.contains('phoneopia ai') || n == 'ai') return true;
  return false;
}

class User {
  final int id;
  final String username;
  final String displayName;
  final String? phone;
  final String? avatar;
  final String? statusMessage;
  final String status; // online, away, busy, offline
  final bool isOnline;
  final DateTime? lastSeen;
  final bool isAiBot;
  final bool isVerified;
  final bool noVoiceCall;
  final bool noVideoCall;
  final bool noVoiceNote;
  final String privacyLastSeen;
  final String privacyProfilePhoto;
  final bool notificationsEnabled;
  final bool isTest; // Google-review test account → skip mandatory Drive gate
  // Lightweight placeholder contact synced in from a WhatsApp number with no
  // Phoneopia account — can never log in; outgoing messages to them route
  // out over WhatsApp instead of the normal in-app path.
  final bool isWhatsappShadow;

  const User({
    required this.id,
    required this.username,
    required this.displayName,
    this.phone,
    this.avatar,
    this.statusMessage,
    this.status = 'offline',
    this.isOnline = false,
    this.lastSeen,
    this.isAiBot = false,
    this.isVerified = false,
    this.noVoiceCall = false,
    this.noVideoCall = false,
    this.noVoiceNote = false,
    this.privacyLastSeen = 'everyone',
    this.privacyProfilePhoto = 'everyone',
    this.notificationsEnabled = true,
    this.isTest = false,
    this.isWhatsappShadow = false,
  });

  static String privacyLabel(String value) => switch (value) {
    'contacts' => 'My contacts',
    'nobody' => 'Nobody',
    _ => 'Everyone',
  };

  static String? _normAvatar(dynamic v) {
    final s = v?.toString().trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('http') || s.startsWith('data:')) return s;
    return '${AppConfig.mediaBase}${s.startsWith('/') ? '' : '/'}$s';
  }

  factory User.fromJson(Map<String, dynamic> j) {
    final online = j['is_online'] == 1 || j['is_online'] == true || j['status'] == 'online';
    return User(
      id: int.tryParse(j['id'].toString()) ?? 0,
      username: j['username'] ?? '',
      displayName: j['display_name'] ?? j['username'] ?? '',
      phone: j['phone'],
      avatar: _normAvatar(j['avatar']),
      statusMessage: j['status_message'],
      status: online ? 'online' : (j['status']?.toString() ?? 'offline'),
      isOnline: online,
      lastSeen: parseServerTime(j['last_seen']),
      isAiBot: j['username'] == 'phoneopia_ai',
      isVerified: j['is_verified'] == 1 || j['is_verified'] == true || j['is_verified'] == '1',
      noVoiceCall: j['no_voice_call'] == 1 || j['no_voice_call'] == true || j['no_voice_call'] == '1',
      noVideoCall: j['no_video_call'] == 1 || j['no_video_call'] == true || j['no_video_call'] == '1',
      noVoiceNote: j['no_voice_note'] == 1 || j['no_voice_note'] == true || j['no_voice_note'] == '1',
      privacyLastSeen: j['privacy_last_seen']?.toString() ?? 'everyone',
      privacyProfilePhoto: j['privacy_profile_photo']?.toString() ?? 'everyone',
      notificationsEnabled: j['notifications_enabled'] == 1 || j['notifications_enabled'] == true,
      isTest: j['is_test'] == 1 || j['is_test'] == true || j['is_test'] == '1',
      isWhatsappShadow: j['is_whatsapp_shadow'] == 1 || j['is_whatsapp_shadow'] == true || j['is_whatsapp_shadow'] == '1',
    );
  }

  User copyWith({
    bool? isOnline,
    String? status,
    DateTime? lastSeen,
    String? statusMessage,
    String? avatar,
    String? displayName,
    String? privacyLastSeen,
    String? privacyProfilePhoto,
    bool? notificationsEnabled,
  }) => User(
    id: id,
    username: username,
    displayName: displayName ?? this.displayName,
    phone: phone,
    avatar: avatar ?? this.avatar,
    statusMessage: statusMessage ?? this.statusMessage,
    status: status ?? this.status,
    isOnline: isOnline ?? this.isOnline,
    lastSeen: lastSeen ?? this.lastSeen,
    isAiBot: isAiBot,
    isVerified: isVerified,
    noVoiceCall: noVoiceCall,
    noVideoCall: noVideoCall,
    noVoiceNote: noVoiceNote,
    privacyLastSeen: privacyLastSeen ?? this.privacyLastSeen,
    privacyProfilePhoto: privacyProfilePhoto ?? this.privacyProfilePhoto,
    notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
    isTest: isTest,
    isWhatsappShadow: isWhatsappShadow,
  );

  String get initials {
    final parts = displayName.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    if (displayName.isNotEmpty) return displayName[0].toUpperCase();
    return '?';
  }
}

class Message {
  final int id;
  final int conversationId;
  final int senderId;
  final String type; // text, image, audio, video, file, voice
  final String? content;
  final String? fileUrl;
  final String? fileName;
  final String? senderName;
  final String? senderAvatar;
  final String? senderUsername;
  final DateTime createdAt;
  final String status; // sending, sent, delivered, read
  final int? replyToId;
  final bool isDeleted;
  final bool isStarred;
  final Map<String, dynamic> reactions;
  final int? duration; // voice/audio length in seconds
  final String? localPath; // local file of an outgoing image/file while it uploads (preview)

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.type,
    this.content,
    this.fileUrl,
    this.fileName,
    this.senderName,
    this.senderAvatar,
    this.senderUsername,
    required this.createdAt,
    this.status = 'sent',
    this.replyToId,
    this.isDeleted = false,
    this.isStarred = false,
    this.reactions = const {},
    this.duration,
    this.localPath,
  });

  // Server returns relative paths like /uploads/... — Image.network needs full URLs
  static String? _absUrl(dynamic v) {
    final s = v?.toString();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('http') || s.startsWith('data:')) return s;
    return '${AppConfig.mediaBase}${s.startsWith('/') ? '' : '/'}$s';
  }

  factory Message.fromJson(Map<String, dynamic> j) => Message(
    id: int.tryParse(j['id'].toString()) ?? 0,
    conversationId: int.tryParse(j['conversation_id'].toString()) ?? 0,
    senderId: int.tryParse(j['sender_id'].toString()) ?? 0,
    type: j['type'] ?? 'text',
    content: j['content'],
    fileUrl: _absUrl(j['file_path'] ?? j['file_url']),
    fileName: j['file_name'],
    localPath: j['local_path'],
    senderName: j['sender_name'] ?? j['display_name'],
    senderAvatar: _absUrl(j['sender_avatar']),
    senderUsername: j['sender_username'],
    createdAt: parseServerTime(j['created_at']) ?? DateTime.now(),
    status: j['status'] ?? 'sent',
    replyToId: j['reply_to_id'] != null ? int.tryParse(j['reply_to_id'].toString()) : null,
    isDeleted: (j['is_deleted_for_all'] ?? j['is_deleted']) == 1 || (j['is_deleted_for_all'] ?? j['is_deleted']) == true,
    isStarred: j['is_starred'] == 1 || j['is_starred'] == true,
    reactions: j['reactions_parsed'] is Map ? Map<String, dynamic>.from(j['reactions_parsed']) : {},
    duration: j['duration'] != null ? int.tryParse(j['duration'].toString()) : null,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversation_id': conversationId,
    'sender_id': senderId,
    'type': type,
    'content': content,
    'file_path': fileUrl,
    'file_name': fileName,
    'local_path': localPath,
    'sender_name': senderName,
    'sender_avatar': senderAvatar,
    'sender_username': senderUsername,
    'created_at': createdAt.toIso8601String(),
    'status': status,
    'reply_to_id': replyToId,
    'is_deleted': isDeleted,
    'is_starred': isStarred,
    'reactions_parsed': reactions,
    'duration': duration,
  };

  bool get isImage {
    if (type == 'image') return true;
    if (type != 'file') return false;
    final n = (fileName ?? fileUrl ?? '').toLowerCase();
    return RegExp(r'\.(jpe?g|png|gif|webp|heic|bmp)$').hasMatch(n);
  }
  bool get isAudio => type == 'audio' || type == 'voice';
  bool get isFile  => type == 'file';
  bool get isVideo => type == 'video';
  bool get isText  => type == 'text';

  Message copyWith({String? status, bool? isDeleted, String? content}) => Message(
    id: id, conversationId: conversationId, senderId: senderId,
    type: type, content: content ?? this.content, fileUrl: fileUrl, fileName: fileName,
    senderName: senderName, senderAvatar: senderAvatar, senderUsername: senderUsername,
    createdAt: createdAt, status: status ?? this.status,
    replyToId: replyToId, isDeleted: isDeleted ?? this.isDeleted, isStarred: isStarred, reactions: reactions,
    duration: duration, localPath: localPath,
  );
}

class GroupMember {
  final int id;
  final String displayName;
  final String? username;
  final String? avatar;
  final String role; // admin | member
  final bool isOnline;
  final String status; // active | removed | left
  const GroupMember({required this.id, required this.displayName, this.username, this.avatar, this.role = 'member', this.isOnline = false, this.status = 'active'});
  bool get isAdmin => role == 'admin';
  factory GroupMember.fromJson(Map<String, dynamic> j) => GroupMember(
        id: int.tryParse(j['id'].toString()) ?? 0,
        displayName: j['display_name']?.toString() ?? 'User',
        username: j['username']?.toString(),
        avatar: j['avatar']?.toString(),
        role: j['role']?.toString() ?? 'member',
        isOnline: j['is_online'] == 1 || j['is_online'] == true,
        status: j['status']?.toString() ?? 'active',
      );
}

class Conversation {
  final int id;
  final String type; // direct, group
  final String name;
  final String? description;
  final String? avatar;
  final User? otherUser;
  final List<GroupMember> members;
  final List<GroupMember> pastMembers;
  final String myRole;
  final int createdBy;
  final String? lastMessageContent;
  final String? lastMessageType;
  final int? lastMessageSender;
  final DateTime? lastMessageAt;
  final int unreadCount;
  final bool isPinned;
  final bool isMuted;
  final int memberCount;

  const Conversation({
    required this.id,
    required this.type,
    required this.name,
    this.description,
    this.avatar,
    this.otherUser,
    this.members = const [],
    this.pastMembers = const [],
    this.myRole = 'member',
    this.createdBy = 0,
    this.lastMessageContent,
    this.lastMessageType,
    this.lastMessageSender,
    this.lastMessageAt,
    this.unreadCount = 0,
    this.isPinned = false,
    this.isMuted = false,
    this.memberCount = 0,
  });

  factory Conversation.fromJson(Map<String, dynamic> j) {
    User? ou;
    if (j['other_user'] is Map) ou = User.fromJson(Map<String, dynamic>.from(j['other_user']));
    List<GroupMember> mem = const [];
    if (j['members'] is List) mem = (j['members'] as List).map((m) => GroupMember.fromJson(Map<String, dynamic>.from(m))).toList();
    List<GroupMember> past = const [];
    if (j['past_members'] is List) past = (j['past_members'] as List).map((m) => GroupMember.fromJson(Map<String, dynamic>.from(m))).toList();
    return Conversation(
      id: int.tryParse(j['id'].toString()) ?? 0,
      type: j['type'] ?? 'direct',
      name: j['name'] ?? ou?.displayName ?? 'Chat',
      description: j['description']?.toString(),
      avatar: User._normAvatar(j['avatar'] ?? ou?.avatar),
      otherUser: ou,
      members: mem,
      pastMembers: past,
      myRole: j['my_role']?.toString() ?? 'member',
      createdBy: int.tryParse(j['created_by']?.toString() ?? '0') ?? 0,
      lastMessageContent: j['last_message_content'],
      lastMessageType: j['last_message_type'] ?? 'text',
      lastMessageSender: j['last_message_sender'] != null ? int.tryParse(j['last_message_sender'].toString()) : null,
      lastMessageAt: parseServerTime(j['last_message_at']),
      unreadCount: int.tryParse(j['unread_count']?.toString() ?? '0') ?? 0,
      isPinned: j['is_pinned'] == 1 || j['is_pinned'] == true,
      isMuted: j['is_muted'] == 1 || j['is_muted'] == true,
      memberCount: int.tryParse(j['member_count']?.toString() ?? '0') ?? 0,
    );
  }

  /// [myUserId] — when set, never returns the logged-in user's name for 1:1 chats.
  String displayNameFor({int? myUserId}) {
    if (type == 'group') return name;
    final ou = otherUser;
    if (ou != null && myUserId != null && ou.id > 0 && ou.id != myUserId) {
      if (ou.displayName.trim().isNotEmpty) return ou.displayName;
      if (ou.username.trim().isNotEmpty) return ou.username;
    }
    if (myUserId != null && name.trim().isNotEmpty) {
      // Cached row used sender name by mistake — don't show self as chat title
      if (ou == null || ou.id != myUserId) return name;
    }
    if (ou != null && ou.displayName.trim().isNotEmpty) return ou.displayName;
    return name.isNotEmpty ? name : 'Chat';
  }

  String get displayName => displayNameFor();

  String displayAvatarFor({int? myUserId}) {
    if (type == 'group') return avatar ?? '';
    final ou = otherUser;
    if (ou != null && myUserId != null && ou.id > 0 && ou.id != myUserId) {
      return ou.avatar ?? avatar ?? '';
    }
    return avatar ?? ou?.avatar ?? '';
  }

  String get displayAvatar => displayAvatarFor();
  bool get isAiBot => isPhoneopiaBot(user: otherUser, avatar: displayAvatar, name: displayName);
  bool get isVerified => otherUser?.isVerified == true;
  bool get isGroup => type == 'group';
  bool get amAdmin => myRole == 'admin';
}
