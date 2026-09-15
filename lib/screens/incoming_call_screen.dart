import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/audio_service.dart';
import '../services/call_alert_service.dart';
import '../services/nearby_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import 'active_call_screen.dart';
import 'group_call_screen.dart';

class IncomingCallScreen extends StatefulWidget {
  final Map<String, dynamic> callData;
  const IncomingCallScreen({super.key, required this.callData});
  @override State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> with TickerProviderStateMixin {
  late AnimationController _pulse1Ctrl;
  late AnimationController _pulse2Ctrl;
  late AnimationController _slideCtrl;
  late AnimationController _btnCtrl;
  bool _handling = false;
  Timer? _vibrateTimer;

  void _stopVibration() { _vibrateTimer?.cancel(); _vibrateTimer = null; }

  @override
  void initState() {
    super.initState();
    NotificationService().cancelCallNotification();
    if (!AudioService().isPlaying) AudioService().playIncomingCall();
    // Tell the caller their offer genuinely reached this device and is
    // ringing right now — without this, "Ringing…" on their screen was just
    // an assumption made the instant the offer was sent, true or not. Only
    // fires once this screen actually exists, so it can't lie either.
    final ackCallerId = _callerId;
    if (ackCallerId != null) {
      if (widget.callData['via_nearby'] == true) {
        unawaited(NearbyService().sendCallSignal(ackCallerId, {'type': 'call_ringing'}));
      } else {
        context.read<AppProvider>().sendWs({'type': 'call_ringing', 'target_user_id': ackCallerId});
      }
    }
    // Continuous vibration while ringing — keeps buzzing until the user
    // accepts or declines (stopped in dispose / on accept / on decline).
    HapticFeedback.heavyImpact();
    _vibrateTimer = Timer.periodic(const Duration(milliseconds: 1100), (_) {
      HapticFeedback.heavyImpact();
    });
    _pulse1Ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))..repeat();
    _pulse2Ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
    _slideCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _btnCtrl    = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _pulse2Ctrl.repeat();
    });
    _slideCtrl.forward();
    _btnCtrl.forward();
  }

  @override
  void dispose() {
    _stopVibration();
    _pulse1Ctrl.dispose();
    _pulse2Ctrl.dispose();
    _slideCtrl.dispose();
    _btnCtrl.dispose();
    super.dispose();
  }

  String get _name    => widget.callData['from_display_name']?.toString() ?? widget.callData['from_username']?.toString() ?? 'Unknown';
  String? get _avatar => AvatarWidget.resolveUrl(widget.callData['from_avatar']?.toString());
  bool get _isVideo   => widget.callData['call_type']?.toString() == 'video';
  int get _convId     => int.tryParse(widget.callData['conversation_id']?.toString() ?? '') ?? 0;
  int? get _callerId  => int.tryParse(widget.callData['from_user_id']?.toString() ?? '');

  Future<void> _accept() async {
    if (_handling) return;
    _handling = true;
    _stopVibration();
    _pulse1Ctrl.stop(); _pulse2Ctrl.stop();
    final prov = context.read<AppProvider>();
    // The ringtone loop otherwise kept playing through the whole WebRTC
    // accept/handshake sequence in ActiveCallScreen (which only stops it
    // once that async work finishes) — stop it the instant Accept is tapped.
    unawaited(prov.stopRing());

    prov.setInActiveCallUi(true);
    unawaited(CallAlertService().stopAll());
    unawaited(CallAlertService().clearPendingCall());
    prov.clearIncomingCall();

    if (!mounted) return;
    final nav = Navigator.of(context, rootNavigator: true);

    // Group call → join the mesh instead of a 1-1 connection.
    if (widget.callData['is_group'] == true) {
      final convId = int.tryParse(widget.callData['group_conv_id']?.toString() ?? '') ?? _convId;
      final members = prov.conversationById(convId)?.members ?? const <GroupMember>[];
      nav.pushReplacement(_callRoute(GroupCallScreen(
        convId: convId,
        groupName: _name,
        isInitiator: false,
        members: members,
      )));
      return;
    }

    if (_callerId != null) prov.setActiveCallPeer(_callerId.toString());
    nav.pushReplacement(_callRoute(ActiveCallScreen(
      callerName: _name, callerAvatar: _avatar, isVideo: _isVideo, convId: _convId,
      isOutgoing: false, calleeUserId: _callerId,
      incomingOfferSdp: widget.callData['sdp']?.toString(),
      incomingOfferType: widget.callData['sdp_type']?.toString() ?? 'offer',
      viaNearby: widget.callData['via_nearby'] == true,
      callId: widget.callData['call_id']?.toString() ?? widget.callData['nearby_call_id']?.toString(),
    )));
  }

  Future<void> _decline() async {
    if (_handling) return;
    _handling = true;
    _stopVibration();
    _pulse1Ctrl.stop(); _pulse2Ctrl.stop();
    final prov = context.read<AppProvider>();
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    unawaited(prov.dismissIncomingCall(
      sendReject: true,
      callerId: _callerId,
      convId: _convId,
      isVideo: _isVideo,
    ));
  }

  static PageRoute _callRoute(Widget page) => PageRouteBuilder(
    pageBuilder: (_, a, __) => page,
    transitionsBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
    transitionDuration: const Duration(milliseconds: 300),
  );

  @override
  Widget build(BuildContext context) {
    // This screen previously had NO way to know the caller hung up before
    // being answered — call_end/call_missed arriving over the wire clears
    // AppProvider.incomingCall correctly, but nothing here ever reacted to
    // that, leaving the attend screen sitting on top of the caller's own
    // already-ended call. _handling guards against reacting to OUR OWN
    // accept/decline (which also clears incomingCall, deliberately, right
    // before popping this same screen).
    final stillIncoming = context.watch<AppProvider>().incomingCall != null;
    if (!stillIncoming && !_handling) {
      _handling = true;
      _stopVibration();
      unawaited(AudioService().stop());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
      });
    }

    final size = MediaQuery.of(context).size;
    final hasPhoto = _avatar != null && _avatar!.isNotEmpty;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // Blurred caller photo as the wallpaper (iPhone style)
        if (hasPhoto) Positioned.fill(
          child: Image.network(_avatar!, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox()),
        ),
        Positioned.fill(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: hasPhoto
                      ? [Colors.black.withOpacity(.45), Colors.black.withOpacity(.75)]
                      : [const Color(0xFF0D2014), const Color(0xFF071510)],
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
        ),

        Builder(builder: (context) {
          return SafeArea(child: Column(children: [
            const Spacer(flex: 2),

            // Pulsing rings + avatar
            AnimatedBuilder(
              animation: Listenable.merge([_pulse1Ctrl, _pulse2Ctrl]),
              builder: (_, child) => SizedBox(
                width: 220, height: 220,
                child: Stack(alignment: Alignment.center, children: [
                  // Ring 2 (outer, delayed)
                  Transform.scale(
                    scale: 1.0 + _pulse2Ctrl.value * 1.1,
                    child: Opacity(
                      opacity: ((1 - _pulse2Ctrl.value) * 0.25).clamp(0.0, 1.0),
                      child: Container(
                        width: 120, height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.primary, width: 2),
                        ),
                      ),
                    ),
                  ),
                  // Ring 1 (inner)
                  Transform.scale(
                    scale: 1.0 + _pulse1Ctrl.value * 0.65,
                    child: Opacity(
                      opacity: ((1 - _pulse1Ctrl.value) * 0.5).clamp(0.0, 1.0),
                      child: Container(
                        width: 120, height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary.withOpacity(0.18),
                        ),
                      ),
                    ),
                  ),
                  child!,
                ]),
              ),
              child: AvatarWidget(imageUrl: _avatar, name: _name, size: 108),
            ),

            const SizedBox(height: 28),
            SlideTransition(
              position: Tween(begin: const Offset(0, 0.4), end: Offset.zero)
                  .animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOut)),
              child: FadeTransition(
                opacity: _slideCtrl,
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(_name,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
                  ),
                  const SizedBox(height: 10),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_isVideo ? Icons.videocam : Icons.call, color: Colors.white60, size: 15),
                    const SizedBox(width: 6),
                    Text(
                      _isVideo ? 'Incoming video call...' : 'Incoming call...',
                      style: const TextStyle(color: Colors.white60, fontSize: 14, letterSpacing: 0.3),
                    ),
                  ]),
                ]),
              ),
            ),

            const Spacer(flex: 3),

            // Action buttons
            FadeTransition(
              opacity: _btnCtrl,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.5), end: Offset.zero)
                    .animate(CurvedAnimation(parent: _btnCtrl, curve: Curves.easeOut)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 60),
                  child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    _ActionButton(
                      icon: Icons.call_end,
                      color: const Color(0xFFEF4444),
                      label: 'Decline',
                      onTap: _decline,
                    ),
                    _ActionButton(
                      icon: Icons.call,
                      color: AppColors.primary,
                      label: 'Accept',
                      onTap: _accept,
                    ),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 64),
          ]));
        }),
      ]),
    );
  }
}

class _ActionButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;
  const _ActionButton({required this.icon, required this.color, required this.label, required this.onTap});
  @override State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override void initState() { super.initState(); _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 120), lowerBound: 0.85, upperBound: 1.0, value: 1.0); }
  @override void dispose() { _c.dispose(); super.dispose(); }

  void _down(_) => _c.reverse();
  void _up(_) => _c.forward();

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: _down,
    onTapUp: _up,
    onTapCancel: () => _c.forward(),
    onTap: widget.onTap,
    child: Column(children: [
      ScaleTransition(
        scale: _c,
        child: ClipOval(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              width: 78, height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withOpacity(0.92),
                border: Border.all(color: Colors.white.withOpacity(0.25), width: 1.5),
                boxShadow: [BoxShadow(color: widget.color.withOpacity(0.45), blurRadius: 24, spreadRadius: 1)],
              ),
              child: Icon(widget.icon, color: Colors.white, size: 33),
            ),
          ),
        ),
      ),
      const SizedBox(height: 11),
      Text(widget.label, style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
    ]),
  );
}
