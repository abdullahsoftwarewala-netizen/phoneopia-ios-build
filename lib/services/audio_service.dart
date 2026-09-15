import 'package:audioplayers/audioplayers.dart';

enum AppSound { notification, ringing, incomingCall }

class AudioService {
  static final AudioService _i = AudioService._();
  factory AudioService() => _i;
  AudioService._();

  final _player = AudioPlayer();
  AppSound? _current;
  bool _looping = false;

  static const _assets = {
    AppSound.notification: 'sounds/notification.mp3',
    AppSound.ringing:      'sounds/ringing.mp3',
    AppSound.incomingCall: 'sounds/incoming_call.mp3',
  };

  Future<void> play(AppSound sound, {bool loop = false}) async {
    // Replayed Nearby call_offer events must not restart the same looping
    // ringtone. Restarting the player creates the audible stop/start gap.
    if (_current == sound && _looping == loop) return;
    await stop();
    _current = sound;
    _looping = loop;
    final asset = _assets[sound]!;
    await _player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
    await _player.setVolume(1.0);
    await _player.play(AssetSource(asset));
  }

  Future<void> stop() async {
    _current = null;
    _looping = false;
    await _player.stop();
  }

  bool get isPlaying => _current != null;

  // Convenience methods
  Future<void> playNotification()  => play(AppSound.notification, loop: false);
  Future<void> playRinging()       => play(AppSound.ringing,      loop: true);
  Future<void> playIncomingCall()  => play(AppSound.incomingCall, loop: true);
}
