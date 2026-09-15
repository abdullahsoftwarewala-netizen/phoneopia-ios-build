import 'dart:async' show Timer, StreamSubscription, unawaited;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../config/app_config.dart';
import '../config/feature_flags.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../services/background_service.dart' show startCallKeepAlive, stopCallKeepAlive;
import '../services/call_service.dart';
import '../services/notification_service.dart';
import '../services/nearby_service.dart';
import '../services/nearby_voice_call_service.dart';
import '../services/sse_service.dart';
import '../services/websocket_service.dart' show WsMessageCallback;
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCVideoView, RTCVideoViewObjectFit;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import 'missed_call_screen.dart';

class ActiveCallScreen extends StatefulWidget {
  final String callerName;
  final String? callerAvatar;
  final bool isVideo;
  final int convId;
  final bool isOutgoing;
  final int? calleeUserId;
  final String? incomingOfferSdp;
  final String? incomingOfferType;
  final bool viaNearby;
  final String? callId;
  const ActiveCallScreen({
    super.key,
    required this.callerName,
    required this.callerAvatar,
    required this.isVideo,
    required this.convId,
    required this.isOutgoing,
    this.calleeUserId,
    this.incomingOfferSdp,
    this.incomingOfferType,
    this.viaNearby = false,
    this.callId,
  });
  @override
  State<ActiveCallScreen> createState() => _ActiveCallScreenState();
}

