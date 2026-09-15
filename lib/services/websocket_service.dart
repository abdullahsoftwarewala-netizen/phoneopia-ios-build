import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

typedef WsMessageCallback = void Function(Map<String, dynamic> data);

class WebSocketService {
  static String get wsUrl => AppConfig.wsUrl;

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _intentionalClose = false;
  bool isConnected = false;

  final List<WsMessageCallback> _listeners = [];

  void addListener(WsMessageCallback cb) => _listeners.add(cb);
  void removeListener(WsMessageCallback cb) => _listeners.remove(cb);

  String? _token;

  Future<void> connect() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('phoneopia_token');
    if (_token == null) return;

    _intentionalClose = false;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      // In web_socket_channel v2, ready happens asynchronously via stream.
      // Catch sink errors (connection refused, protocol mismatch) via done future.
      _channel!.sink.done.then<void>(
        (_) {
          if (!_intentionalClose) _scheduleReconnect();
        },
        onError: (_, __) {
          if (!_intentionalClose) _scheduleReconnect();
        },
      );

      _sub = _channel!.stream.listen(
        _onMessage,
        onError: (_) {
          if (!_intentionalClose) _scheduleReconnect();
        },
        onDone: () {
          if (!_intentionalClose) _scheduleReconnect();
        },
        cancelOnError: true,
      );

      send({'type': 'auth', 'token': _token});
      _startPing();
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    isConnected = true; // receiving data — connection is live
    try {
      final data = jsonDecode(raw.toString()) as Map<String, dynamic>;
      for (final cb in List.of(_listeners)) cb(data);
    } catch (_) {}
  }

  void send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (_) {}
  }

  void sendTyping(int convId, bool typing) =>
      send({'type': 'typing', 'conversation_id': convId, 'is_typing': typing});

  void sendRecording(int convId, bool recording) => send({
    'type': 'recording',
    'conversation_id': convId,
    'is_recording': recording,
  });

  void markRead(int convId) =>
      send({'type': 'read', 'conversation_id': convId});

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(
      const Duration(seconds: 25),
      (_) => send({'type': 'ping'}),
    );
  }

  void _scheduleReconnect() {
    isConnected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 8), connect);
  }

  void reconnectWithToken(String token) {
    _token = token;
    dispose();
    _intentionalClose = false;
    connect();
  }

  void dispose() {
    _intentionalClose = true;
    _pingTimer?.cancel();
    _reconnectTimer?.cancel();
    _sub?.cancel();
    try {
      _channel?.sink.close();
    } catch (_) {}
  }
}
