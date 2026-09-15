import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';
import 'providers/app_provider.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/safety_gate.dart';
import 'screens/splash_screen.dart';
import 'utils/gdrive_gate.dart';

import 'screens/incoming_call_screen.dart';
import 'screens/active_call_screen.dart';
import 'screens/profile_setup_screen.dart';
import 'screens/qr_scan_screen.dart';
import 'screens/linked_devices_screen.dart';
import 'screens/web_sync_screen.dart';
import 'screens/link_device_screen.dart';
import 'screens/nearby_screen.dart';
import 'config/storage_keys.dart';
import 'theme/app_theme.dart';
import 'services/notification_service.dart';
import 'services/background_service.dart';
import 'services/fcm_service.dart';
import 'services/update_service.dart';
import 'widgets/update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Deep link handler — processes phoneopia://chat/{username} and
/// https://phoneopia.com/s/{username} links.
const _deepLinkChannel = MethodChannel('phoneopia/deeplink');

/// Tracks whether the fullscreen incoming-call screen is the current top
/// route — a back gesture/button press can dismiss it without the user ever
/// tapping Accept or Decline, and unlike those two paths that always clear
/// prov.incomingCall, an accidental dismiss leaves it still set. That
/// combination (call still pending, but its screen no longer on top) is
/// exactly when the top banner below needs to show.
class _IncomingCallRouteObserver extends NavigatorObserver {
  bool isTop = false;
  void _update(Route<dynamic>? route) =>
      isTop = route?.settings.name == '/incoming_call';
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(previousRoute);
  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _update(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _update(newRoute);
}

final _incomingCallRouteObserver = _IncomingCallRouteObserver();

/// Check the server for a newer APK and prompt the user to update.
/// APK side-loading is Android-only; on iOS the App Store handles updates,
/// and `getExternalStorageDirectory()` is unsupported there — so skip it.
Future<void> maybePromptAppUpdate({bool force = false}) async {
  if (!Platform.isAndroid) return;
  try {
    final info = await UpdateService().checkOnce(force: force);
    if (info == null) return;
    final ctx = navigatorKey.currentContext;
    if (ctx != null) await showUpdateDialog(ctx, info);
  } catch (_) {}
}

/// Process a deep link URI like:
/// - phoneopia://chat/{username}
/// - https://phoneopia.com/s/{username}
void _handleDeepLink(String uri) {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  final prov = ctx.read<AppProvider>();
  if (!prov.isLoggedIn) return;

  String? username;
  // phoneopia://chat/{username}
  if (uri.startsWith('phoneopia://chat/')) {
    username = uri.substring('phoneopia://chat/'.length);
  }
  // https://phoneopia.com/s/{username}
  if (uri.contains('phoneopia.com/s/')) {
    final match = RegExp(r'phoneopia\.com/s/([a-zA-Z0-9_.-]+)').firstMatch(uri);
    if (match != null) username = match.group(1);
  }
  if (username == null || username.isEmpty) return;

  // Find existing conversation with this user
  for (final c in prov.conversations) {
    if (c.otherUser?.username == username) {
      prov.openChatFromNotification(c.id, c.otherUser?.id);
      return;
    }
  }
  // If no existing conversation, store pending username and go to home
  // (new_chat_screen will handle creating the conversation)
  prov.setPendingDeepLinkUsername(username);
}

void _handleCallNotification(NotificationResponse resp) {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  final prov = ctx.read<AppProvider>();

  if (resp.actionId == NotificationService.callActionDecline) {
    prov.declineIncomingCallFromNotification(resp.payload);
    return;
  }
  if (resp.actionId == NotificationService.callActionAccept ||
      resp.payload != null) {
    prov.presentIncomingCallFromNotification(resp.payload);
  }
}

Future<void> _goHomeThenOpenChat(int convId, int toRaw) async {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  await ensureGDriveThenGoHome(ctx);
  if (convId > 0) {
    final ctx2 = navigatorKey.currentContext;
    if (ctx2 != null)
      ctx2.read<AppProvider>().openChatFromNotification(
        convId,
        toRaw > 0 ? toRaw : null,
      );
  }
}

void _handleNotificationTap(NotificationResponse resp) {
  if (resp.actionId == NotificationService.callActionDecline ||
      resp.actionId == NotificationService.callActionAccept) {
    _handleCallNotification(resp);
    return;
  }
  if (resp.payload == null) return;
  try {
    final data = jsonDecode(resp.payload!) as Map<String, dynamic>;
    final type = data['type'];
    if (type == 'message') {
      final convId = int.tryParse(data['conv_id']?.toString() ?? '0') ?? 0;
      final toRaw = int.tryParse(data['to_user_id']?.toString() ?? '0') ?? 0;
      unawaited(_goHomeThenOpenChat(convId, toRaw));
    } else if (type == 'incoming_call') {
      _handleCallNotification(resp);
    }
  } catch (_) {}
}

void main() {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: Colors.white,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
      );

