import 'package:flutter/services.dart';

/// Thin bridge to Android's native Bluetooth enable prompt — apps can't
/// silently turn Bluetooth on (Android blocks that for privacy since
/// Android 13), so this fires the system's own "Turn on Bluetooth?" dialog.
class BluetoothServiceNative {
  static const _channel = MethodChannel('phoneopia/bluetooth');

  static Future<bool> isEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('isEnabled') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Returns true once the system prompt was shown (or Bluetooth was
  /// already on) — not a guarantee the user actually tapped "Allow".
  static Future<bool> requestEnable() async {
    try {
      return await _channel.invokeMethod<bool>('enable') ?? false;
    } catch (_) {
      return false;
    }
  }
}
