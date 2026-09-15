import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../config/app_config.dart';
import 'api_service.dart';

/// WebRTC audio/video engine for calls — compatible with the web client's
/// signaling: call_offer{sdp,sdp_type} / call_answer{sdp,sdp_type} /
/// call_ice_candidate{candidate,sdpMid,sdpMLineIndex}.
class CallService {
  static final CallService _i = CallService._();
  factory CallService() => _i;
  CallService._();

  // Same ICE config as the web client (incl. TURN for NAT traversal)
  static const _fallbackRtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
      {'urls': 'stun:stun3.l.google.com:19302'},
      {'urls': 'stun:stun4.l.google.com:19302'},
      {'urls': 'stun:162.220.11.169:3478'},
      {
        'urls': 'turn:162.220.11.169:3478',
        'username': 'phoneopia',
        'credential': 'Ph0n30p1aTURN2025',
      },
      {
        'urls': 'turn:162.220.11.169:3478?transport=tcp',
        'username': 'phoneopia',
        'credential': 'Ph0n30p1aTURN2025',
      },
    ],
    'sdpSemantics': 'unified-plan',
    'iceTransportPolicy': 'all',
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
  };

  Future<Map<String, dynamic>> _loadRtcConfig() async {
    try {
      final result = await ApiService.get('turn-config.php');
      final servers = result['iceServers'];
      if (servers is List && servers.isNotEmpty) {
        // This used to fully REPLACE iceServers with whatever the server
        // returned. turn-config.php only appends its TURN entries when the
        // TURN_CREDENTIAL secret is actually configured server-side — if
        // that secret is ever unset/rotated-and-forgotten, the endpoint
        // still responds with a non-empty (STUN-only) list, which passed
        // this check and silently discarded the bundled TURN fallback for
        // EVERY client at once. STUN-only can't traverse symmetric/CGNAT
        // NATs — exactly the "rings but never connects" / one-way-audio
        // failure mode. Only trust the server's list on its own once it
        // actually contains a TURN entry; otherwise keep the bundled TURN
        // servers as a safety net alongside whatever STUN it sent.
        final hasTurn = servers.any((s) =>
            s is Map && (s['urls']?.toString() ?? '').startsWith('turn:'));
        if (hasTurn) return {..._fallbackRtcConfig, 'iceServers': servers};
        final fallbackTurnOnly = (_fallbackRtcConfig['iceServers'] as List)
            .where((s) => (s['urls'] as String).startsWith('turn:'));
        return {..._fallbackRtcConfig, 'iceServers': [...servers, ...fallbackTurnOnly]};
      }
    } catch (_) {
      // Keep calls usable if the authenticated config endpoint is briefly
      // unavailable; the bundled STUN/TURN fallback remains available.
    }
    return _fallbackRtcConfig;
  }

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? remoteStream;
  void Function(Map<String, dynamic>)? _sendSignal;
  int? _peerId;
  final List<Map<String, dynamic>> _pendingIce = [];
  bool _remoteSet = false;
  // Whether THIS side placed the call (startOutgoing) vs answered it
  // (acceptIncoming) — see _tryRestartIce() for why this matters.
  bool _isCaller = false;

  // Video renderers — the call screen shows these
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;

  /// Called when the remote audio/video starts flowing
  void Function()? onRemoteStream;

  /// Called when the peer connection is genuinely gone (disconnected/failed/
  /// closed for longer than a short grace period) — a safety net so a call
  /// still ends locally even if the peer's call_end signal never arrives
  /// (e.g. their app got backgrounded and the event expired server-side).
  void Function()? onPeerGone;
  Timer? _peerGoneTimer;
  Timer? _iceRestartTimer;
  bool _everConnected = false;
  bool get isIceConnected => _everConnected;

  /// Fired the instant ICE reports the media path is degraded — this is the
  /// ground truth for "call audio is actually broken right now", unlike the
  /// Connectivity plugin which only fires on FULL internet loss and stays
  /// silent when the OS just switches interfaces (WiFi -> mobile) mid-call,
  /// which is exactly when ICE's active candidate pair dies but the device
  /// still reports "online". Drives the Reconnecting UI directly.
  void Function()? onIceDisconnected;
  void Function()? onIceRecovered;

  /// Plain-text snapshot of ICE/track state, refreshed on every relevant
  /// event. debugPrint never reaches logcat on a release APK installed via
  /// `adb install` (only under `flutter run`/`attach`), so this is the only
  /// way to see what's actually happening on-device during a live test —
  /// surfaced directly in the call screen behind CALL_DEBUG_LOGGING instead.
  String debugStatus = '';
  void Function()? onDebugUpdate;
  void _setDebugStatus(String s) {
    debugStatus = s;
    onDebugUpdate?.call();
  }

  bool get isActive => _pc != null;

  // Bumped every time a new call starts (_createPeer). ActiveCallScreen
  // captures this when it starts/accepts a call and passes it back to
  // end() on hangup/dispose — end() only tears down the peer connection if
  // the token still matches the CURRENT session. Without this, a stale
  // screen instance whose dispose() fires after the user already redialed
  // (double-tapped Call, or backed out and immediately called again) would
  // call end() on the CallService singleton and kill the brand-new call's
  // connection instead of the one it actually owned — confirmed live:
  // "Ringing…" immediately followed by RTCPeerConnectionStateClosed on a
  // fresh outgoing call. A prior fix here only guarded a delayed close()
  // racing a concurrent _createPeer reassignment; it didn't cover a stale
  // end() call arriving after the new call had already fully started.
  int _sessionToken = 0;
  int get sessionToken => _sessionToken;

  /// Reads WebRTC's own getStats() to see which candidate types (host /
  /// srflx / relay) were actually gathered on ICE failure — the only way to
  /// tell a real NAT/TURN traversal failure apart from an app-level bug when
  /// debugPrint/logcat isn't reachable on a release APK.
  Future<void> _dumpCandidateStats() async {
    try {
      final stats = await _pc?.getStats();
      if (stats == null) return;
      final localTypes = <String>{};
      final remoteTypes = <String>{};
      for (final r in stats) {
        if (r.type == 'local-candidate') {
          final t = r.values['candidateType'];
          if (t != null) localTypes.add(t.toString());
        } else if (r.type == 'remote-candidate') {
          final t = r.values['candidateType'];
          if (t != null) remoteTypes.add(t.toString());
        }
      }
      _setDebugStatus('FAILED candTypes local=$localTypes remote=$remoteTypes');
    } catch (e) {
      _setDebugStatus('FAILED getStats error: $e');
    }
  }

  Future<void> _createPeer(
    bool video,
    int peerId,
    void Function(Map<String, dynamic>) sendSignal,
  ) async {
    _sessionToken++;
    _peerId = peerId;
    _sendSignal = sendSignal;
    _remoteSet = false;
    _pendingIce.clear();
    _everConnected = false;

    // These three operations are independent. Starting them together removes
    // the old renderer -> microphone -> TURN-config serial delay that made a
    // caller sit on "Connecting" before the offer was even sent.
    final rendererInit = !_renderersReady
        ? () async {
            await Future.wait<void>([
              localRenderer.initialize(),
              remoteRenderer.initialize(),
            ]);
            _renderersReady = true;
          }()
        : Future<void>.value();
    final localStreamFuture = navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl': true,
      },
      // Ask for a real HD capture profile while allowing weaker cameras to
      // negotiate down. The old facingMode-only request often selected a
      // low-resolution stream, which made the local video look pixelated.
      'video': video
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280, 'max': 1920},
              'height': {'ideal': 720, 'max': 1080},
              'frameRate': {'ideal': 30, 'max': 30},
            }
          : false,
    });
    final rtcConfigFuture = _loadRtcConfig();
    final parallel = await Future.wait<dynamic>([
      rendererInit,
      localStreamFuture,
      rtcConfigFuture,
    ]);
    _localStream = parallel[1] as MediaStream;
    final rtcConfig = parallel[2] as Map<String, dynamic>;
    if (video) localRenderer.srcObject = _localStream;
    debugPrint(
      '[Call] local audio=${_localStream!.getAudioTracks().length} '
      'enabled=${_localStream!.getAudioTracks().map((t) => t.enabled).toList()}',
    );

    // Use the server's current TURN credentials. The old APK carried a
    // stale static credential, so calls could ring but never establish media
    // on mobile networks/NATs.
    _pc = await createPeerConnection(rtcConfig);
    for (final track in _localStream!.getTracks()) {
      await _pc!.addTrack(track, _localStream!);
    }

    _pc!.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _sendSignal?.call({
        'type': 'call_ice_candidate',
        'target_user_id': _peerId,
        'candidate': c.candidate,
        'sdpMid': c.sdpMid,
        'sdpMLineIndex': c.sdpMLineIndex,
      });
    };

    _pc!.onTrack = (e) {
      debugPrint(
        '[Call] onTrack kind=${e.track.kind} enabled=${e.track.enabled} streams=${e.streams.length}',
      );
      _setDebugStatus('track kind=${e.track.kind} streams=${e.streams.length}');
      if (e.streams.isNotEmpty) {
        remoteStream = e.streams[0];
        debugPrint(
          '[Call] remoteStream audio=${remoteStream!.getAudioTracks().length} video=${remoteStream!.getVideoTracks().length} '
          'audioEnabled=${remoteStream!.getAudioTracks().map((t) => t.enabled).toList()}',
        );
        remoteRenderer.srcObject = remoteStream;
        _setDebugStatus(
          'remoteStream audio=${remoteStream!.getAudioTracks().length} '
          'enabled=${remoteStream!.getAudioTracks().map((t) => t.enabled).toList()}',
        );
        onRemoteStream?.call();
      }
    };

    _pc!.onIceConnectionState = (state) {
      if (AppConfig.CALL_DEBUG_LOGGING)
        debugPrint('[CALL] ICE state=$state everConnected=$_everConnected');
      _setDebugStatus('ICE=$state everConnected=$_everConnected');
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
        unawaited(_dumpCandidateStats());
      }
      final gone =
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed;
      // ICE routinely passes through "disconnected" as a transient blip
      // during totally normal call setup (candidates still racing, first
      // connectivity check failing before a better pair is found) — that's
      // not a real problem and reacting to it before the call has ever
      // actually connected once just interferes with normal negotiation.
      if (gone && !_everConnected) return;
      if (gone) {
        onIceDisconnected?.call();
        // Grace period — ICE briefly reports "disconnected" during normal
        // network hiccups and often recovers on its own within a few
        // seconds. Only treat it as a real hangup if it stays gone.
        _peerGoneTimer ??= Timer(const Duration(seconds: 6), () {
          _peerGoneTimer = null;
          if (_pc != null) onPeerGone?.call();
        });
        // Try to heal the media path itself instead of just waiting —
        // restartIce() renegotiates fresh ICE candidates over whichever
        // interface is currently active, recovering audio after a network
        // switch without the call ever visibly dropping. Debounced a few
        // seconds so a self-recovering blip never triggers a renegotiation
        // at all. Only the caller side ever self-initiates: ICE going
        // "disconnected" is symmetric (both peers see it when the media path
        // breaks), so without this BOTH sides used to independently call
        // createOffer({iceRestart:true}) around the same time — a glare
        // where each side's setRemoteDescription(incoming offer) throws
        // because it's already sitting in have-local-offer from its own
        // attempt. That error was silently swallowed, leaving that side's
        // PeerConnection permanently stuck: confirmed live as caller
        // reconnecting fine while the callee's screen showed "Call failed —
        // no connection". The callee still answers a restart offer from the
        // caller normally (handleIceRestartOffer) — it just never sends one
        // of its own, so there's only ever one offer in flight.
        if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
          if (_isCaller) {
            _iceRestartTimer ??= Timer(const Duration(seconds: 4), () {
              _iceRestartTimer = null;
              if (_pc != null) unawaited(_tryRestartIce());
            });
          } else {
            // The callee can't safely run its own restartIce() (that's the
            // glare this whole caller-only design avoids) — but it can ask
            // the caller to run its already-proven one, covering the case
            // where the break is asymmetric and the caller's own ICE never
            // reports "disconnected" at all, so _tryRestartIce() above would
            // otherwise never fire on either side.
            _iceRestartTimer ??= Timer(const Duration(seconds: 4), () {
              _iceRestartTimer = null;
              if (_pc != null) unawaited(_requestPeerIceRestart());
            });
          }
        }
      } else {
        _peerGoneTimer?.cancel();
        _peerGoneTimer = null;
        _iceRestartTimer?.cancel();
        _iceRestartTimer = null;
        if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
            state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
          _everConnected = true;
          if (AppConfig.CALL_DEBUG_LOGGING)
            debugPrint('[CALL] ICE CONNECTED - audio should be flowing');
          onIceRecovered?.call();
        }
      }
    };

    _pc!.onConnectionState = (state) {
      if (AppConfig.CALL_DEBUG_LOGGING)
        debugPrint('[CALL] PeerConnection state=$state');
      _setDebugStatus('PC=$state');
      // onIceConnectionState (above) is the only thing that used to react to
      // real failures — but a PeerConnection can transition straight to
      // RTCPeerConnectionStateClosed/Failed (e.g. .close() firing from an
      // unrelated code path, or a hard WebRTC-level failure) WITHOUT ever
      // passing through ICE "disconnected" first. Nothing was watching this
      // signal, so the call screen just sat on "Ringing…"/"Reconnecting…"
      // forever with the debug text alone silently showing the truth —
      // confirmed live: a leftover call screen was still stuck showing
      // "Ringing… PC=Closed" minutes later, surviving even a Back-button
      // press, because nothing ever told the UI the call was over. Only
      // fire while never connected — once real media has flowed, the
      // existing ICE-disconnected/grace-period path already owns recovery
      // and reacting here too would double-handle the same hangup.
      if ((state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
              state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) &&
          !_everConnected) {
        onPeerGone?.call();
      }
    };

    // Route audio to speaker by default (matches the call screen toggle)
    await Helper.setSpeakerphoneOn(true);
  }

  /// Outgoing call: returns the SDP offer to embed in call_offer
  Future<Map<String, String>> startOutgoing(
    int calleeId,
    bool video,
    void Function(Map<String, dynamic>) sendSignal,
  ) async {
    if (AppConfig.CALL_DEBUG_LOGGING)
      debugPrint('[CALL] startOutgoing callee=$calleeId video=$video');
    await _createPeer(video, calleeId, sendSignal);
    _isCaller = true;
    final offer = await _pc!.createOffer({});
    await _pc!.setLocalDescription(offer);
    if (AppConfig.CALL_DEBUG_LOGGING)
      debugPrint(
        '[CALL] offer created type=${offer.type} sdp_len=${offer.sdp?.length}',
      );
    return {'sdp': offer.sdp ?? '', 'sdp_type': offer.type ?? 'offer'};
  }

  /// Incoming call accepted: returns the SDP answer to embed in call_answer
  Future<Map<String, String>> acceptIncoming(
    int callerId,
    bool video,
    String offerSdp,
    String offerType,
    void Function(Map<String, dynamic>) sendSignal,
  ) async {
    if (AppConfig.CALL_DEBUG_LOGGING)
      debugPrint(
        '[CALL] acceptIncoming caller=$callerId video=$video offer_sdp_len=${offerSdp.length}',
      );
    await _createPeer(video, callerId, sendSignal);
    _isCaller = false;
    await _pc!.setRemoteDescription(RTCSessionDescription(offerSdp, offerType));
    _remoteSet = true;
    await _flushPendingIce();
    final answer = await _pc!.createAnswer({});
    await _pc!.setLocalDescription(answer);
    if (AppConfig.CALL_DEBUG_LOGGING)
      debugPrint(
        '[CALL] answer created type=${answer.type} sdp_len=${answer.sdp?.length}',
      );
    return {'sdp': answer.sdp ?? '', 'sdp_type': answer.type ?? 'answer'};
  }

  /// Caller side: callee answered with SDP
  Future<void> handleAnswer(String sdp, String type) async {
    if (_pc == null) return;
    if (AppConfig.CALL_DEBUG_LOGGING)
      debugPrint('[CALL] handleAnswer type=$type sdp_len=${sdp.length}');
    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteSet = true;
    await _flushPendingIce();
  }

  Future<void> handleRemoteIce(Map<String, dynamic> data) async {
    final cand = {
      'candidate': data['candidate'],
      'sdpMid': data['sdpMid'],
      'sdpMLineIndex': data['sdpMLineIndex'],
    };
    if (_pc == null) return;
    if (!_remoteSet) {
      _pendingIce.add(cand);
      return;
    }
    try {
      await _pc!.addCandidate(
        RTCIceCandidate(
          cand['candidate'],
          cand['sdpMid'],
          cand['sdpMLineIndex'],
        ),
      );
      if (AppConfig.CALL_DEBUG_LOGGING)
        debugPrint(
          '[CALL] ICE candidate added mid=${cand['sdpMid']} mline=${cand['sdpMLineIndex']}',
        );
    } catch (e) {
      if (AppConfig.CALL_DEBUG_LOGGING)
        debugPrint('[CALL] ICE candidate add error: $e');
    }
  }

  bool _restartingIce = false;

  /// Renegotiates fresh ICE candidates over whichever network interface is
  /// currently active — recovers audio after a mid-call WiFi<->mobile switch
  /// without the call ever visibly dropping. Only the side whose ICE went
  /// "disconnected" initiates this; the other side just answers.
  Future<void> _tryRestartIce() async {
    if (_pc == null || _sendSignal == null || _peerId == null || _restartingIce)
      return;
    _restartingIce = true;
    try {
      final offer = await _pc!.createOffer({'iceRestart': true});
      await _pc!.setLocalDescription(offer);
      _sendSignal!({
        'type': 'ice_restart_offer',
        'target_user_id': _peerId,
        'sdp': offer.sdp ?? '',
        'sdp_type': offer.type ?? 'offer',
      });
    } catch (e) {
      if (AppConfig.CALL_DEBUG_LOGGING) print('[CALL] ICE restart offer failed: $e');
    } finally {
      _restartingIce = false;
    }
  }

  /// The callee's side of an asymmetric ICE break: it can't run
  /// _tryRestartIce() itself (that would race the caller's own attempt —
  /// the exact glare this design avoids), so it asks the caller to run its
  /// already-proven one instead.
  Future<void> _requestPeerIceRestart() async {
    if (_sendSignal == null || _peerId == null) return;
    _sendSignal!({'type': 'ice_restart_request', 'target_user_id': _peerId});
  }

  /// Received by whichever side the peer's ice_restart_request targeted —
  /// only ever actually the caller (the callee is the only one that sends
  /// this). Guarded by _isCaller anyway so a misdelivered/echoed request
  /// can't make the callee attempt its own restart.
  Future<void> restartIceOnRequest() async {
    if (!_isCaller) return;
    await _tryRestartIce();
  }

  Future<void> handleIceRestartOffer(String sdp, String type) async {
    if (_pc == null || _sendSignal == null || _peerId == null) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      _sendSignal!({
        'type': 'ice_restart_answer',
        'target_user_id': _peerId,
        'sdp': answer.sdp ?? '',
        'sdp_type': answer.type ?? 'answer',
      });
    } catch (e) {
      if (AppConfig.CALL_DEBUG_LOGGING) print('[CALL] ICE restart answer failed: $e');
    }
  }

  Future<void> handleIceRestartAnswer(String sdp, String type) async {
    if (_pc == null) return;
    try {
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
    } catch (e) {
      if (AppConfig.CALL_DEBUG_LOGGING) print('[CALL] ICE restart apply answer failed: $e');
    }
  }

  Future<void> _flushPendingIce() async {
    for (final c in _pendingIce) {
      try {
        await _pc!.addCandidate(
          RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
        );
      } catch (_) {}
    }
    _pendingIce.clear();
  }

  /// Mid-call upgrade from audio-only to video — the local stream never had
  /// a video track (getUserMedia was called with video:false at call start),
  /// so this adds one now and renegotiates over the same peer connection
  /// (unified-plan SDP semantics support adding a track after the fact).
  Future<Map<String, String>> createVideoUpgradeOffer() async {
    if (_pc == null) throw Exception('no active call');
    MediaStream? camStream;
    try {
      camStream = await navigator.mediaDevices.getUserMedia({
        'audio': false,
        'video': {
          'facingMode': 'user',
          'width': {'ideal': 1280, 'max': 1920},
          'height': {'ideal': 720, 'max': 1080},
          'frameRate': {'ideal': 30, 'max': 30},
        },
      });
      final videoTrack = camStream.getVideoTracks().first;
      await _localStream?.addTrack(videoTrack);
      await _pc!.addTrack(videoTrack, _localStream ?? camStream);
      localRenderer.srcObject = _localStream ?? camStream;
      final offer = await _pc!.createOffer({});
      await _pc!.setLocalDescription(offer);
      return {'sdp': offer.sdp ?? '', 'sdp_type': offer.type ?? 'offer'};
    } catch (e) {
      camStream?.getTracks().forEach((t) => t.stop());
      rethrow;
    }
  }

  /// Peer accepted the video-upgrade request — apply their renegotiation
  /// offer, add our own video track, and answer.
  Future<Map<String, String>> acceptVideoUpgradeOffer(
    String offerSdp,
    String offerType,
  ) async {
    if (_pc == null) throw Exception('no active call');
    await _pc!.setRemoteDescription(RTCSessionDescription(offerSdp, offerType));
    final camStream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1280, 'max': 1920},
        'height': {'ideal': 720, 'max': 1080},
        'frameRate': {'ideal': 30, 'max': 30},
      },
    });
    final videoTrack = camStream.getVideoTracks().first;
    await _localStream?.addTrack(videoTrack);
    await _pc!.addTrack(videoTrack, _localStream ?? camStream);
    localRenderer.srcObject = _localStream ?? camStream;
    final answer = await _pc!.createAnswer({});
    await _pc!.setLocalDescription(answer);
    return {'sdp': answer.sdp ?? '', 'sdp_type': answer.type ?? 'answer'};
  }

  /// Requester side: apply the renegotiation answer to complete the upgrade.
  Future<void> completeVideoUpgrade(String answerSdp, String answerType) async {
    if (_pc == null) return;
    await _pc!.setRemoteDescription(
      RTCSessionDescription(answerSdp, answerType),
    );
  }

  void setMuted(bool muted) {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !muted);
  }

  Future<void> setSpeaker(bool on) async {
    try {
      await Helper.setSpeakerphoneOn(on);
    } catch (_) {}
  }

  /// A brief network blip (network toggled off/on for a couple seconds) can
  /// leave ICE self-healing back to "connected" — so the call never even
  /// shows Reconnecting for long — while the OS audio capture/playback
  /// pipeline underneath stays stuck from the interruption, leaving the
  /// call visibly "connected" with silence in both directions. Toggling the
  /// local track off/on nudges the native capture pipeline to restart, and
  /// re-asserting the speaker route does the same for playback.
  Future<void> nudgeAudioPipeline() async {
    final tracks = _localStream?.getAudioTracks() ?? [];
    for (final t in tracks) {
      if (!t.enabled) continue;
      try {
        t.enabled = false;
        await Future.delayed(const Duration(milliseconds: 150));
        t.enabled = true;
      } catch (_) {}
    }
  }

  void setVideoEnabled(bool on) {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = on);
  }

  Future<void> switchCamera() async {
    final tracks = _localStream?.getVideoTracks();
    if (tracks != null && tracks.isNotEmpty) {
      try {
        await Helper.switchCamera(tracks.first);
      } catch (_) {}
    }
  }

  /// [expectedToken], when passed, must match the session that was active
  /// when the caller started/accepted ITS call — if a newer call has since
  /// started (token has moved on), this is a stale hangup call from a
  /// screen that no longer owns the live connection and is a no-op instead
  /// of tearing down the new call. Omit it for a genuine "I own whatever is
  /// live right now" hangup (e.g. the user tapping the end-call button).
  Future<void> end({int? expectedToken}) async {
    if (expectedToken != null && expectedToken != _sessionToken) return;
    _peerGoneTimer?.cancel();
    _peerGoneTimer = null;
    _iceRestartTimer?.cancel();
    _iceRestartTimer = null;
    _everConnected = false;
    try {
      localRenderer.srcObject = null;
    } catch (_) {}
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}
    // Capture and clear the fields synchronously, before any await, so a new
    // call starting concurrently (_createPeer assigning a fresh _pc while
    // this end() is still mid-flight from the previous call) never has its
    // brand-new peer connection stolen and closed by this call's delayed
    // close() — confirmed live: a fresh outgoing call showed
    // RTCPeerConnectionStateClosed while still "Ringing…", because _pc had
    // already been reassigned to the new call by the time this reached
    // `await _pc?.close()`.
    final pc = _pc;
    final stream = _localStream;
    _pc = null;
    _localStream = null;
    remoteStream = null;
    _peerId = null;
    _remoteSet = false;
    _pendingIce.clear();
    onRemoteStream = null;
    onPeerGone = null;
    try {
      await stream?.dispose();
    } catch (_) {}
    try {
      await pc?.close();
    } catch (_) {}
  }
}
