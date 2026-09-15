import 'dart:ui';
import 'package:flutter_background_service/flutter_background_service.dart';

/// The SSE-polling version of this service (kept below in git history) was
/// replaced by Firebase Cloud Messaging (FCM) for message/call delivery when
/// the app is fully closed — FCM handles that reliably without a permanent
/// notification. What FCM does NOT do is protect an ALREADY-CONNECTED call
/// from being killed by the OS when the user backgrounds the app mid-call
/// (opens another app) — a normal "ongoing" notification alone is not a real
/// Android foreground service and does not raise the process's priority.
/// This file now only configures the plugin so [startCallKeepAlive] can
/// start a real foreground service (type "microphone") for the duration of
/// an active call, keeping the process — and the live WebRTC connection —
/// alive in the background. Stopped the moment the call screen is disposed.
Future<void> initBackgroundService() async {
  try {
    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onBgServiceStart,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: 'phoneopia_bg',
        initialNotificationTitle: 'Phoneopia',
        initialNotificationContent: 'Call in progress',
        foregroundServiceNotificationId: 778899,
        foregroundServiceTypes: const [AndroidForegroundType.microphone],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
  } catch (_) {}
}

Future<void> startBackgroundService() async {
  // no-op: FCM handles background message/call delivery now.
}

Future<void> stopBackgroundService() async {
  try {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) service.invoke('stopService');
  } catch (_) {}
}

/// Call this the moment a call becomes CONNECTED (not just ringing) — pairs
/// with [stopCallKeepAlive] which must run when that same call ends.
Future<void> startCallKeepAlive() async {
  try {
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) await service.startService();
  } catch (_) {}
}

Future<void> stopCallKeepAlive() async {
  try {
    final service = FlutterBackgroundService();
    if (await service.isRunning()) service.invoke('stopService');
  } catch (_) {}
}

@pragma('vm:entry-point')
void onBgServiceStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
  }
  service.on('stopService').listen((_) => service.stopSelf());
}