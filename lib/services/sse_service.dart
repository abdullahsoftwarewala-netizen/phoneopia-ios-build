import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../config/storage_keys.dart';
import 'api_service.dart';

typedef SseMessageCallback = void Function(Map<String, dynamic> data);

/// Server-Sent Events client — real-time delivery over plain HTTPS (port 443).
class SseService {
  static final SseService _i = SseService._();
  factory SseService() => _i;
  SseService._();

  final List<SseMessageCallback> _listeners = [];
  http.Client? _client;
  bool _running = false;
  bool _connecting = false;
  int _lastId = 0;
  int _backoffMs = 2000;
  String? _clientId;
  String _cursorKey = StorageKeys.sseLastId;
  String? get clientInstanceId => _clientId;

  Future<String> ensureClientInstanceId() async {
    if (_clientId != null && _clientId!.isNotEmpty) return _clientId!;
    final prefs = await SharedPreferences.getInstance();
    _clientId = prefs.getString('phoneopia_sse_client_id');
    if (_clientId == null || _clientId!.isEmpty) {
      _clientId = '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_${identityHashCode(this).toRadixString(36)}';
      await prefs.setString('phoneopia_sse_client_id', _clientId!);
    }
    return _clientId!;
  }

  void addListener(SseMessageCallback cb) => _listeners.add(cb);
  void removeListener(SseMessageCallback cb) => _listeners.remove(cb);

  /// Deliver an event straight to the listeners (e.g. from an FCM push) so the
  /// active-call UI reacts instantly instead of waiting for the SSE stream.
  void dispatchLocal(Map<String, dynamic> data) {
    for (final cb in List.of(_listeners)) {
      try { cb(data); } catch (_) {}
    }
  }

  Future<void> _loadLastId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('phoneopia_user_id') ?? '0';
      // Event ids belong to a user's queue. Sharing one cursor across account
      // switches made account B inherit account A's much higher last id and
      // silently skip calls/messages until the global table caught up.
      _cursorKey = '${StorageKeys.sseLastId}_$userId';
      _lastId = prefs.getInt(_cursorKey) ?? 0;
      await ensureClientInstanceId();
    } catch (_) {}
  }

  Future<void> _saveLastId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_cursorKey, _lastId);
    } catch (_) {}
  }

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  void stop() {
    _running = false;
    _connecting = false;
    try { _client?.close(); } catch (_) {}
    _client = null;
  }

  Future<void> _loop() async {
    await _loadLastId();
    while (_running) {
      if (_connecting) {
        await Future.delayed(const Duration(milliseconds: 500));
        continue;
      }
      _connecting = true;
      http.Client? client;
      // sse.php deliberately closes the stream every ~12s server-side
      // (a clean, expected end — not a failure). That fell through to the
      // same post-loop delay as a genuine error below, so the client spent
      // a fixed ~2s fully disconnected from realtime delivery every ~12s
      // even when everything was healthy (an ~86% duty cycle at best).
      // Anything landing during that gap — most importantly call_busy/
      // call_ringing, which the server never durably queues — could be
      // missed outright rather than just delayed. Only back off on an
      // actual error; reconnect immediately after a clean server-initiated
      // cycle end.
      var cleanEnd = false;
      try {
        final t = await ApiService.token;
        if (t == null) {
          _connecting = false;
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }
        client = http.Client();
        _client = client;
        final uri = Uri.parse(
            '${ApiService.baseUrl}/sse.php?token=$t&last_id=$_lastId&client=app_${Uri.encodeQueryComponent(_clientId!)}');
        final req = http.Request('GET', uri);
        req.headers['Accept'] = 'text/event-stream';
        final res = await client.send(req).timeout(const Duration(seconds: 20));

        _backoffMs = 2000;

        int? pendingEventId;
        await for (final line in res.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .timeout(const Duration(seconds: 35))) {
          if (!_running) break;
          if (line.startsWith('id:')) {
            pendingEventId = int.tryParse(line.substring(3).trim());
          } else if (line.startsWith('data:')) {
            final raw = line.substring(5).trim();
            if (raw.isEmpty) continue;
            try {
              final data = jsonDecode(raw);
              if (data is Map<String, dynamic>) {
                final type = data['type'];
                if (type == 'sse_reconnect') {
                  final lid = int.tryParse(data['last_id']?.toString() ?? '') ?? 0;
                  if (lid > 0) {
                    _lastId = lid;
                    unawaited(_saveLastId());
                  }
                  continue;
                }
                if (type == 'sse_busy' || type == 'error') continue;
                for (final cb in List.of(_listeners)) {
                  cb(data);
                }
                // Commit the cursor only after the payload has reached every
                // listener. Saving on the preceding `id:` line could lose an
                // answer/message forever if Android killed the process in
                // the tiny gap before its `data:` line was handled.
                if (pendingEventId != null && pendingEventId > _lastId) {
                  _lastId = pendingEventId;
                  await _saveLastId();
                }
                pendingEventId = null;
              }
            } catch (_) {}
          }
        }
        cleanEnd = true;
      } catch (_) {
        _backoffMs = (_backoffMs * 1.4).round().clamp(2000, 30000);
      } finally {
        try { client?.close(); } catch (_) {}
        if (_client == client) _client = null;
        _connecting = false;
      }
      if (_running && !cleanEnd) await Future.delayed(Duration(milliseconds: _backoffMs));
    }
  }
}
