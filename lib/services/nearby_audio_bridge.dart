import 'dart:async';
import 'package:flutter/services.dart';

/// Raw 16kHz mono PCM mic capture + speaker playback, native side only —
/// used for Nearby calls that stay on plain Bluetooth (no WiFi Direct, so
/// no IP link for WebRTC to use at all). Chunks are handed off to whatever
/// transport the caller wires up (see NearbyVoiceCallService).
class NearbyAudioBridge {
  static const _method = MethodChannel('phoneopia/nearby_audio');
  static const _captureEvents = EventChannel('phoneopia/nearby_audio_capture');

  StreamSubscription<dynamic>? _captureSub;

  Future<void> startCapture(void Function(Uint8List chunk) onChunk) async {
    await _captureSub?.cancel();
    _captureSub = _captureEvents.receiveBroadcastStream().listen((data) {
      if (data is Uint8List) {
        onChunk(data);
      } else if (data is List<int>) {
        onChunk(Uint8List.fromList(data));
      }
    });
    // Subscribe before starting AudioRecord. Some fast devices produced the
    // first frames before EventChannel.onListen had installed its sink; if
    // recording then failed/retried during a WebRTC handoff the Dart side
    // could remain attached to no useful stream and the call stayed silent.
    await _method.invokeMethod('startRecording');
  }

  Future<void> stopCapture() async {
    await _captureSub?.cancel();
    _captureSub = null;
    try { await _method.invokeMethod('stopRecording'); } catch (_) {}
  }

  Future<void> startPlayback() async {
    try { await _method.invokeMethod('startPlayback'); } catch (_) {}
  }

  Future<void> writePlayback(Uint8List chunk) async {
    try { await _method.invokeMethod('writePlayback', chunk); } catch (_) {}
  }

  Future<void> stopPlayback() async {
    try { await _method.invokeMethod('stopPlayback'); } catch (_) {}
  }

  Future<void> setSpeaker(bool on) async {
    try { await _method.invokeMethod('setSpeaker', on); } catch (_) {}
  }
}