      // Register callbacks synchronously, but never hold Flutter's first frame
      // behind several native plugin/network initializers. On slower phones the
      // old sequential awaits blocked launch for 4-7 seconds and Android logged
      // hundreds of skipped frames before the splash could even render.
      NotificationService.onTap = _handleNotificationTap;
      onCallNotificationAction = _handleCallNotification;

      runApp(
        ChangeNotifierProvider(
          create: (_) => AppProvider(),
          child: const PhoneopiaApp(),
        ),
      );

      // Let the splash render first, then bring notifications/background/FCM
      // online. These remain automatic and start within the first frame, but
      // can no longer freeze the visible UI while Android services initialise.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(const Duration(milliseconds: 1200), () {
          unawaited(_initRuntimeServices());
        });
      });
    },
    (error, stack) {
      // Diagnostic instrumentation — captures the ORIGINAL call site for
      // uncaught async errors during startup, since the engine's own log line
      // only shows Future-internal frames (dart:async), not where the
      // offending .catchError/.then was actually attached in our code.
      debugPrint('PHONEOPIA_ZONE_ERROR: $error');
      debugPrint('PHONEOPIA_ZONE_STACK:\n$stack');
    },
  );
}

Future<void> _initRuntimeServices() async {
  try {
    await NotificationService().init();
  } catch (_) {}
  await Future.wait<void>([
    () async {
      try {
        await initBackgroundService();
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getString('phoneopia_token') != null) {
          await startBackgroundService();
        }
      } catch (_) {}
    }(),
    () async {
      try {
        await FcmService().init();
      } catch (_) {}
    }(),
  ]);

  // ── Deep link listener ──────────────────────────────────────────────
  _deepLinkChannel.setMethodCallHandler((call) async {
    if (call.method == 'onDeepLink') {
      final uri = call.arguments?.toString() ?? '';
      if (uri.isNotEmpty) _handleDeepLink(uri);
    }
  });
  // Process any initial deep link (app opened from link while cold/killed)
  try {
    final initial = await _deepLinkChannel.invokeMethod<String>('getInitialLink');
    if (initial != null && initial.isNotEmpty) _handleDeepLink(initial);
  } catch (_) {}
}

class PhoneopiaApp extends StatelessWidget {
  const PhoneopiaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<AppProvider>();
    return MaterialApp(
      title: 'Phoneopia',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      navigatorObservers: [_incomingCallRouteObserver],
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: prov.themeMode,
      home: const SplashScreen(),
      onGenerateRoute: (settings) {
        Widget page;
        switch (settings.name) {
          case '/login':
            page = const LoginScreen();
            break;
          case '/home':
            page = const HomeScreen();
            break;
          case '/setup':
            page = const ProfileSetupScreen();
            break;
          case '/qr':
            page = const QrScanScreen();
            break;
          case '/linked_devices':
            page = const LinkedDevicesScreen();
            break;
          case '/web_sync':
            page = const WebSyncScreen();
            break;
          case '/link_device':
            page = const LinkDeviceScreen();
            break;
          case '/nearby':
            page = const NearbyScreen();
            break;
          default:
            page = prov.isLoggedIn ? const HomeScreen() : const LoginScreen();
        }
        return PageRouteBuilder(
          settings: settings,
          pageBuilder: (_, __, ___) => page,
          transitionsBuilder: (_, a, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: a, curve: Curves.easeIn),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 300),
        );
      },
      builder: (context, child) => MediaQuery(
        // Apply the user's chosen font size globally.
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(prov.fontScale)),
        child: SafetyGate(
          child: _CallOverlayWrapper(child: child ?? const SizedBox()),
        ),
      ),
    );
  }
}

