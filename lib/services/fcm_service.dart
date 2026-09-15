import 'dart:convert';
import 'package:provider/provider.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'api_service.dart';
import '../config/app_config.dart';
import '../main.dart' show navigatorKey, maybePromptAppUpdate;
import '../providers/app_provider.dart';
import 'call_alert_service.dart';

/// The server tags every FCM push with the intended recipient's id
/// (fcm-lib.php's fcm_send_to_user() always fills to_user_id in). A push can
/// still land on the wrong device/account when a token wasn't re-registered
/// promptly after an account switch on the same phone (a common test setup:
/// two accounts, one device) — the FCM token itself is still valid, it's
/// just now sitting under a different logged-in session, so the server's
/// "don't push to the sender" check can't catch it. Confirmed live: sending
/// a message showed a notification for that same message on the sender's
/// own device — the push had actually gone to a stale token for the
/// recipient that pointed at the sender's phone. Reject anything not
/// addressed to whoever is ACTUALLY logged in right now.
Future<bool> _isForCurrentUser(Map<String, dynamic> d) async {
  final toUserId = int.tryParse(d['to_user_id']?.toString() ?? '');
  if (toUserId == null)
    return true; // no recipient tag — can't check, let it through
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('phoneopia_user');
    if (raw == null || raw.isEmpty) return false;
    final j = jsonDecode(raw);
    final currentId = j is Map ? int.tryParse(j['id']?.toString() ?? '') : null;
    return currentId != null && currentId == toUserId;
  } catch (_) {
    return true; // can't verify — fail open rather than silently dropping real pushes
  }
}

/// Background / terminated-state push handler. Must be a top-level function.
/// Fires even when the app is fully closed — this is what makes calls &
/// messages arrive reliably (Doze-proof, OEM-kill-proof).
@pragma('vm:entry-point')
Future<void> firebaseBgHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // No permission requests in the background isolate (no Activity → crash).
  await NotificationService().init(requestPermissions: false);
  await _showFromData(message.data);
}

Future<void> _showFromData(Map<String, dynamic> d) async {
  if (!await _isForCurrentUser(d)) return;
  final type = (d['type'] ?? '').toString();
  if (type == 'incoming_call' || type == 'call_offer') {
    // Persist the call so when the app launches/resumes (from the full-screen
    // notification) it restores the IncomingCallScreen — NOT the chat dashboard.
    try {
      final normalized = CallAlertService().normalizeCallData({
        ...d,
        'type': 'call_offer',
      });
      await CallAlertService().savePendingCall(normalized);
    } catch (_) {}
    await NotificationService().showIncomingCallNotification(
      callerId: int.tryParse(d['caller_id']?.toString() ?? '0') ?? 0,
      callerName: (d['caller_name'] ?? 'Incoming call').toString(),
      callType: (d['call_type'] ?? 'audio').toString(),
      convId: int.tryParse(d['conversation_id']?.toString() ?? '0') ?? 0,
      offerTs: int.tryParse(d['offer_ts']?.toString() ?? '0') ?? 0,
      callerAvatar: (d['caller_avatar'] ?? '').toString(),
    );
  } else if (type == 'missed_call') {
    await NotificationService().showMessageNotification(
      convId: int.tryParse(d['conversation_id']?.toString() ?? '0') ?? 0,
      senderName: (d['caller_name'] ?? 'Missed call').toString(),
      body: (d['call_type'] == 'video')
          ? '📹 Missed video call'
          : '📞 Missed voice call',
      toUserId: int.tryParse(d['to_user_id']?.toString() ?? '0'),
    );
  } else if (type == 'call_cancel' ||
      type == 'call_end' ||
      type == 'call_reject') {
    // Caller hung up / call answered elsewhere → stop the ring + vibration.
    try {
      await NotificationService().cancelCallNotification();
    } catch (_) {}
    try {
      await CallAlertService().stopAll();
    } catch (_) {}
    try {
      await CallAlertService().clearPendingCall();
    } catch (_) {}
  } else if (type == 'new_message') {
    var avatar = (d['sender_avatar'] ?? '').toString();
    if (avatar.isNotEmpty && !avatar.startsWith('http')) {
      avatar =
          '${AppConfig.mediaBase}${avatar.startsWith('/') ? '' : '/'}$avatar';
    }
    await NotificationService().showMessageNotification(
      convId: int.tryParse(d['conversation_id']?.toString() ?? '0') ?? 0,
      senderName: (d['sender_name'] ?? 'New message').toString(),
      body: (d['body'] ?? '').toString(),
      avatarUrl: avatar.isEmpty ? null : avatar,
      toUserId: int.tryParse(d['to_user_id']?.toString() ?? '0'),
    );
  } else if (type == 'app_update') {
    await NotificationService().showMessageNotification(
      convId: 990011,
      senderName: 'Phoneopia',
      body: '🚀 New update available — open the app to install',
    );
  } else if (type == 'blue_tick_awarded') {
    await NotificationService().showMessageNotification(
      convId: 990012,
      senderName: (d['title'] ?? 'Phoneopia Blue Tick').toString(),
      body: (d['body'] ?? 'Congratulations! Your account is now verified.')
          .toString(),
      toUserId: int.tryParse(d['to_user_id']?.toString() ?? '0'),
    );
  }
}