class _ActiveCallScreenState extends State<ActiveCallScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  late AnimationController _fadeCtrl;
  late AnimationController _pipCtrl;

  bool _muted = false;
  bool _speaker = true;
  bool _videoOn = true;
  bool _isVideoCall = false;
  bool _upgradeRequested = false;
  bool _connected = false;
  bool _peerRinging = false;
  // SSE and the direct poll fallback can deliver the same answer. Mark it as
  // consumed before awaiting WebRTC so a duplicate cannot apply an answer to
  // an already-stable PeerConnection.
  bool _answerApplied = false;
  bool _recording = false;
  final _callRecorder = AudioRecorder();
  String? _recordPath;

  // Captured right after startOutgoing/acceptIncoming create the peer
  // connection this screen actually owns — passed to every CallService().end()
  // call below so a stale dispose()/timeout firing after the user already
  // redialed can never tear down a newer call's live connection. See the
  // token's definition in call_service.dart for the full story.
  int? _myCallToken;

  Duration _elapsed = Duration.zero;
  Timer? _timer;
  Timer? _ringTimer;
  Timer? _pollTimer;
  Timer? _mediaWaitTimer;
  late WsMessageCallback _wsHandler;
  int _lastBusyAt = 0;
  bool _callEnded = false;
  bool _offline = false;
  // Set while mid-call internet loss is being handled — either waiting to
  // see if it comes back, or actively handing the call off to the Nearby
  // Bluetooth link if the peer happens to be in range.
  bool _reconnecting = false;
  // Set once the reconnect grace window has genuinely run out — shows an
  // explicit Retry/End Call choice instead of silently killing the call.
  // "Unable to reconnect" is a dead end the user resolves, not a state we
  // auto-exit from.
  bool _reconnectFailed = false;
  String? _lastAcceptError;
  bool _switchingToNearby = false;
  Timer? _reconnectGraceTimer;
  Timer? _nearbyReconnectGraceTimer;
  bool _nearbyReconnecting = false;
  Timer? _reconnectingUiTimer;
  int _callPollLastId = 0;
  bool _callPollInFlight = false;
  late final int _callStartedEpochSeconds;
  late final String _callId;
  final Set<int> _handledCallEventIds = <int>{};
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _viaNearby = false;
  StreamSubscription<Map<String, dynamic>>? _nearbyCallSub;
  List<ConnectivityResult> _connKinds = const [];

  Offset _pipPos = const Offset(16, 400);

  /// Routes a call-signaling message to wherever this call's peer actually
  /// is — the normal server relay, or straight over the Bluetooth/WiFi
  /// Direct link when there's no internet but the peer is right there.
  void _sendSignal(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    final payload = type.startsWith('call_') || type.startsWith('ice_restart_')
        ? <String, dynamic>{...data, 'call_id': data['call_id'] ?? _callId}
        : data;
    if (_viaNearby) {
      final peerId = widget.calleeUserId;
      if (peerId != null)
        unawaited(_sendNearbySignalWithRetry(peerId, payload));
    } else {
      context.read<AppProvider>().sendWs(payload);
    }
  }

  /// The server path already has a poll-fallback specifically because a
  /// single WS/SSE delivery attempt can silently drop call_answer — Nearby's
  /// sendBytesPayload has the exact same failure mode (a transient send
  /// right after the link comes up, a brief hiccup) but had no equivalent
  /// safety net at all: one failed attempt and the answer was gone forever,
  /// leaving the callee genuinely connected while the caller sat on "No
  /// answer". Retry a few times before giving up.
  Future<void> _sendNearbySignalWithRetry(
    int peerId,
    Map<String, dynamic> data,
  ) async {
    // _callEnded is set true right before _endCall() sends its call_end
    // signal — bailing out on _callEnded here meant this loop never even
    // attempted the one send that actually matters most (hanging up),
    // which is exactly why the other side never saw the disconnect. Only
    // stop retrying if the whole service was torn down (nothing left to
    // send to); the widget's own mounted/lifecycle state doesn't matter —
    // this doesn't touch context or setState.
    final type = data['type']?.toString() ?? '';
    final copiesNeeded =
        (type == 'call_end' ||
            type == 'call_answer' ||
            type == 'call_reject' ||
            type == 'call_busy' ||
            type == 'call_switch_nearby')
        ? 3
        : (type == 'call_offer' ? 2 : 1);
    var sent = 0;
    for (var i = 0; i < 8; i++) {
      if (await NearbyService().sendCallSignal(peerId, data)) {
        sent++;
        if (sent >= copiesNeeded) return;
      }
      await Future.delayed(Duration(milliseconds: sent > 0 ? 140 : 400));
    }
  }

  /// Fires on every NearbyService state change while this screen is alive.
  /// Only cares about one thing: an already-connected Nearby call whose
  /// underlying link just disappeared — that link IS the call's only media
  /// path, so losing it means the call is over even if no call_end signal
  /// ever arrives (the peer may be out of range or already gone).
  void _onNearbyLinkChanged() {
    if (!mounted || _callEnded || !_viaNearby || !_connected) return;
    final peerId = widget.calleeUserId;
    if (peerId == null || NearbyService().isUserReachable(peerId)) return;
    // The Bluetooth link just dropped mid-call. Range hiccups are common and
    // often clear up within a few seconds — try to relink instead of ending
    // the call the instant the connection blips. NearbyVoiceCallService
    // itself doesn't need restarting: it only holds the peer's user id, not
    // a stale endpoint, so audio just resumes once isUserReachable is true
    // again.
    if (_reconnecting)
      return; // an attempt (or its grace timer) is already running
    setState(() => _reconnecting = true);
    _armNearbyReconnectGraceTimer(peerId);
    unawaited(_tryReconnectNearbyLink(peerId));
  }

  /// Actively re-discover/re-link the peer over Bluetooth. Same retry shape
  /// as _tryHandoffToNearby's wait loop, just without the WebRTC teardown
  /// since we're already on the Nearby pipeline.
  Future<void> _tryReconnectNearbyLink(int peerId) async {
    if (_nearbyReconnecting) return;
    _nearbyReconnecting = true;
    try {
      for (var i = 0; i < 20 && mounted && !_callEnded && _viaNearby; i++) {
        if (NearbyService().isUserReachable(peerId)) {
          _nearbyReconnectGraceTimer?.cancel();
          if (mounted && (_reconnecting || _reconnectFailed)) {
            setState(() {
              _reconnecting = false;
              _reconnectFailed = false;
            });
          }
          return;
        }
        unawaited(NearbyService().refresh());
        await Future.delayed(const Duration(seconds: 1));
      }
    } finally {
      _nearbyReconnecting = false;
    }
  }

  /// Mirrors _armReconnectGraceTimer but for a dropped Nearby link — shows
  /// the same "Unable to reconnect" Retry/End Call screen if 25s of active
  /// re-linking attempts don't find the peer again.
  void _armNearbyReconnectGraceTimer(int peerId) {
    _nearbyReconnectGraceTimer?.cancel();
    _nearbyReconnectGraceTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted || _callEnded || !_viaNearby || !_reconnecting) return;
      if (NearbyService().isUserReachable(peerId)) return;
      setState(() {
        _reconnecting = false;
        _reconnectFailed = true;
      });
      context.read<AppProvider>().stopRing();
    });
  }

  /// Internet just dropped mid-call. If the peer happens to be reachable
  /// over Bluetooth right now, hand the call off to the Nearby raw-audio
  /// pipeline instead of just letting WebRTC quietly die. Notifying them
  /// has to go straight over Nearby, not through the usual _sendSignal
  /// router — that router itself decides Nearby-vs-WS based on _viaNearby,
  /// which is still false at this exact moment (we're only just switching).
  Future<void> _tryHandoffToNearby() async {
    if (_switchingToNearby || _viaNearby || _callEnded || !_connected) return;
    final peerId = widget.calleeUserId;
    if (peerId == null) return;
    _switchingToNearby = true;
    // Internet can disappear before the continuous Nearby discovery has
    // completed its handshake. Wait briefly and actively retry instead of
    // checking once and giving up for the rest of the call.
    for (var i = 0; i < 12 && !_callEnded; i++) {
      if (NearbyService().isUserReachable(peerId)) break;
      unawaited(NearbyService().refresh());
      await Future.delayed(const Duration(seconds: 1));
    }
    if (_callEnded || !NearbyService().isUserReachable(peerId)) {
      _switchingToNearby = false;
      return;
    }
    // A single sendCallSignal() attempt here used to mean: if that one
    // Bluetooth payload silently dropped (the same known transient failure
    // as call_offer/call_answer), the peer never learned to switch over and
    // sat stuck on "Reconnecting" forever while our own side had already
    // moved to "Using Nearby" — exactly the asymmetric state that was
    // reported. Same retry helper used for every other Nearby signal.
    await _sendNearbySignalWithRetry(peerId, {'type': 'call_switch_nearby'});
    await _switchToNearby(peerId);
  }

  /// Actually perform the handoff — either because we detected the loss and
  /// the peer confirmed reachable, or because the peer told us they're
  /// switching (call_switch_nearby arrived from their side instead).
  Future<void> _switchToNearby(int peerId) async {
    if (_viaNearby || _callEnded) return;
    // Must be awaited — this releases WebRTC's own VOICE_COMMUNICATION mic
    // recorder, and Nearby's native audio bridge grabs a mic recorder of
    // its own right after. Starting that before this actually finished
    // meant the two fought over the same Android audio resource and
    // Nearby's side lost, leaving the mic silent for the rest of the call.
    await CallService().end(expectedToken: _myCallToken);
    _viaNearby = true;
    _switchingToNearby = false;
    if (_videoOn) setState(() => _videoOn = false);
    await NearbyVoiceCallService().start(peerId);
    // Carry over whatever mute/speaker state was already set on the WebRTC
    // side — the new pipeline starts fresh and doesn't know about it.
    NearbyVoiceCallService().muted = _muted;
    unawaited(NearbyVoiceCallService().setSpeaker(_speaker));
    _reconnectGraceTimer?.cancel();
    if (mounted)
      setState(() {
        _reconnecting = false;
        _reconnectFailed = false;
      });
  }

  /// Requests the peer's consent before upgrading a plain audio call to
  /// video mid-call — actually adding the video track only happens after
  /// they say yes (video_upgrade_response), not on this tap.
  void _requestVideoUpgrade() {
    if (_viaNearby ||
        _isVideoCall ||
        _upgradeRequested ||
        widget.calleeUserId == null)
      return;
    setState(() => _upgradeRequested = true);
    _sendSignal({
      'type': 'video_upgrade_request',
      'target_user_id': widget.calleeUserId,
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Video call ki request bheji gayi…'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showVideoUpgradeDialog() async {
    if (!mounted || _callEnded || _isVideoCall) return;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Video call'),
        content: Text(
          '${widget.callerName} video call pe switch karna chahte hain.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (!mounted || _callEnded || widget.calleeUserId == null) return;
    _sendSignal({
      'type': 'video_upgrade_response',
      'target_user_id': widget.calleeUserId,
      'accepted': accepted == true,
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Keep screen on + device awake during calls
    WakelockPlus.enable();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _pipCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _fadeCtrl.forward();
    _videoOn = widget.isVideo;
    _callStartedEpochSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    _callId = (widget.callId != null && widget.callId!.trim().isNotEmpty)
        ? widget.callId!.trim()
        : '${DateTime.now().microsecondsSinceEpoch}_${widget.calleeUserId ?? 0}';
    // Phoneopia currently supports reliable voice calls only.
    _isVideoCall = false;
    _videoOn = false;
    _viaNearby = widget.viaNearby;

    _wsHandler = _onWsMessage;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final prov = context.read<AppProvider>();
      prov.setInActiveCallUi(true);
      if (widget.calleeUserId != null) {
        prov.setActiveCallPeer(widget.calleeUserId.toString());
      }
      prov.addWsListener(_wsHandler);

      // Signaling that arrives over Nearby instead of the server — same
      // shape as a WS event, so it feeds through the exact same handler.
      _nearbyCallSub = NearbyService().onCallSignal.listen((data) {
        if (data['type'] == 'call_offer')
          return; // handled at the app level to ring
        final peerId = widget.calleeUserId;
        final fromId = int.tryParse(data['from_user_id']?.toString() ?? '');
        if (peerId != null && fromId != null && fromId != peerId) return;
        _onWsMessage(data);
      });
      // A Nearby call's only transport IS the Bluetooth/WiFi Direct link —
      // if it drops (out of range, radio churn, peer's app killed) there is
      // no server relay to fall back on for delivering call_end, so a lost
      // retry left this screen sitting on "Connected" forever with the other
      // side already gone. The link dropping is itself proof the call is
      // over — don't wait for a signal that may never arrive.
      NearbyService().addListener(_onNearbyLinkChanged);

      // If internet drops while we're still ringing/connecting (not yet
      // _connected), stop pretending the call is progressing — show "No
      // internet" instead of leaving the ringtone playing over a dead link.
      // Not for a call already going over Nearby — that's expected to be
      // offline the whole time, that's the entire point of it.
      Connectivity().checkConnectivity().then((r) {
        if (mounted) setState(() => _connKinds = r);
      });
      _connSub = Connectivity().onConnectivityChanged.listen((r) async {
        if (mounted) setState(() => _connKinds = r);
        final pluginSaysOffline =
            r.isEmpty || r.every((c) => c == ConnectivityResult.none);
        final offline = pluginSaysOffline || await ApiService.isOffline();
        if (!mounted || _callEnded || _viaNearby) return;
        if (offline && !_connected) {
          setState(() => _offline = true);
          context.read<AppProvider>().stopRing();
          _logCall();
          _showMissed('No network');
        } else if (offline && _connected) {
          // Already mid-call when the internet dropped — don't just hang up
          // silently and let WebRTC's own ICE timeout eventually kill it.
          // Show "Reconnecting…" and, if the other person happens to be
          // Bluetooth-reachable right now, hand the call off to the Nearby
          // audio pipeline instead of dropping it. Give it a real grace
          // window before giving up — WebRTC's own ICE-gone timeout used to
          // win this race and silently end the call out from under the
          // "Reconnecting…" state the instant it fired, regardless of
          // whether Nearby might still connect a few seconds later.
          if (!_reconnecting) {
            setState(() => _reconnecting = true);
            _armReconnectGraceTimer();
          }
          // kCallNearbyFailoverEnabled: automatic transport switch is
          // disabled for now — still shows Reconnecting and still gives
          // the same-transport ICE restart a chance, just doesn't move the
          // call to a different network.
          if (kCallNearbyFailoverEnabled) unawaited(_tryHandoffToNearby());
        } else if (!offline) {
          if (_offline) setState(() => _offline = false);
          if (_reconnecting && !_switchingToNearby) {
            _reconnectGraceTimer?.cancel();
            setState(() => _reconnecting = false);
          }
          if (_reconnectFailed) setState(() => _reconnectFailed = false);
        }
      });

      // Direct poll fallback — SSE/WS can drop or delay call_answer, leaving
      // the caller stuck on "Ringing" with no audio even though the other
      // side genuinely picked up. This polls the server directly every
      // second for any pending call events, independent of the real-time
      // channel, and feeds them through the same handler. Pointless (and
      // just wasted requests) once we're actually offline over Nearby.
      _pollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) async {
        if (!mounted || _callEnded || _viaNearby || _callPollInFlight) return;
        _callPollInFlight = true;
        try {
          final result = await ApiService.pollCallEvents(
            afterId: _callPollLastId,
            sinceEpochSeconds: _callStartedEpochSeconds - 2,
          );
          _callPollLastId = result['last_id'] as int? ?? _callPollLastId;
          final events =
              result['events'] as List<Map<String, dynamic>>? ?? const [];
          for (final e in events) {
            final eventId = int.tryParse(e['_event_id']?.toString() ?? '');
            if (eventId != null && !_handledCallEventIds.add(eventId)) continue;
            if (mounted && !_callEnded) _onWsMessage(e);
          }
        } finally {
          _callPollInFlight = false;
        }
      });

      // Register media callbacks BEFORE creating/accepting the peer. On the
      // callee, setRemoteDescription can fire onTrack inside acceptIncoming;
      // registering this afterwards loses the only event and the old 15s
      // timer then closed a healthy negotiation as "Call failed".
      CallService().onRemoteStream = _markWebRtcConnected;

      if (widget.isOutgoing) {
        if (widget.calleeUserId == null) {
          if (mounted && !_callEnded) {
            _callEnded = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Call failed — recipient missing'),
                behavior: SnackBarBehavior.floating,
              ),
            );
            final nav = Navigator.of(context, rootNavigator: true);
            if (nav.canPop()) nav.pop();
          }
          return;
        }
        // Do not hold the caller on the ring screen for a full connectivity
        // probe timeout. Nearby reachability is checked immediately below;
        // normal calls can still fall back to the server if the short probe
        // has not completed yet.
        final offline = await ApiService.isOffline().timeout(
          const Duration(milliseconds: 800),
          onTimeout: () => false,
        );
        final nearbyReachable = NearbyService().isUserReachable(
          widget.calleeUserId!,
        );
        if (offline && !nearbyReachable) {
          if (mounted && !_callEnded) {
            setState(() => _offline = true);
            context.read<AppProvider>().stopRing();
            _logCall();
            _showMissed('No network');
          }
          return;
        }
        // Offline but the person is right there over Bluetooth/WiFi Direct —
        // route the whole call through that link instead of the server.
        if (offline && nearbyReachable) _viaNearby = true;
        // Mark the link busy for the WHOLE ring window, not just from answer
        // onward (NearbyVoiceCallService.start() used to be the only place
        // that set this). The health-timer restart of advertising/discovery
        // this guards against causes real BLE radio churn — which was free
        // to fire every 5s throughout the caller's own ringing tone, an
        // audible stutter with no counterpart on a normal network call.
        // Every path that ends this call (answered, missed, rejected, busy,
        // hung up) already calls NearbyVoiceCallService().end(), which
        // unconditionally clears this back to false, so it can't get stuck.
        if (_viaNearby) NearbyService().setVoiceActive(true);
        // Bluetooth alone has no IP layer for WebRTC to use, and forcing a
        // WiFi Direct upgrade just for calling is exactly the disruptive
        // toggle this was built to avoid — Nearby calls carry raw PCM audio
        // directly over the Bluetooth link instead. No video over that path.
        if (_viaNearby) _videoOn = false;
        final permsOk = await _ensureCallPermissions(
          _viaNearby ? false : widget.isVideo,
        );
        if (!permsOk) {
          // Never send a call_offer with no SDP — that used to leave both
          // sides looking "connected" (timer running, UI normal) with zero
          // audio/video actually set up, since no peer connection existed.
          if (mounted && !_callEnded) {
            _logCall();
            _showMissed('Permission denied');
          }
          return;
        }
        Map<String, String>? offer;
        if (_viaNearby) {
          // No SDP needed at all — the "offer" is just the ring signal.
          offer = {'sdp': '', 'sdp_type': ''};
        } else {
          // Start WebRTC and embed the SDP offer so real audio flows
          try {
            offer = await CallService().startOutgoing(
              widget.calleeUserId!,
              widget.isVideo,
              _sendSignal,
            );
          } catch (_) {
            offer = null;
          }
        }
        if (offer == null) {
          // WebRTC setup itself failed (mic/camera busy, codec error, etc.) —
          // same rule: don't pretend the call connected with no media.
          if (mounted && !_callEnded) {
            context.read<AppProvider>().stopRing();
            _logCall();
            _showMissed('Call failed');
          }
          return;
        }
        if (!_viaNearby) _myCallToken = CallService().sessionToken;
        final callOffer = {
          'type': 'call_offer',
          'target_user_id': widget.calleeUserId,
          'call_type': _viaNearby
              ? 'audio'
              : (widget.isVideo ? 'video' : 'audio'),
          'conversation_id': widget.convId,
          'caller_name': prov.me?.displayName ?? '',
          'caller_username': prov.me?.username ?? '',
          'caller_avatar': prov.me?.avatar ?? '',
          'sdp': offer['sdp'],
          'sdp_type': offer['sdp_type'],
          'nearby_call_id':
              '${_callStartedEpochSeconds}_${prov.me?.id ?? 0}_${widget.calleeUserId}',
          'call_id': _callId,
        };
        _sendSignal(callOffer);
        // Auto-end after 45s if not answered → show missed-call screen
        _ringTimer = Timer(const Duration(seconds: 45), () {
          if (mounted && !_connected) {
            context.read<AppProvider>().stopRing();
            if (widget.calleeUserId != null) {
              _sendSignal({
                'type': 'call_end',
                'target_user_id': widget.calleeUserId,
              });
            }
            _logCall();
            _showMissed('No answer');
          }
        });
      } else {
        await _completeIncomingAccept(prov);
      }

      // Safety net — end the call locally if the peer connection is truly
      // gone even without ever receiving a call_end signal from the other
      // side (e.g. their app was backgrounded and the event expired).
      // Skipped while _reconnecting is already handling exactly this
      // situation (internet just dropped) — ICE reporting the peer gone is
      // expected there, not a surprise failure, and used to win the race
      // against the Nearby handoff / grace window and kill the call the
      // instant it fired, before either had a real chance to recover it.
      CallService().onPeerGone = () {
        // _reconnectFailed is a dead end the USER resolves via Retry/End
        // Call — a stray ICE state flip re-arming this safety net must not
        // silently end the call out from under that explicit choice.
        if (!mounted || _callEnded || _reconnecting || _reconnectFailed) return;
        // A peer connection can close during initial ICE/SDP setup before the
        // answer arrives (especially while the other device is waking up).
        // Ending here races the signaling retry and turns a recoverable setup
        // blip into a misleading "No answer". The ring/media timers already
        // handle a genuinely unanswered or unconnected call.
        if (!_connected) return;
        _endCall();
      };

      // ICE itself is the ground truth for "audio is actually broken right
      // now" — the Connectivity plugin only fires on FULL internet loss and
      // stays silent when the OS just switches interfaces (WiFi -> mobile)
      // mid-call, which is exactly when the active ICE candidate pair dies
      // while the device still reports itself online. Drive Reconnecting
      // from ICE directly instead of relying on the plugin catching it.
      CallService().onIceDisconnected = () {
        if (!mounted || _callEnded || _viaNearby || !_connected) return;
        if (_reconnecting) return;
        // ICE routinely reports a brief "disconnected" blip right after a
        // call first connects — the candidate pair upgrading from an
        // initial relay/reflexive path to a better one — that self-heals
        // within a second or two on its own. Reacting to it instantly
        // showed "Reconnecting…" for perfectly normal calls where nothing
        // was actually wrong. Give it a short window to resolve quietly
        // before ever showing the UI; only a disconnect that's still there
        // after that is treated as real.
        _reconnectingUiTimer?.cancel();
        _reconnectingUiTimer = Timer(const Duration(seconds: 3), () {
          if (!mounted ||
              _callEnded ||
              _viaNearby ||
              !_connected ||
              _reconnecting)
            return;
          setState(() => _reconnecting = true);
          _armReconnectGraceTimer();
          if (kCallNearbyFailoverEnabled) unawaited(_tryHandoffToNearby());
        });
      };
      CallService().onDebugUpdate = () {
        if (mounted && AppConfig.CALL_DEBUG_LOGGING) setState(() {});
      };
      CallService().onIceRecovered = () {
        if (!mounted || _callEnded || _switchingToNearby) return;
        _markWebRtcConnected();
        _reconnectingUiTimer?.cancel();
        _reconnectingUiTimer = null;
        final wasReconnecting = _reconnecting;
        if (_reconnecting) {
          _reconnectGraceTimer?.cancel();
          setState(() => _reconnecting = false);
        }
        if (_reconnectFailed) setState(() => _reconnectFailed = false);
        // ICE can self-heal back to "connected" within a couple seconds on
        // a brief network blip without ever needing a full ICE restart —
        // but the OS audio pipeline can still be left stuck from the
        // interruption. Nudge it back to life either way; cheap and silent
        // if audio was actually fine.
        if (wasReconnecting) {
          unawaited(CallService().setSpeaker(_speaker));
          unawaited(CallService().nudgeAudioPipeline());
        }
      };
    });
  }

  Future<bool> _ensureCallPermissions(bool video) async {
    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission required for calls'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }
    if (video) {
      final cam = await Permission.camera.request();
      if (!cam.isGranted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Camera permission required for video calls'),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return false;
      }
    }
    return true;
  }

  void _markWebRtcConnected() {
    if (!mounted || _callEnded || _viaNearby || _connected) return;
    final hasRemoteAudio =
        CallService().remoteStream?.getAudioTracks().isNotEmpty ?? false;
    if (!hasRemoteAudio || !CallService().isIceConnected) return;
    _mediaWaitTimer?.cancel();
    unawaited(CallService().setSpeaker(_speaker));
    setState(() => _connected = true);
    _startTimer();
    // Show persistent notification + start a real foreground service so the
    // OS doesn't kill this process if the user switches to another app.
    NotificationService().showActiveCallNotification(
      callerName: widget.callerName,
      isVideo: widget.isVideo,
    );
    unawaited(startCallKeepAlive());
  }

  Future<void> _completeIncomingAccept(AppProvider prov) async {
    final callerId = widget.calleeUserId;
    final sdp = widget.incomingOfferSdp;
    if (_viaNearby) _videoOn = false;
    final permsOk = await _ensureCallPermissions(
      _viaNearby ? false : widget.isVideo,
    );
    if (!permsOk) {
      // Used to still send a "no_sdp" answer here and fake-connect via the
      // fallback timer below — that made BOTH sides look connected (timer
      // running) with no real audio pipeline on this end at all. Reject
      // properly instead so the caller sees a real failure, not silence.
      if (callerId != null)
        _sendSignal({'type': 'call_reject', 'target_user_id': callerId});
      if (mounted && !_callEnded) {
        prov.stopRing();
        _showMissed('Permission denied');
      }
      return;
    }
    if (_viaNearby) {
      // Same reasoning as the caller side — no WebRTC/SDP involved, the
      // Bluetooth link already exists, so accepting just means "start the
      // raw audio pipeline and tell the caller to do the same."
      if (callerId != null) {
        _sendSignal({
          'type': 'call_answer',
          'target_user_id': callerId,
          'sdp': '',
          'sdp_type': '',
        });
        unawaited(NearbyVoiceCallService().start(callerId));
      }
      if (mounted) {
        prov.stopRing();
        _mediaWaitTimer?.cancel();
        setState(() => _connected = true);
        _startTimer();
        NotificationService().showActiveCallNotification(
          callerName: widget.callerName, isVideo: false,
        );
        unawaited(startCallKeepAlive());
      }
      return;
    }
    bool accepted = false;
    if (callerId != null && sdp != null && sdp.isNotEmpty) {
      try {
        final answer = await CallService().acceptIncoming(
          callerId,
          widget.isVideo,
          sdp,
          widget.incomingOfferType ?? 'offer',
          _sendSignal,
        );
        _myCallToken = CallService().sessionToken;
        _sendSignal({
          'type': 'call_answer',
          'target_user_id': callerId,
          'sdp': answer['sdp'],
          'sdp_type': answer['sdp_type'],
        });
        accepted = true;
      } catch (e) {
        accepted = false;
        _lastAcceptError = e.toString();
      }
    }
    if (!accepted) {
      if (callerId != null)
        _sendSignal({'type': 'call_end', 'target_user_id': callerId});
      if (mounted && !_callEnded) {
        prov.stopRing();
        // debugPrint never reaches logcat on an installed release APK, so
        // this is the only way to actually see WHY acceptIncoming() threw
        // — temporary diagnostic surfacing until the root cause is found.
        final reason = _lastAcceptError != null
            ? 'Call failed — ${_lastAcceptError!}'
            : 'Call failed';
        _showMissed(reason);
      }
      return;
    }
    if (mounted) {
      // Don't mark "Connected" the instant the answer is sent — that's before
      // the WebRTC handshake (ICE/DTLS) actually completes, so the screen
      // could say "Connected" with no audio actually flowing yet. Wait for
      // onRemoteStream (real media arriving); fall back to marking connected
      // anyway after a few seconds so the UI never gets stuck if something
      // about that signal itself fails.
      prov.stopRing();
      _mediaWaitTimer?.cancel();
      // Used to blindly mark "connected" after 8s if onRemoteStream hadn't
      // fired yet — reasoned as "fine for server calls, STUN/TURN almost
      // always succeeds within a few seconds". In practice that's exactly
      // backwards: on the calls where it actually takes longer (or ICE
      // silently fails one-directionally — asymmetric NAT, a TURN relay
      // reachable from only one side), THAT side got a normal-looking,
      // running call timer with total silence forever, while the other
      // side (whose media genuinely arrived) sounded fine — the precise
      // asymmetric "voice for one side but not the other" pattern this was
      // built to fix. Fail honestly instead, same principle already used
      // for Nearby: never claim connected without real media.
      _mediaWaitTimer = Timer(Duration(seconds: _viaNearby ? 20 : 25), () {
        if (!mounted || _connected || _callEnded) return;
        prov.stopRing();
        _showMissed('Call failed — no connection');
      });
    }
  }

  void _onWsMessage(Map<String, dynamic> data) {
    final type = data['type'];
    final signalCallId = data['call_id']?.toString() ?? '';
    // Every new build carries a unique call id end-to-end. This blocks a
    // delayed answer/end from the previous attempt from auto-connecting or
    // terminating a freshly dialled call. Missing IDs remain accepted for
    // compatibility with already-queued events from older app versions.
    if (signalCallId.isNotEmpty && signalCallId != _callId) return;
    final expectedPeer = widget.calleeUserId;
    if (expectedPeer != null &&
        type is String &&
        (type.startsWith('call_') ||
            type.startsWith('ice_restart_') ||
            type.startsWith('video_upgrade_'))) {
      final signalPeer = int.tryParse(
        (data['answerer_id'] ?? data['from_user_id'] ?? data['caller_id'])
                ?.toString() ??
            '',
      );
      // Signals with an explicit sender belong only to that peer's call.
      // This prevents another phone/call on the same account from consuming
      // an answer, ICE candidate, or hangup meant for a different screen.
      if (signalPeer != null && signalPeer != expectedPeer) return;
    }
    if (type == 'call_ringing') {
      if (mounted && widget.isOutgoing && !_connected) {
        setState(() => _peerRinging = true);
      }
    } else if (type == 'call_answer') {
      // Callee answered — complete the WebRTC handshake if SDP present.
      // Guarded against double-delivery (SSE + the direct poll fallback can
      // both observe the same event) — applying a remote answer twice would
      // throw inside the peer connection.
      if (_connected || _answerApplied) return;
      // The callee has genuinely answered — ringing is over, this is now a
      // media-connecting phase governed by _mediaWaitTimer below. _ringTimer
      // was still counting down from call start with no idea an answer just
      // arrived; left running, it could fire "No answer" and kill a call
      // that's mid-handshake (ICE/TURN can legitimately take a few more
      // seconds) purely because the callee happened to accept close to the
      // 45s mark. Confirmed live: caller showed "No answer" while the callee
      // was still actively negotiating, whose PeerConnection then closed the
      // instant the caller's call_end arrived.
      _ringTimer?.cancel();
      if (_viaNearby) {
        // No WebRTC handshake at all here — the Bluetooth link is already
        // up (that's how this signal arrived), so "answered" and "media
        // ready" are the same moment. Start the raw audio pipeline now.
        final peerId = widget.calleeUserId;
        if (peerId != null) unawaited(NearbyVoiceCallService().start(peerId));
        if (mounted) {
          context.read<AppProvider>().stopRing();
          _mediaWaitTimer?.cancel();
          setState(() => _connected = true);
          _startTimer();
          NotificationService().showActiveCallNotification(
            callerName: widget.callerName, isVideo: false,
          );
          unawaited(startCallKeepAlive());
        }
        return;
      }
      final sdp = data['sdp']?.toString();
      // The callee has already accepted at this point.  Show the active call
      // immediately instead of keeping the caller on "Ringing..." while the
      // final ICE/DTLS media handshake finishes in the background.  The local
      // microphone was opened when the offer was created; WebRTC continues
      // applying the answer below without blocking the call UI.
      if (mounted && !_connected) {
        context.read<AppProvider>().stopRing();
        _mediaWaitTimer?.cancel();
        setState(() => _connected = true);
        _startTimer();
      }
      if (sdp != null && sdp.isNotEmpty) {
        _answerApplied = true;
        unawaited(() async {
          try {
            await CallService().handleAnswer(
              sdp,
              data['sdp_type']?.toString() ?? 'answer',
            );
          } catch (error) {
            // Permit a genuinely fresh answer after a transient application
            // failure, but never race two applications concurrently.
            _answerApplied = false;
            debugPrint('[Call] remote answer failed: $error');
          }
        }());
      }
      if (mounted) {
        // Signaling finished, but audio isn't flowing yet — same rule as the
        // callee side (_completeIncomingAccept below). Don't start the timer
        // here; wait for onRemoteStream so BOTH sides only start their timer
        // once real media has actually connected, never one side alone.
        final prov = context.read<AppProvider>();
        prov.stopRing();
        _mediaWaitTimer?.cancel();
        // Accept has completed and the answer has been sent.  Open the call
        // screen immediately; waiting for onTrack here made the answerer keep
        // showing Ringing even though the mic and SDP answer were ready.
        if (!_connected) {
          setState(() => _connected = true);
          _startTimer();
        }
        // Same honesty fix as the callee side (_completeIncomingAccept) —
        // never fake "connected" without onRemoteStream actually firing.
        _mediaWaitTimer = Timer(Duration(seconds: _viaNearby ? 20 : 25), () {
          if (!mounted || _connected || _callEnded) return;
          prov.stopRing();
          _showMissed('Call failed — no connection');
        });
      }
    } else if (type == 'call_ice_candidate') {
      CallService().handleRemoteIce(data);
    } else if (type == 'call_switch_nearby') {
      // The peer lost internet on their end and is handing the call off to
      // Nearby — follow them over, even if our own connectivity is fine.
      if (!kCallNearbyFailoverEnabled) return;
      final peerId = widget.calleeUserId;
      if (peerId != null) unawaited(_switchToNearby(peerId));
    } else if (type == 'video_upgrade_request') {
      unawaited(_showVideoUpgradeDialog());
    } else if (type == 'video_upgrade_response') {
      if (!mounted || _callEnded || !_upgradeRequested) return;
      if (data['accepted'] != true) {
        setState(() => _upgradeRequested = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Video call request decline ho gayi'),
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      () async {
        try {
          final offer = await CallService().createVideoUpgradeOffer();
          if (!mounted || _callEnded) return;
          setState(() {
            _isVideoCall = true;
            _upgradeRequested = false;
          });
          _sendSignal({
            'type': 'video_upgrade_offer',
            'target_user_id': widget.calleeUserId,
            'sdp': offer['sdp'],
            'sdp_type': offer['sdp_type'],
          });
        } catch (_) {
          if (mounted) setState(() => _upgradeRequested = false);
        }
      }();
    } else if (type == 'video_upgrade_offer') {
      final sdp = data['sdp']?.toString();
      final sdpType = data['sdp_type']?.toString() ?? 'offer';
      if (sdp == null || sdp.isEmpty) return;
      () async {
        try {
          final answer = await CallService().acceptVideoUpgradeOffer(
            sdp,
            sdpType,
          );
          if (!mounted || _callEnded) return;
          setState(() => _isVideoCall = true);
          _sendSignal({
            'type': 'video_upgrade_answer',
            'target_user_id': widget.calleeUserId,
            'sdp': answer['sdp'],
            'sdp_type': answer['sdp_type'],
          });
        } catch (_) {}
      }();
    } else if (type == 'video_upgrade_answer') {
      final sdp = data['sdp']?.toString();
      final sdpType = data['sdp_type']?.toString() ?? 'answer';
      if (sdp == null || sdp.isEmpty) return;
      unawaited(CallService().completeVideoUpgrade(sdp, sdpType));
    } else if (type == 'ice_restart_offer') {
      final sdp = data['sdp']?.toString();
      final sdpType = data['sdp_type']?.toString() ?? 'offer';
      if (sdp == null || sdp.isEmpty) return;
      unawaited(CallService().handleIceRestartOffer(sdp, sdpType));
    } else if (type == 'ice_restart_answer') {
      final sdp = data['sdp']?.toString();
      final sdpType = data['sdp_type']?.toString() ?? 'answer';
      if (sdp == null || sdp.isEmpty) return;
      unawaited(CallService().handleIceRestartAnswer(sdp, sdpType));
    } else if (type == 'ice_restart_request') {
      // Only the caller side ever self-initiates a restart (see the glare
      // comment in call_service.dart) — but ICE going "disconnected" is
      // symmetric, so a break that only the callee's path actually suffers
      // (asymmetric NAT/relay failure) left the callee with no way to ask
      // for one: it just sat on "Reconnecting…" until the 25s grace timer
      // gave up. This lets the callee explicitly ask the caller to run the
      // same proven restart instead of attempting one itself (which would
      // reintroduce the glare).
      unawaited(CallService().restartIceOnRequest());
    } else if (type == 'call_answered_elsewhere') {
      if (data['answering_instance_id']?.toString() ==
          SseService().clientInstanceId)
        return;
      if (mounted && !_callEnded && !widget.isOutgoing) {
        _callEnded = true;
        context.read<AppProvider>().stopRing();
        CallService().end(expectedToken: _myCallToken);
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    } else if (type == 'call_reject' ||
        type == 'call_end' ||
        type == 'call_ended' ||
        type == 'call_missed') {
      // Guard against double-delivery (SSE + the direct poll fallback can
      // both observe the same hangup event) — a second Navigator.pop() on
      // an already-popped route crashes with a Navigator assertion.
      if (mounted && !_callEnded) {
        _callEnded = true;
        final prov = context.read<AppProvider>();
        prov.setInActiveCallUi(false);
        prov.setActiveCallPeer(null);
        prov.stopRing();
        CallService().end(expectedToken: _myCallToken);
        unawaited(NearbyVoiceCallService().end());
        if (widget.isOutgoing && !_connected) {
          if (type == 'call_end' ||
              type == 'call_ended' ||
              type == 'call_missed') {
            unawaited(
              prov.logCall(
                peerId: widget.calleeUserId ?? 0,
                isOutgoing: true,
                convId: widget.convId,
                status: 'missed',
                isVideo: widget.isVideo,
              ),
            );
          } else {
            unawaited(prov.loadMessages(widget.convId, refresh: true));
            unawaited(prov.refreshRecents());
          }
          _showMissed(type == 'call_reject' ? 'Declined' : 'No answer');
        } else {
          final nav = Navigator.of(context, rootNavigator: true);
          if (nav.canPop()) nav.pop();
        }
      }
    } else if (type == 'call_busy') {
      if (!mounted || !widget.isOutgoing || _connected || _callEnded) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastBusyAt < 4000) return;
      _lastBusyAt = now;
      _callEnded = true;
      final prov = context.read<AppProvider>();
      prov.stopRing();
      if (widget.calleeUserId != null)
        prov.markCallerDismissed(widget.calleeUserId.toString());
      prov.setActiveCallPeer(null);
      CallService().end(expectedToken: _myCallToken);
      unawaited(NearbyVoiceCallService().end());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('User is busy'),
          duration: Duration(seconds: 2),
        ),
      );
      final nav = Navigator.of(context, rootNavigator: true);
      if (nav.canPop()) nav.pop();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  /// Arms (or re-arms, via Retry) the grace window a mid-call reconnect gets
  /// before giving up. On expiry this does NOT end the call — it shows an
  /// explicit "Unable to reconnect" / Retry / End Call choice, matching the
  /// same pattern as the missed-call screen but staying on THIS screen so
  /// the call can still resume if the network comes back after the user
  /// taps Retry (ending it here would make that impossible).
  void _armReconnectGraceTimer() {
    _reconnectGraceTimer?.cancel();
    _reconnectGraceTimer = Timer(const Duration(seconds: 25), () {
      if (!mounted || _callEnded || _viaNearby || !_reconnecting) return;
      setState(() {
        _reconnecting = false;
        _reconnectFailed = true;
      });
      context.read<AppProvider>().stopRing();
    });
  }

  /// User tapped Retry on the "Unable to reconnect" screen — re-check
  /// connectivity right now and, if still down, arm a fresh grace window
  /// instead of the call just sitting dead with no further attempts.
  void _retryReconnect() {
    if (!mounted || _callEnded) return;
    setState(() {
      _reconnectFailed = false;
      _reconnecting = true;
    });
    final peerId = widget.calleeUserId;
    if (_viaNearby) {
      if (peerId != null) {
        _armNearbyReconnectGraceTimer(peerId);
        unawaited(_tryReconnectNearbyLink(peerId));
      }
      return;
    }
    _armReconnectGraceTimer();
    if (kCallNearbyFailoverEnabled) unawaited(_tryHandoffToNearby());
    unawaited(() async {
      final offline = await ApiService.isOffline();
      if (!mounted || _callEnded) return;
      if (!offline && _reconnecting) {
        _reconnectGraceTimer?.cancel();
        setState(() => _reconnecting = false);
      }
    }());
  }

  void _showMissed(String reason) {
    if (!mounted || _callEnded) return;
    _callEnded = true;
    _ringTimer?.cancel();
    CallService().end(expectedToken: _myCallToken);
    unawaited(NearbyVoiceCallService().end());
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => MissedCallScreen(
          name: widget.callerName,
          avatar: widget.callerAvatar,
          isVideo: widget.isVideo,
          convId: widget.convId,
          calleeUserId: widget.calleeUserId,
          reason: reason,
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    NotificationService().cancelActiveCallNotification();
    unawaited(stopCallKeepAlive());
    try {
      final prov = context.read<AppProvider>();
      prov.removeWsListener(_wsHandler);
      prov.setInActiveCallUi(false);
      prov.setActiveCallPeer(null);
    } catch (_) {}
    CallService().onDebugUpdate = null;
    CallService().end(expectedToken: _myCallToken);
    unawaited(NearbyVoiceCallService().end());
    _callRecorder.dispose();
    _fadeCtrl.dispose();
    _pipCtrl.dispose();
    _timer?.cancel();
    _ringTimer?.cancel();
    _pollTimer?.cancel();
    _mediaWaitTimer?.cancel();
    _reconnectGraceTimer?.cancel();
    _nearbyReconnectGraceTimer?.cancel();
    _reconnectingUiTimer?.cancel();
    _connSub?.cancel();
    _nearbyCallSub?.cancel();
    NearbyService().removeListener(_onNearbyLinkChanged);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep call alive when backgrounded — don't tear down the peer connection.
    // WebRTC audio continues flowing as long as the peer connection exists.
    // The wakelock + foreground service keeps the process alive.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      // App going to background — call stays alive, just ensure signaling
      // reconnects when we come back.
    } else if (state == AppLifecycleState.resumed) {
      // App came back to foreground — refresh connectivity state
      if (mounted && !_callEnded) {
        Connectivity().checkConnectivity().then((r) {
          if (mounted) setState(() => _connKinds = r);
        });
      }
    }
  }

  /// Matches the "Using WiFi" / "Using Nearby (offline)" label style already
  /// shown in the chat header — shown here too so it's obvious mid-call
  /// whether audio is riding the internet or the Bluetooth Nearby link.
  String? get _connectionLabel {
    if (!_connected) return null;
    if (_viaNearby) return 'Using Nearby';
    if (_connKinds.contains(ConnectivityResult.wifi)) return 'Using WiFi';
    if (_connKinds.contains(ConnectivityResult.mobile))
      return 'Using Mobile Data';
    return null;
  }

  String get _timerText {
    if (!_connected) {
      if (_offline) return 'No network';
      return 'Ringing...';
    }
    if (_reconnectFailed) return 'Unable to reconnect';
    if (_reconnecting) return 'Reconnecting…';
    final h = _elapsed.inHours;
    final m = _elapsed.inMinutes % 60;
    final s = _elapsed.inSeconds % 60;
    if (h > 0)
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      final path = await _callRecorder.stop();
      setState(() => _recording = false);
      if (path != null && mounted) {
        try {
          final bytes = await File(path).readAsBytes();
          final prov = context.read<AppProvider>();
          await prov.uploadAndSendFile(
            widget.convId,
            bytes,
            'call_recording_${DateTime.now().millisecondsSinceEpoch}.m4a',
            'audio',
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Recording chat mein save ho gayi'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (_) {}
      }
      return;
    }
    try {
      if (!await _callRecorder.hasPermission()) return;
      final dir = await getTemporaryDirectory();
      _recordPath =
          '${dir.path}/call_rec_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _callRecorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: _recordPath!,
      );
      setState(() => _recording = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🔴 Recording shuru — speaker on rakho'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (_) {}
  }

  Future<void> _endCall() async {
    if (_callEnded) return;
    _callEnded = true;
    if (_recording) _toggleRecording();
    final prov = context.read<AppProvider>();
    if (widget.calleeUserId != null) {
      final endSignal = {
        'type': 'call_end',
        'target_user_id': widget.calleeUserId,
      };
      if (_viaNearby) {
        // Stop high-frequency PCM first so hangup control packets cannot sit
        // behind audio. Keep the Nearby endpoint itself alive until all
        // redundant call_end copies have been issued.
        await NearbyVoiceCallService().end();
        await _sendNearbySignalWithRetry(widget.calleeUserId!, endSignal);
      } else {
        try {
          _sendSignal(endSignal);
        } catch (_) {}
      }
      // If our OWN device has no internet right now, the server-relay send
      // above has no way to actually leave this phone — the other side
      // would just sit connected forever with a dead call. When they're
      // still Bluetooth-reachable, fire the same signal over Nearby too as
      // a redundant, internet-independent delivery path.
      if (!_viaNearby &&
          NearbyService().isUserReachable(widget.calleeUserId!)) {
        await _sendNearbySignalWithRetry(widget.calleeUserId!, endSignal);
      }
    }
    prov.setInActiveCallUi(false);
    prov.setActiveCallPeer(null);
    CallService().end();
    if (!_viaNearby) unawaited(NearbyVoiceCallService().end());
    _logCall();
    prov.stopRing();
    final rootNav = Navigator.of(context, rootNavigator: true);
    if (rootNav.canPop()) rootNav.pop();
  }

  void _logCall() {
    if (widget.calleeUserId == null) return;
    // Chat bubble always from caller — callee only logs via decline flow
    if (!widget.isOutgoing) return;
    final duration = _elapsed.inSeconds;
    final status = _connected ? 'completed' : 'missed';
    final prov = context.read<AppProvider>();
    unawaited(
      prov.logCall(
        peerId: widget.calleeUserId!,
        isOutgoing: true,
        convId: widget.convId,
        status: status,
        duration: duration,
        isVideo: widget.isVideo,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _fadeCtrl,
        child: _isVideoCall && _videoOn
            ? _buildVideoCall(size)
            : _buildAudioCall(size),
      ),
    );
  }

  // ── Audio Call ────────────────────────────────────────────────────────────────
  Widget _buildAudioCall(Size size) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF0D2014), Color(0xFF0B1E16), Color(0xFF071510)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Spacer(),
                  if (_isVideoCall && !_viaNearby)
                    IconButton(
                      icon: const Icon(Icons.videocam, color: Colors.white70),
                      onPressed: () => setState(() {
                        _videoOn = true;
                      }),
                    )
                  else if (false && !_viaNearby && _connected)
                    IconButton(
                      icon: Icon(
                        Icons.videocam_outlined,
                        color: _upgradeRequested
                            ? Colors.white30
                            : Colors.white70,
                      ),
                      tooltip: 'Video call ki request bhejein',
                      onPressed: _upgradeRequested
                          ? null
                          : _requestVideoUpgrade,
                    ),
                  IconButton(
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white70,
                      size: 28,
                    ),
                    onPressed: _endCall,
                  ),
                ],
              ),
            ),

            const Spacer(flex: 2),

            // Avatar + name
            if (_connectionLabel != null) ...[
              Text(
                _connectionLabel!,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 8),
            ],
            AvatarWidget(
              imageUrl: widget.callerAvatar,
              name: widget.callerName,
              size: 100,
            ),
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                widget.callerName,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: Text(
                _timerText,
                key: ValueKey(_timerText),
                style: TextStyle(
                  color: _connected ? AppColors.primary : Colors.white60,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            const Spacer(flex: 3),

            // Controls
            _buildCallControls(),
            const SizedBox(height: 56),
          ],
        ),
      ),
    );
  }

  // ── Video Call ────────────────────────────────────────────────────────────────
  Widget _buildVideoCall(Size size) {
    final cs = CallService();
    final hasRemote = cs.remoteStream != null;
    return Stack(
      children: [
        // Remote video — full screen (avatar while connecting)
        Container(
          color: const Color(0xFF071510),
          child: hasRemote
              ? RTCVideoView(
                  cs.remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AvatarWidget(
                        imageUrl: widget.callerAvatar,
                        name: widget.callerName,
                        size: 80,
                      ),
                      const SizedBox(height: 14),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          widget.callerName,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _timerText,
                        style: TextStyle(
                          color: _connected
                              ? AppColors.primary
                              : Colors.white60,
                          fontSize: 14,
                          letterSpacing: 1,
                        ),
                      ),
                      if (_connectionLabel != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _connectionLabel!,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),

        // Draggable self-preview PiP — live camera
        Positioned(
          left: _pipPos.dx,
          top: _pipPos.dy,
          child: GestureDetector(
            onPanUpdate: (d) => setState(() {
              final newX = (_pipPos.dx + d.delta.dx).clamp(
                8.0,
                size.width - 116.0,
              );
              final newY = (_pipPos.dy + d.delta.dy).clamp(
                8.0,
                size.height - 176.0,
              );
              _pipPos = Offset(newX, newY);
            }),
            child: Container(
              width: 108,
              height: 164,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: const Color(0xFF0D2014),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 16,
                    spreadRadius: 2,
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  _videoOn
                      ? RTCVideoView(
                          cs.localRenderer,
                          mirror: true,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        )
                      : Icon(
                          Icons.videocam_off,
                          color: Colors.white.withOpacity(0.5),
                          size: 36,
                        ),
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.black45,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _muted ? Icons.mic_off : Icons.mic,
                        color: Colors.white,
                        size: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Top controls
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
                  onPressed: () => CallService().switchCamera(),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.keyboard_arrow_down,
                    color: Colors.white,
                    size: 28,
                  ),
                  onPressed: _endCall,
                ),
              ],
            ),
          ),
        ),

        // Bottom controls
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [Colors.transparent, Colors.black.withOpacity(0.7)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
              child: _buildCallControls(isVideoMode: true),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCallControls({bool isVideoMode = false}) {
    if (_reconnectFailed) return _buildReconnectFailedControls();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 1: secondary controls
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _ControlBtn(
              icon: _muted ? Icons.mic_off : Icons.mic,
              label: _muted ? 'Unmute' : 'Mute',
              active: _muted,
              onTap: () {
                setState(() => _muted = !_muted);
                if (_viaNearby) {
                  NearbyVoiceCallService().muted = _muted;
                } else {
                  CallService().setMuted(_muted);
                }
              },
            ),
            _ControlBtn(
              icon: _speaker ? Icons.volume_up : Icons.volume_off,
              label: _speaker ? 'Speaker' : 'Earpiece',
              active: _speaker,
              onTap: () {
                setState(() => _speaker = !_speaker);
                if (_viaNearby) {
                  NearbyVoiceCallService().setSpeaker(_speaker);
                } else {
                  CallService().setSpeaker(_speaker);
                }
              },
            ),
            if (_isVideoCall && !_viaNearby)
              _ControlBtn(
                icon: _videoOn ? Icons.videocam : Icons.videocam_off,
                label: _videoOn ? 'Camera' : 'Cam off',
                active: _videoOn,
                onTap: () {
                  setState(() => _videoOn = !_videoOn);
                  CallService().setVideoEnabled(_videoOn);
                },
              )
            else
              _ControlBtn(
                icon: _recording
                    ? Icons.stop_circle
                    : Icons.fiber_manual_record,
                label: _recording ? 'Stop rec' : 'Record',
                active: _recording,
                onTap: _toggleRecording,
              ),
          ],
        ),
        const SizedBox(height: 28),
        // End call button
        GestureDetector(
          onTap: _endCall,
          child: Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFEF4444),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFEF4444).withOpacity(0.35),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(Icons.call_end, color: Colors.white, size: 30),
          ),
        ),
      ],
    );
  }

  /// The reconnect grace window ran out — a dead end the user has to
  /// actually resolve (Retry or End Call) rather than the call just
  /// silently hanging or being force-ended out from under them.
  Widget _buildReconnectFailedControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Unable to reconnect.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            OutlinedButton.icon(
              onPressed: _retryReconnect,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Retry', style: TextStyle(color: Colors.white)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white54),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
            const SizedBox(width: 16),
            ElevatedButton.icon(
              onPressed: _endCall,
              icon: const Icon(Icons.call_end, color: Colors.white),
              label: const Text(
                'End Call',
                style: TextStyle(color: Colors.white),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF4444),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ControlBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _ControlBtn({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  @override
  State<_ControlBtn> createState() => _ControlBtnState();
}

class _ControlBtnState extends State<_ControlBtn>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      lowerBound: 0.88,
      upperBound: 1.0,
      value: 1.0,
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTapDown: (_) => _c.reverse(),
    onTapUp: (_) {
      _c.forward();
      widget.onTap();
    },
    onTapCancel: () => _c.forward(),
    child: ScaleTransition(
      scale: _c,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.active
                  ? Colors.white.withOpacity(0.2)
                  : Colors.white.withOpacity(0.1),
              border: Border.all(
                color: widget.active
                    ? Colors.white.withOpacity(0.4)
                    : Colors.white.withOpacity(0.15),
                width: 1.5,
              ),
            ),
            child: Icon(widget.icon, color: Colors.white, size: 24),
          ),
          const SizedBox(height: 6),
          Text(
            widget.label,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    ),
  );
}