class _CallOverlayWrapper extends StatefulWidget {
  final Widget child;
  const _CallOverlayWrapper({required this.child});
  @override
  State<_CallOverlayWrapper> createState() => _CallOverlayWrapperState();
}

class _CallOverlayWrapperState extends State<_CallOverlayWrapper>
    with WidgetsBindingObserver {
  int _shownCallNonce = -1;
  // Guards the pop+push below against overlapping presentations — two
  // incoming-call signals arriving close together (e.g. a Nearby offer
  // retried while the first is still being presented) could otherwise each
  // schedule their own postFrameCallback and race a popUntil/push against
  // each other, which is what threw the Flutter element-tree assertion
  // ('_elements.contains(element)': is not true).
  bool _presentingCall = false;
  Timer? _fgBeacon;
  Timer? _updatePoll;
  ({String path, int versionCode})? _pendingInstall;
  bool _reopeningInstaller = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _markForeground(true);
    // Check for an OTA update shortly after launch.
    Future.delayed(const Duration(seconds: 4), () async {
      if (!mounted) return;
      await maybePromptAppUpdate();
      _checkPendingInstall(); // pick up right away if the dialog just closed without installing
    });
    _checkPendingInstall();
    // Re-check periodically while the app stays open on one screen — launch
    // and resume alone would miss an update published while someone sits in
    // a chat for a while. force:true bypasses the once-per-session cache.
    _updatePoll = Timer.periodic(const Duration(minutes: 5), (_) async {
      if (mounted) await maybePromptAppUpdate(force: true);
      _checkPendingInstall();
    });
  }

  Future<void> _checkPendingInstall() async {
    final p = await UpdateService().pendingInstall();
    if (mounted) setState(() => _pendingInstall = p);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _fgBeacon?.cancel();
    _updatePoll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    _markForeground(resumed);
    if (!resumed) {
      SharedPreferences.getInstance().then(
        (p) => p.setInt(StorageKeys.appForegroundAt, 0),
      );
    }
    if (state == AppLifecycleState.resumed) {
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        final prov = ctx.read<AppProvider>();
        unawaited(prov.purgeStaleCallState());
        // Retry Firebase after Play Services/network becomes available. This
        // keeps closed-app call/message delivery working after a transient
        // startup failure without requiring a manual app restart.
        unawaited(FcmService().init());
        unawaited(prov.ensurePushRegistered());
        prov.refreshRecents();
        prov.restorePendingIncomingCall();
      }
      maybePromptAppUpdate().then((_) => _checkPendingInstall());
      _checkPendingInstall();
    }
  }

  // The background service skips notifications while the UI is visible —
  // this heartbeat tells it the app is in the foreground.
  void _markForeground(bool visible) {
    _fgBeacon?.cancel();
    if (visible) {
      _writeBeacon();
      _fgBeacon = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _writeBeacon(),
      );
    } else {
      SharedPreferences.getInstance().then(
        (p) => p.setInt(StorageKeys.appForegroundAt, 0),
      );
    }
  }

  void _writeBeacon() {
    SharedPreferences.getInstance().then(
      (p) => p.setInt(
        StorageKeys.appForegroundAt,
        DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<AppProvider>();
    final callData = prov.incomingCall;
    final nonce = prov.incomingCallNonce;

    void showIncomingCallScreen(Map<String, dynamic> snapshot) {
      if (_presentingCall) return;
      _presentingCall = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Don't force-navigate away from whatever the user is doing.
        // The call banner (below) + notification Accept/Decline are the
        // primary UIs. Only push the full-screen attend screen when the
        // user explicitly taps the banner or notification.
        FocusManager.instance.primaryFocus?.unfocus();
      });
      _presentingCall = false;
    }

    // inActiveCallUi guard here matters even more than on the banner below:
    // showIncomingCallScreen pops back to the app shell before pushing —
    // without this check, a stray late re-presentation of the call that's
    // already active (see the banner comment above for why that happens)
    // wouldn't just show a wrong banner, it would yank the user straight
    // out of their own active call screen.
    if (callData != null && nonce != _shownCallNonce && !prov.inActiveCallUi) {
      _shownCallNonce = nonce;
      NotificationService().cancelCallNotification();
      showIncomingCallScreen(Map<String, dynamic>.from(callData));
    }

    // Still ringing (prov.incomingCall survives both Accept and Decline —
    // both clear it — so non-null here means neither happened) but its
    // fullscreen screen got swiped/backed away from underneath it. Surface
    // a tappable top banner instead of just losing the call silently.
    // inActiveCallUi is checked directly too — a stray late re-presentation
    // of the SAME call (the notification's own Accept action re-presents it
    // independently of the actual in-app accept flow, and the two can race)
    // must never show this banner over a call that's already genuinely
    // active, even if _incomingCall itself didn't get cleared in time.
    final showCallBanner =
        callData != null &&
        !_incomingCallRouteObserver.isTop &&
        !prov.inActiveCallUi;

    if (_pendingInstall == null && !showCallBanner) return widget.child;

    // A downloaded update is sitting there un-installed — Android only opens
    // its own confirmation screen, it doesn't force the user through it, so
    // this stays up (re-checked every 5 min + on resume) until the install
    // actually happens or the user dismisses it.
    return Stack(
      children: [
        widget.child,
        if (showCallBanner)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: SafeArea(
              bottom: false,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B8457),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        callData['call_type']?.toString() == 'video'
                            ? Icons.videocam
                            : Icons.call,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${callData['from_display_name'] ?? callData['from_username'] ?? 'Someone'}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              callData['call_type']?.toString() == 'video'
                                  ? 'Incoming video call'
                                  : 'Incoming voice call',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Decline button
                      GestureDetector(
                        onTap: () {
                          final prov = Provider.of<AppProvider>(
                            context,
                            listen: false,
                          );
                          prov.dismissIncomingCall(
                            sendReject: true,
                            callerId: int.tryParse(
                              callData['from_user_id']?.toString() ?? '',
                            ),
                            convId: int.tryParse(
                              callData['conversation_id']?.toString() ?? '',
                            ) ?? 0,
                            isVideo: callData['call_type']?.toString() == 'video',
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(
                            Icons.call_end,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Accept button
                      GestureDetector(
                        onTap: () {
                          // Navigate directly to ActiveCallScreen
                          final nav = navigatorKey.currentState;
                          if (nav == null) return;
                          final callerName =
                              callData['from_display_name']?.toString() ??
                              callData['from_username']?.toString() ??
                              'Unknown';
                          final callerId = int.tryParse(
                            callData['from_user_id']?.toString() ?? '',
                          );
                          final convId = int.tryParse(
                            callData['conversation_id']?.toString() ?? '',
                          ) ?? 0;
                          final prov = Provider.of<AppProvider>(
                            context,
                            listen: false,
                          );
                          prov.setInActiveCallUi(true);
                          if (callerId != null) {
                            prov.setActiveCallPeer(callerId.toString());
                          }
                          prov.clearIncomingCall();
                          nav.push(
                            MaterialPageRoute(
                              builder: (_) => ActiveCallScreen(
                                callerName: callerName,
                                callerAvatar: callData['from_avatar']
                                    ?.toString(),
                                isVideo: callData['call_type']?.toString() == 'video',
                                convId: convId,
                                isOutgoing: false,
                                calleeUserId: callerId,
                                incomingOfferSdp: callData['sdp']
                                    ?.toString(),
                                incomingOfferType: callData['sdp_type']
                                        ?.toString() ??
                                    'offer',
                                viaNearby: callData['via_nearby'] == true,
                                callId: callData['call_id']?.toString() ??
                                    callData['nearby_call_id']?.toString(),
                              ),
                            ),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.green,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Icon(
                            Icons.call,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (_pendingInstall != null)
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: SafeArea(
              top: false,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111B21),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.system_update_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Update download ho chuka hai — install abhi baaki hai',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _reopeningInstaller
                            ? null
                            : () async {
                                setState(() => _reopeningInstaller = true);
                                await UpdateService().reopenInstaller(
                                  _pendingInstall!.path,
                                );
                                if (mounted)
                                  setState(() => _reopeningInstaller = false);
                              },
                        child: Text(
                          _reopeningInstaller ? '…' : 'Install',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.close,
                          color: Colors.white70,
                          size: 18,
                        ),
                        onPressed: () async {
                          await UpdateService().clearPendingInstall();
                          if (mounted) setState(() => _pendingInstall = null);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
