import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import 'nearby_audio_bridge.dart';
import 'nearby_service.dart';

/// Voice-only calling over a plain Bluetooth Nearby link — no WebRTC, no
/// WiFi Direct, no IP networking at all. Raw 16kHz mono PCM captured on one
/// phone is streamed as small chunks through NearbyService's byte-payload
/// channel and played back immediately on the other. This is what a Nearby
/// call actually uses now instead of WebRTC — WebRTC needs a real IP link,
/// which Bluetooth alone never provides, so trying to use it here only ever
/// produced a WiFi Direct upgrade attempt (the very toggle this exists to
/// avoid) or a silently-dead call when that upgrade didn't happen.
class NearbyVoiceCallService {
  static final NearbyVoiceCallService _i = NearbyVoiceCallService._();
  factory NearbyVoiceCallService() => _i;
  NearbyVoiceCallService._();

  final _bridge = NearbyAudioBridge();
  StreamSubscription<NearbyAudioChunk>? _audioSub;
  int? _peerUserId;
  bool _active = false;
  bool muted = false;
  // Keep a short FIFO instead of discarding every frame during a brief
  // Android/Play-Services scheduling burst. Dropping speech frames is heard
  // as chopped syllables; six 100-ms frames still bounds worst-case latency.
  final Queue<Uint8List> _sendQueue = Queue<Uint8List>();
  final Queue<Uint8List> _playQueue = Queue<Uint8List>();
  bool _draining = false;
  bool _playing = false;
  bool _playbackBuffered = false;

  bool get isActive => _active;

  Future<void> setSpeaker(bool on) => _bridge.setSpeaker(on);

  Future<void> start(int peerUserId) async {
    if (_active) return;
    _active = true;
    NearbyService().setVoiceActive(true);
    _peerUserId = peerUserId;
    // Put the audio session into MODE_IN_COMMUNICATION *before* the
    // AudioTrack/AudioRecord get created below — on some OEM ROMs Android
    // decides how to route a VOICE_COMMUNICATION-usage stream at the moment
    // it's created, so setting the mode afterward (the previous order) left
    // both sides connected with the timer running but total silence.
    // VOICE_COMMUNICATION audio content also defaults to the earpiece, not
    // the loudspeaker — match the rest of the app's calls, speaker-on.
    // These are independent native audio-session operations. Starting them in
    // parallel removes the sequential speaker -> playback delay before the
    // first received voice frame can be heard.
    await Future.wait<void>([
      _bridge.setSpeaker(true),
      _bridge.startPlayback(),
    ]);
    await _audioSub?.cancel();
    _audioSub = NearbyService().onAudioChunk.listen((chunk) {
      if (chunk.fromUserId == _peerUserId) {
        // Keep a tiny jitter buffer for Bluetooth delivery. Clearing the
        // queue for every packet made the receiver throw away nearly every
        // frame when Nearby delivered two packets close together, producing
        // cut/cut voice. A three-frame cap keeps latency bounded while
        // allowing the AudioTrack worker to play a continuous stream.
        _playQueue.addLast(Uint8List.fromList(chunk.bytes));
        // Keep a short jitter buffer. Three frames was too aggressive on
        // busy Android phones: a normal 2–3 frame scheduling burst dropped
        // valid speech and sounded like chopped audio. Five frames absorbs
        // those bursts while keeping worst-case latency at ~500ms instead of
        // the 800ms an 8-frame cap let the queue drift up to — noticeably
        // laggy once a call had been running a while and the queue crept
        // toward the cap.
        while (_playQueue.length > 5) {
          _playQueue.removeFirst();
        }
        // Re-buffer briefly after every underflow instead of alternating
        // sound/silence for each late BLE packet.
        if (!_playbackBuffered && _playQueue.length >= 2) {
          _playbackBuffered = true;
        }
        _drainPlayback();
      }
    });
    await _bridge.startCapture((chunk) {
      if (!_active || muted || chunk.isEmpty) return;
      // Native emits 100-ms frames into one long-lived Nearby stream. Keep a
      // short FIFO so a scheduling burst does not discard audible syllables —
      // capped the same as the playback queue (see above) so a slow patch on
      // either side of the call can't add more than ~500ms of one-way delay.
      _sendQueue.addLast(Uint8List.fromList(chunk));
      while (_sendQueue.length > 5) {
        _sendQueue.removeFirst();
      }
      _drainAudio();
    });
  }

  void _drainPlayback() {
    if (_playing || !_playbackBuffered) return;
    _playing = true;
    unawaited(() async {
      try {
        while (_active && _playQueue.isNotEmpty) {
          await _bridge.writePlayback(_playQueue.removeFirst());
        }
      } finally {
        _playing = false;
        if (_playQueue.isEmpty) _playbackBuffered = false;
        if (_active && _playbackBuffered && _playQueue.isNotEmpty)
          _drainPlayback();
      }
    }());
  }

  void _drainAudio() {
    if (_draining) return;
    _draining = true;
    unawaited(() async {
      try {
        while (_active && _sendQueue.isNotEmpty) {
          final peer = _peerUserId;
          final chunk = _sendQueue.removeFirst();
          if (peer == null) break;
          await NearbyService().sendAudioChunk(peer, chunk);
        }
      } finally {
        _draining = false;
        if (_active && _sendQueue.isNotEmpty) _drainAudio();
      }
    }());
  }

  Future<void> end() async {
    final peer = _peerUserId;
    _active = false;
    NearbyService().setVoiceActive(false);
    _sendQueue.clear();
    _playQueue.clear();
    _playbackBuffered = false;
    muted = false;
    await _audioSub?.cancel();
    _audioSub = null;
    await _bridge.stopCapture();
    if (peer != null) await NearbyService().stopAudioStream(peer);
    await _bridge.stopPlayback();
    _peerUserId = null;
  }
}
