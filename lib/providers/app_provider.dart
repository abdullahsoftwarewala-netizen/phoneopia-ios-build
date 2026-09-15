import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../models/models.dart';
import '../utils/server_time.dart';
import '../services/api_service.dart';
import '../services/account_service.dart';
import '../services/websocket_service.dart'
    show WebSocketService, WsMessageCallback;
import '../services/audio_service.dart';
import '../services/call_alert_service.dart';
import '../services/call_wake_service.dart';
import '../services/notification_service.dart';
import '../services/sse_service.dart';
import '../services/fcm_service.dart';
import '../services/background_service.dart';
import '../services/nearby_service.dart';
import '../services/sharing_service.dart';
import '../config/storage_keys.dart';
import '../main.dart' show navigatorKey;
import '../widgets/avatar_widget.dart';

class _PendingDelete {
  final Message message;
  final bool forAll;
  final Timer timer;
  _PendingDelete(this.message, this.forAll, this.timer);
}

class AppProvider extends ChangeNotifier {
  // Invalidates every account-scoped async response that started before the
  // latest login/switch. Without this, an old account's slow getMe/list call
  // could complete after a switch and overwrite the new header and chats.
  int _accountEpoch = 0;
  User? _me;
  List<Conversation> _conversations = [];
  List<Map<String, dynamic>> _statusGroups = [];
  bool _statusesLoading = false;
  String? _statusesError;
  List<Map<String, dynamic>> _callLogs = [];
  bool _refreshRecentsRunning = false;
  final Map<int, List<Message>> _messages = {};

  /// Stable ListView keys — temp id → real id without re-animating the bubble.
  final Map<int, String> _clientMsgKeys = {};
  final Map<int, _PendingDelete> _pendingDeletes = {};
  final Map<int, bool> _messagesLoading = {};
  final Map<int, String?> _messagesErrors = {};
  final Map<int, bool> _typingMap = {};
  final Map<int, bool> _recordingMap = {};
  bool _loading = false;
  String? _error;
  ThemeMode _themeMode = ThemeMode.system;
  double _fontScale = 1.0; // 0.85 small, 1.0 medium, 1.2 large
  String? _chatWallpaper; // asset/color id for chat background
  bool _isLoggedIn = false;
  Map<String, dynamic>? _incomingCall;
  int _incomingCallNonce = 0;
  bool _inActiveCallUi = false;
  String? _pendingDeepLinkUsername;

  final WebSocketService _ws = WebSocketService();
  final AccountService _accountService = AccountService();

  User? get me => _me;
  List<Conversation> get conversations => _conversations;
  List<Map<String, dynamic>> get statusGroups => _statusGroups;
  bool get statusesLoading => _statusesLoading;
  String? get statusesError => _statusesError;
  List<Map<String, dynamic>> get callLogs => _callLogs;
  bool get loading => _loading;
  String? get error => _error;
  ThemeMode get themeMode => _themeMode;
  double get fontScale => _fontScale;
  String? get chatWallpaper => _chatWallpaper;
  bool get isLoggedIn => _isLoggedIn;
  Map<String, dynamic>? get incomingCall => _incomingCall;
  int get incomingCallNonce => _incomingCallNonce;
  bool get inActiveCallUi => _inActiveCallUi;

  void setInActiveCallUi(bool active) {
    _inActiveCallUi = active;
    if (!active) _activeCallPeer = null;
  }

  /// Stores the username from a deep link so the home/new-chat screen can
  /// open a conversation with that user after navigating.
  String? consumePendingDeepLinkUsername() {
    final u = _pendingDeepLinkUsername;
    _pendingDeepLinkUsername = null;
    return u;
  }

  void setPendingDeepLinkUsername(String username) {
    _pendingDeepLinkUsername = username;
    notifyListeners();
  }

  int _lastPresentedAt = 0;
  String _lastPresentedKey = '';

  /// Single choke point for showing the incoming-call screen — a call_offer
  /// can reach the app via SSE, direct WS, AND an FCM push, each hitting a
  /// different entry point. Without a dedup here, the SAME call presents
  /// itself multiple times (multiple rings/screens for one placed call).
  /// Returns true if this call was actually presented (state set, screen
  /// will show) — false if the dedup guard swallowed it as a repeat
  /// delivery of the same offer. Callers MUST check this before doing
  /// anything else caller-visible (like playing the ring) — the two used
  /// to be independent: a call that got silently deduped here still rang,
  /// because the ring was fired unconditionally alongside this call
  /// instead of gated on whether it actually returned true. That's exactly
  /// backwards for a genuine quick re-call from the same person (e.g. a
  /// redial right after "No answer") on the Nearby path, where every call
  /// shares the same dedup key (conversation_id is always 0 there) — the
  /// second call's ring played with no attend screen behind it at all.
  bool _presentIncomingCall(Map<String, dynamic> data) {
    final callerId =
        (data['from_user_id'] ?? data['caller_id'])?.toString() ?? '';
    final convId =
        (data['conversation_id'] ?? data['group_conv_id'])?.toString() ?? '';
    final callId =
        (data['call_id'] ?? data['nearby_call_id'])?.toString().trim() ?? '';
    final key = callId.isNotEmpty ? '$callerId:$callId' : '$callerId:$convId';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (key.isNotEmpty &&
        key != ':' &&
        key == _lastPresentedKey &&
        now - _lastPresentedAt < 12000) {
      return false;
    }
    _lastPresentedKey = key;
    _lastPresentedAt = now;

    _incomingCall = data;
    _incomingCallNonce++;
    notifyListeners();
    unawaited(CallWakeService.wakeForIncomingCall());
    return true;
  }

  // Call dedup state — stops SSE-replayed offers from re-ringing dead calls
  final Set<String> _dismissedCallers = {};
  String? _activeCallPeer;
  void setActiveCallPeer(String? id) => _activeCallPeer = id;

  /// Only after user explicitly declines — blocks SSE replay ~45s, not future calls.
  void markCallerDismissed(String id) {
    if (id.isEmpty) return;
    _dismissedCallers.add(id);
    CallAlertService().markCallerDismissed(id);
    Future.delayed(
      const Duration(seconds: 46),
      () => _dismissedCallers.remove(id),
    );
  }

  void clearCallerDismissed(String id) {
    if (id.isEmpty) return;
    _dismissedCallers.remove(id);
    CallAlertService().clearCallerDismissed(id);
  }

  // Separate, much shorter-lived suppression for a LATE call_offer arriving
  // just after that same caller's call_end/call_missed already landed (a
  // slow poll cycle or brief reconnect, not a real new call) — reusing the
  // 45s explicit-decline window here was wrong: it also silently swallowed
  // a genuine redial from the same caller placed within 45s of their last
  // call ending. A few seconds is enough to catch the actual race without
  // blocking real follow-up calls.
  final Set<String> _brieflyDismissedCallers = {};
  void _markCallerBrieflyDismissed(String id) {
    if (id.isEmpty) return;
    _brieflyDismissedCallers.add(id);
    Future.delayed(
      const Duration(seconds: 5),
      () => _brieflyDismissedCallers.remove(id),
    );
  }

  Future<bool> _isCallerDismissed(String id) async {
    if (id.isEmpty) return false;
    if (_dismissedCallers.contains(id)) return true;
    return CallAlertService().isCallerDismissed(id);
  }

  int _lastCallOfferAt = 0;
  String _lastCallOfferKey = '';

