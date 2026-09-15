import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../config/storage_keys.dart';
import '../models/models.dart';

class ApiService {
  static String get baseUrl => AppConfig.apiBase;

  /// connectivity_plus can report a stale/wrong "no connection" on some OEM
  /// ROMs — confirmed live on an OPPO device that had a real, Android-
  /// validated LTE connection while the plugin still said offline, which
  /// silently killed every Nearby call attempt before it even tried (no
  /// internet detected + not yet Nearby-connected = instant "No internet").
  /// Treat the plugin's "offline" as a hint, not gospel: only actually
  /// treat the device as offline once a real, fast request to our own
  /// server also fails to respond.
  static Future<bool> isOffline() async {
    final conn = await Connectivity().checkConnectivity();
    final pluginSaysOffline = conn.isEmpty || conn.every((c) => c == ConnectivityResult.none);
    if (!pluginSaysOffline) return false;
    try {
      final res = await http.get(Uri.parse('$baseUrl/ping.php')).timeout(const Duration(milliseconds: 1200));
      return res.statusCode < 200 || res.statusCode >= 500;
    } catch (_) {
      return true;
    }
  }
  static String? _token;
  static bool transcriptionOn = false;
  static final ValueNotifier<bool> transcriptionNotifier = ValueNotifier<bool>(false);
  static final Map<int, String> transcriptCache = {};

  static void setTranscriptionEnabled(bool on) {
    transcriptionOn = on;
    if (transcriptionNotifier.value != on) transcriptionNotifier.value = on;
    if (!on) transcriptCache.clear();
  }

  static Future<String?> get token async {
    _token ??= (await SharedPreferences.getInstance()).getString('phoneopia_token');
    return _token;
  }

