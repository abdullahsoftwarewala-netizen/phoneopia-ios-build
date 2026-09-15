import 'package:flutter/services.dart';

/// Wakes the screen and shows the app over the lock screen for incoming calls.
class CallWakeService {
  static const _channel = MethodChannel('phoneopia/call');

  static Future<void> wakeForIncomingCall() async {
    try {
      await _channel.invokeMethod('wakeForIncomingCall');
    } catch (_) {}
  }
}