  /// Call signaling via HTTP relay — retry once so web callee gets the offer.
  void _sendCallSignal(Map<String, dynamic> data) {
    Future<void> relay() async {
      final envelope = <String, dynamic>{
        ...data,
        'client_instance_id': await SseService().ensureClientInstanceId(),
      };
      // call_answer/end/ICE are not optional fire-and-forget messages. A
      // request could previously hang forever (no HTTP timeout), preventing
      // even the single retry. Use bounded attempts with backoff; duplicate
      // events are safe because call handlers are idempotent.
      for (var attempt = 0; attempt < 5; attempt++) {
        try {
          final r = await ApiService.post(
            'ws-relay.php',
            envelope,
          ).timeout(const Duration(seconds: 5));
          if ((r['success'] == true || r['ok'] == true) && r['error'] == null)
            return;
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
    }

    unawaited(relay());
  }

  bool _isCallOfferStale(Map<String, dynamic> data) {
    final normalized = data['type'] == 'call_offer'
        ? CallAlertService().normalizeCallData(data)
        : data;
    return !CallAlertService.isOfferFresh(normalized);
  }

  bool _isDuplicateCallOffer(Map<String, dynamic> data) {
    final callerId =
        (data['caller_id'] ?? data['from_user_id'])?.toString() ?? '';
    if (callerId.isEmpty) return false;
    final callId =
        (data['call_id'] ?? data['nearby_call_id'])?.toString().trim() ?? '';
    final key = callId.isNotEmpty
        ? '$callerId:$callId'
        : '$callerId:${data['conversation_id'] ?? 0}';
    final now = DateTime.now().millisecondsSinceEpoch;
    if (key == _lastCallOfferKey && now - _lastCallOfferAt < 12000) return true;
    _lastCallOfferKey = key;
    _lastCallOfferAt = now;
    return false;
  }

  bool _shouldDismissIncomingFor(Map<String, dynamic> data) {
    if (_incomingCall == null) return true;
    final from =
        (data['from_user_id'] ?? data['caller_id'] ?? data['answerer_id'])
            ?.toString() ??
        '';
    if (from.isEmpty) return true;
    final cur =
        (_incomingCall!['from_user_id'] ?? _incomingCall!['caller_id'])
            ?.toString() ??
        '';
    return cur.isEmpty || cur == from;
  }

  void clearIncomingCall() {
    _incomingCall = null;
    notifyListeners();
  }

  /// Lock screen / notification se call UI dikhane ke liye.
  Future<void> presentIncomingCallFromNotification(String? payload) async {
    // Use the payload when it carries a FRESH offer (foreground FCM push); the
    // tap payload is minimal, so fall back to the saved pending call then.
    Map<String, dynamic>? data;
    if (payload != null && payload.isNotEmpty) {
      try {
        data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      } catch (_) {}
    }
    if (data == null ||
        !CallAlertService.isOfferFresh(
          CallAlertService().normalizeCallData(data),
        )) {
      final pending = await CallAlertService().loadPendingCall();
      if (pending != null) data = pending;
    }
    if (data == null) return;

    var normalized = CallAlertService().normalizeCallData(data);
    if (!CallAlertService.isOfferFresh(normalized)) {
      await CallAlertService().clearPendingCall();
      return;
    }
    final callerId = normalized['from_user_id']?.toString() ?? '';
    if (callerId.isNotEmpty) {
      if (_dismissedCallers.contains(callerId)) return;
      if (_activeCallPeer == callerId) return;
    }

    // The FCM push that wakes the app from background/killed only carries
    // caller metadata — never the SDP offer (WhatsApp-style pushes never do;
    // the offer is comparatively large and time-sensitive). Accepting a call
    // with no SDP used to silently "connect" with no audio pipeline at all.
    // Fetch the real offer the server queued (same one WS/SSE would have
    // delivered) before presenting the accept screen.
    if ((normalized['sdp']?.toString() ?? '').isEmpty) {
      for (
        var i = 0;
        i < 4 && (normalized['sdp']?.toString() ?? '').isEmpty;
        i++
      ) {
        final poll = await ApiService.pollCallEvents(
          sinceEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60,
        );
        final events =
            poll['events'] as List<Map<String, dynamic>>? ?? const [];
        for (final e in events) {
          if (e['type'] == 'call_offer' &&
              (e['caller_id']?.toString() ?? '') == callerId &&
              (e['sdp']?.toString() ?? '').isNotEmpty) {
            normalized = {
              ...normalized,
              'sdp': e['sdp'],
              'sdp_type': e['sdp_type'],
            };
          }
        }
        if ((normalized['sdp']?.toString() ?? '').isEmpty) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
    }

    await NotificationService().cancelCallNotification();
    await CallWakeService.wakeForIncomingCall();
    _presentIncomingCall(normalized);
    if (!AudioService().isPlaying) await AudioService().playIncomingCall();
  }

  /// Notification Decline — turant vibrate/ring band + server ko reject.
  Future<void> declineIncomingCallFromNotification(String? payload) async {
    Map<String, dynamic>? data;
    if (payload != null && payload.isNotEmpty) {
      try {
        data = Map<String, dynamic>.from(jsonDecode(payload) as Map);
      } catch (_) {}
    }
    data ??= await CallAlertService().loadPendingCall();
    final callerId = int.tryParse(data?['from_user_id']?.toString() ?? '');
    final convId =
        int.tryParse(data?['conversation_id']?.toString() ?? '') ?? 0;
    final isVideo = data?['call_type']?.toString() == 'video';

    await CallAlertService().stopAll();
    _incomingCall = null;
    if (callerId != null) {
      _sendCallSignal({'type': 'call_reject', 'target_user_id': callerId});
      markCallerDismissed(callerId.toString());
      unawaited(
        logCall(
          peerId: callerId,
          isOutgoing: false,
          convId: convId,
          status: 'rejected',
          isVideo: isVideo,
        ),
      );
    }
    notifyListeners();
  }

  Future<void> dismissIncomingCall({
    bool sendReject = false,
    int? callerId,
    int? convId,
    bool isVideo = false,
  }) async {
    if (callerId != null) markCallerDismissed(callerId.toString());
    _incomingCall = null;
    notifyListeners();
    await CallAlertService().stopAll();
    // Release the ring-window BLE-churn guard armed on call_offer — we're
    // declining before NearbyVoiceCallService ever started, so its own
    // end() (which normally clears this) never runs.
    NearbyService().setVoiceActive(false);
    if (sendReject && callerId != null) {
      _sendCallSignal({'type': 'call_reject', 'target_user_id': callerId});
      unawaited(
        logCall(
          peerId: callerId,
          isOutgoing: false,
          convId: convId ?? 0,
          status: 'rejected',
          isVideo: isVideo,
        ),
      );
    }
  }

  Timer? _refreshDebounce;
  Timer? _activeChatPoll;
  Timer? _staleCallWatchdog;

  /// Pull latest chats — message sync is via SSE / silent poll (no list flash).
  Future<void> refreshRecents({bool refreshActiveChat = false}) async {
    if (_refreshRecentsRunning || !_isLoggedIn) return;
    _refreshRecentsRunning = true;
    final epoch = _accountEpoch;
    try {
      await syncBackgroundMessageCache();
      if (epoch != _accountEpoch) return;
      await loadConversations();
      if (epoch != _accountEpoch) return;
      if (refreshActiveChat &&
          _activeChatConvId != null &&
          _activeChatConvId! > 0) {
        final convId = _activeChatConvId!;
        markRead(convId);
        await loadMessages(convId, refresh: true, silent: true);
      }
    } finally {
      _refreshRecentsRunning = false;
    }
  }

  void _scheduleAutoRefresh({bool refreshActiveChat = false}) {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (!_isLoggedIn) return;
      unawaited(refreshRecents(refreshActiveChat: refreshActiveChat));
    });
  }

  int _autoRefreshTick = 0;
  bool _nearbyFlushRunning = false;
  void startRecentsAutoRefresh() {
    _recentsRefreshTimer?.cancel();
    _recentsRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_isLoggedIn || _inActiveCallUi) return;
      // Refresh recents AND the open chat's messages (so messages + read receipts
      // stay live as a fallback even if the SSE stream is interrupted). SSE is
      // the instant path; this is only a safety net, so running the whole sync
      // stack every 2s needlessly saturated slower phones and made call UI jank.
      unawaited(refreshRecents(refreshActiveChat: true));
      _autoRefreshTick++;
      if (_autoRefreshTick % 2 == 0) unawaited(_flushNearbyOutbox());
      if (_autoRefreshTick % 3 == 0) unawaited(loadCalls());
      if (_autoRefreshTick % 6 == 0) unawaited(loadStatuses(silent: true));
      // Refresh my own account/profile (drives Settings, avatar, status) every ~30s.
      if (_autoRefreshTick % 6 == 0) unawaited(refreshMe());
      // Google Drive backup is disabled.
    });
  }

  /// Move messages/files that were delivered directly over Nearby into the
  /// normal server history as soon as internet returns.  Without this, the
  /// sender saw the message locally forever while a later login/device could
  /// not see it.  Only messages authored by this account are uploaded, so a
  /// received Nearby message is never duplicated by the receiver.
  Future<void> _flushNearbyOutbox() async {
    if (_nearbyFlushRunning || !_isLoggedIn || _me == null) return;
    _nearbyFlushRunning = true;
    try {
      if (await ApiService.isOffline()) return;
      final snapshot = _messages.entries
          .where((e) => e.key > 0)
          .expand((e) => e.value)
          .where(
            (m) =>
                m.status == 'sent_nearby' && m.senderId == _me!.id && m.id < 0,
          )
          .toList();
      for (final m in snapshot) {
        try {
          Message? uploaded;
          if (m.type == 'text') {
            final r = await ApiService.sendMessage(
              m.conversationId,
              m.content ?? '',
              type: m.type,
              replyToId: m.replyToId,
            );
            uploaded = _parseSendResponse(r, m.conversationId);
          } else if (m.localPath != null &&
              m.localPath!.isNotEmpty &&
              await File(m.localPath!).exists()) {
            final bytes = await File(m.localPath!).readAsBytes();
            final r = await ApiService.uploadFile(
              m.conversationId,
              bytes,
              m.fileName ?? 'nearby_file',
              m.type,
              durationSecs: m.duration,
            );
            uploaded = _parseSendResponse(r, m.conversationId);
          }
          if (uploaded != null) {
            _commitMessage(m.conversationId, uploaded, replaceTempId: m.id);
            _upsertConvFromMessage(
              m.conversationId,
              uploaded,
              bumpUnread: false,
            );
            unawaited(
              _saveCachedMessages(
                m.conversationId,
                messagesFor(m.conversationId),
              ),
            );
          }
        } catch (_) {
          // Keep it marked sent_nearby; the next online cycle retries it.
        }
      }
      notifyListeners();
    } finally {
      _nearbyFlushRunning = false;
    }
  }

  Future<void> _autoGDriveBackup() async {
    return;
    try {
      final s = await ApiService.gdriveStatus();
      if (s['connected'] == true) await ApiService.gdriveBackup();
    } catch (_) {}
  }

  /// Matches the phone's saved contacts against Phoneopia accounts by phone
  /// number, and adds any match as a Phoneopia contact under the same name
  /// already saved in the phone. Returns how many were newly added.
  Future<int> syncPhoneContacts() async {
    final granted = await FlutterContacts.requestPermission();
    if (!granted) return 0;
    final contacts = await FlutterContacts.getContacts(withProperties: true);
    int added = 0;
    for (final c in contacts) {
      final name = c.displayName.trim();
      if (name.isEmpty) continue;
      for (final p in c.phones) {
        final raw = p.number.trim();
        if (raw.isEmpty) continue;
        try {
          final r = await ApiService.addContactByPhone(raw, nickname: name);
          if (r['success'] == true && r['is_self'] != true) added++;
        } catch (_) {}
        break; // one match attempt per contact is enough
      }
    }
    if (added > 0) unawaited(loadConversations());
    return added;
  }

  void stopRecentsAutoRefresh() {
    _recentsRefreshTimer?.cancel();
    _recentsRefreshTimer = null;
    _staleCallWatchdog?.cancel();
    _staleCallWatchdog = null;
    _activeChatPoll?.cancel();
    _activeChatPoll = null;
    _refreshDebounce?.cancel();
    _refreshDebounce = null;
    _convListDebounce?.cancel();
    _convListDebounce = null;
    _inactiveAccountsPoll?.cancel();
    _inactiveAccountsPoll = null;
  }

  /// Merge messages cached by the background SSE worker into the live list.
  Future<void> _restoreReadMarkers(SharedPreferences prefs) async {
    final userId =
        _me?.id ??
        int.tryParse(prefs.getString('phoneopia_user_id') ?? '') ??
        0;
    if (userId <= 0) return;
    final prefix = 'recently_read_${userId}_';
    for (final key in prefs.getKeys().where((k) => k.startsWith(prefix))) {
      final convId = int.tryParse(key.substring(prefix.length));
      final at = prefs.getInt(key);
      if (convId != null && convId > 0 && at != null) {
        _recentlyReadAt[convId] = at;
      }
    }
  }

  Future<void> syncBackgroundMessageCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _restoreReadMarkers(prefs);
      final userId = prefs.getString('phoneopia_user_id') ?? '0';
      final prefix = 'msg_cache_${userId}_';
      var dirty = false;
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(prefix)) continue;
        final convId = int.tryParse(key.substring(prefix.length)) ?? 0;
        if (convId <= 0) continue;
        final raw = prefs.getString(key);
        if (raw == null || raw.isEmpty) continue;
        try {
          final cached = (jsonDecode(raw) as List)
              .map((m) => Message.fromJson(Map<String, dynamic>.from(m as Map)))
              .toList();
          final list = List<Message>.from(messagesFor(convId));
          var convDirty = false;
          for (final msg in cached) {
            if (!list.any((m) => m.id == msg.id)) {
              list.add(msg);
              convDirty = true;
            }
          }
          if (convDirty) {
            list.sort(_compareMessagesChronologically);
            _messages[convId] = list;
            if (list.isNotEmpty) {
              _upsertConvFromMessage(
                convId,
                list.last,
                bumpUnread: convId != _activeChatConvId,
              );
            }
            dirty = true;
          }
        } catch (_) {}
      }
      final dirtyAt = prefs.getInt(StorageKeys.recentsDirtyAt) ?? 0;
      if (dirty) notifyListeners();
      if (dirtyAt > 0) {
        await prefs.remove(StorageKeys.recentsDirtyAt);
        _scheduleAutoRefresh(refreshActiveChat: false);
      }
    } catch (_) {}
  }

  /// Stop ringtone + drop expired pending offers (old sessions).
  Future<void> purgeStaleCallState() async {
    await AudioService().stop();
    var cleared = false;

    if (_incomingCall != null) {
      final live = CallAlertService().normalizeCallData(_incomingCall!);
      if (!CallAlertService.isOfferFresh(live)) {
        _incomingCall = null;
        cleared = true;
      }
    }

    final pending = await CallAlertService().loadPendingCall();
    if (pending != null) {
      final n = CallAlertService().normalizeCallData(pending);
      if (!CallAlertService.isOfferFresh(n)) {
        await CallAlertService().clearPendingCall();
        cleared = true;
      }
    }

    if (cleared) {
      await NotificationService().cancelCallNotification();
      notifyListeners();
    }
  }

  void _startStaleCallWatchdog() {
    _staleCallWatchdog?.cancel();
    _staleCallWatchdog = Timer.periodic(const Duration(seconds: 12), (_) {
      if (!_isLoggedIn) return;
      unawaited(purgeStaleCallState());
    });
  }

  Future<void> restorePendingIncomingCall({bool playRing = true}) async {
    await purgeStaleCallState();
    if (_incomingCall != null) return;
    if (_activeCallPeer != null || _inActiveCallUi) {
      await CallAlertService().clearPendingCall();
      return;
    }
    final pending = await CallAlertService().loadPendingCall();
    if (pending == null) return;
    final normalized = CallAlertService().normalizeCallData(pending);
    if (!CallAlertService.isOfferFresh(normalized)) {
      await CallAlertService().stopAll();
      return;
    }
    final callerId = normalized['from_user_id']?.toString() ?? '';
    if (callerId.isNotEmpty && await _isCallerDismissed(callerId)) {
      await CallAlertService().clearPendingCall();
      return;
    }
    _presentIncomingCall(normalized);
    if (playRing && !AudioService().isPlaying) {
      await AudioService().playIncomingCall();
    }
  }

  List<Message> messagesFor(int convId) => _messages[convId] ?? [];
  String messageUiKey(Message m) {
    final known = _clientMsgKeys[m.id];
    if (known != null) return known;
    // Keep every bubble distinct even while optimistic/Nearby rows have
    // temporary or repeated IDs; duplicate keys can crash Flutter's list
    // element reconciliation during a live message update.
    return 'msg-${m.id}-${m.senderId}-${m.createdAt.microsecondsSinceEpoch}-${m.type}-${(m.content ?? '').hashCode}';
  }

  bool _contentMatches(String? a, String? b) =>
      (a ?? '').trim() == (b ?? '').trim();

  bool _sameMessageList(List<Message> a, List<Message> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      if (x.id != y.id ||
          x.status != y.status ||
          x.content != y.content ||
          x.isDeleted != y.isDeleted ||
          x.type != y.type) {
        return false;
      }
    }
    return true;
  }

  bool _isOwnMessage(Message msg) =>
      msg.senderId == (_me?.id ?? 0) && (_me?.id ?? 0) > 0;

  void _registerPendingKey(int tempId) {
    _clientMsgKeys[tempId] = 'c-$tempId';
  }

  void _transferClientKey(int fromId, int toId) {
    final key = _clientMsgKeys.remove(fromId);
    if (key != null)
      _clientMsgKeys[toId] = key;
    else
      _clientMsgKeys[toId] = 'msg-$toId';
  }

  Message? _parseSendResponse(Map<String, dynamic> r, int convId) {
    if (r['success'] != true) return null;
    final raw = r['message'];
    if (raw is! Map || raw['id'] == null) return null;
    final m = Map<String, dynamic>.from(raw);
    if (m['conversation_id'] == null) m['conversation_id'] = convId;
    try {
      return Message.fromJson(m);
    } catch (_) {
      return null;
    }
  }

  /// Merge server list with local — never wipe committed messages on empty API response.
  List<Message> _mergeServerMessages(int convId, List<Message> serverMsgs) {
    final existing = messagesFor(convId);
    if (serverMsgs.isEmpty) return existing;

    final byId = <int, Message>{};
    for (final m in existing) {
      if (m.id > 0 || m.status == 'sent_nearby') byId[m.id] = m;
    }
    for (final m in serverMsgs) {
      byId[m.id] = m;
    }

    final pending = existing
        .where(
          (m) =>
              m.status != 'sent_nearby' &&
              (m.id < 0 || m.status == 'sending' || m.status == 'failed'),
        )
        .toList();
    final merged = byId.values.toList();
    final myId = _me?.id ?? 0;
    for (final p in pending) {
      final dup = merged.any(
        (m) =>
            (m.senderId == p.senderId || m.senderId == myId) &&
            m.type == p.type &&
            _contentMatches(m.content, p.content) &&
            m.createdAt.difference(p.createdAt).inSeconds.abs() < 45,
      );
      if (!dup) merged.add(p);
    }
    merged.sort(_compareMessagesChronologically);
    return merged;
  }

  void _failPendingMessage(int convId, int tempId) {
    final list = List<Message>.from(messagesFor(convId));
    final idx = list.indexWhere((m) => m.id == tempId);
    if (idx >= 0) {
      list[idx] = list[idx].copyWith(status: 'failed');
      _messages[convId] = list;
    }
  }

  /// Drop a message straight into a conversation's list without going
  /// through the server — used for messages sent/received over a direct
  /// offline link (Nearby/Bluetooth) where there's no server round trip to
  /// wait on. Notifies listeners so the open chat screen updates live.
  void injectLocalMessage(int convId, Message msg) {
    _commitMessage(convId, msg);
    notifyListeners();
  }

  /// Insert or replace — never leaves temp + real duplicates for the same send.
  void _commitMessage(int convId, Message msg, {int? replaceTempId}) {
    final list = List<Message>.from(messagesFor(convId));
    final myId = _me?.id ?? 0;
    int? keyFromId = replaceTempId;

    if (replaceTempId != null) list.removeWhere((m) => m.id == replaceTempId);

    final idx = list.indexWhere((m) => m.id == msg.id);
    if (idx >= 0) {
      list[idx] = msg;
    } else {
      final pendingIdx = list.indexWhere(
        (m) =>
            m.status != 'sent_nearby' &&
            msg.status != 'sent_nearby' &&
            (m.id < 0 || m.status == 'sending') &&
            (m.senderId == msg.senderId || m.senderId == myId) &&
            m.type == msg.type &&
            _contentMatches(m.content, msg.content),
      );
      if (pendingIdx >= 0) {
        keyFromId ??= list[pendingIdx].id;
        list[pendingIdx] = msg;
      } else {
        list.add(msg);
      }
    }

    if (keyFromId != null && keyFromId != msg.id) {
      _transferClientKey(keyFromId, msg.id);
    } else if (!_clientMsgKeys.containsKey(msg.id)) {
      _clientMsgKeys[msg.id] = 'msg-${msg.id}';
    }

    list.sort(_compareMessagesChronologically);
    _messages[convId] = list;
  }

  bool messagesLoading(int convId) => _messagesLoading[convId] == true;
  String? messagesError(int convId) => _messagesErrors[convId];
  bool isTyping(int convId) => _typingMap[convId] ?? false;
  bool isRecording(int convId) => _recordingMap[convId] ?? false;

  // ChatScreen renders this list with reverse:true, so the provider must keep
  // it strictly oldest -> newest. Server timestamps are only second-precision
  // on some responses; using the id as a deterministic tie-breaker prevents
  // a newly sent message from jumping above an older bubble. Temporary local
  // ids are negative and represent the newest optimistic message.
  int _compareMessagesChronologically(Message a, Message b) {
    final byTime = a.createdAt.compareTo(b.createdAt);
    if (byTime != 0) return byTime;
    if (a.id < 0 && b.id >= 0) return 1;
    if (a.id >= 0 && b.id < 0) return -1;
    return a.id.compareTo(b.id);
  }

  // Show the typing bubble locally (e.g. while AI generates an image)
  void setLocalTyping(int convId, bool typing) {
    _typingMap[convId] = typing;
    notifyListeners();
  }

  Timer? _tokenCheckTimer;
  Timer? _onlineHeartbeat;
  Timer? _recentsRefreshTimer;
  Timer? _inactiveAccountsPoll;
  Timer? _convListDebounce;
  final Set<int> _optimisticConvIds = {};
  final Map<int, int> _recentlyReadAt = {};
  final Completer<void> _initCompleter = Completer<void>();

  /// Await before routing to home/login so saved token is restored first.
  Future<void> get ready => _initCompleter.future;

  AppProvider() {
    // Creating the provider happens while Flutter is assembling its very
    // first frame. Give that branded splash one frame to reach Android before
    // SharedPreferences/account restoration starts invoking platform plugins;
    // otherwise slower OEM builds can report several seconds of skipped
    // frames even though all startup work is asynchronous at the Dart level.
    Future.delayed(const Duration(milliseconds: 250), _init);
  }

  Future<void> _init() async {
    try {
      // Bounded: a slow/unreachable network must never leave the app stuck on
      // the blank bootstrap screen forever — fall through to cached state.
      await _initBody().timeout(const Duration(seconds: 12));
    } catch (_) {
    } finally {
      if (!_initCompleter.isCompleted) _initCompleter.complete();
    }
  }

  Future<void> _initBody() async {
    final prefs = await SharedPreferences.getInstance();
    await _restoreReadMarkers(prefs);
    unawaited(_loadNicknames());
    // One-time wipe of cached conversations/messages — clears any chats that
    // leaked across accounts in older builds so everything reloads clean.
    if (prefs.getString('cache_wipe_v18') != '1') {
      for (final k in prefs.getKeys().toList()) {
        if (k.startsWith('conv_cache_') ||
            k.startsWith('msg_cache_') ||
            k == 'conv_cache') {
          await prefs.remove(k);
        }
      }
      await prefs.setString('cache_wipe_v18', '1');
    }
    final savedTheme = prefs.getString('theme_mode') ?? 'light';
    _themeMode = savedTheme == 'dark' ? ThemeMode.dark : ThemeMode.light;
    _fontScale = prefs.getDouble('font_scale') ?? 1.0;
    _chatWallpaper = prefs.getString('chat_wallpaper');

    final token = prefs.getString('phoneopia_token');
    if (token != null) {
      ApiService.primeToken(token);
      _isLoggedIn = true;
      // Restore cached user, but validate against the stored active account
      // to prevent showing the wrong person's data (e.g. leftover from a
      // previous account that wasn't properly logged out).
      _restoreCachedUser(prefs);
      final activeUserId = await _accountService.activeUserId();
      if (_me != null && activeUserId != null && _me!.id != activeUserId) {
        // Cached user doesn't match the active account — try to restore the
        // correct account's data from the account store.
        final correctAcc = await _accountService.accountById(activeUserId);
        if (correctAcc != null && correctAcc.token.isNotEmpty) {
          await ApiService.setToken(correctAcc.token);
          if (correctAcc.userJson.isNotEmpty) {
            _me = User.fromJson(correctAcc.userJson);
          }
        }
      }
      // Start local discovery immediately from the cached account. Nearby
      // must not wait for the network bootstrap/conversation API calls; when
      // internet is slow or unavailable, both phones still need to advertise
      // and discover each other locally.
      if (_me != null) {
        unawaited(
          NearbyService().start(
            _me!.displayName.isNotEmpty ? _me!.displayName : _me!.username,
            _me!.id,
          ),
        );
        _listenNearbyMessages();
        _listenNearbyFiles();
        _listenNearbyCallSignals();
        NearbyService().removeListener(_onNearbyChanged);
        NearbyService().addListener(_onNearbyChanged);
      }
      await _migrateLegacyAccount(token, prefs);
      _dismissedCallers.addAll(await CallAlertService().loadDismissedCallers());
      _inActiveCallUi = false;
      _activeCallPeer = null;
      _incomingCall = null;
      await AudioService().stop();
      await NotificationService().cancelCallNotification();
      await purgeStaleCallState();
      notifyListeners();
      final meOk = await _loadMe(validateAccount: true);
      if (!meOk) {
        await _invalidateSession();
        return;
      }
      // Start the realtime call/message channel before the heavier initial
      // conversations/status/call-log loads. Otherwise an incoming call
      // arriving during bootstrap waited for all three requests to finish.
      _connectWs();
      // Load all data in parallel for faster startup
      await Future.wait([loadConversations(), loadStatuses(), loadCalls()]);
      unawaited(_ensurePushRegistered());
      _startTokenCheck();
      _startOnlineHeartbeat();
      startRecentsAutoRefresh();
      _startStaleCallWatchdog();
      _startInactiveAccountsPoll();
      await startBackgroundService();
      await refreshRecents();
      await restorePendingIncomingCall(playRing: false);
      // Nearby (Bluetooth/WiFi Direct) previously only started right after
      // a fresh phone+OTP login — it never ran again for a normal app
      // relaunch that restores an existing saved session, which is by far
      // the more common case. Start it here too.
      if (_me != null) {
        unawaited(
          NearbyService().start(
            _me!.displayName.isNotEmpty ? _me!.displayName : _me!.username,
            _me!.id,
          ),
        );
        _listenNearbyMessages();
        _listenNearbyFiles();
        _listenNearbyCallSignals();
        NearbyService().addListener(_onNearbyChanged);
      }
    }
  }

  void _restoreCachedUser(SharedPreferences prefs) {
    try {
      final raw = prefs.getString('phoneopia_user');
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      if (j is Map) {
        _me = User.fromJson(Map<String, dynamic>.from(j));
      }
    } catch (_) {}
  }

  Future<void> _migrateLegacyAccount(
    String token,
    SharedPreferences prefs,
  ) async {
    try {
      // This is migration code, not a startup sync. Running it on every launch
      // could pair a stale cached user with another account's current token and
      // corrupt the multi-account list. Existing account stores need no migration.
      if ((await _accountService.loadAccounts()).isNotEmpty) return;
      final raw = prefs.getString('phoneopia_user');
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      if (j is Map) {
        await _accountService.upsertAccount(
          token: token,
          user: Map<String, dynamic>.from(j),
        );
      }
    } catch (_) {}
  }

  String _convCacheKey() => 'conv_cache_${_me?.id ?? 0}';

  Future<void> _syncStoredAccount({String? token}) async {
    if (_me == null) return;
    final t = token ?? await ApiService.token;
    if (t == null || t.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('phoneopia_user');
      Map<String, dynamic> user;
      if (raw != null && raw.isNotEmpty) {
        user = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } else {
        user = {
          'id': _me!.id,
          'username': _me!.username,
          'display_name': _me!.displayName,
          'avatar': _me!.avatar,
          'phone': _me!.phone,
        };
      }
      await _accountService.upsertAccount(token: t, user: user);
    } catch (_) {}
  }

  Future<void> _persistUser(Map<String, dynamic> user) async {
    _me = User.fromJson(user);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('phoneopia_user', jsonEncode(user));
    await prefs.setString('phoneopia_user_id', user['id']?.toString() ?? '0');
    await _syncStoredAccount();
    notifyListeners();
  }

  void _clearInMemorySession() {
    _accountEpoch++;
    _conversations = [];
    _messages.clear();
    _clientMsgKeys.clear();
    for (final p in _pendingDeletes.values) {
      p.timer.cancel();
    }
    _pendingDeletes.clear();
    _messagesLoading.clear();
    _messagesErrors.clear();
    _statusGroups = [];
    _callLogs = [];
    _typingMap.clear();
    _recordingMap.clear();
    _incomingCall = null;
    _optimisticConvIds.clear();
    _recentlyReadAt.clear();
    _activeChatConvId = null;
    _inActiveCallUi = false;
    _activeCallPeer = null;
  }

  Future<void> _teardownLiveServices() async {
    _tokenCheckTimer?.cancel();
    _onlineHeartbeat?.cancel();
    _inactiveAccountsPoll?.cancel();
    stopRecentsAutoRefresh();
    _staleCallWatchdog?.cancel();
    await CallAlertService().stopAll();
    await stopBackgroundService();
    // Await this before advertising the next account. Fire-and-forget left
    // the previous account's Bluetooth name/id alive during a fast switch.
    await NearbyService().stop();
    unawaited(SharingService().stop());
    _ws.dispose();
    SseService().stop();
  }

  Future<bool> switchToAccount(int userId) async {
    if (_me?.id == userId) return true;
    final acc = await _accountService.accountById(userId);
    if (acc == null || acc.token.isEmpty) return false;

    // Verify which user this stored token actually belongs to. Besides keeping
    // the header fresh, this prevents a legacy token/user mismatch from opening
    // account A with account B's chats. Offline switching still uses the saved
    // account payload; a confirmed mismatch is the only hard failure.
    Map<String, dynamic>? verifiedUser;
    try {
      final live = await ApiService.getWithToken(
        acc.token,
        'auth.php?action=me',
      ).timeout(const Duration(seconds: 6));
      if (live['success'] == true && live['user'] is Map) {
        final user = Map<String, dynamic>.from(live['user'] as Map);
        final liveId = int.tryParse(user['id']?.toString() ?? '') ?? 0;
        if (liveId > 0 && liveId != userId) return false;
        if (liveId == userId) verifiedUser = user;
      }
    } catch (_) {}

    await _teardownLiveServices();
    _clearInMemorySession();
    // IMPORTANT: do NOT wipe the on-disk caches here. They are per-account
    // (conv_cache_<id>, msg_cache_<id>_*), so there is no cross-account leak —
    // and wiping them left the target account blank until a (possibly slow)
    // network reload finished, which looked like "chats/messages don't load".

    await ApiService.setToken(acc.token);
    await _accountService.setActiveUserId(userId);
    final accountUser =
        verifiedUser ??
        (acc.userJson.isNotEmpty
            ? acc.userJson
            : <String, dynamic>{
                'id': acc.userId,
                'username': acc.username,
                'display_name': acc.displayName,
                'avatar': acc.avatar,
                'phone': acc.phone,
              });
    // Persist even legacy/minimal account entries. The old else branch only
    // changed _me in memory, leaving phoneopia_user / phoneopia_user_id on the
    // previous account; widgets reading preferences kept showing the old name.
    await _persistUser(accountUser);
    _isLoggedIn = true;

    // Show the account immediately with its OWN cached chats, then hydrate live
    // in the background. The switch must not block on the network (that made the
    // "Switching account…" overlay hang for 10s+ on a slow connection).
    notifyListeners();
    // Keep the switching overlay up until this account's own cache/server list
    // has replaced the previous screen. Returning early exposed stale content.
    await loadConversations(showLoading: true);
    unawaited(_hydrateAfterSwitch());
    return true;
  }

  // Live-refresh everything for the just-switched account, off the UI path.
  Future<void> _hydrateAfterSwitch() async {
    try {
      await _loadMe(
        validateAccount: true,
      ); // best-effort; never blocks/reverts the switch
      await Future.wait([loadStatuses(), loadCalls()]);
      _connectWs();
      unawaited(_ensurePushRegistered());
      _startTokenCheck();
      _startOnlineHeartbeat();
      startRecentsAutoRefresh();
      _startStaleCallWatchdog();
      _startInactiveAccountsPoll();
      await startBackgroundService();
      await refreshRecents();
      if (_me != null) {
        await NearbyService().start(
          _me!.displayName.isNotEmpty ? _me!.displayName : _me!.username,
          _me!.id,
        );
        _listenNearbyMessages();
        _listenNearbyFiles();
        _listenNearbyCallSignals();
        NearbyService().removeListener(_onNearbyChanged);
        NearbyService().addListener(_onNearbyChanged);
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> removeAccount(int userId) async {
    final isActive = _me?.id == userId;
    await _accountService.removeAccount(userId);
    if (!isActive) return;
    final remaining = await _accountService.loadAccounts();
    if (remaining.isNotEmpty) {
      await switchToAccount(remaining.first.userId);
      return;
    }
    await _invalidateSession();
  }

  // ── Notification tap → (switch account if needed) → open chat ──────────
  int? _pendingOpenConvId;
  int? get pendingOpenConvId => _pendingOpenConvId;
  void consumePendingOpenConv() {
    _pendingOpenConvId = null;
  }

  bool _switchingAccount = false;
  bool get switchingAccount => _switchingAccount;

  /// Open the chat a notification points to. If the notification belongs to a
  /// DIFFERENT logged-in account, switch to that account first (UI shows a
  /// "Switching account…" overlay via [switchingAccount]).
  Future<void> openChatFromNotification(int convId, int? toUserId) async {
    try {
      if (toUserId != null && toUserId > 0 && toUserId != _me?.id) {
        final acc = await _accountService.accountById(toUserId);
        if (acc != null && acc.token.isNotEmpty) {
          _switchingAccount = true;
          notifyListeners();
          final ok = await switchToAccount(toUserId);
          _switchingAccount = false;
          notifyListeners();
          if (!ok) return;
        }
      } else if (_conversations.isEmpty) {
        await loadConversations();
      }
      _pendingOpenConvId = convId;
      notifyListeners();
    } catch (_) {
      _switchingAccount = false;
      notifyListeners();
    }
  }

  void _startInactiveAccountsPoll() {
    _inactiveAccountsPoll?.cancel();
    _inactiveAccountsPoll = Timer.periodic(const Duration(seconds: 35), (_) {
      if (!_isLoggedIn) return;
      unawaited(_pollInactiveAccounts());
    });
  }

  Future<void> _pollInactiveAccounts() async {
    final activeId = _me?.id;
    if (activeId == null) return;
    final accounts = await _accountService.loadAccounts();
    final snapshots = await _accountService.loadUnreadSnapshots();

    for (final acc in accounts) {
      if (acc.userId == activeId) {
        final total = _conversations.fold<int>(0, (s, c) => s + c.unreadCount);
        await _accountService.saveUnreadSnapshot(acc.userId, total);
        continue;
      }
      try {
        final r = await ApiService.getWithToken(
          acc.token,
          'conversations.php?action=list',
        );
        if (r['success'] != true || r['conversations'] is! List) continue;
        final convs = (r['conversations'] as List)
            .map(
              (c) => Conversation.fromJson(Map<String, dynamic>.from(c as Map)),
            )
            .toList();
        final totalUnread = convs.fold<int>(0, (s, c) => s + c.unreadCount);
        final prev = snapshots[acc.userId.toString()] ?? 0;
        if (totalUnread > prev) {
          Conversation? top;
          for (final c in convs) {
            if (c.unreadCount > 0) {
              top = c;
              break;
            }
          }
          top ??= convs.isNotEmpty ? convs.first : null;
          if (top != null) {
            final peer = top.displayNameFor(myUserId: acc.userId);
            final body = top.lastMessageType == 'call'
                ? _callPreviewFromContent(
                    top.lastMessageContent,
                    top.lastMessageSender,
                    myId: acc.userId,
                  )
                : (top.lastMessageContent?.trim().isNotEmpty == true
                      ? top.lastMessageContent!
                      : 'New message');
            await NotificationService().showMessageNotification(
              convId: 900000000 + acc.userId * 10000 + (top.id % 10000),
              senderName: '${acc.displayName}: $peer',
              body: body,
            );
          }
        }
        await _accountService.saveUnreadSnapshot(acc.userId, totalUnread);
      } catch (_) {}
    }
  }

  int _tokenCheckFailures = 0;

  void _startOnlineHeartbeat() {
    _onlineHeartbeat?.cancel();
    ApiService.post('users.php?action=online_status', {
      'is_online': true,
    }).catchError((_) => <String, dynamic>{});
    _onlineHeartbeat = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!_isLoggedIn) return;
      ApiService.post('users.php?action=online_status', {
        'is_online': true,
      }).catchError((_) => <String, dynamic>{});
    });
  }

  void _startTokenCheck() {
    _tokenCheckTimer?.cancel();
    _tokenCheckFailures = 0;
    // Check every 5 minutes; only force-logout after 3 consecutive failures
    // (avoids kicking out the user on transient network errors)
    // Heartbeat only (keeps "online" status fresh). Tokens never expire now, so
    // the app must NEVER auto-logout — the user stays signed in until they tap
    // Logout themselves. We no longer force-logout on any auth-check result.
    _tokenCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      if (!_isLoggedIn) return;
      try {
        await ApiService.getMe();
      } catch (_) {}
    });
  }

  void _forceLogout() {
    _tokenCheckTimer?.cancel();
    logout();
  }

  Future<bool> _loadMe({bool validateAccount = false}) async {
    final requestEpoch = _accountEpoch;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final r = await ApiService.getMe();
        if (requestEpoch != _accountEpoch) return true;
        if (r['success'] == true && r['user'] != null) {
          final user = Map<String, dynamic>.from(r['user']);
          if (validateAccount && _me != null) {
            final cachedId = _me!.id;
            final liveId = int.tryParse(user['id']?.toString() ?? '') ?? 0;
            if (cachedId > 0 && liveId > 0 && cachedId != liveId) {
              // Server says the token belongs to a DIFFERENT user than cached.
              // Persist the REAL user from the server so the app shows the
              // correct account, not a stale ghost from a leftover session.
              await _persistUser(user);
              return true;
            }
          }
          if (requestEpoch != _accountEpoch) return true;
          await _persistUser(user);
          return true;
        }
      } catch (_) {}
      if (attempt == 0) await Future.delayed(const Duration(milliseconds: 700));
    }
    // getMe never succeeded (transient network). Keep the cached account so
    // the user can still use the app offline — but if validateAccount was
    // requested and we got a mismatch above, we already fixed it.
    return true;
  }

  Future<void> _invalidateSession() async {
    _tokenCheckTimer?.cancel();
    _onlineHeartbeat?.cancel();
    _inactiveAccountsPoll?.cancel();
    _staleCallWatchdog?.cancel();
    _incomingCall = null;
    await CallAlertService().stopAll();
    await stopBackgroundService();
    _ws.dispose();
    SseService().stop();
    final uid = _me?.id;
    await ApiService.clearActiveSession(userId: uid);
    _me = null;
    _clearInMemorySession();
    _isLoggedIn = false;
    notifyListeners();
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (r) => false);
  }

  Future<bool> login(String phone, String otp) async {
    final result = await loginWithResult(phone, otp);
    return result['success'] == true;
  }

  /// Log in using an auth token obtained by showing a QR that another logged-in
  /// device scanned (qr.php poll → status:scanned). Mirrors loginWithResult's
  /// success path but skips OTP.
  Future<bool> loginFromQr(String token, Map<String, dynamic>? user) async {
    if (token.isEmpty) return false;
    _loading = true;
    notifyListeners();
    try {
      await ApiService.setToken(token);
      _clearInMemorySession();
      // Caches are per-account (conv_cache_<id>), so the scanned account only ever
      // reads its own cache — no need to wipe every account's cache (that blanked
      // other accounts until a network reload).
      _isLoggedIn = true;
      if (user != null && user.isNotEmpty) {
        await _persistUser(Map<String, dynamic>.from(user));
      } else {
        await _loadMe();
      }
      await Future.wait([loadConversations(), loadStatuses()]);
      _connectWs();
      unawaited(_ensurePushRegistered());
      _startTokenCheck();
      _startOnlineHeartbeat();
      startRecentsAutoRefresh();
      _startInactiveAccountsPoll();
      await _syncStoredAccount(token: token);
      await startBackgroundService();
      unawaited(refreshRecents());
      _loading = false;
      notifyListeners();
      return true;
    } catch (_) {
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, dynamic>> loginWithResult(String phone, String otp) async {
    _loading = true;
    notifyListeners();
    try {
      final r = await ApiService.verifyOtp(phone, otp);
      final token = r['token']?.toString();
      if (r['success'] == true && token != null && token.isNotEmpty) {
        await ApiService.setToken(token);
        _clearInMemorySession(); // clear in-memory only; per-account disk caches stay
        _isLoggedIn = true;
        if (r['user'] is Map) {
          await _persistUser(Map<String, dynamic>.from(r['user'] as Map));
        } else {
          await _loadMe();
        }
        await Future.wait([loadConversations(), loadStatuses()]);
        _connectWs();
        unawaited(_ensurePushRegistered());
        _startTokenCheck();
        _startOnlineHeartbeat();
        startRecentsAutoRefresh();
        _startInactiveAccountsPoll();
        await _syncStoredAccount(token: token);
        await startBackgroundService();
        if (_me != null) {
          unawaited(
            NearbyService().start(
              _me!.displayName.isNotEmpty ? _me!.displayName : _me!.username,
              _me!.id,
            ),
          );
          _listenNearbyMessages();
          _listenNearbyFiles();
          _listenNearbyCallSignals();
          // Re-sort the chat list the instant a nearby link connects or
          // drops — that's when "who's reachable right now" actually changes.
          NearbyService().addListener(_onNearbyChanged);
        }
        unawaited(refreshRecents());
        _loading = false;
        notifyListeners();
        final isNew = r['is_new_user'] == true || r['is_new_user'] == 1;
        return {'success': true, 'is_new_user': isNew};
      }
      _error =
          r['error']?.toString() ?? r['message']?.toString() ?? 'Invalid OTP';
    } catch (e) {
      _error = 'Network error. Check connection and try again.';
    }
    _loading = false;
    notifyListeners();
    return {'success': false, 'error': _error};
  }

  Future<void> logout() async {
    final currentId = _me?.id;
    ApiService.post('users.php?action=online_status', {
      'is_online': false,
    }).catchError((_) => <String, dynamic>{});
    await _teardownLiveServices();
    try {
      NotificationService().cancelAll();
    } catch (_) {}
    // ── Full account cleanup — remove ALL traces from this device ──
    try {
      final prefs = await SharedPreferences.getInstance();
      // Remove ALL per-account disk caches so no stale messages/calls remain
      final keys = prefs.getKeys().toList();
      for (final k in keys) {
        if (k.startsWith('conv_cache_') ||
            k.startsWith('msg_cache_') ||
            k.startsWith('contact_nickname_') ||
            k == 'phoneopia_token' ||
            k == StorageKeys.callAlertPendingCall ||
            k == StorageKeys.appForegroundAt) {
          await prefs.remove(k);
        }
      }
      await CallAlertService().clearPendingCall();
    } catch (_) {}
    if (currentId != null) {
      await _accountService.removeAccount(currentId);
    } else {
      await ApiService.clearActiveSession();
    }
    _me = null;
    _clearInMemorySession();
    _isLoggedIn = false;
    notifyListeners();

    // Explicit logout always goes to the login screen — never auto-switches to
    // another saved account (that made the Logout button look like it did nothing).
    navigatorKey.currentState?.pushNamedAndRemoveUntil('/login', (r) => false);
  }

  Conversation? conversationById(int id) {
    for (final c in _conversations) {
      if (c.id == id) return c;
    }
    return null;
  }

  // Local per-contact nickname override (like WhatsApp's "edit contact" —
  // renames how a person shows up for you only, doesn't touch their account).
  final Map<int, String> _nicknames = {};
  String _nicknameKey(int userId) => 'contact_nickname_$userId';

  Future<void> _loadNicknames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        if (k.startsWith('contact_nickname_')) {
          final id = int.tryParse(k.substring('contact_nickname_'.length));
          final v = prefs.getString(k);
          if (id != null && v != null && v.isNotEmpty) _nicknames[id] = v;
        }
      }
    } catch (_) {}
  }

  String? nicknameFor(int userId) => _nicknames[userId];

  Future<void> setNickname(int userId, String name) async {
    final trimmed = name.trim();
    final prefs = await SharedPreferences.getInstance();
    if (trimmed.isEmpty) {
      _nicknames.remove(userId);
      await prefs.remove(_nicknameKey(userId));
    } else {
      _nicknames[userId] = trimmed;
      await prefs.setString(_nicknameKey(userId), trimmed);
    }
    notifyListeners();
  }

  String peerDisplayName(Conversation c) {
    final ouId = c.otherUser?.id;
    if (ouId != null && _nicknames.containsKey(ouId)) return _nicknames[ouId]!;
    return sanitizeConversation(c).displayNameFor(myUserId: _me?.id);
  }

  String peerAvatar(Conversation c) =>
      sanitizeConversation(c).displayAvatarFor(myUserId: _me?.id);

  Conversation sanitizeConversation(Conversation c) => _sanitizeDirectConv(c);

  User? _peerFromMessages(int convId, {int? preferId}) {
    final myId = _me?.id ?? 0;
    final msgs = messagesFor(convId);
    if (preferId != null && preferId > 0 && preferId != myId) {
      for (final m in msgs) {
        if (m.senderId == preferId) {
          final dn = m.senderName?.trim() ?? '';
          return User(
            id: m.senderId,
            username: m.senderUsername ?? '',
            displayName: dn.isNotEmpty ? dn : 'User',
            avatar: m.senderAvatar,
          );
        }
      }
    }
    for (final m in msgs.reversed) {
      if (m.senderId > 0 && m.senderId != myId) {
        final dn = m.senderName?.trim() ?? '';
        if (dn.isEmpty) continue;
        return User(
          id: m.senderId,
          username: m.senderUsername ?? '',
          displayName: dn,
          avatar: m.senderAvatar,
        );
      }
    }
    return null;
  }

  bool _isSelfLabel(String? name) {
    if (name == null || name.trim().isEmpty) return false;
    final me = _me;
    if (me == null) return false;
    final n = name.trim();
    return n == me.displayName || n == me.username || n == 'Chat';
  }

  Conversation _withPeer(
    Conversation c, {
    User? otherUser,
    String? name,
    String? avatar,
  }) {
    final ou = otherUser ?? c.otherUser;
    final peerName = ou != null
        ? (ou.displayName.trim().isNotEmpty ? ou.displayName : ou.username)
        : (name ?? c.name);
    return Conversation(
      id: c.id,
      type: c.type,
      name: peerName,
      description: c.description,
      avatar: avatar ?? ou?.avatar ?? c.avatar,
      otherUser: ou,
      members: c.members,
      pastMembers: c.pastMembers,
      myRole: c.myRole,
      createdBy: c.createdBy,
      lastMessageContent: c.lastMessageContent,
      lastMessageType: c.lastMessageType,
      lastMessageSender: c.lastMessageSender,
      lastMessageAt: c.lastMessageAt,
      unreadCount: c.unreadCount,
      isPinned: c.isPinned,
      isMuted: c.isMuted,
      memberCount: c.memberCount,
    );
  }

  Conversation _sanitizeDirectConv(Conversation c) {
    if (c.type != 'direct' || _me == null) return c;
    final me = _me!;
    var ou = c.otherUser;
    if (ou != null && ou.id == me.id) ou = null;

    final preferSender =
        c.lastMessageSender != null && c.lastMessageSender != me.id
        ? c.lastMessageSender
        : null;
    ou ??= _peerFromMessages(c.id, preferId: preferSender);

    if (ou != null && ou.id != me.id) {
      return _withPeer(c, otherUser: ou);
    }

    if (!_isSelfLabel(c.name) && c.name.trim().isNotEmpty) return c;

    unawaited(refreshConversationMeta(c.id));
    return c;
  }

  /// Fetch peer name/avatar from server for direct chats showing "Chat".
  Future<void> refreshConversationMeta(int convId) async {
    if (convId <= 0) return;
    try {
      final fresh = await ApiService.getConversation(convId);
      if (fresh == null) return;
      final idx = _conversations.indexWhere((c) => c.id == convId);
      if (idx < 0) {
        ensureConvInList(fresh);
        return;
      }
      final old = _conversations[idx];
      User? ou = fresh.otherUser;
      if (ou == null && fresh.type == 'direct') {
        for (final m in fresh.members) {
          if (m.id != (_me?.id ?? 0)) {
            ou = User(
              id: m.id,
              username: m.username ?? '',
              displayName: m.displayName,
              avatar: m.avatar,
            );
            break;
          }
        }
      }
      final lT = old.lastMessageAt?.millisecondsSinceEpoch ?? 0;
      final sT = fresh.lastMessageAt?.millisecondsSinceEpoch ?? 0;
      // Respect the read guard: if this chat is open or was just read, never let
      // the server's (possibly still-stale) unread count re-add the badge.
      _conversations[idx] = _sanitizeDirectConv(
        _convCopy(
          _withPeer(
            lT >= sT ? old : fresh,
            otherUser: ou ?? old.otherUser,
            name: fresh.name,
            avatar: fresh.avatar,
          ),
          unreadCount: _mergeServerUnread(fresh),
        ),
      );
      notifyListeners();
      unawaited(_saveCachedConversations(_conversations));
    } catch (_) {}
  }

  Conversation _convCopy(
    Conversation c, {
    String? lastMessageContent,
    String? lastMessageType,
    int? lastMessageSender,
    DateTime? lastMessageAt,
    int? unreadCount,
  }) => Conversation(
    id: c.id,
    type: c.type,
    name: c.name,
    description: c.description,
    avatar: c.avatar,
    otherUser: c.otherUser,
    members: c.members,
    pastMembers: c.pastMembers,
    myRole: c.myRole,
    createdBy: c.createdBy,
    lastMessageContent: lastMessageContent ?? c.lastMessageContent,
    lastMessageType: lastMessageType ?? c.lastMessageType,
    lastMessageSender: lastMessageSender ?? c.lastMessageSender,
    lastMessageAt: lastMessageAt ?? c.lastMessageAt,
    unreadCount: unreadCount ?? c.unreadCount,
    isPinned: c.isPinned,
    isMuted: c.isMuted,
    memberCount: c.memberCount,
  );

  int _mergeServerUnread(Conversation conv) {
    if (conv.id == _activeChatConvId) return 0;
    final readAt = _recentlyReadAt[conv.id];
    if (readAt != null) {
      final lastMessageAt = conv.lastMessageAt?.millisecondsSinceEpoch;
      // Keep the read state across restarts. The old 2-minute-only guard
      // allowed an old unread badge to return after reopening the app.
      if (lastMessageAt == null || lastMessageAt <= readAt) return 0;
    }
    return conv.unreadCount;
  }

  void _mergeServerConversations(List<Conversation> fresh) {
    final prevMap = {for (final c in _conversations) c.id: c};
    // Reconcile an offline-created chat with its server conversation without
    // losing local history or displaying a second row for the same person.
    for (final server in fresh.where(
      (c) => c.type == 'direct' && c.otherUser != null,
    )) {
      final localId = -server.otherUser!.id;
      final local = prevMap[localId];
      if (local == null) continue;
      final history = messagesFor(localId).map(
        (m) => Message.fromJson({...m.toJson(), 'conversation_id': server.id}),
      );
      final combined = <int, Message>{
        for (final m in messagesFor(server.id)) m.id: m,
      };
      for (final m in history) {
        combined[m.id] = m;
      }
      _messages[server.id] = combined.values.toList()
        ..sort(_compareMessagesChronologically);
      prevMap[server.id] = _convCopy(
        server,
        lastMessageContent: local.lastMessageContent,
        lastMessageType: local.lastMessageType,
        lastMessageSender: local.lastMessageSender,
        lastMessageAt: local.lastMessageAt,
        unreadCount: local.unreadCount,
      );
      prevMap.remove(localId);
      _optimisticConvIds.remove(localId);
      if (_activeChatConvId == localId) _activeChatConvId = server.id;
      unawaited(_saveCachedMessages(server.id, messagesFor(server.id)));
    }

    final merged = fresh.map((server) {
      final local = prevMap[server.id];
      var unread = _mergeServerUnread(server);

      if (local?.lastMessageAt != null) {
        final lT = local!.lastMessageAt!.millisecondsSinceEpoch;
        final sT = server.lastMessageAt?.millisecondsSinceEpoch ?? 0;
        if (lT >= sT) {
          if (sT >= lT) _optimisticConvIds.remove(server.id);
          final mergedUnread = server.id == _activeChatConvId
              ? 0
              : (unread > local.unreadCount ? unread : local.unreadCount);
          return _convCopy(
            server,
            lastMessageContent: local.lastMessageContent,
            lastMessageType: local.lastMessageType,
            lastMessageSender: local.lastMessageSender,
            lastMessageAt: local.lastMessageAt,
            unreadCount: mergedUnread,
          );
        }
      }

      _optimisticConvIds.remove(server.id);
      if (server.id == _activeChatConvId) {
        return _convCopy(server, unreadCount: 0);
      }
      return _convCopy(server, unreadCount: unread);
    }).toList();

    final freshIds = merged.map((c) => c.id).toSet();
    final freshPeerIds = merged
        .where((c) => c.type == 'direct' && c.otherUser != null)
        .map((c) => c.otherUser!.id)
        .toSet();
    for (final local in prevMap.values) {
      if (freshIds.contains(local.id)) continue;
      // The server already has a real conversation with this same person —
      // never re-show a stale nearby/optimistic placeholder for them, even
      // if its id didn't line up exactly with -otherUser.id above.
      if (local.otherUser != null && freshPeerIds.contains(local.otherUser!.id))
        continue;
      // Only keep a conversation the server omitted if it's a genuinely
      // just-created optimistic one. Re-inserting ANY cached conv with old
      // content kept phantoms alive (e.g. a duplicate Phoneopia AI carried
      // over from a previously logged-in account).
      if (local.id < 0 || _optimisticConvIds.contains(local.id))
        merged.insert(0, local);
    }

    merged.sort((a, b) {
      final at = a.lastMessageAt ?? DateTime(2000);
      final bt = b.lastMessageAt ?? DateTime(2000);
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return bt.compareTo(at);
    });

    _conversations = merged.map(_sanitizeDirectConv).toList();

    if (_activeChatConvId != null && _activeChatConvId! > 0) {
      _ensureConvInListById(
        _activeChatConvId!,
        moveTop: true,
        zeroUnread: true,
      );
    }
  }

  void _ensureConvInListById(
    int convId, {
    bool moveTop = false,
    bool zeroUnread = false,
  }) {
    final idx = _conversations.indexWhere((c) => c.id == convId);
    if (idx < 0) return;
    var conv = _conversations[idx];
    if (zeroUnread && conv.unreadCount != 0) {
      conv = _convCopy(conv, unreadCount: 0);
    }
    if (moveTop && idx > 0) {
      _conversations.removeAt(idx);
      _conversations.insert(0, conv);
    } else if (zeroUnread) {
      _conversations[idx] = conv;
    }
  }

  /// Keep a chat visible in recents (e.g. when opening a new/direct chat).
  void ensureConvInList(Conversation conv, {bool moveTop = false}) {
    if (conv.id == 0) return;
    final idx = _conversations.indexWhere((c) => c.id == conv.id);
    if (idx < 0) {
      // A real (server) conversation for this person is arriving — drop any
      // stale nearby/offline placeholder for the same peer immediately
      // instead of leaving two rows for one person until the next sync.
      if (conv.id > 0 && conv.type == 'direct' && conv.otherUser != null) {
        _conversations.removeWhere(
          (c) => c.id < 0 && c.otherUser?.id == conv.otherUser!.id,
        );
      }
      _conversations.insert(0, _sanitizeDirectConv(conv));
      _optimisticConvIds.add(conv.id);
      _sortConversations();
      unawaited(_saveCachedConversations(_conversations));
      notifyListeners();
      if (conv.otherUser == null || _isSelfLabel(conv.name)) {
        unawaited(refreshConversationMeta(conv.id));
      }
      return;
    }
    final old = _conversations[idx];
    final needsPeer = old.otherUser == null || _isSelfLabel(old.name);
    final incomingPeer = conv.otherUser != null && !_isSelfLabel(conv.name);
    if (needsPeer && incomingPeer) {
      _conversations[idx] = _sanitizeDirectConv(
        _withPeer(
          old,
          otherUser: conv.otherUser,
          name: conv.name,
          avatar: conv.avatar,
        ),
      );
      notifyListeners();
    }
    if (moveTop && idx > 0) {
      final c = _conversations.removeAt(idx);
      _conversations.insert(0, c);
      notifyListeners();
    }
  }

  Future<void> loadConversations({bool showLoading = false}) async {
    final requestEpoch = _accountEpoch;
    final requestUserId = _me?.id ?? 0;
    bool isCurrentRequest() =>
        requestEpoch == _accountEpoch &&
        requestUserId > 0 &&
        _me?.id == requestUserId;
    if (showLoading) {
      _loading = true;
      notifyListeners();
    }
    try {
      final cached = await _loadCachedConversations(requestUserId);
      if (!isCurrentRequest()) return;
      if (cached.isNotEmpty) {
        for (final c in cached) {
          if (c.id != 0 && !_conversations.any((x) => x.id == c.id)) {
            _conversations.add(c);
          }
        }
        if (_conversations.isNotEmpty) notifyListeners();
      }
      List<Conversation> fresh;
      try {
        fresh = await ApiService.getConversations();
      } catch (_) {
        // A fresh install/login has no local cache to fall back on, so a
        // single transient failure right here (auth token not fully
        // propagated yet, a brief network hiccup) used to leave the chat
        // list looking permanently empty — indistinguishable from actually
        // having lost every conversation — with no retry at all. Only
        // matters when there's nothing already on screen to fall back to;
        // if conversations already loaded fine before, let the outer catch
        // below handle it same as always.
        if (_conversations.isNotEmpty) rethrow;
        await Future.delayed(const Duration(seconds: 2));
        if (!isCurrentRequest()) return;
        fresh = await ApiService.getConversations();
      }
      if (!isCurrentRequest()) return;
      if (fresh.isNotEmpty) {
        _mergeServerConversations(fresh);
        // Server is authoritative for which chats this account has — drop any
        // cached conversation it didn't return (stops another account's chats,
        // e.g. its Phoneopia AI, from leaking in).
        final freshIds = fresh.map((c) => c.id).toSet();
        _conversations.removeWhere((c) => c.id > 0 && !freshIds.contains(c.id));
      } else if (_conversations.isEmpty && cached.isNotEmpty) {
        _conversations = cached;
      }
      await _saveCachedConversations(_conversations, userId: requestUserId);
      if (!isCurrentRequest()) return;
      notifyListeners();
    } catch (_) {}
    if (showLoading && isCurrentRequest()) {
      _loading = false;
      notifyListeners();
    }
  }

  Future<List<Conversation>> _loadCachedConversations(int userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Account-scoped cache ONLY. The old global 'conv_cache' key leaked the
      // previous account's chats (e.g. a duplicate Phoneopia AI) into a newly
      // switched account, so it must never be read as a fallback.
      unawaited(
        prefs.remove('conv_cache'),
      ); // purge the leaky legacy global cache
      final raw = prefs.getString('conv_cache_$userId');
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((c) => Conversation.fromJson(Map<String, dynamic>.from(c)))
          .map((c) => _convCopy(c, unreadCount: _mergeServerUnread(c)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveCachedConversations(
    List<Conversation> convs, {
    int? userId,
  }) async {
    try {
      final targetUserId = userId ?? _me?.id ?? 0;
      if (targetUserId <= 0) return;
      final prefs = await SharedPreferences.getInstance();
      final payload = convs
          .map(
            (c) => {
              'id': c.id,
              'type': c.type,
              'name': c.name,
              'avatar': c.avatar,
              'unread_count': c.unreadCount,
              'is_pinned': c.isPinned ? 1 : 0,
              'last_message_content': c.lastMessageContent,
              'last_message_type': c.lastMessageType,
              'last_message_at': c.lastMessageAt?.toIso8601String(),
              if (c.otherUser != null)
                'other_user': {
                  'id': c.otherUser!.id,
                  'username': c.otherUser!.username,
                  'display_name': c.otherUser!.displayName,
                  'avatar': c.otherUser!.avatar,
                  'status_message': c.otherUser!.statusMessage,
                  'is_online': c.otherUser!.isOnline ? 1 : 0,
                  'last_seen': c.otherUser!.lastSeen?.toIso8601String(),
                },
            },
          )
          .toList();
      await prefs.setString('conv_cache_$targetUserId', jsonEncode(payload));
    } catch (_) {}
  }

  void _updateUserPresence(
    int userId, {
    required bool isOnline,
    DateTime? lastSeen,
  }) {
    var changed = false;
    _conversations = _conversations.map((c) {
      final ou = c.otherUser;
      if (ou == null || ou.id != userId) return c;
      changed = true;
      return Conversation(
        id: c.id,
        type: c.type,
        name: c.name,
        description: c.description,
        avatar: c.avatar,
        otherUser: ou.copyWith(
          isOnline: isOnline,
          status: isOnline ? 'online' : 'offline',
          lastSeen: lastSeen ?? ou.lastSeen,
        ),
        members: c.members,
        pastMembers: c.pastMembers,
        myRole: c.myRole,
        createdBy: c.createdBy,
        lastMessageContent: c.lastMessageContent,
        lastMessageType: c.lastMessageType,
        lastMessageSender: c.lastMessageSender,
        lastMessageAt: c.lastMessageAt,
        unreadCount: c.unreadCount,
        isPinned: c.isPinned,
        isMuted: c.isMuted,
        memberCount: c.memberCount,
      );
    }).toList();
    if (changed) notifyListeners();
  }

  Future<void> loadStatuses({bool silent = false}) async {
    final epoch = _accountEpoch;
    final userId = _me?.id;
    if (!silent) _statusesLoading = true;
    _statusesError = null;
    if (!silent) notifyListeners();
    try {
      final r = await ApiService.get('statuses.php?action=list');
      if (epoch != _accountEpoch || userId != _me?.id) return;
      if (r['success'] == true && r['groups'] is List) {
        _statusGroups = (r['groups'] as List)
            .map((g) => Map<String, dynamic>.from(g as Map))
            .toList();
        _statusesError = null;
        if (_statusGroups.isEmpty ||
            _statusGroups.every((g) => g['is_me'] != true)) {
          _ensureDefaultStatusGroup();
        }
      } else {
        _statusesError = r['error']?.toString() ?? 'Failed to load updates';
        _ensureDefaultStatusGroup();
      }
    } catch (_) {
      _statusesError = 'Network error';
      _ensureDefaultStatusGroup();
    }
    _statusesLoading = false;
    notifyListeners();
  }

  void _ensureDefaultStatusGroup() {
    if (_statusGroups.isNotEmpty) return;
    final u = _me;
    _statusGroups = [
      {
        'is_me': true,
        'all_viewed': true,
        'statuses': <dynamic>[],
        'user': {
          'id': u?.id,
          'display_name': u?.displayName ?? 'Me',
          'username': u?.username ?? 'me',
          'avatar': u?.avatar,
        },
      },
    ];
  }

  Future<void> loadCalls() async {
    final epoch = _accountEpoch;
    final userId = _me?.id;
    try {
      final r = await ApiService.get('calls.php?action=list');
      if (epoch != _accountEpoch || userId != _me?.id) return;
      if (r['success'] == true && r['calls'] is List) {
        _callLogs = (r['calls'] as List)
            .map((c) => Map<String, dynamic>.from(c as Map))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  int conversationIdForPeer(int peerId) => _resolveDirectConvId(peerId);

  int _resolveDirectConvId(int peerId) {
    if (peerId <= 0) return 0;
    for (final c in _conversations) {
      if (c.type == 'direct' && c.otherUser?.id == peerId) return c.id;
    }
    return 0;
  }

  Future<void> logCall({
    required int peerId,
    required bool isOutgoing,
    required int convId,
    required String status,
    int duration = 0,
    bool isVideo = false,
  }) async {
    if (peerId <= 0) return;
    final resolvedConv = convId > 0 ? convId : _resolveDirectConvId(peerId);
    Map? chatRaw;
    try {
      final body = {
        'peer_id': peerId,
        'is_outgoing': isOutgoing,
        'conversation_id': resolvedConv,
        'type': isVideo ? 'video' : 'audio',
        'status': status,
        'duration': duration,
      };
      // A transient network blip must never silently lose the call-log
      // message — retry once before giving up.
      Map<String, dynamic> r;
      try {
        r = await ApiService.post('calls.php?action=log', body);
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 500));
        r = await ApiService.post('calls.php?action=log', body);
      }
      chatRaw = r['chat_message'] ?? r['message'];
      if (chatRaw is Map) {
        final msg = _parseIncomingMessage({
          'message': chatRaw,
          'conversation_id': resolvedConv > 0
              ? resolvedConv
              : chatRaw['conversation_id'],
        });
        if (msg != null) _applyIncomingMessage(msg);
      }
      await loadCalls();
      final refreshId = resolvedConv > 0
          ? resolvedConv
          : (chatRaw is Map
                ? int.tryParse(chatRaw['conversation_id']?.toString() ?? '') ??
                      0
                : 0);
      if (refreshId > 0) await loadMessages(refreshId, refresh: true);
      await refreshRecents();
    } catch (_) {}
  }

  Future<void> loadMessages(
    int convId, {
    bool refresh = false,
    bool silent = false,
  }) async {
    if (convId == 0) return;
    final epoch = _accountEpoch;
    final userId = _me?.id;
    if (!refresh &&
        _messages.containsKey(convId) &&
        _messagesErrors[convId] == null)
      return;

    // Must be in memory before anything below (including the sync
    // _mergeServerMessages call further down) can filter against it.
    await _loadClearedAt(convId);

    if (!_messages.containsKey(convId) || _messages[convId]!.isEmpty) {
      final cached = _dropCleared(convId, await _loadCachedMessages(convId));
      if (cached.isNotEmpty) {
        _messages[convId] = cached;
        notifyListeners();
      }
    }

    if (convId < 0) return;
    final peerId = conversationById(convId)?.otherUser?.id;
    if (peerId != null) {
      final local = _dropCleared(convId, await _loadCachedMessages(-peerId));
      if (epoch != _accountEpoch || userId != _me?.id) return;
      final combined = <int, Message>{
        for (final m in messagesFor(convId)) m.id: m,
      };
      for (final m in local) {
        combined.putIfAbsent(
          m.id,
          () => Message.fromJson({...m.toJson(), 'conversation_id': convId}),
        );
      }
      _messages[convId] = combined.values.toList()
        ..sort(_compareMessagesChronologically);
    }
    final before = List<Message>.from(messagesFor(convId));
    final hasLocal = before.isNotEmpty;
    var showLoading = !silent && !hasLocal;
    if (showLoading) {
      _messagesLoading[convId] = true;
      notifyListeners();
    }
    _messagesErrors[convId] = null;

    try {
      final msgs = await ApiService.getMessages(convId);
      if (epoch != _accountEpoch || userId != _me?.id) return;
      _messages[convId] = _mergeServerMessages(
        convId,
        _dropCleared(convId, msgs),
      );
      _messagesErrors[convId] = null;
      if (_messages[convId]!.isNotEmpty) {
        await _saveCachedMessages(convId, _messages[convId]!);
      }
      final conv = conversationById(convId);
      if (conv != null && (conv.otherUser == null || _isSelfLabel(conv.name))) {
        final peer = _peerFromMessages(convId);
        if (peer != null) {
          final idx = _conversations.indexWhere((c) => c.id == convId);
          if (idx >= 0) {
            _conversations[idx] = _sanitizeDirectConv(
              _withPeer(_conversations[idx], otherUser: peer),
            );
          }
        } else {
          unawaited(refreshConversationMeta(convId));
        }
      }
    } catch (_) {
      if ((_messages[convId] ?? []).isEmpty) {
        _messagesErrors[convId] =
            'Could not load messages. Check your connection.';
        showLoading = true;
      }
    } finally {
      _messagesLoading[convId] = false;
      final after = messagesFor(convId);
      if (showLoading || !_sameMessageList(before, after)) {
        notifyListeners();
      }
    }
  }

  // ── Local message cache — chats stay saved on the phone ────────
  String _msgCacheKey(int convId) => 'msg_cache_${_me?.id ?? 0}_$convId';

  Future<List<Message>> _loadCachedMessages(int convId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_msgCacheKey(convId));
      if (raw == null) return [];
      final messages = (jsonDecode(raw) as List)
          .map((m) => Message.fromJson(Map<String, dynamic>.from(m)))
          // Guard: never show a cached message that belongs to a different chat.
          .where((m) => m.conversationId == 0 || m.conversationId == convId)
          .toList();
      messages.sort(_compareMessagesChronologically);
      return messages;
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveCachedMessages(int convId, List<Message> msgs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep only the newest 50 to stay light
      final keep = msgs.length > 50 ? msgs.sublist(msgs.length - 50) : msgs;
      await prefs.setString(
        _msgCacheKey(convId),
        jsonEncode(keep.map((m) => m.toJson()).toList()),
      );
    } catch (_) {}
  }

  // ── "Clear chat" cutoff ─────────────────────────────────────────────
  // For a normal (server-backed) conversation, clearing the local list and
  // cache alone doesn't stick: the very next background refresh (every ~5s,
  // see startRecentsAutoRefresh) re-fetches this chat from the server and
  // merges the exact same history right back in. A real fix needs a
  // persisted cutoff — same idea WhatsApp/Telegram use — so every load path
  // (cache, local-nearby merge, server fetch) drops anything at or before
  // the moment "Clear chat" was tapped, forever, on this device. A message
  // sent or received *after* that moment still shows normally.
  final Map<int, DateTime> _clearedAt = {};
  String _clearedAtKey(int convId) => 'cleared_at_${_me?.id ?? 0}_$convId';

  Future<void> _loadClearedAt(int convId) async {
    if (_clearedAt.containsKey(convId)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_clearedAtKey(convId));
      if (raw != null) {
        final t = DateTime.tryParse(raw);
        if (t != null) _clearedAt[convId] = t;
      }
    } catch (_) {}
  }

  List<Message> _dropCleared(int convId, List<Message> msgs) {
    final cutoff = _clearedAt[convId];
    if (cutoff == null) return msgs;
    return msgs.where((m) => m.createdAt.isAfter(cutoff)).toList();
  }

  /// "Clear chat" — wipes this chat's history on THIS device only, same as
  /// every other messaging app's version of the feature (the other side's
  /// copy is untouched). This is the only way to clear a Nearby-only
  /// conversation (negative id) since it never had a server-side copy to
  /// begin with; for a normal conversation it just clears the local
  /// cache/view, it does not call the server. Local-only messages (a
  /// `sent_nearby` bubble, say) have no other copy anywhere, so this is also
  /// the only way to remove a message that arrived with a corrupted local
  /// clock — no separate "fix the timestamp" operation is possible once a
  /// bad value is already saved.
  Future<void> clearConversationMessages(int convId) async {
    // Always real "now" — NOT the newest existing message's createdAt. That
    // was tried (to also cover a Nearby message stuck with a clock-corrupted
    // FUTURE timestamp) but backfired badly: if any old message in this
    // chat had a bad future createdAt, the cutoff itself inherited that bad
    // future value, and every genuinely-new message sent afterward — with a
    // normal, correct "now" timestamp — landed BEFORE that inflated cutoff
    // and got silently hidden by _dropCleared forever. Confirmed live: user
    // cleared a chat and the same stale ordering kept showing up because
    // nothing new could ever pass the corrupted cutoff again. A future-dated
    // straggler not clearing is the smaller problem — _monotonicNearbyTime
    // already stops any *new* message from getting a bad clock in the first
    // place, so real "now" is the only cutoff that can't itself go stale.
    final cutoff = DateTime.now();
    _clearedAt[convId] = cutoff;
    _messages[convId] = [];
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_msgCacheKey(convId));
      final peerId = conversationById(convId)?.otherUser?.id;
      if (peerId != null) await prefs.remove(_msgCacheKey(-peerId));
      await prefs.setString(_clearedAtKey(convId), cutoff.toIso8601String());
    } catch (_) {}
    notifyListeners();
  }

  Future<void> sendMessage(
    int convId,
    String content, {
    String type = 'text',
    int? replyToId,
  }) async {
    final tempId = -DateTime.now().millisecondsSinceEpoch;
    final temp = Message(
      id: tempId,
      conversationId: convId,
      senderId: _me?.id ?? 0,
      type: type,
      content: content,
      // Floored the same way an incoming Nearby message is — a message I'm
      // sending right now must never sort above something already in this
      // chat, even if this conversation was earlier polluted by a stale
      // Nearby clock (see _monotonicNearbyTime).
      createdAt: _monotonicNearbyTime(convId, DateTime.now()),
      status: 'sending',
      senderName: _me?.displayName,
      senderAvatar: _me?.avatar,
    );
    _registerPendingKey(tempId);
    _messages[convId] = [...(messagesFor(convId)), temp];
    notifyListeners();
    // Move the conversation to Recents immediately. Waiting for the server
    // response left a message sent to an older contact in its old position
    // (especially on a slow/offline link), even though the message bubble was
    // already visible in the open chat.
    _upsertConvFromMessage(convId, temp, bumpUnread: false);

    // This contact only exists via a synced WhatsApp chat (no Phoneopia
    // account of their own) — deliver out over the user's linked WhatsApp
    // instead of the normal in-app path, which they could never receive.
    final otherUser = conversationById(convId)?.otherUser;
    if (false && type == 'text' && otherUser?.isWhatsappShadow == true) {
      try {
        final r = await ApiService.post('whatsapp-relay.php?action=send', {
          'conversation_id': convId,
          'content': content,
        });
        final msg = _parseSendResponse(r, convId);
        if (msg != null) {
          _commitMessage(convId, msg, replaceTempId: tempId);
          _upsertConvFromMessage(convId, msg, bumpUnread: false);
          unawaited(_saveCachedMessages(convId, messagesFor(convId)));
          notifyListeners();
        } else {
          _failPendingMessage(convId, tempId);
          notifyListeners();
        }
      } catch (_) {
        _failPendingMessage(convId, tempId);
        notifyListeners();
      }
      return;
    }

    // Match the composer's Using Nearby route. Already delivered local
    // messages are retained in history, never replayed as new server sends.
    // Internet takes priority whenever it's actually up — Nearby (Bluetooth/
    // WiFi Direct) is much slower, so jumping to it just because the peer
    // happens to be in range made every send laggy even on good WiFi.
    if (convId < 0) {
      if (await _tryNearbyFallback(convId, tempId, content)) return;
    } else if (type == 'text') {
      final peerId = conversationById(convId)?.otherUser?.id;
      if (peerId != null &&
          NearbyService().isUserReachable(peerId) &&
          await ApiService.isOffline().timeout(
            const Duration(milliseconds: 800),
            onTimeout: () => true,
          )) {
        if (await _tryNearbyFallback(convId, tempId, content)) return;
      }
    }

    try {
      if (convId < 0) throw StateError('Nearby peer is unavailable');
      final r = await ApiService.sendMessage(
        convId,
        content,
        type: type,
        replyToId: replyToId,
      ).timeout(const Duration(seconds: 6));
      final msg = _parseSendResponse(r, convId);
      if (msg != null) {
        _commitMessage(convId, msg, replaceTempId: tempId);
        _upsertConvFromMessage(convId, msg, bumpUnread: false);
        unawaited(_saveCachedMessages(convId, messagesFor(convId)));
        notifyListeners();
      } else if (r['success'] == true) {
        // Server saved it but payload shape was unexpected — refresh without dropping temp
        unawaited(loadMessages(convId, refresh: true));
      } else if (!await _tryNearbyFallback(convId, tempId, content)) {
        _failPendingMessage(convId, tempId);
        notifyListeners();
      }
    } catch (_) {
      // convId < 0 means we already tried _tryNearbyFallback once, right
      // above, and it failed — that threw StateError on purpose specifically
      // to skip the (impossible, no server conversation exists) API call and
      // land here. Retrying nearby again for that same case doesn't recover
      // anything extra (isUserReachable hasn't magically changed in the few
      // ms since), it just resends the same content a second time — the
      // peer's phone actually receives the payload twice over Bluetooth even
      // though the SENDER'S OWN bubble looks like one message (this tempId
      // just gets overwritten again). Only a genuine server-path failure
      // (convId >= 0, the try above actually attempted ApiService.sendMessage)
      // should fall back to nearby here.
      if (convId < 0 ||
          !await _tryNearbyFallback(convId, tempId, content)) {
        _failPendingMessage(convId, tempId);
        notifyListeners();
      }
    }
  }

  Conversation ensureNearbyConversation(int peerId, String name) {
    final existing = _conversations
        .where((c) => c.type == 'direct' && c.otherUser?.id == peerId)
        .firstOrNull;
    if (existing != null) return existing;
    final conversation = Conversation(
      id: -peerId,
      type: 'direct',
      name: name,
      otherUser: User(id: peerId, username: '', displayName: name),
    );
    ensureConvInList(conversation, moveTop: true);
    unawaited(_saveCachedConversations(_conversations));
    return conversation;
  }

  StreamSubscription<NearbyMessage>? _nearbySub;

  /// Feed incoming offline (Bluetooth/WiFi Direct) messages into the same
  /// conversation the sender's server-synced chat already uses, so they show
  /// up in the normal chat screen — not a separate offline-only UI.
  void _listenNearbyMessages() {
    _nearbySub?.cancel();
    _nearbySub = NearbyService().onMessage.listen((m) {
      final peerUid = NearbyService().peerUserId[m.endpointId];
      if (peerUid == null) return;
      Conversation? conv;
      if (m.conversationId != null && m.conversationId! > 0) {
        conv = conversationById(m.conversationId!);
        if (conv?.type != 'direct' || conv?.otherUser?.id != peerUid)
          conv = null;
      }
      for (final c in _conversations) {
        if (conv == null && c.otherUser?.id == peerUid) {
          conv = c;
          break;
        }
      }
      // Offline Nearby delivery can arrive before this account has refreshed
      // its server conversation list. The sender includes the shared real
      // conversation id, so create the row locally instead of silently
      // dropping the message until the user closes/reopens the app.
      if (conv == null && (m.conversationId ?? 0) > 0) {
        final peer = User(id: peerUid, username: '', displayName: m.senderName);
        conv = Conversation(
          id: m.conversationId!,
          type: 'direct',
          name: m.senderName,
          otherUser: peer,
          lastMessageContent: m.text,
          lastMessageType: 'text',
          lastMessageSender: peerUid,
          lastMessageAt: m.at,
          unreadCount: 1,
        );
        ensureConvInList(conv, moveTop: true);
      }
      conv ??= ensureNearbyConversation(peerUid, m.senderName);
      final msg = Message(
        id: -DateTime.now().millisecondsSinceEpoch,
        conversationId: conv.id,
        senderId: peerUid,
        type: 'text',
        content: m.text,
        // Sender and receiver clocks can differ; local receive order keeps a
        // Nearby message beside the messages that actually preceded it here.
        // Floored to land after this chat's newest message no matter what —
        // see _monotonicNearbyTime.
        createdAt: _monotonicNearbyTime(conv.id, DateTime.now()),
        status: 'sent_nearby',
        senderName: m.senderName,
      );
      _commitMessage(conv.id, msg);
      _upsertConvFromMessage(conv.id, msg, bumpUnread: true);
      notifyListeners();
      unawaited(_saveCachedMessages(conv.id, messagesFor(conv.id)));
      if (_activeChatConvId != conv.id && !conv.isMuted) {
        unawaited(
          NotificationService().showMessageNotification(
            convId: conv.id,
            senderName: m.senderName,
            body: m.text,
            avatarUrl: conv.otherUser?.avatar,
            toUserId: _me?.id,
          ),
        );
      }
    });
  }

  StreamSubscription<NearbyFile>? _nearbyFileSub;

  // A file/voice note can finish transferring several seconds after it was
  // sent. Keep the sender's timestamp so it lands in true send order, but
  // Nearby has no server clock to arbitrate — it's the sender's own device
  // time, raw. A phone with a wrong clock (fast, slow, or just a wrong
  // date) would otherwise place the received bubble way above (stale clock
  // in the past) or below/hidden (clock in the future) today's real
  // messages. Transfers happen live, device-to-device, so anything outside
  // a generous few-minute window either way can only be a bad clock, not a
  // genuine send time — fall back to our own "now" for those.
  DateTime _nearbyFileOrderTime(DateTime? sentAt) {
    final now = DateTime.now();
    final remote = sentAt?.toLocal();
    if (remote == null) return now;
    final drift = remote.difference(now).abs();
    if (drift > const Duration(minutes: 10)) return now;
    return remote;
  }

  /// A live Nearby arrival — text or file — has to land after whatever this
  /// chat already shows, full stop. Clamping bad-clock drift (above) still
  /// leaves a gap: a handful of messages sent hours earlier while a phone's
  /// clock was genuinely wrong stay parked in the middle of history forever,
  /// and *every* new message that arrives afterward with a correct, earlier
  /// wall-clock time than that stale batch keeps sorting ABOVE it instead of
  /// at the bottom where "just arrived" belongs — this is the case users
  /// actually notice ("naya message upar chala jata hai"), not the one-time
  /// clock skew itself. There's no way to un-corrupt those old entries from
  /// here without deleting messages, which isn't done automatically — but a
  /// genuinely new arrival can always be floored to sort after them.
  DateTime _monotonicNearbyTime(int convId, DateTime candidate) {
    final existing = messagesFor(convId);
    if (existing.isEmpty) return candidate;
    final newest = existing.last.createdAt; // _commitMessage keeps this sorted ascending
    return candidate.isBefore(newest)
        ? newest.add(const Duration(milliseconds: 1))
        : candidate;
  }

  /// Incoming file/document received over Bluetooth/WiFi Direct — inject it
  /// into the same conversation as a real chat message, same as
  /// _listenNearbyMessages() does for text.
  void _listenNearbyFiles() {
    _nearbyFileSub?.cancel();
    _nearbyFileSub = NearbyService().onFile.listen((f) {
      Conversation? conv;
      if (f.conversationId != null && f.conversationId! > 0) {
        conv = conversationById(f.conversationId!);
        if (conv?.type != 'direct' || conv?.otherUser?.id != f.fromUserId) {
          conv = null;
        }
      }
      for (final c in _conversations) {
        if (c.otherUser?.id == f.fromUserId) {
          conv = c;
          break;
        }
      }
      conv ??= ensureNearbyConversation(f.fromUserId, 'Nearby user');
      final type = f.mimeType.startsWith('image/')
          ? 'image'
          : f.mimeType.startsWith('audio/')
          ? 'audio'
          : 'file';
      final senderName = conv.otherUser?.displayName ?? 'Nearby user';
      final senderAvatar = conv.otherUser?.avatar;
      final content = type == 'image'
          ? '📷 Photo'
          : type == 'audio'
          ? '🎤 Voice message'
          : '📎 ${f.fileName}';
      final msg = Message(
        id: -DateTime.now().millisecondsSinceEpoch,
        conversationId: conv.id,
        senderId: f.fromUserId,
        type: type,
        content: content,
        fileName: f.fileName,
        localPath: f.localPath,
        createdAt: _monotonicNearbyTime(conv.id, _nearbyFileOrderTime(f.sentAt)),
        status: 'sent_nearby',
        // Was missing entirely — every Nearby file/voice bubble fell back to
        // the "unknown sender" placeholder avatar even though conv.otherUser
        // is right here and already confirmed to match f.fromUserId above.
        senderName: senderName,
        senderAvatar: senderAvatar,
      );
      _commitMessage(conv.id, msg);
      _upsertConvFromMessage(conv.id, msg, bumpUnread: true);
      notifyListeners();
      unawaited(_saveCachedMessages(conv.id, messagesFor(conv.id)));
      // Was missing entirely — unlike _listenNearbyMessages' text path, a
      // Nearby voice note/file never notified at all when the chat wasn't
      // open. The recipient had no way to know it had arrived short of
      // opening this exact chat and scrolling to it themselves.
      if (_activeChatConvId != conv.id && !conv.isMuted) {
        unawaited(
          NotificationService().showMessageNotification(
            convId: conv.id,
            senderName: senderName,
            body: content,
            avatarUrl: senderAvatar,
            toUserId: _me?.id,
          ),
        );
      }
    });
  }

  StreamSubscription<Map<String, dynamic>>? _nearbyCallSub;

  /// A call_offer arriving over Bluetooth/WiFi Direct — the whole point is
  /// this works with zero internet on either side, so it can't go through
  /// the normal FCM/WS/poll incoming-call path at all. Presents the same
  /// IncomingCallScreen; ActiveCallScreen itself listens for the rest of the
  /// signaling (answer/ice/end) once it's open, same as it does for WS.
  void _listenNearbyCallSignals() {
    _nearbyCallSub?.cancel();
    _nearbyCallSub = NearbyService().onCallSignal.listen((data) {
      final type = data['type']?.toString() ?? '';
      final signalPeer =
          (data['from_user_id'] ?? data['caller_id'])?.toString() ?? '';
      // This global listener owns the pending incoming-call alert. The active
      // call screen separately consumes the same signal and pops itself.
      if (type == 'call_end' ||
          type == 'call_ended' ||
          type == 'call_reject' ||
          type == 'call_missed' ||
          type == 'call_busy') {
        final pendingPeer =
            (_incomingCall?['from_user_id'] ?? _incomingCall?['caller_id'])
                ?.toString() ??
            '';
        if (signalPeer.isNotEmpty) _markCallerBrieflyDismissed(signalPeer);
        if (_incomingCall != null &&
            (pendingPeer.isEmpty ||
                signalPeer.isEmpty ||
                pendingPeer == signalPeer)) {
          _incomingCall = null;
          _activeCallPeer = null;
          notifyListeners();
          unawaited(stopRing());
          // Caller hung up/timed out before we answered — the ring-window
          // BLE-churn guard armed below (on call_offer) never got released
          // by NearbyVoiceCallService().end() since that pipeline was never
          // started for a call we never answered.
          NearbyService().setVoiceActive(false);
        }
        return;
      }
      if (type != 'call_offer') return;
      final callerId = data['from_user_id'];
      if (callerId == null) return;
      final callerIdStr = callerId.toString();
      if (_dismissedCallers.contains(callerIdStr)) return;
      final pendingPeer =
          (_incomingCall?['from_user_id'] ?? _incomingCall?['caller_id'])
              ?.toString() ??
          '';
      if (_incomingCall != null && pendingPeer == callerIdStr) return;
      if (_inActiveCallUi) {
        unawaited(
          NearbyService().sendCallSignal(int.parse(callerIdStr), {
            'type': 'call_busy',
          }),
        );
        return;
      }
      // Was hardcoded to 0 for every Nearby call — meant every call from
      // the same person shared one dedup key regardless of how much later
      // it was, so a genuine quick re-call (e.g. a redial right after "No
      // answer") collided with the previous attempt's key and got silently
      // dropped by _presentIncomingCall's 12s same-key guard.
      final resolvedConvId = _resolveDirectConvId(
        int.tryParse(callerIdStr) ?? 0,
      );
      final presented = _presentIncomingCall({
        'type': 'incoming_call',
        'from_user_id': callerId,
        'from_display_name': data['from_name'],
        'from_username': data['from_name'],
        'from_avatar': null,
        'call_type': data['call_type'] ?? 'audio',
        'conversation_id': resolvedConvId,
        'sdp': data['sdp'],
        'sdp_type': data['sdp_type'],
        'offer_ts': DateTime.now().millisecondsSinceEpoch,
        'via_nearby': true,
        'call_id': data['call_id'] ?? data['nearby_call_id'],
      });
      if (presented) {
        unawaited(AudioService().playIncomingCall());
        // Guard the whole ring window against NearbyService's health-timer
        // restarting advertising/discovery — that BLE radio churn was free
        // to fire every 5s while this ringtone loops, producing an audible
        // stutter a normal-network call never has. Cleared above on
        // call_end/call_reject/etc., in dismissIncomingCall() on our own
        // decline, and by NearbyVoiceCallService().start() → end() once
        // answered.
        NearbyService().setVoiceActive(true);
      }
    });
  }

  /// The normal server send failed — if the peer is reachable right now over
  /// Bluetooth/WiFi Direct (Nearby), deliver it that way instead of just
  /// marking it failed. Returns true if it went out via Nearby.
  Future<bool> _tryNearbyFallback(
    int convId,
    int tempId,
    String content,
  ) async {
    final peerId = conversationById(convId)?.otherUser?.id;
    if (peerId == null || !NearbyService().isUserReachable(peerId))
      return false;
    final ok = await NearbyService().sendToUser(
      peerId,
      content,
      conversationId: convId,
    );
    if (!ok) return false;
    final idx = messagesFor(convId).indexWhere((m) => m.id == tempId);
    if (idx >= 0) {
      final list = List<Message>.from(messagesFor(convId));
      list[idx] = list[idx].copyWith(status: 'sent_nearby');
      _messages[convId] = list;
      unawaited(_saveCachedMessages(convId, list));
      notifyListeners();
    }
    return true;
  }

  /// Retry a failed send — re-uses the same temp bubble (tap the red "!").
  Future<void> retrySendMessage(int convId, int tempId) async {
    final list = List<Message>.from(messagesFor(convId));
    final idx = list.indexWhere((m) => m.id == tempId);
    if (idx < 0) return;
    final failed = list[idx];
    list[idx] = failed.copyWith(status: 'sending');
    _messages[convId] = list;
    notifyListeners();

    final peerId = conversationById(convId)?.otherUser?.id;
    if (peerId != null &&
        NearbyService().isUserReachable(peerId) &&
        await ApiService.isOffline()) {
      final nearbyOk = failed.type == 'text'
          ? await _tryNearbyFallback(convId, tempId, failed.content ?? '')
          : (failed.localPath != null
                ? await _tryNearbyFileFallback(
                    convId,
                    tempId,
                    peerId,
                    failed.localPath!,
                    failed.fileName ?? 'nearby_file',
                    failed.type,
                    failed.duration,
                  )
                : false);
      if (nearbyOk) return;
    }

    try {
      final r = await ApiService.sendMessage(
        convId,
        failed.content ?? '',
        type: failed.type,
      );
      final msg = _parseSendResponse(r, convId);
      if (msg != null) {
        _commitMessage(convId, msg, replaceTempId: tempId);
        _upsertConvFromMessage(convId, msg, bumpUnread: false);
        unawaited(_saveCachedMessages(convId, messagesFor(convId)));
      } else {
        _failPendingMessage(convId, tempId);
      }
    } catch (_) {
      _failPendingMessage(convId, tempId);
    }
    notifyListeners();
  }

  String _messagePreview(Message msg) {
    if (msg.isImage) return '📷 Photo';
    if (msg.isAudio) return '🎤 Voice message';
    if (msg.isVideo) return '🎥 Video';
    if (msg.isFile) return '📎 ${msg.fileName ?? 'File'}';
    if (msg.type == 'call')
      return _callPreviewFromContent(msg.content, msg.senderId);
    return msg.content ?? '';
  }

  Timer? _nearbySortDebounce;

  // Nearby (Bluetooth/WiFi Direct) discovery churns constantly in the
  // background — peers flicker between discovered/connecting/connected every
  // few seconds even when nothing chat-relevant happened. Reacting to every
  // single one of those with an immediate full-list resort + rebuild was
  // what made the top conversation visibly "blink" on the home screen.
  // Collapse rapid bursts into a single re-sort instead.
  void _onNearbyChanged() {
    _nearbySortDebounce?.cancel();
    _nearbySortDebounce = Timer(const Duration(milliseconds: 900), () {
      promoteReachableNearbyPeers();
      notifyListeners();
    });
  }

  /// Promote every currently-reachable Nearby peer into the normal chat
  /// list. Users no longer need to open a separate "Nearby" screen and tap
  /// "connect" before an already-known contact can use the offline route —
  /// this is what makes that automatic. _onNearbyChanged calls this on a
  /// 900ms debounce after every discovery/connection event; call it directly
  /// (e.g. the instant the "Nearby" filter chip is tapped) for a list that's
  /// complete right away instead of waiting out that debounce.
  void promoteReachableNearbyPeers() {
    final nearby = NearbyService();
    for (final entry in nearby.peerUserId.entries) {
      final peerId = entry.value;
      // isUserNearby (not the stricter isUserReachable) on purpose — a peer
      // still mid-handshake ('discovered'/'connecting') needs a row in the
      // chat list just as much as an already-'connected' one, otherwise the
      // Nearby tab looks empty for however long the handshake takes.
      if (peerId <= 0 || !nearby.isUserNearby(peerId)) continue;
      ensureNearbyConversation(
        peerId,
        nearby.peers[entry.key]?.trim().isNotEmpty == true
            ? nearby.peers[entry.key]!
            : 'Nearby user',
      );
    }
    _sortConversations();
  }

  void _sortConversations() {
    // Nearby-reachable conversations group ahead of everything else (below
    // pinned), matching "put Nearby ones at the start" — but recency still
    // decides order *within* each of those two groups, on both sides. A
    // previous version of this made reachability override recency entirely
    // (any Bluetooth-reachable contact permanently pinned above a chat that
    // just got a brand new message — confirmed live as the reported "latest
    // message doesn't move to top" bug). Grouping instead of a full override
    // keeps "Nearby first" true while a fresh message still bubbles to the
    // top of whichever group it belongs to.
    bool reachable(Conversation c) =>
        c.otherUser != null && NearbyService().isUserNearby(c.otherUser!.id);
    _conversations.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      final ar = reachable(a);
      final br = reachable(b);
      if (ar != br) return ar ? -1 : 1;
      final at = a.lastMessageAt ?? DateTime(2000);
      final bt = b.lastMessageAt ?? DateTime(2000);
      return bt.compareTo(at);
    });
  }

  void _scheduleConversationsRefresh() {
    _convListDebounce?.cancel();
    _convListDebounce = Timer(const Duration(milliseconds: 1500), () {
      if (!_isLoggedIn) return;
      loadConversations();
    });
  }

  Message? _parseIncomingMessage(Map<String, dynamic> data) {
    try {
      if (data['message'] is Map) {
        final m = Map<String, dynamic>.from(data['message'] as Map);
        if (!m.containsKey('conversation_id') &&
            data['conversation_id'] != null) {
          m['conversation_id'] = data['conversation_id'];
        }
        return Message.fromJson(m);
      }
      if (data['id'] != null) return Message.fromJson(data);
    } catch (_) {}
    return null;
  }

  /// Returns true if the conversation was already in recents.
  bool _upsertConvFromMessage(
    int convId,
    Message msg, {
    required bool bumpUnread,
  }) {
    final preview = _messagePreview(msg);
    final idx = _conversations.indexWhere((c) => c.id == convId);
    final fromOther = msg.senderId != _me?.id;
    final shouldUnread =
        bumpUnread &&
        fromOther &&
        convId != _activeChatConvId &&
        msg.type != 'system';

    if (idx < 0) {
      User? other;
      String name = 'Chat';
      String? avatar;
      if (fromOther && msg.senderId > 0) {
        other = User(
          id: msg.senderId,
          username: msg.senderUsername ?? '',
          displayName: msg.senderName ?? 'Chat',
          avatar: msg.senderAvatar,
        );
        name = msg.senderName ?? 'Chat';
        avatar = msg.senderAvatar;
      } else {
        for (final m in messagesFor(convId)) {
          if (m.senderId > 0 && m.senderId != (_me?.id ?? 0)) {
            other = User(
              id: m.senderId,
              username: m.senderUsername ?? '',
              displayName: m.senderName ?? 'Chat',
              avatar: m.senderAvatar,
            );
            name = m.senderName ?? 'Chat';
            avatar = m.senderAvatar;
            break;
          }
        }
      }
      ensureConvInList(
        _sanitizeDirectConv(
          Conversation(
            id: convId,
            type: 'direct',
            name: name,
            avatar: avatar,
            otherUser: other,
            lastMessageContent: preview,
            lastMessageType: msg.type,
            lastMessageSender: msg.senderId,
            lastMessageAt: msg.createdAt,
            unreadCount: shouldUnread ? 1 : 0,
          ),
        ),
        moveTop: true,
      );
      _scheduleConversationsRefresh();
      return false;
    }

    var old = _conversations[idx];
    if ((old.otherUser == null || _isSelfLabel(old.name)) &&
        fromOther &&
        msg.senderId > 0) {
      old = _withPeer(
        old,
        otherUser: User(
          id: msg.senderId,
          username: msg.senderUsername ?? '',
          displayName: msg.senderName ?? 'User',
          avatar: msg.senderAvatar,
        ),
      );
    }
    _optimisticConvIds.remove(convId);
    // A delayed server response can carry a stale/older timestamp than the
    // local optimistic message. Never let that response move an active chat
    // back down in Recents.
    final oldAt = old.lastMessageAt;
    final keepIncoming =
        oldAt == null || msg.createdAt.isAfter(oldAt) || msg.id < 0;
    _conversations[idx] = _convCopy(
      old,
      lastMessageContent: keepIncoming ? preview : old.lastMessageContent,
      lastMessageType: keepIncoming ? msg.type : old.lastMessageType,
      lastMessageSender: keepIncoming ? msg.senderId : old.lastMessageSender,
      lastMessageAt: keepIncoming ? msg.createdAt : old.lastMessageAt,
      unreadCount: shouldUnread
          ? old.unreadCount + 1
          : (convId == _activeChatConvId ? 0 : old.unreadCount),
    );
    _sortConversations();
    notifyListeners();
    unawaited(_saveCachedConversations(_conversations));
    return true;
  }

  String _callPreviewFromContent(String? content, int? senderId, {int? myId}) {
    myId ??= _me?.id ?? 0;
    final raw = (content ?? '').trim();
    var callType = 'audio';
    var status = 'missed';
    var dur = 0;
    if (raw.contains('|')) {
      final p = raw.split('|');
      callType = p.isNotEmpty ? p[0] : 'audio';
      status = p.length > 1 ? p[1] : 'missed';
      dur = p.length > 2 ? int.tryParse(p[2]) ?? 0 : 0;
    }
    final isOut = (senderId ?? 0) == myId;
    final answered = status == 'answered' || status == 'completed';
    final ringing = status == 'ringing' || status == 'outgoing';
    final missed =
        !answered && !ringing && (status == 'missed' || status == 'rejected');
    final vid = callType == 'video';
    if (ringing) {
      return isOut
          ? (vid ? '📹 Outgoing video call' : '📞 Outgoing call')
          : (vid ? '📹 Incoming video call' : '📞 Incoming call');
    }
    if (!isOut && missed)
      return vid ? '📹 Missed video call' : '📞 Missed voice call';
    if (answered && dur > 0) {
      final m = dur ~/ 60;
      final s = (dur % 60).toString().padLeft(2, '0');
      return '📞 ${vid ? 'Video' : 'Voice'} call · $m:$s';
    }
    if (answered) return vid ? '📹 Video call' : '📞 Voice call';
    if (isOut)
      return status == 'rejected' ? '📞 Call declined' : '📞 No answer';
    return vid ? '📹 Video call' : '📞 Voice call';
  }

  void _bumpRecentsForCall(Map<String, dynamic> data) {
    final convId = int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
    final callerId =
        int.tryParse(
          (data['caller_id'] ?? data['from_user_id'])?.toString() ?? '',
        ) ??
        0;
    final callerName =
        data['caller_name']?.toString() ??
        data['from_display_name']?.toString() ??
        'Incoming call';
    final callerAvatar = AvatarWidget.resolveUrl(
      data['caller_avatar']?.toString() ?? data['from_avatar']?.toString(),
    );
    final isVideo = data['call_type']?.toString() == 'video';
    final preview = '${isVideo ? 'video' : 'audio'}|ringing|0';
    final now = DateTime.now();

    var idx = convId > 0
        ? _conversations.indexWhere((c) => c.id == convId)
        : -1;
    if (idx < 0 && callerId > 0) {
      idx = _conversations.indexWhere(
        (c) => c.type == 'direct' && c.otherUser?.id == callerId,
      );
    }

    if (idx >= 0) {
      final old = _conversations[idx];
      final bumpUnread = convId != _activeChatConvId;
      _conversations[idx] = Conversation(
        id: old.id,
        type: old.type,
        name: old.name,
        description: old.description,
        avatar: old.avatar,
        otherUser: old.otherUser,
        members: old.members,
        pastMembers: old.pastMembers,
        myRole: old.myRole,
        createdBy: old.createdBy,
        isPinned: old.isPinned,
        isMuted: old.isMuted,
        memberCount: old.memberCount,
        lastMessageContent: preview,
        lastMessageType: 'call',
        lastMessageSender: callerId > 0 ? callerId : old.lastMessageSender,
        lastMessageAt: now,
        unreadCount: bumpUnread ? old.unreadCount + 1 : old.unreadCount,
      );
    } else if (callerId > 0) {
      _conversations.insert(
        0,
        Conversation(
          id: convId > 0 ? convId : 0,
          type: 'direct',
          name: callerName,
          avatar: callerAvatar,
          otherUser: User(
            id: callerId,
            username: data['caller_username']?.toString() ?? '',
            displayName: callerName,
            avatar: callerAvatar,
          ),
          lastMessageContent: preview,
          lastMessageType: 'call',
          lastMessageSender: callerId,
          lastMessageAt: now,
          unreadCount: convId != _activeChatConvId ? 1 : 0,
        ),
      );
    } else {
      return;
    }
    _sortConversations();
    notifyListeners();
  }

  void _applyIncomingMessage(Message msg) {
    final convId = msg.conversationId;
    if (convId <= 0) return;
    final list = messagesFor(convId);
    if (list.any((m) => m.id == msg.id && m.id > 0)) return;

    // SSE echoes our own send — merge into pending or skip if already shown.
    if (_isOwnMessage(msg)) {
      final pending = list
          .where((m) => m.id < 0 || m.status == 'sending')
          .toList();
      for (final p in pending) {
        if (p.type == msg.type && _contentMatches(p.content, msg.content)) {
          _commitMessage(convId, msg, replaceTempId: p.id);
          _upsertConvFromMessage(convId, msg, bumpUnread: false);
          unawaited(_saveCachedMessages(convId, messagesFor(convId)));
          notifyListeners();
          return;
        }
      }
      if (list.any(
        (m) =>
            m.id > 0 &&
            m.senderId == msg.senderId &&
            m.type == msg.type &&
            _contentMatches(m.content, msg.content) &&
            m.createdAt.difference(msg.createdAt).inSeconds.abs() < 90,
      )) {
        return;
      }
    }

    _commitMessage(convId, msg);
    final fromOther = msg.senderId != _me?.id;
    final bumpUnread =
        fromOther && convId != _activeChatConvId && msg.type != 'system';
    final hadConv = _upsertConvFromMessage(convId, msg, bumpUnread: bumpUnread);
    unawaited(_saveCachedMessages(convId, messagesFor(convId)));

    // A stale/redelivered SSE event (e.g. re-queued on reconnect after an app
    // restart) can bump the local unread count for a message that was already
    // read — reconcile with the server's real unread_count shortly after so
    // it self-corrects instead of sticking.
    if (!hadConv || bumpUnread) _scheduleConversationsRefresh();
    if (convId == _activeChatConvId) {
      markRead(convId);
      if (fromOther && msg.type != 'call' && msg.type != 'system') {
        AudioService().playNotification();
      }
    } else if (fromOther && msg.type != 'call' && msg.type != 'system') {
      AudioService().playNotification();
      final conv = _conversations.firstWhere(
        (c) => c.id == convId,
        orElse: () => Conversation(
          id: convId,
          type: 'direct',
          name: msg.senderName ?? 'New message',
        ),
      );
      final senderName = msg.senderName ?? conv.displayName;
      NotificationService().showMessageNotification(
        convId: convId,
        senderName: senderName,
        body: _messagePreview(msg),
      );
    }
    notifyListeners();
  }

  void _connectWs() {
    // SSE over HTTPS — primary real-time channel
    SseService().addListener(_onWsMessage);
    SseService().start();
    // Also connect WS for faster call signaling (WS → instant; HTTP relay → ~5s)
    _ws.addListener(_onWsMessage);
    _ws.connect();
  }

  int? _activeChatConvId;
  int? get activeChatConvId => _activeChatConvId;
  void setActiveChat(int? convId) {
    _activeChatConvId = convId;
    _activeChatPoll?.cancel();
    _activeChatPoll = null;
    if (convId != null && convId > 0) {
      // startRecentsAutoRefresh()'s existing 4s timer already refreshes the
      // active chat's messages (refreshActiveChat: true) — a second poll
      // here was fetching the same chat twice every cycle, wasting network
      // and causing UI jank. Just do one immediate refresh on entry.
      unawaited(loadMessages(convId, refresh: true, silent: true));
    }
  }

  void _onWsMessage(Map<String, dynamic> data) {
    final type = data['type'];
    if (type == 'new_message' || type == 'message') {
      final msg = _parseIncomingMessage(data);
      if (msg != null) {
        _applyIncomingMessage(msg);
        _scheduleAutoRefresh();
      }
    } else if (type == 'message_deleted') {
      final convId =
          int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
      final msgId = int.tryParse(data['message_id']?.toString() ?? '') ?? 0;
      if (convId > 0 && msgId > 0) {
        applyMessageDeleted(
          convId,
          msgId,
          forAll: data['for_all'] == true || data['for_all'] == 1,
        );
      }
    } else if (type == 'incoming_call' || type == 'call_offer') {
      if (_isCallOfferStale(data)) {
        unawaited(CallAlertService().stopAll());
        _incomingCall = null;
        notifyListeners();
        return;
      }
      if (_isDuplicateCallOffer(data)) return;
      final callerId =
          (data['caller_id'] ?? data['from_user_id'])?.toString() ?? '';
      if (callerId.isNotEmpty) {
        if (_dismissedCallers.contains(callerId)) return;
        if (_brieflyDismissedCallers.contains(callerId)) return;
        if (_inActiveCallUi) {
          final cid = int.tryParse(callerId);
          if (cid != null) {
            _sendCallSignal({'type': 'call_busy', 'target_user_id': cid});
          }
          return;
        }
      }
      _bumpRecentsForCall(data);
      _scheduleAutoRefresh(refreshActiveChat: false);
      final normalized = CallAlertService().normalizeCallData(
        type == 'call_offer' ? {...data, 'type': 'call_offer'} : data,
      );
      if (normalized['from_avatar'] != null) {
        normalized['from_avatar'] = AvatarWidget.resolveUrl(
          normalized['from_avatar']?.toString(),
        );
      }
      unawaited(CallAlertService().savePendingCall(normalized));
      _presentIncomingCall(normalized);
      unawaited(
        CallAlertService().startIncomingAlerts(normalized, forceNotify: true),
      );
    } else if (type == 'call_answered_elsewhere') {
      if (data['answering_instance_id']?.toString() ==
          SseService().clientInstanceId)
        return;
      if (_shouldDismissIncomingFor(data)) {
        _incomingCall = null;
        notifyListeners();
        CallAlertService().stopAll();
      }
    } else if (type == 'call_reject' || type == 'call_rejected') {
      if (_shouldDismissIncomingFor(data)) {
        _incomingCall = null;
        notifyListeners();
        CallAlertService().stopAll();
      }
      _scheduleAutoRefresh();
    } else if (type == 'call_ended' ||
        type == 'call_end' ||
        type == 'call_missed' ||
        type == 'call_busy') {
      // The caller just ended their side of this call. If their original
      // call_offer got delayed (a slow poll cycle, a brief reconnect) it can
      // still be sitting in flight and arrive moments AFTER this — showing
      // a fresh-looking incoming-call screen for a call the caller already
      // gave up on, sometimes a minute or more later. Remember them as
      // dismissed for the same window call_offer freshness already uses, so
      // that late arrival gets blocked by the existing dismissed-caller
      // check instead of ringing for a call that's already over.
      final endedCallerId =
          (data['caller_id'] ?? data['from_user_id'])?.toString() ?? '';
      if (endedCallerId.isNotEmpty) _markCallerBrieflyDismissed(endedCallerId);
      if (_shouldDismissIncomingFor(data)) {
        _incomingCall = null;
        _activeCallPeer = null;
        notifyListeners();
        CallAlertService().stopAll();
      }
      _scheduleAutoRefresh();
    } else if (type == 'group_call_invite') {
      final convId =
          int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
      if (convId <= 0) return;
      if (_inActiveCallUi) return;
      if (_dismissedCallers.contains('g$convId')) return;
      // De-dup repeated invites for the same group within a short window.
      final key = 'g$convId';
      final now = DateTime.now().millisecondsSinceEpoch;
      if (key == _lastCallOfferKey && now - _lastCallOfferAt < 15000) return;
      _lastCallOfferKey = key;
      _lastCallOfferAt = now;
      var gname = data['from_name']?.toString() ?? 'Group call';
      final gc = _conversations.where((c) => c.id == convId);
      if (gc.isNotEmpty && gc.first.name.isNotEmpty) gname = gc.first.name;
      final gdata = {
        'type': 'incoming_call',
        'is_group': true,
        'group_conv_id': convId,
        'conversation_id': convId,
        'from_user_id': data['from_user_id']?.toString() ?? '',
        'from_display_name': gname,
        'from_avatar': AvatarWidget.resolveUrl(data['from_avatar']?.toString()),
        'call_type': data['call_type'] ?? 'audio',
        'offer_ts': now,
      };
      _bumpRecentsForCall(data);
      _presentIncomingCall(gdata);
      unawaited(
        CallAlertService().startIncomingAlerts(gdata, forceNotify: true),
      );
    } else if (type == 'SHARING_REQUEST' ||
        type == 'SHARING_ACCEPTED' ||
        type == 'SHARING_DECLINED' ||
        type == 'SHARING_STARTED' ||
        type == 'SHARING_STOPPED' ||
        type == 'SHARING_DISCONNECTED') {
      SharingService().handleServerEvent(data);
    } else if (type == 'force_logout') {
      _forceLogout();
    } else if (type == 'user_online' || type == 'user_offline') {
      final userId = int.tryParse(data['user_id']?.toString() ?? '') ?? 0;
      if (userId > 0) {
        final online = type == 'user_online'
            ? (data['is_online'] == true || data['is_online'] == 1)
            : false;
        final lastSeen = parseServerTime(data['last_seen']);
        _updateUserPresence(userId, isOnline: online, lastSeen: lastSeen);
      }
    } else if (type == 'typing' || type == 'typing_start') {
      final cid = int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
      if (cid <= 0) return;
      final typing =
          type == 'typing_start' ||
          data['is_typing'] == true ||
          data['is_typing'] == 1;
      _typingMap[cid] = typing;
      notifyListeners();
      if (typing) {
        Future.delayed(const Duration(seconds: 5), () {
          if (_typingMap[cid] == true) {
            _typingMap[cid] = false;
            notifyListeners();
          }
        });
      }
    } else if (type == 'typing_stop') {
      final cid = int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
      _typingMap[cid] = false;
      notifyListeners();
    } else if (type == 'recording') {
      final cid = int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
      if (cid <= 0) return;
      final recording =
          data['is_recording'] == true || data['is_recording'] == 1;
      _recordingMap[cid] = recording;
      notifyListeners();
      if (recording) {
        Future.delayed(const Duration(seconds: 8), () {
          if (_recordingMap[cid] == true) {
            _recordingMap[cid] = false;
            notifyListeners();
          }
        });
      }
    } else if (type == 'messages_read') {
      final convId =
          int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
      final readBy = int.tryParse(data['read_by']?.toString() ?? '') ?? 0;
      // Only update statuses if the OTHER user read our messages
      if (convId > 0 && readBy != _me?.id && _messages.containsKey(convId)) {
        final updated = _messages[convId]!.map((m) {
          if (m.senderId == _me?.id && m.status != 'read')
            return m.copyWith(status: 'read');
          return m;
        }).toList();
        _messages[convId] = updated;
        notifyListeners();
      }
    }
  }

  // ── Sound controls ───────────────────────────────────────────
  final _audio = AudioService();
  void startOutgoingCallRing() => _audio.playRinging();
  void startIncomingCallRing() => _audio.playIncomingCall();
  Future<void> stopRing() async {
    await _audio.stop();
    await NotificationService().cancelCallNotification();
  }

  void sendWs(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    // Group-call signaling (invite/join/offer/answer/ice/leave) is just as
    // time-critical as 1:1 call signaling — route it through the same
    // guaranteed HTTP-relay-with-retry path instead of a raw WS send that
    // silently drops if the recipient isn't WS-connected right now.
    const reliableGroupCallTypes = {
      'group_call_invite',
      'group_join',
      'group_leave',
      'group_offer',
      'group_answer',
      'group_ice',
    };
    if (type.startsWith('call_') ||
        type.startsWith('ice_restart_') ||
        reliableGroupCallTypes.contains(type)) {
      // Try WS first when connected — much faster than HTTP relay.
      // Fall back to HTTP relay if WS is not connected.
      if (_ws.isConnected) {
        _ws.send(data);
      } else {
        _sendCallSignal(data);
      }
      return;
    }
    if (_ws.isConnected) {
      _ws.send(data);
    } else {
      ApiService.post(
        'ws-relay.php',
        data,
      ).catchError((_) => <String, dynamic>{});
    }
  }

  void addWsListener(WsMessageCallback cb) {
    _ws.addListener(cb);
    SseService().addListener(cb);
  }

  void removeWsListener(WsMessageCallback cb) {
    _ws.removeListener(cb);
    SseService().removeListener(cb);
  }

  /// Register this device's FCM token under the CURRENT account. Must run after
  /// every login / account switch / session restore — otherwise a freshly
  /// logged-in account has no token and never receives call/message pushes
  /// (the incoming-call attend screen never fires).
  Future<void> _ensurePushRegistered() async {
    // getToken() often returns null on the first try (Play Services / Firebase
    // not warmed up yet) which left many users with NO token → no calls/messages
    // when the app is closed. Retry a few times so every device registers.
    for (int attempt = 0; attempt < 6; attempt++) {
      try {
        final t = await FcmService.getToken();
        if (t != null && t.isNotEmpty) {
          await FcmService.registerToken(t);
          return;
        }
      } catch (_) {}
      if (!_isLoggedIn) return;
      await Future.delayed(Duration(seconds: 2 + attempt * 2));
    }
  }

  /// Public entry — called on every app resume so a logged-in user's token is
  /// kept fresh under their account even if a prior registration was missed.
  Future<void> ensurePushRegistered() async {
    if (!_isLoggedIn) return;
    await _ensurePushRegistered();
  }

  /// Push an FCM call signal (cancel/reject/end) straight to the live call
  /// listeners so an outgoing-call screen closes instantly — the FCM push is
  /// far faster than the SSE-queued event.
  void injectCallSignal(Map<String, dynamic> data) {
    clearIncomingCall();
    SseService().dispatchLocal(data);
  }

  void sendTyping(int convId, bool typing) => _ws.sendTyping(convId, typing);
  void sendRecording(int convId, bool recording) =>
      _ws.sendRecording(convId, recording);
  void markRead(int convId) {
    final readAt = DateTime.now().millisecondsSinceEpoch;
    _recentlyReadAt[convId] = readAt;
    SharedPreferences.getInstance().then(
      (p) => p.setInt('recently_read_${_me?.id ?? 0}_$convId', readAt),
    );
    if (convId > 0) _ws.markRead(convId);
    // HTTP path — updates message statuses + notifies the sender (blue ticks).
    // The app may background right after a chat is read (e.g. user hits
    // recents immediately) — a lost request here means the server still
    // thinks it's unread on the next resume, so retry once before giving up.
    if (convId > 0) {
      _postMarkReadWithRetry('messages.php?action=mark_read_msg', convId);
      _postMarkReadWithRetry('conversations.php?action=mark_read', convId);
    }
    final idx = _conversations.indexWhere((c) => c.id == convId);
    if (idx >= 0) {
      final old = _conversations[idx];
      _conversations[idx] = Conversation(
        id: old.id,
        type: old.type,
        name: old.name,
        avatar: old.avatar,
        otherUser: old.otherUser,
        isPinned: old.isPinned,
        isMuted: old.isMuted,
        lastMessageContent: old.lastMessageContent,
        lastMessageType: old.lastMessageType,
        lastMessageSender: old.lastMessageSender,
        lastMessageAt: old.lastMessageAt,
        unreadCount: 0,
      );
      notifyListeners();
      unawaited(_saveCachedConversations(_conversations));
    }
  }

  Future<void> _postMarkReadWithRetry(String endpoint, int convId) async {
    try {
      await ApiService.post(endpoint, {'conversation_id': convId});
    } catch (_) {
      try {
        await Future.delayed(const Duration(milliseconds: 500));
        await ApiService.post(endpoint, {'conversation_id': convId});
      } catch (_) {}
    }
  }

  Future<void> refreshMe() => _loadMe();

  void setMessages(int convId, List<Message> msgs) {
    final ordered = List<Message>.from(msgs)
      ..sort(_compareMessagesChronologically);
    _messages[convId] = ordered;
    notifyListeners();
  }

  void applyMessageDeleted(int convId, int msgId, {required bool forAll}) {
    if (!_messages.containsKey(convId)) return;
    if (forAll) {
      _messages[convId] = _messages[convId]!.map((m) {
        if (m.id != msgId) return m;
        return m.copyWith(isDeleted: true, content: 'This message was deleted');
      }).toList();
    } else {
      _messages[convId] = _messages[convId]!
          .where((m) => m.id != msgId)
          .toList();
      _clientMsgKeys.remove(msgId);
    }
    notifyListeners();
    unawaited(_saveCachedMessages(convId, _messages[convId]!));
  }

  Message? _messageById(int convId, int msgId) {
    for (final m in messagesFor(convId)) {
      if (m.id == msgId) return m;
    }
    return null;
  }

  /// WhatsApp-style: show deleted state immediately, commit to server after 5s unless undone.
  bool scheduleDeleteMessage(int convId, Message msg, {required bool forAll}) {
    if (msg.id <= 0) return false;
    _pendingDeletes[msg.id]?.timer.cancel();

    final original = _messageById(convId, msg.id) ?? msg;
    applyMessageDeleted(convId, msg.id, forAll: forAll);

    final timer = Timer(const Duration(seconds: 5), () {
      final pending = _pendingDeletes.remove(msg.id);
      unawaited(
        _commitDeleteToServer(
          convId,
          msg.id,
          forAll: forAll,
          restore: pending?.message,
        ),
      );
    });
    _pendingDeletes[msg.id] = _PendingDelete(original, forAll, timer);
    return true;
  }

  void undoDeleteMessage(int convId, int msgId) {
    final pending = _pendingDeletes.remove(msgId);
    if (pending == null) return;
    pending.timer.cancel();
    _commitMessage(convId, pending.message);
    unawaited(_saveCachedMessages(convId, messagesFor(convId)));
    notifyListeners();
  }

  Future<void> _commitDeleteToServer(
    int convId,
    int msgId, {
    required bool forAll,
    Message? restore,
  }) async {
    try {
      final r = await ApiService.deleteMessage(msgId, forAll: forAll);
      if (r['success'] != true && restore != null) {
        _commitMessage(convId, restore);
        notifyListeners();
      }
    } catch (_) {
      if (restore != null) {
        _commitMessage(convId, restore);
        notifyListeners();
      }
    }
  }

  bool deleteMessage(int convId, int msgId, {required bool forAll}) {
    final msg = _messageById(convId, msgId);
    if (msg == null || msg.id <= 0) return false;
    return scheduleDeleteMessage(convId, msg, forAll: forAll);
  }

  void addMessage(int convId, Message msg) {
    if (messagesFor(convId).any((m) => m.id == msg.id && m.id > 0)) return;
    _commitMessage(convId, msg);
    _upsertConvFromMessage(convId, msg, bumpUnread: false);
    notifyListeners();
  }

  Future<void> uploadAndSendFile(
    int convId,
    List<int> bytes,
    String filename,
    String type, {
    int? durationSecs,
    String? localPath,
  }) async {
    // Android's document picker can provide bytes without a filesystem path.
    // Nearby's native FILE payload requires a real path, so materialize a
    // durable temporary copy before deciding on the offline route. This is
    // what previously made documents/voice notes silently stay on "sending".
    var nearbyLocalPath = localPath;
    if (nearbyLocalPath == null ||
        nearbyLocalPath.isEmpty ||
        !File(nearbyLocalPath).existsSync()) {
      try {
        final dir = await getTemporaryDirectory();
        nearbyLocalPath =
            '${dir.path}/phoneopia_nearby_${DateTime.now().microsecondsSinceEpoch}_$filename';
        await File(nearbyLocalPath).writeAsBytes(bytes, flush: true);
      } catch (_) {
        nearbyLocalPath = null;
      }
    }
    final tempId = -DateTime.now().millisecondsSinceEpoch;
    final temp = Message(
      id: tempId,
      conversationId: convId,
      senderId: _me?.id ?? 0,
      type: type,
      content: type == 'image'
          ? '📷 Photo'
          : type == 'audio'
          ? '🎤 Voice message'
          : '📎 $filename',
      fileName: filename,
      createdAt: DateTime.now(),
      status: 'sending',
      senderName: _me?.displayName,
      senderAvatar: _me?.avatar,
      duration: durationSecs,
      localPath:
          nearbyLocalPath, // show the picked image instantly while it uploads
    );
    _registerPendingKey(tempId);
    _messages[convId] = [...messagesFor(convId), temp];
    notifyListeners();

    // Same reasoning as sendMessage()'s Nearby fallback: only hijack the
    // send over Bluetooth/WiFi Direct when genuinely offline, and only when
    // we actually have a real file on disk to hand to sendFilePayload (the
    // in-memory `bytes` alone aren't enough — nearby_connections needs a path).
    if (nearbyLocalPath != null) {
      final peerId = conversationById(convId)?.otherUser?.id;
      if (peerId != null &&
          NearbyService().isUserReachable(peerId) &&
          await ApiService.isOffline()) {
        if (await _tryNearbyFileFallback(
          convId,
          tempId,
          peerId,
          nearbyLocalPath,
          filename,
          type,
          durationSecs,
        ))
          return;
      }
    }

    try {
      final r = await ApiService.uploadFile(
        convId,
        bytes,
        filename,
        type,
        durationSecs: durationSecs,
      );
      final msg = _parseSendResponse(r, convId);
      if (msg != null) {
        _commitMessage(convId, msg, replaceTempId: tempId);
        _upsertConvFromMessage(convId, msg, bumpUnread: false);
        unawaited(_saveCachedMessages(convId, messagesFor(convId)));
        notifyListeners();
      } else if (r['success'] == true) {
        unawaited(loadMessages(convId, refresh: true));
      } else if (nearbyLocalPath != null) {
        final peerId = conversationById(convId)?.otherUser?.id;
        if (peerId == null ||
            !await _tryNearbyFileFallback(
              convId,
              tempId,
              peerId,
              nearbyLocalPath,
              filename,
              type,
              durationSecs,
            )) {
          _failPendingMessage(convId, tempId);
          notifyListeners();
        }
      } else {
        _failPendingMessage(convId, tempId);
        notifyListeners();
      }
    } catch (_) {
      if (nearbyLocalPath == null) {
        _failPendingMessage(convId, tempId);
        notifyListeners();
        return;
      }
      final peerId = conversationById(convId)?.otherUser?.id;
      if (peerId == null ||
          !await _tryNearbyFileFallback(
            convId,
            tempId,
            peerId,
            nearbyLocalPath,
            filename,
            type,
            durationSecs,
          )) {
        _failPendingMessage(convId, tempId);
        notifyListeners();
      }
    }
  }

  /// The normal server upload isn't going to work (offline, or it just
  /// failed) — if the peer is reachable right now over Bluetooth/WiFi Direct,
  /// send the file directly instead of leaving it stuck on "sending".
  Future<bool> _tryNearbyFileFallback(
    int convId,
    int tempId,
    int peerId,
    String localPath,
    String filename,
    String type,
    int? durationSecs,
  ) async {
    if (!NearbyService().isUserReachable(peerId)) return false;
    final mimeType = type == 'image'
        ? 'image/*'
        : type == 'audio'
        ? 'audio/*'
        : 'application/octet-stream';
    final ok = await NearbyService().sendFile(
      peerId,
      localPath,
      filename,
      mimeType,
      conversationId: convId > 0 ? convId : null,
    );
    if (!ok) return false;
    final idx = messagesFor(convId).indexWhere((m) => m.id == tempId);
    if (idx >= 0) {
      final list = List<Message>.from(messagesFor(convId));
      list[idx] = list[idx].copyWith(status: 'sent_nearby');
      _messages[convId] = list;
      notifyListeners();
    }
    unawaited(_saveCachedMessages(convId, messagesFor(convId)));
    return true;
  }

  void setTheme(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'theme_mode',
      mode == ThemeMode.dark
          ? 'dark'
          : mode == ThemeMode.light
          ? 'light'
          : 'system',
    );
  }

  void setFontScale(double scale) async {
    _fontScale = scale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('font_scale', scale);
  }

  void setChatWallpaper(String? id) async {
    _chatWallpaper = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove('chat_wallpaper');
    } else {
      await prefs.setString('chat_wallpaper', id);
    }
  }

  Future<bool> updateProfile(Map<String, dynamic> data) async {
    final r = await ApiService.updateProfile(data);
    if (r['success'] == true && r['user'] is Map) {
      await _persistUser(Map<String, dynamic>.from(r['user'] as Map));
      return true;
    }
    if (r['success'] == true) {
      final ok = await _loadMe();
      if (ok) notifyListeners();
      return ok;
    }
    return false;
  }

  Future<bool> updatePrivacy({String? lastSeen, String? profilePhoto}) async {
    final data = <String, dynamic>{};
    if (lastSeen != null) data['privacy_last_seen'] = lastSeen;
    if (profilePhoto != null) data['privacy_profile_photo'] = profilePhoto;
    if (data.isEmpty) return false;
    return updateProfile(data);
  }

  Future<bool> setAvatarPreset(String presetPath) async =>
      updateProfile({'avatar_preset': presetPath});

  Future<bool> applyUserPayload(Map<String, dynamic>? user) async {
    if (user == null) return false;
    await _persistUser(user);
    return true;
  }

  @override
  void dispose() {
    _nearbySortDebounce?.cancel();
    _ws.dispose();
    super.dispose();
  }
}