  /// Bypasses the in-memory cache and re-reads the token straight from disk.
  /// Defensive fallback for OEM builds (some OPPO/ColorOS devices) that can
  /// intermittently return a stale/empty SharedPreferences read right after
  /// process start.
  static Future<String?> forceReloadToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    _token = prefs.getString('phoneopia_token');
    return _token;
  }

  static void primeToken(String t) => _token = t;

  static Future<void> setToken(String t) async {
    _token = t;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('phoneopia_token', t);
  }

  static Future<void> clearMessageCachesOnly({int? userId}) async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().toList();
    for (final k in keys) {
      if (userId != null) {
        if (k.startsWith('msg_cache_${userId}_') || k == 'conv_cache_$userId') {
          await prefs.remove(k);
        }
      } else if (k.startsWith('msg_cache_') || k == 'conv_cache' || k.startsWith('conv_cache_')) {
        await prefs.remove(k);
      }
    }
  }

  /// Clears active session only — keeps multi-account list intact.
  static Future<void> clearActiveSession({int? userId}) async {
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    final uid = userId?.toString() ?? prefs.getString('phoneopia_user_id');
    await prefs.remove('phoneopia_token');
    await prefs.remove('phoneopia_user');
    await prefs.remove('phoneopia_user_id');
    await prefs.remove(StorageKeys.appForegroundAt);
    if (uid != null) {
      await clearMessageCachesOnly(userId: int.tryParse(uid));
    }
    await prefs.reload();
  }

  static Future<void> clearToken() async {
    _token = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('phoneopia_token');
    await prefs.remove('phoneopia_user');
    await prefs.remove('phoneopia_user_id');
    await prefs.remove('fcm_token');
    await prefs.remove(StorageKeys.appForegroundAt);
    await clearMessageCachesOnly();
    await prefs.reload();
  }

  static Future<Map<String, String>> _headers({bool auth = true}) async {
    final headers = {'Content-Type': 'application/json'};
    if (auth) {
      final t = await token;
      if (t != null) headers['Authorization'] = 'Bearer $t';
    }
    return headers;
  }

  static Map<String, dynamic> _parseJsonResponse(http.Response res) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return {
      'success': false,
      'error': res.statusCode >= 500
          ? 'Server error (${res.statusCode})'
          : 'Invalid server response',
    };
  }

  static Future<Map<String, dynamic>> post(String endpoint, Map body, {bool auth = true}) async {
    final res = await http.post(
      Uri.parse('$baseUrl/$endpoint'),
      headers: await _headers(auth: auth),
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 12));
    return _parseJsonResponse(res);
  }

  static Future<Map<String, dynamic>> get(String endpoint, {Map<String, String>? params}) async {
    var uri = Uri.parse('$baseUrl/$endpoint');
    // Merge with existing query params — replace() alone would wipe out
    // anything already in the endpoint string (e.g. ?action=list)
    if (params != null) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...params});
    }
    final res = await http.get(uri, headers: await _headers()).timeout(const Duration(seconds: 12));
    return _parseJsonResponse(res);
  }

  static Future<Map<String, dynamic>> getWithToken(
    String authToken,
    String endpoint, {
    Map<String, String>? params,
  }) async {
    var uri = Uri.parse('$baseUrl/$endpoint');
    if (params != null) {
      uri = uri.replace(queryParameters: {...uri.queryParameters, ...params});
    }
    final res = await http.get(uri, headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $authToken',
    });
    return _parseJsonResponse(res);
  }

  // ── Google Drive (compulsory) ─────────────────────────────────
  static Future<Map<String, dynamic>> gdriveStatus() => get('gdrive.php?action=status');
  static Future<Map<String, dynamic>> gdriveConnect() => get('gdrive.php?action=connect&platform=app');
  static Future<Map<String, dynamic>> gdriveDisconnect() => get('gdrive.php?action=disconnect');
  static Future<Map<String, dynamic>> gdriveSync() => get('gdrive.php?action=sync');
  static Future<Map<String, dynamic>> gdriveBackup() => get('gdrive.php?action=backup');
  static Future<Map<String, dynamic>> gdriveRestore() => get('gdrive.php?action=restore');

  // ── Business Tools ────────────────────────────────────────────
  static Future<Map<String, dynamic>> toolsConfig() => get('tools.php?action=config');
  static Future<Map<String, dynamic>> toolsSaveAutoreply(bool enabled, String training) =>
      post('tools.php?action=save_autoreply', {'enabled': enabled, 'training': training});
  static Future<Map<String, dynamic>> toolsSaveTranscription(bool enabled) =>
      post('tools.php?action=save_transcription', {'enabled': enabled});
  static Future<Map<String, dynamic>> toolsTranscribe(int msgId) =>
      post('tools.php?action=transcribe', {'message_id': msgId});
  static Future<Map<String, dynamic>> toolsScamCheck(int msgId) =>
      post('tools.php?action=scam_check', {'message_id': msgId});
  static Future<Map<String, dynamic>> toolsTranslate(int msgId, String target) =>
      post('tools.php?action=translate', {'message_id': msgId, 'target': target});

  // ── Safety (account restriction + face verification) ──────────
  static Future<Map<String, dynamic>> safetyStatus() => get('safety.php?action=status');
  static Future<Map<String, dynamic>> safetyFaceVerify(String imageB64) =>
      post('safety.php?action=face_verify', {'image': imageB64});
  static Future<Map<String, dynamic>> safetySelfRestrict() =>
      post('safety.php?action=self_restrict', {});

  // ── Call signaling — direct poll fallback (independent of SSE/WS) ──────
  static Future<Map<String, dynamic>> pollCallEvents({
    int afterId = 0,
    int? sinceEpochSeconds,
  }) async {
    try {
      final r = await get('call-poll.php', params: {
        'after_id': '$afterId',
        if (sinceEpochSeconds != null) 'since': '$sinceEpochSeconds',
      }).timeout(const Duration(seconds: 6));
      if (r['success'] == true && r['events'] is List) {
        return {
          'events': (r['events'] as List).map((e) => Map<String, dynamic>.from(e)).toList(),
          'last_id': int.tryParse(r['last_id']?.toString() ?? '') ?? afterId,
        };
      }
    } catch (_) {}
    return {'events': <Map<String, dynamic>>[], 'last_id': afterId};
  }

  // ── Auth ──────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> sendOtp(String phone, {String method = 'whatsapp'}) =>
      post('auth.php?action=send_otp', {'phone': phone, 'method': method}, auth: false);

  static Future<Map<String, dynamic>> verifyOtp(String phone, String otp) =>
      post('auth.php?action=verify_otp', {'phone': phone, 'otp': otp}, auth: false);

  // ── Conversations ─────────────────────────────────────────────
  static Future<List<Conversation>> getConversations() async {
    final r = await get('conversations.php?action=list');
    if (r['success'] == true && r['conversations'] is List) {
      return (r['conversations'] as List).map((c) => Conversation.fromJson(Map<String, dynamic>.from(c))).toList();
    }
    // A genuinely empty account looks identical to a failed request here
    // unless callers can tell them apart — silently returning [] on error
    // (a stale token right after a fresh install+login, a brief network
    // blip) made every chat/contact look permanently gone with nothing to
    // retry against. Let the caller decide what a failure means instead of
    // masking it as "you have zero chats".
    throw Exception(r['error']?.toString() ?? 'Failed to load conversations');
  }

  // ── Messages ──────────────────────────────────────────────────
  static Future<List<Message>> getMessages(int convId, {int? before}) async {
    final params = <String, String>{
      'conversation_id': convId.toString(),
      'limit': '100',
    };
    if (before != null) params['before'] = before.toString();
    final r = await get('messages.php?action=list', params: params);
    if (r['success'] == true && r['messages'] is List) {
      return (r['messages'] as List).map((m) => Message.fromJson(Map<String, dynamic>.from(m))).toList();
    }
    return [];
  }

  static Future<Map<String, dynamic>> sendMessage(int convId, String content, {String type = 'text', int? replyToId}) =>
      post('messages.php?action=send', {
        'conversation_id': convId,
        'content': content,
        'type': type,
        if (replyToId != null) 'reply_to_id': replyToId,
      });

  // ── AI image generation ───────────────────────────────────────
  // Server-side HuggingFace FLUX — fast (~1-3s), free, good quality.
  static Future<String?> aiGenerateImage(String prompt) async {
    final enc = Uri.encodeComponent(prompt);
    try {
      final t = await token;
      final res = await http.get(
        Uri.parse('$baseUrl/gen-image.php?action=generate&prompt=$enc'),
        headers: {if (t != null) 'Authorization': 'Bearer $t'})
          .timeout(const Duration(seconds: 60));
      final d = jsonDecode(res.body) as Map<String, dynamic>;
      final u = d['url']?.toString();
      if (u != null && u.isNotEmpty) return u;
    } catch (_) {}
    return null;
  }

  static Future<Map<String, dynamic>> deleteMessage(int msgId, {bool forAll = false}) =>
      post('messages.php?action=delete', {
        'message_id': msgId,
        'for_all': forAll,
      });

  static Future<Map<String, dynamic>> reactToMessage(int msgId, String emoji) =>
      post('messages.php?action=react', {'message_id': msgId, 'emoji': emoji});

  // ── Users ─────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> getMe() =>
      get('auth.php?action=me');

  static Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> data) =>
      post('users.php?action=update_profile', data);

  static Future<Map<String, dynamic>> usernameAvailable(String username) =>
      get('users.php?action=username_available', params: {'username': username});

  static Future<List<User>> searchUsers(String q) async {
    final r = await get('users.php?action=search', params: {'q': q});
    if (r['success'] == true && r['users'] is List) {
      return (r['users'] as List).map((u) => User.fromJson(Map<String, dynamic>.from(u))).toList();
    }
    return [];
  }

  static Future<Map<String, dynamic>> addContactByPhone(String phone, {String? nickname}) =>
      post('users.php?action=add_contact_by_phone', {'phone': phone, if (nickname != null) 'nickname': nickname});

  static Future<Map<String, dynamic>> createConversation(int userId) =>
      post('conversations.php?action=create_direct', {'user_id': userId});

  static Future<Map<String, dynamic>> createGroup(String name, List<int> memberIds) =>
      post('conversations.php?action=create_group', {'name': name, 'member_ids': memberIds});

  // ── Group management ──────────────────────────────────────────
  static Future<Conversation?> getConversation(int convId) async {
    final r = await get('conversations.php?action=get', params: {'id': convId.toString()});
    if (r['success'] == true && r['conversation'] is Map) {
      return Conversation.fromJson(Map<String, dynamic>.from(r['conversation']));
    }
    return null;
  }

  static Future<Map<String, dynamic>> groupAddMember(int convId, int userId) =>
      post('conversations.php?action=add_member', {'conversation_id': convId, 'user_id': userId});
  static Future<Map<String, dynamic>> groupRemoveMember(int convId, int userId) =>
      post('conversations.php?action=remove_member', {'conversation_id': convId, 'user_id': userId});
  static Future<Map<String, dynamic>> groupMakeAdmin(int convId, int userId, {bool demote = false}) =>
      post('conversations.php?action=make_admin', {'conversation_id': convId, 'user_id': userId, 'demote': demote});
  static Future<Map<String, dynamic>> blockUser(int userId) =>
      post('users.php?action=block', {'user_id': userId});
  static Future<Map<String, dynamic>> muteConversation(int convId) =>
      post('conversations.php?action=mute', {'conversation_id': convId});
  static Future<Map<String, dynamic>> pinConversation(int convId) =>
      post('conversations.php?action=pin', {'conversation_id': convId});
  static Future<Map<String, dynamic>> deleteConversation(int convId) =>
      post('conversations.php?action=delete', {'conversation_id': convId});

  // ── AI ────────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> aiBotReply(int convId, String msg) =>
      post('ai.php?action=bot_reply', {'conversation_id': convId, 'user_message': msg});

  static Future<Map<String, dynamic>> aiSummarize(int convId) =>
      post('ai.php?action=summarize', {'conversation_id': convId});

  static Future<Map<String, dynamic>> aiTranslate(String text, String lang) =>
      post('ai.php?action=translate', {'text': text, 'lang': lang});

  static Future<Map<String, dynamic>> aiSmartReply(String msg) =>
      post('ai.php?action=smart_reply', {'message': msg});

  static Future<Map<String, dynamic>> aiImprove(String text) =>
      post('ai.php?action=improve', {'text': text});

  // ── Upload avatar ─────────────────────────────────────────────
  static Future<Map<String, dynamic>> uploadAvatar(List<int> bytes, String filename) async {
    final t = await token;
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/users.php?action=upload_avatar'));
    if (t != null) req.headers['Authorization'] = 'Bearer $t';
    req.files.add(http.MultipartFile.fromBytes('avatar', bytes, filename: filename));
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Upload status media ───────────────────────────────────────
  static MediaType _mimeFromFilename(String filename) {
    final ext = filename.split('.').last.toLowerCase();
    const map = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif',  'webp': 'image/webp', 'heic': 'image/heic',
      'heif': 'image/heif','mp4': 'video/mp4',   'mov': 'video/quicktime',
      'webm': 'video/webm','avi': 'video/avi',
      'mp3': 'audio/mpeg', 'm4a': 'audio/mp4',   'aac': 'audio/aac',
      'ogg': 'audio/ogg',  'wav': 'audio/wav',
      'pdf': 'application/pdf',
    };
    final mime = map[ext] ?? 'application/octet-stream';
    final parts = mime.split('/');
    return MediaType(parts[0], parts[1]);
  }

  static Future<Map<String, dynamic>> uploadStatusMedia(List<int> bytes, String filename) async {
    final t = await token;
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/statuses.php?action=upload'));
    if (t != null) req.headers['Authorization'] = 'Bearer $t';
    req.files.add(http.MultipartFile.fromBytes('file', bytes,
        filename: filename, contentType: _mimeFromFilename(filename)));
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // ── Starred messages ──────────────────────────────────────────
  static Future<List<Message>> getStarredMessages() async {
    final r = await get('messages.php?action=starred');
    if (r['success'] == true && r['messages'] is List) {
      return (r['messages'] as List)
          .map((m) => Message.fromJson(Map<String, dynamic>.from(m)))
          .toList();
    }
    return [];
  }

  static Future<Map<String, dynamic>> toggleStar(int msgId) =>
      post('messages.php?action=star', {'message_id': msgId});

  // ── FCM token ─────────────────────────────────────────────────
  static Future<void> saveFcmToken(String fcmToken) async {
    await post('fcm-token.php', {'fcm_token': fcmToken});
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fcm_token', fcmToken);
  }

  // ── Upload file ───────────────────────────────────────────────
  static Future<Map<String, dynamic>> uploadFile(
    int convId,
    List<int> bytes,
    String filename,
    String type, {
    int? durationSecs,
  }) async {
    final t = await token;
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/messages.php?action=send'));
    if (t != null) req.headers['Authorization'] = 'Bearer $t';
    req.fields['conversation_id'] = convId.toString();
    req.fields['type'] = type;
    if (durationSecs != null && durationSecs > 0) {
      req.fields['duration'] = durationSecs.toString();
    }
    req.files.add(http.MultipartFile.fromBytes('file', bytes,
        filename: filename, contentType: _mimeFromFilename(filename)));
    final streamed = await req.send();
    final res = await http.Response.fromStream(streamed);
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
