import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Prompts OEMs whose battery/background-app management sits OUTSIDE the
/// standard Android ignoreBatteryOptimizations permission (Oppo/Realme/
/// OnePlus's ColorOS, Vivo's FuntouchOS/OriginOS, Xiaomi's MIUI, Huawei) to
/// whitelist this app — otherwise those skins silently drop FCM wake-ups in
/// the background, which is why calls/messages arrive inconsistently on
/// exactly these brands regardless of how reliable the server-side delivery
/// is. Shown once per install, and only on manufacturers actually known to
/// need it — asking Samsung/Google/generic-AOSP users to visit a settings
/// screen that doesn't apply to them just adds confusing friction.
class OemAutostartService {
  static const _method = MethodChannel('phoneopia/oem_autostart');
  static const _prefsKey = 'oem_autostart_prompted';

  static const _needsPromptBrands = {
    'oppo', 'realme', 'oneplus', 'vivo', 'iqoo', 'xiaomi', 'redmi', 'poco', 'huawei', 'honor',
  };

  static Future<bool> shouldPrompt() async {
    if (!Platform.isAndroid) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefsKey) == true) return false;
      final manufacturer = (await _method.invokeMethod<String>('manufacturer'))?.toLowerCase() ?? '';
      return _needsPromptBrands.any((b) => manufacturer.contains(b));
    } catch (_) {
      return false;
    }
  }

  static Future<void> markPrompted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, true);
    } catch (_) {}
  }

  static Future<void> openSettings() async {
    try { await _method.invokeMethod('openAutostartSettings'); } catch (_) {}
  }
}
