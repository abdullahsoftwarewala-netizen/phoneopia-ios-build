import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' show Color;
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin _flnp = FlutterLocalNotificationsPlugin();

// Callback for when user taps a notification while app is terminated
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse resp) {}

/// Set from main.dart — handles accept/decline/tap on call notifications.
void Function(NotificationResponse)? onCallNotificationAction;

class NotificationService {
  static final NotificationService _i = NotificationService._();
  factory NotificationService() => _i;
  NotificationService._();

  static const callNotificationId = 9999;
  static const callActionAccept = 'call_accept';
  static const callActionDecline = 'call_decline';

  // Called from main.dart onDidReceiveNotificationResponse
  static void Function(NotificationResponse)? onTap;

  Future<void> init({bool requestPermissions = true}) async {
    const android = AndroidInitializationSettings('@drawable/ic_stat_phoneopia');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _flnp.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: _onNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    await _createChannels();
    // Permission requests need an Activity context — they CRASH in a background
    // isolate (FCM handler). Only request from the main/UI isolate.
    if (requestPermissions) {
      try { await _requestPermissions(); } catch (_) {}
    }
  }

  void _onNotificationResponse(NotificationResponse resp) {
    var isCallPayload = false;
    if (resp.payload != null) {
      try {
        final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
        isCallPayload = data['type'] == 'incoming_call' || data['type'] == 'call_offer';
      } catch (_) {}
    }
    if (resp.actionId == callActionAccept || resp.actionId == callActionDecline || isCallPayload) {
      onCallNotificationAction?.call(resp);
    }
    onTap?.call(resp);
  }

  Future<void> _createChannels() async {
    final plugin = _flnp.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (plugin == null) return;

    await plugin.createNotificationChannel(const AndroidNotificationChannel(
      'messages',
      'Messages',
      description: 'New message notifications',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    ));

    // Bump channel id when changing ring/vibrate behaviour.
    await plugin.createNotificationChannel(AndroidNotificationChannel(
      'calls_v5',
      'Incoming Calls',
      description: 'Incoming call ring, vibration & lock screen',
      importance: Importance.max,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('incoming_call'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 800, 600, 800, 600, 800]),
      enableLights: true,
    ));

    await plugin.createNotificationChannel(const AndroidNotificationChannel(
      'phoneopia_bg',
      'Background Connection',
      description: 'Keeps Phoneopia connected for messages & calls',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    ));
  }

  Future<void> _requestPermissions() async {
    final android = _flnp.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
    try { await android?.requestFullScreenIntentPermission(); } catch (_) {}
  }

  Future<void> showMessageNotification({
    required int convId,
    required String senderName,
    required String body,
    String? avatarUrl,
    int? toUserId,
  }) async {
    // Download the sender's avatar to show as the big icon (WhatsApp-style):
    // sender's photo as the large icon, Phoneopia logo stays the small status
    // bar icon.
    AndroidBitmap<Object>? largeIcon;
    if (avatarUrl != null && avatarUrl.isNotEmpty) {
      try {
        final res = await http.get(Uri.parse(avatarUrl)).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
          largeIcon = ByteArrayAndroidBitmap(res.bodyBytes);
        }
      } catch (_) {}
    }
    final androidDetails = AndroidNotificationDetails(
      'messages',
      'Messages',
      channelDescription: 'New message notifications',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_stat_phoneopia',
      color: const Color(0xFFFF2D2D),
      largeIcon: largeIcon,
      styleInformation: BigTextStyleInformation(body, contentTitle: senderName),
      groupKey: 'phoneopia_messages',
      setAsGroupSummary: false,
    );

    await _flnp.show(
      convId,
      senderName,
      body,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode({'type': 'message', 'conv_id': convId, 'to_user_id': toUserId}),
    );
  }

  /// Full-screen incoming call — lock screen par Accept/Decline buttons ke sath.
  Future<void> showIncomingCallNotification({
    required int callerId,
    required String callerName,
    required String callType,
    required int convId,
    int offerTs = 0,
    String callerAvatar = '',
    Map<String, dynamic>? payload,
  }) async {
    final typeLabel = callType == 'video' ? 'Video call' : 'Voice call';
    // offer_ts MUST be carried in the payload — when a locked/closed device
    // launches via the full-screen-intent, this payload is the only call data
    // available; a missing offer_ts makes the offer look stale and the pickup
    // screen never presents.
    final callPayload = payload ?? {
      'type': 'incoming_call',
      'from_user_id': callerId,
      'from_display_name': callerName,
      'from_avatar': callerAvatar,
      'call_type': callType,
      'conversation_id': convId,
      'offer_ts': offerTs,
    };

    final androidDetails = AndroidNotificationDetails(
      'calls_v5',
      'Incoming Calls',
      channelDescription: 'Incoming call ring, vibration & lock screen',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.call,
      icon: '@drawable/ic_stat_phoneopia',
      color: const Color(0xFFFF2D2D),
      ongoing: true,
      autoCancel: false,
      visibility: NotificationVisibility.public,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('incoming_call'),
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 800, 600, 800, 600, 800]),
      additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT — loop until dismissed
      timeoutAfter: 45000,
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          callActionDecline,
          'Decline',
          showsUserInterface: false,
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          callActionAccept,
          'Accept',
          showsUserInterface: true,
          cancelNotification: true,
        ),
      ],
    );

    await _flnp.show(
      callNotificationId,
      '$callerName is calling',
      typeLabel,
      NotificationDetails(android: androidDetails),
      payload: jsonEncode(callPayload),
    );
  }

  Future<void> cancelCallNotification() async {
    // Must never throw — a plugin error here used to abort the incoming-call
    // presentation, so the pickup screen never appeared.
    try { await _flnp.cancel(callNotificationId); } catch (_) {}
  }

  static const activeCallNotificationId = 9998;

  /// Persistent low-priority notification while a call is active — this is
  /// what Android uses as a foreground-service proxy to keep the process
  /// alive when the user backgrounds the app mid-call. Without it, the OS
  /// can kill the app after a few minutes and the call silently drops.
  Future<void> showActiveCallNotification({
    required String callerName,
    required bool isVideo,
  }) async {
    final typeLabel = isVideo ? 'Video call' : 'Voice call';
    final androidDetails = AndroidNotificationDetails(
      'phoneopia_bg',
      'Background Connection',
      channelDescription: 'Keeps Phoneopia connected for messages & calls',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      icon: '@drawable/ic_stat_phoneopia',
      color: const Color(0xFF128C7E),
      styleInformation: BigTextStyleInformation('$typeLabel with $callerName', contentTitle: 'Phoneopia Call Active'),
      showWhen: false,
    );

    await _flnp.show(
      activeCallNotificationId,
      'Phoneopia Call Active',
      '$typeLabel with $callerName',
      NotificationDetails(android: androidDetails),
    );
  }

  Future<void> cancelActiveCallNotification() async {
    try { await _flnp.cancel(activeCallNotificationId); } catch (_) {}
  }

  Future<void> cancelAll() async {
    try { await _flnp.cancelAll(); } catch (_) {}
  }
}
