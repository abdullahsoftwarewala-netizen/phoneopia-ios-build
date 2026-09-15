import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Mesh WebRTC engine for group voice calls. Each remote participant gets its
/// own RTCPeerConnection. Signaling mirrors ws-relay.php:
///   group_call_invite (ring) / group_join / group_offer / group_answer /
///   group_ice / group_leave.
///
/// Mesh rule (avoids glare): the EXISTING participants offer each NEW joiner.
/// A joiner never offers — it only answers. So when X sends group_join, every
/// member already in the call calls [offerPeer(X)].
class GroupCallService {
  static final GroupCallService _i = GroupCallService._();
  factory GroupCallService() => _i;
  GroupCallService._();

  static const _rtcConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:162.220.11.169:3478'},
      {'urls': 'turn:162.220.11.169:3478', 'username': 'phoneopia', 'credential': 'Ph0n30p1aTURN2025'},
      {'urls': 'turn:162.220.11.169:3478?transport=tcp', 'username': 'phoneopia', 'credential': 'Ph0n30p1aTURN2025'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  MediaStream? _localStream;
  final Map<int, RTCPeerConnection> _peers = {};
  final Map<int, MediaStream> remoteStreams = {};
  final Map<int, bool> _remoteSet = {};
  final Map<int, List<Map<String, dynamic>>> _pendingIce = {};
  void Function(Map<String, dynamic>)? _send;
  void Function()? onChange;
  bool _muted = false;
  bool _active = false;

  bool get isActive => _active;
  bool get isMuted => _muted;
  Set<int> get peerIds => _peers.keys.toSet();
  int get connectedCount => remoteStreams.length;

  void setSender(void Function(Map<String, dynamic>) send) => _send = send;

  Future<void> initLocal() async {
    if (_localStream != null) { _active = true; return; }
    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true},
      'video': false,
    });
    _active = true;
    try { await Helper.setSpeakerphoneOn(true); } catch (_) {}
  }

  Future<RTCPeerConnection> _makePeer(int peerId) async {
    final pc = await createPeerConnection(_rtcConfig);
    _peers[peerId] = pc;
    _remoteSet[peerId] = false;
    _pendingIce[peerId] = [];
    if (_localStream != null) {
      for (final t in _localStream!.getTracks()) {
        await pc.addTrack(t, _localStream!);
      }
    }
    pc.onIceCandidate = (c) {
      if (c.candidate == null) return;
      _send?.call({
        'type': 'group_ice', 'target_user_id': peerId,
        'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex,
      });
    };
    pc.onTrack = (e) {
      if (e.streams.isNotEmpty) { remoteStreams[peerId] = e.streams[0]; onChange?.call(); }
    };
    pc.onConnectionState = (s) {
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        removePeer(peerId);
      }
    };
    return pc;
  }

  /// Existing participant offers a newly-joined peer.
  Future<void> offerPeer(int peerId) async {
    if (peerId <= 0 || _peers.containsKey(peerId) || _localStream == null) return;
    final pc = await _makePeer(peerId);
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    _send?.call({'type': 'group_offer', 'target_user_id': peerId, 'sdp': offer.sdp, 'sdp_type': offer.type});
  }

  Future<void> handleOffer(int fromId, String sdp, String type) async {
    if (_localStream == null) return;
    var pc = _peers[fromId];
    pc ??= await _makePeer(fromId);
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteSet[fromId] = true;
    await _flush(fromId);
    final answer = await pc.createAnswer({});
    await pc.setLocalDescription(answer);
    _send?.call({'type': 'group_answer', 'target_user_id': fromId, 'sdp': answer.sdp, 'sdp_type': answer.type});
  }

  Future<void> handleAnswer(int fromId, String sdp, String type) async {
    final pc = _peers[fromId];
    if (pc == null) return;
    await pc.setRemoteDescription(RTCSessionDescription(sdp, type));
    _remoteSet[fromId] = true;
    await _flush(fromId);
  }

  Future<void> handleIce(int fromId, Map<String, dynamic> data) async {
    final pc = _peers[fromId];
    final cand = {'candidate': data['candidate'], 'sdpMid': data['sdpMid'], 'sdpMLineIndex': data['sdpMLineIndex']};
    if (pc == null) return;
    if (_remoteSet[fromId] != true) { _pendingIce[fromId]?.add(cand); return; }
    try {
      await pc.addCandidate(RTCIceCandidate(cand['candidate'] as String?, cand['sdpMid'] as String?, cand['sdpMLineIndex'] as int?));
    } catch (_) {}
  }

  Future<void> _flush(int id) async {
    for (final c in _pendingIce[id] ?? <Map<String, dynamic>>[]) {
      try {
        await _peers[id]!.addCandidate(RTCIceCandidate(c['candidate'] as String?, c['sdpMid'] as String?, c['sdpMLineIndex'] as int?));
      } catch (_) {}
    }
    _pendingIce[id]?.clear();
  }

  void removePeer(int peerId) {
    try { _peers[peerId]?.close(); } catch (_) {}
    _peers.remove(peerId);
    remoteStreams.remove(peerId);
    _remoteSet.remove(peerId);
    _pendingIce.remove(peerId);
    onChange?.call();
  }

  void setMuted(bool m) {
    _muted = m;
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !m);
  }

  Future<void> setSpeaker(bool on) async {
    try { await Helper.setSpeakerphoneOn(on); } catch (_) {}
  }

  Future<void> end() async {
    _active = false;
    for (final pc in _peers.values) { try { await pc.close(); } catch (_) {} }
    _peers.clear();
    remoteStreams.clear();
    _remoteSet.clear();
    _pendingIce.clear();
    try { await _localStream?.dispose(); } catch (_) {}
    _localStream = null;
    _muted = false;
    onChange = null;
  }
}