// Foreground push: when the app is OPEN, an incoming call must show the
// full in-app attend screen (Accept/Decline), not just a notification.
Future<void> _handleForeground(RemoteMessage m) async {
  final d = m.data;
  if (!await _isForCurrentUser(d)) return;
  final type = (d['type'] ?? '').toString();
  if (type == 'incoming_call' || type == 'call_offer') {
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      try {
        ctx.read<AppProvider>().presentIncomingCallFromNotification(
          jsonEncode({...d, 'type': 'call_offer'}),
        );
        return;
      } catch (_) {}
    }
  } else if (type == 'call_cancel' ||
      type == 'call_end' ||
      type == 'call_ended' ||
      type == 'call_reject' ||
      type == 'call_rejected' ||
      type == 'call_answered_elsewhere') {
    // Dismiss the in-app incoming-call UI AND close any outgoing-call screen
    // instantly. call_status tells us if the callee declined vs just ended.
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      try {
        final status = (d['call_status'] ?? '').toString();
        final signalType =
            status == 'declined' ||
                type == 'call_reject' ||
                type == 'call_rejected'
            ? 'call_reject'
            : type == 'call_answered_elsewhere'
            ? type
            : 'call_end';
        ctx.read<AppProvider>().injectCallSignal({...d, 'type': signalType});
      } catch (_) {}
    }
    try {
      await NotificationService().cancelCallNotification();
    } catch (_) {}
    try {
      await CallAlertService().stopAll();
    } catch (_) {}
    try {
      await CallAlertService().clearPendingCall();
    } catch (_) {}
    return;
  } else if (type == 'new_message') {
    // The chat is already visible and receives the message through SSE. A
    // second foreground notification is noisy and can reopen the same chat.
    final convId = int.tryParse(d['conversation_id']?.toString() ?? '') ?? 0;
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      try {
        if (ctx.read<AppProvider>().activeChatConvId == convId) return;
      } catch (_) {}
    }
  } else if (type == 'app_update') {
    try {
      maybePromptAppUpdate(force: true);
    } catch (_) {}
    return;
  }
  await _showFromData(d);
}

class FcmService {
  static final FcmService _i = FcmService._();
  factory FcmService() => _i;
  FcmService._();

  bool _ready = false;
  bool _initializing = false;
  bool _listenersRegistered = false;

  Future<void> init() async {
    if (_ready || _initializing) return;
    _initializing = true;
    try {
      await Firebase.initializeApp();
      final fm = FirebaseMessaging.instance;
      // Register the realtime callbacks before permission prompts, token
      // retrieval, or token registration. Those operations can take several
      // seconds on Android; registering them afterwards made a call that
      // arrived during startup appear late or only after the app was resumed.
      if (!_listenersRegistered) {
        FirebaseMessaging.onMessage.listen(_handleForeground);
        FirebaseMessaging.onBackgroundMessage(firebaseBgHandler);
        _listenersRegistered = true;
      }
      // Keep FCM alive across process restarts. This is especially important
      // for data-only call/message pushes, which must wake the terminated app.
      await fm.setAutoInitEnabled(true);
      await fm.requestPermission(alert: true, badge: true, sound: true);
      fm.onTokenRefresh.listen((token) async {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('fcm_token', token);
        } catch (_) {}
        await registerToken(token);
      });
      final token = await fm.getToken();
      if (token != null && token.isNotEmpty) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('fcm_token', token);
        } catch (_) {}
        await registerToken(token);
      }
      _ready = true;
    } catch (_) {
      // Do not permanently disable push after a transient Play Services or
      // network failure. AppProvider calls ensurePushRegistered on resume,
      // and a later init() can now retry cleanly.
      _ready = false;
    } finally {
      _initializing = false;
    }
  }

  static Future<String?> getToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  static Future<void> registerToken(String token) async {
    if (token.isEmpty) return;
    try {
      await ApiService.post('fcm.php?action=register', {
        'token': token,
        'platform': 'android',
      });
    } catch (_) {}
  }
}
