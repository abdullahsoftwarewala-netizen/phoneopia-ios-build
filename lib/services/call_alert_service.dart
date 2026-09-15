import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/storage_keys.dart';
import '../widgets/avatar_widget.dart';
import 'audio_service.dart';
import 'notification_service.dart';

/// Persists incoming-call payload, shows lock-screen alerts, and stops ring+vibrate.
class CallAlertService {
  static final CallAlertService _i = CallAlertService._();
  factory CallAlertService() => _i;
  CallAlertService._();

  Future<void> savePendingCall(Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.callPendingState, jsonEncode(data));
  }

  Future<Map<String, dynamic>?> loadPendingCall() async {
    final prefs = await SharedPreferences.getInstance();
    var raw = prefs.getString(StorageKeys.callPendingState);
    if (raw == null || raw.isEmpty) {
      // One-time migration from pre-v1.0.3 prefs field name.
      final legacy = ['pending', 'incoming', 'call'].join('_');
      raw = prefs.getString(legacy);
      if (raw != null && raw.isNotEmpty) {
        await prefs.setString(StorageKeys.callPendingState, raw);
        await prefs.remove(legacy);
      }
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw);
      if (m is Map<String, dynamic>) return m;
      if (m is Map) return Map<String, dynamic>.from(m);
    } catch (_) {}
    return null;
  }

  Future<void> clearPendingCall() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(StorageKeys.callPendingState);
  }

  static const _dismissTtlMs =
      45000; // 45s — blocks SSE replay of a just-declined call only

  Future<void> clearCallerDismissed(String callerId) async {
    if (callerId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadDismissedMap(prefs);
    map.remove(callerId);
    await prefs.setString(StorageKeys.dismissedCallers, jsonEncode(map));
  }

  Future<void> markCallerDismissed(String callerId) async {
    if (callerId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final map = await _loadDismissedMap(prefs);
    map[callerId] = DateTime.now().millisecondsSinceEpoch;
    _pruneDismissed(map);
    await prefs.setString(StorageKeys.dismissedCallers, jsonEncode(map));
  }

  Future<bool> isCallerDismissed(String callerId) async {
    if (callerId.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final map = await _loadDismissedMap(prefs);
    _pruneDismissed(map);
    final ts = map[callerId];
    if (ts == null) return false;
    return DateTime.now().millisecondsSinceEpoch - ts < _dismissTtlMs;
  }

  Future<Set<String>> loadDismissedCallers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final map = await _loadDismissedMap(prefs);
    _pruneDismissed(map);
    return map.keys.toSet();
  }

  Future<Map<String, int>> _loadDismissedMap(SharedPreferences prefs) async {
    try {
      final raw = prefs.getString(StorageKeys.dismissedCallers);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry(k.toString(), int.tryParse(v.toString()) ?? 0),
        );
      }
    } catch (_) {}
    return {};
  }

  void _pruneDismissed(Map<String, int> map) {
    final cutoff = DateTime.now().millisecondsSinceEpoch - _dismissTtlMs;
    map.removeWhere((_, ts) => ts < cutoff);
  }

  static const offerMaxAgeMs = 45000;

  static int _readOfferTs(Map<String, dynamic> data) =>
      int.tryParse(data['offer_ts']?.toString() ?? '') ?? 0;

  static bool isOfferFresh(Map<String, dynamic> data) {
    final ts = _readOfferTs(data);
    if (ts <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch - ts < offerMaxAgeMs;
  }

  /// Normalise call_offer / incoming_call into one shape for IncomingCallScreen.
  /// Never fabricates offer_ts — missing ts means stale (blocks old-session ring).
  Map<String, dynamic> normalizeCallData(Map<String, dynamic> data) {
    if (data['type'] == 'call_offer') {
      return {
        'type': 'incoming_call',
        'from_user_id': data['caller_id'] ?? data['from_user_id'],
        'from_display_name': data['caller_name'] ?? data['from_display_name'],
        'from_username': data['caller_username'] ?? data['from_username'],
        'from_avatar': AvatarWidget.resolveUrl(
          (data['caller_avatar'] ?? data['from_avatar'])?.toString(),
        ),
        'call_type': data['call_type'] ?? 'audio',
        'conversation_id': data['conversation_id'] ?? 0,
        'sdp': data['sdp'],
        'sdp_type': data['sdp_type'],
        // Keep the caller's identity for the complete signaling handshake.
        // Dropping this here made the attendee create a new local call id;
        // the caller then rejected the valid answer as belonging to another
        // call and eventually showed "No answer".
        'call_id': data['call_id'] ?? data['nearby_call_id'],
        'nearby_call_id': data['nearby_call_id'],
        'offer_ts': _readOfferTs(data),
      };
    }
    final copy = Map<String, dynamic>.from(data);
    copy['offer_ts'] = _readOfferTs(copy);
    return copy;
  }

  Future<bool> isAppForeground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final fgAt = prefs.getInt(StorageKeys.appForegroundAt) ?? 0;
    return DateTime.now().millisecondsSinceEpoch - fgAt < 8000;
  }

  Future<void> startIncomingAlerts(
    Map<String, dynamic> callData, {
    bool forceNotify = false,
  }) async {
    final normalized = normalizeCallData(callData);
    if (!isOfferFresh(normalized)) {
      await stopAll();
      return;
    }
    await savePendingCall(normalized);
    await AudioService().playIncomingCall();
    final fg = await isAppForeground();
    if (forceNotify || !fg) {
      await NotificationService().showIncomingCallNotification(
        callerId:
            int.tryParse(normalized['from_user_id']?.toString() ?? '0') ?? 0,
        callerName:
            normalized['from_display_name']?.toString() ??
            normalized['from_username']?.toString() ??
            'Incoming call',
        callType: normalized['call_type']?.toString() ?? 'audio',
        convId:
            int.tryParse(normalized['conversation_id']?.toString() ?? '0') ?? 0,
        payload: normalized,
      );
    }
  }

  /// Stop in-app ringtone AND system notification vibration/sound.
  Future<void> stopAll() async {
    await AudioService().stop();
    await NotificationService().cancelCallNotification();
    await clearPendingCall();
  }
}
