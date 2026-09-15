import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

/// A raw PCM audio chunk received from a peer over the Bluetooth-only voice
/// pipeline (see NearbyAudioBridge) — kept separate from [NearbyMessage]
/// since it's binary, high-frequency, and never persisted.
class NearbyAudioChunk {
  final int fromUserId;
  final Uint8List bytes;
  NearbyAudioChunk({required this.fromUserId, required this.bytes});
}

/// A file fully received from a peer over Nearby — local path is where the
/// plugin saved it on disk, ready to display/play/open immediately.
class NearbyFile {
  final int fromUserId;
  final String fileName;
  final String localPath;
  final String mimeType;
  final int? conversationId;
  final DateTime? sentAt;
  NearbyFile({
    required this.fromUserId,
    required this.fileName,
    required this.localPath,
    required this.mimeType,
    this.conversationId,
    this.sentAt,
  });
}

/// A message received/sent over a direct offline Bluetooth/BLE link.
class NearbyMessage {
  final String endpointId;
  final String senderName;
  final String text;
  final DateTime at;
  final bool fromMe;
  final int? conversationId;
  NearbyMessage({
    required this.endpointId,
    required this.senderName,
    required this.text,
    required this.at,
    required this.fromMe,
    this.conversationId,
  });
}

/// A nearby Phoneopia user discovered offline (no internet needed) —
/// advertises/discovers through Bluetooth Classic + BLE compatibility mode;
/// its native connection options are non-disruptive and BLE-preferred.
/// Phase 1: text chat only, single-hop (direct range), no mesh relay.
class NearbyService extends ChangeNotifier {
  static final NearbyService _i = NearbyService._();
  factory NearbyService() => _i;
  NearbyService._();

  static const _serviceId = 'com.phoneopia.nearby';
  // P2P_STAR was chosen back when Nearby calls used WebRTC and needed the
  // strategy to aggressively upgrade the link to WiFi Direct for real media
  // bandwidth. Nearby calls now run over a custom raw-PCM-over-Bluetooth
  // pipeline instead (NearbyVoiceCallService) — no WebRTC, no WiFi Direct
  // upgrade needed for anything anymore. P2P_CLUSTER connects noticeably
  // faster and more reliably for many simultaneous low-bandwidth links since
  // it doesn't spend time negotiating a medium upgrade nobody uses now.
  static const _strategy = Strategy.P2P_CLUSTER;

  bool advertising = false;
  bool discovering = false;
  bool _started = false;
  String myName = 'Phoneopia User';
  int myUserId = 0;
  Timer? _healthTimer;
  DateTime? _voiceActiveUntil;
  final Map<String, Timer> _endpointLostTimers = {};

  /// Discovery restarts can disturb a live raw-audio stream. The voice layer
  /// marks that short critical window explicitly; ordinary connected chats do
  /// not block discovery of additional nearby users.
  ///
  /// This is a self-expiring guard, not a plain flag that some caller must
  /// remember to clear — confirmed live that it isn't: an incoming Nearby
  /// call_offer arms this for the whole ring window, but AppProvider clears
  /// its pending-call state (_incomingCall = null) from well over a dozen
  /// different places (stale-offer watchdog, account switch, etc.), and only
  /// two of them were ever taught to also clear this. Every missed call
  /// through one of the untaught paths left this stuck true for the rest of
  /// the app session, silently disabling the health-timer restart below —
  /// exactly the "Nearby just stops working, messages go out late, calls
  /// stop arriving" symptom this was reported as. A bounded auto-expiry (well
  /// past the longest legitimate use: a 45s ring or one raw-PCM call) means a
  /// missed clear costs at most a short delay, never a stuck session.
  void setVoiceActive(bool active) => _voiceActiveUntil = active
      ? DateTime.now().add(const Duration(seconds: 60))
      : null;
  bool get _voiceActive =>
      _voiceActiveUntil != null && DateTime.now().isBefore(_voiceActiveUntil!);

  /// endpointId -> display name of a discovered/connected peer.
  final Map<String, String> peers = {};

  /// endpointId -> Phoneopia user id of that peer (parsed from the
  /// advertised "uid:name" identity), so a chat screen can look up "is the
  /// person I'm chatting with reachable right now" by their real user id.
  final Map<String, int> peerUserId = {};

  /// endpointId -> connection state ('discovered' | 'connecting' | 'connected').
  final Map<String, String> peerState = {};
  final Map<String, List<NearbyMessage>> _messages = {};

  /// The endpointId of a CONNECTED peer with this Phoneopia user id, or null.
  String? endpointForUser(int userId) {
    if (userId <= 0) return null;
    for (final e in peerUserId.entries) {
      if (e.value == userId && peerState[e.key] == 'connected') return e.key;
    }
    return null;
  }

  bool isUserReachable(int userId) => endpointForUser(userId) != null;

  /// Broader than isUserReachable on purpose: true the moment a peer is
  /// discovered or mid-handshake, not just once fully 'connected'. Routing
  /// an actual message needs a real connected link (isUserReachable stays
  /// strict for that), but the "who's nearby" UI needs to show a peer the
  /// instant it's found — otherwise a phone stuck reconnecting (Bluetooth
  /// drops constantly, see the reconnect-retry logic below) looks like
  /// nobody is nearby at all even while auto-connect is actively working on
  /// it just off-screen.
  bool isUserNearby(int userId) {
    if (userId <= 0) return false;
    for (final e in peerUserId.entries) {
      if (e.value == userId && peerState.containsKey(e.key)) return true;
    }
    return false;
  }

  /// Raw peerState ('discovered' | 'connecting' | 'connected') for a user,
  /// for UI that wants to show the live Nearby status next to their name —
  /// null when they aren't nearby at all right now.
  String? nearbyStateForUser(int userId) {
    if (userId <= 0) return null;
    for (final e in peerUserId.entries) {
      if (e.value == userId) return peerState[e.key];
    }
    return null;
  }

  Future<bool> sendToUser(
    int userId,
    String text, {
    int? conversationId,
  }) async {
    final id = endpointForUser(userId);
    if (id == null) return false;
    return sendText(id, text, conversationId: conversationId);
  }

  final _messageCtrl = StreamController<NearbyMessage>.broadcast();
  Stream<NearbyMessage> get onMessage => _messageCtrl.stream;

  // ── Call signaling over the same link — no internet needed ────────────
  // Piggybacks call_offer/call_answer/call_ice_candidate/call_end on the
  // same byte-payload channel used for chat, tagged 'kind':'call' so they
  // never get mixed up with a text message. When the Nearby link has
  // upgraded to WiFi Direct, both phones share a real local IP subnet, so
  // WebRTC's own ICE host candidates connect directly — no STUN/TURN (i.e.
  // no internet) required for that case. A Bluetooth-only link has no IP
  // transport at all, so a call can't carry media over it — text still
  // works there, but calling only actually connects once WiFi Direct kicks
  // in between the two phones.
  final _callSignalCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onCallSignal => _callSignalCtrl.stream;

  Future<bool> sendCallSignal(int peerUserId, Map<String, dynamic> data) async {
    final id = endpointForUser(peerUserId);
    if (id == null) return false;
    try {
      final json = utf8.encode(jsonEncode({'kind': 'call', ...data}));
      await Nearby().sendBytesPayload(id, Uint8List.fromList([0x00, ...json]));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Internet-sharing request/accept handshake — rides the SAME already-
  // authenticated Nearby link used for calls/chat, tagged 'kind':'sharing'.
  // This is deliberately NOT a new Bluetooth stack: Nearby Connections
  // already does discovery, pairing and a UKEY2-encrypted channel, so the
  // sharing protocol only needs to add its own message kind on top, exactly
  // like calls do. The server-side sharing.php request is still the source
  // of truth for authorization — this channel is how the two nearby devices
  // find each other's Phoneopia user id and exchange the resulting
  // request_id/session_token quickly, not a bypass of server authorization.
  final _sharingSignalCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onSharingSignal => _sharingSignalCtrl.stream;

  Future<bool> sendSharingSignal(
    int peerUserId,
    Map<String, dynamic> data,
  ) async {
    final id = endpointForUser(peerUserId);
    if (id == null) return false;
    try {
      final json = utf8.encode(jsonEncode({'kind': 'sharing', ...data}));
      await Nearby().sendBytesPayload(id, Uint8List.fromList([0x00, ...json]));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Bluetooth-only voice — raw PCM, no WebRTC/IP link needed ──────────
  // Every payload is tagged with a 1-byte prefix so binary audio chunks
  // (high-frequency, no JSON overhead) never get routed through the
  // JSON/UTF8 decode path meant for chat/call-signal messages: 0x00 = JSON
  // envelope (existing chat/call kind system), 0x01 = raw 16kHz mono PCM
  // audio chunk.
  final _audioChunkCtrl = StreamController<NearbyAudioChunk>.broadcast();
  Stream<NearbyAudioChunk> get onAudioChunk => _audioChunkCtrl.stream;
  Future<bool> sendAudioChunk(int peerUserId, Uint8List pcm) async {
    final id = endpointForUser(peerUserId);
    if (id == null) return false;
    try {
      // One long-lived STREAM keeps audio at the live edge. A reliable BYTES
      // payload per frame queued old speech inside Play Services.
      await Nearby().sendAudioStreamChunk(id, pcm);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stopAudioStream(int peerUserId) async {
    final id = endpointForUser(peerUserId);
    if (id == null) return;
    try {
      await Nearby().stopAudioStream(id);
    } catch (_) {}
  }

  // ── File/document sharing — the plugin's native FILE payload type ─────
  // Unlike chat/call, files use Nearby Connections' own chunked file
  // transfer (sendFilePayload) instead of hand-rolled byte payloads — it's
  // built for exactly this (arbitrary size, progress tracking, writes
  // straight to disk on the receiving end). The one gap: it has no concept
  // of a filename, so a small JSON "file_meta" message (still on the 0x00
  // JSON channel) carries the real name/mime alongside the payload id,
  // and the receiver only fires onFile once BOTH the meta arrived AND the
  // transfer itself reports SUCCESS — whichever comes second.
  final _fileCtrl = StreamController<NearbyFile>.broadcast();
  Stream<NearbyFile> get onFile => _fileCtrl.stream;

  final Map<int, Map<String, dynamic>> _pendingFileMeta =
      {}; // payloadId -> {fileName, mimeType, fromUserId}
  final Map<int, Payload> _pendingFilePayloads =
      {}; // payloadId -> Payload (once received, before SUCCESS)
  final Set<int> _completedFilePayloads = {};

  void _maybeCompleteFile(int payloadId) async {
    final meta = _pendingFileMeta[payloadId];
    final payload = _pendingFilePayloads[payloadId];
    if (meta == null ||
        payload == null ||
        !_completedFilePayloads.contains(payloadId))
      return;
    final path = payload.filePath ?? payload.uri;
    if (path == null) return;
    // Claim the completed payload before awaiting disk work: metadata and
    // transfer callbacks may both arrive during the same frame.
    _pendingFileMeta.remove(payloadId);
    _pendingFilePayloads.remove(payloadId);
    _completedFilePayloads.remove(payloadId);
    try {
      final dir = await getApplicationSupportDirectory();
      final inbox = await Directory(
        '${dir.path}/nearby_files',
      ).create(recursive: true);
      final name = (meta['fileName']?.toString() ?? 'file').replaceAll(
        RegExp(r'[^a-zA-Z0-9._-]'),
        '_',
      );
      final destination =
          '${inbox.path}/${DateTime.now().microsecondsSinceEpoch}_${payloadId}_$name';
      if (path.startsWith('content://')) {
        if (!await Nearby().copyFileAndDeleteOriginal(path, destination))
          return;
      } else {
        await File(
          path.startsWith('file:') ? Uri.parse(path).toFilePath() : path,
        ).copy(destination);
      }
      _fileCtrl.add(
        NearbyFile(
          fromUserId: meta['fromUserId'] as int,
          fileName: meta['fileName']?.toString() ?? 'file',
          localPath: destination,
          mimeType: meta['mimeType']?.toString() ?? 'application/octet-stream',
          conversationId: int.tryParse(
            meta['conversationId']?.toString() ?? '',
          ),
          sentAt: DateTime.tryParse(
            meta['sentAt']?.toString() ?? '',
          )?.toLocal(),
        ),
      );
    } catch (error) {
      debugPrint('Nearby received file could not be saved: $error');
    }
  }

  final Map<int, void Function(double progress)> _sendProgressCallbacks = {};

  /// Returns true once the transfer completes successfully; [onProgress] is
  /// called with 0.0–1.0 as bytes go, if given.
  Future<bool> sendFile(
    int peerUserId,
    String filePath,
    String fileName,
    String mimeType, {
    int? conversationId,
    void Function(double progress)? onProgress,
  }) async {
    final id = endpointForUser(peerUserId);
    if (id == null) return false;
    int? payloadId;
    final earlyResults = <int, bool>{};
    final completer = Completer<bool>();
    final sub = _sendResultCtrl.stream.listen((result) {
      if (payloadId == null) earlyResults[result.$1] = result.$2;
      if (result.$1 == payloadId && !completer.isCompleted)
        completer.complete(result.$2);
    });
    try {
      payloadId = await Nearby().sendFilePayload(id, filePath);
      if (earlyResults.containsKey(payloadId) && !completer.isCompleted) {
        completer.complete(earlyResults[payloadId]!);
      }
      final json = utf8.encode(
        jsonEncode({
          'kind': 'file_meta',
          'payloadId': payloadId,
          'fileName': fileName,
          'mimeType': mimeType,
          if (conversationId != null && conversationId > 0)
            'conversationId': conversationId,
          'sentAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await Nearby().sendBytesPayload(id, Uint8List.fromList([0x00, ...json]));
      if (onProgress != null) _sendProgressCallbacks[payloadId] = onProgress;
      return await completer.future.timeout(
        const Duration(minutes: 3),
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    } finally {
      await sub.cancel();
      _sendProgressCallbacks.remove(payloadId);
    }
  }

  final _sendResultCtrl = StreamController<(int, bool)>.broadcast();

  List<NearbyMessage> messagesFor(String endpointId) {
    final list = List<NearbyMessage>.from(_messages[endpointId] ?? const []);
    list.sort((a, b) => a.at.compareTo(b.at));
    return List.unmodifiable(list);
  }

  Future<bool> ensurePermissions() async {
    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      // Google Play Services validates this runtime grant before starting
      // discovery on Android 13+, even when lowPower mode restricts the real
      // radio medium to BLE. Requesting it does not turn Wi-Fi on.
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ].request();
    // locationWhenInUse is the only one of these that's a real, universally
    // required runtime permission on every supported Android version — BLE
    // scanning has needed it since Android 6. The Bluetooth permissions only exist as
    // distinct runtime permissions on Android 12+; on older OS versions
    // permission_handler can report them as plain "denied" rather than
    // granted/not-applicable. Requiring ALL five to be granted meant this
    // check always failed on pre-Android-12 phones, silently stopping
    // Nearby from ever starting at all — confirmed live on an Android 10
    // device where it never even registered as a discovery client. Request
    // them for forward compatibility, but only gate success on the one
    // permission that's actually meaningful everywhere.
    final location = statuses[Permission.locationWhenInUse];
    return location != null && (location.isGranted || location.isLimited);
  }

  /// What's actually advertised over Bluetooth — "userId:displayName" so a
  /// discovering peer can resolve the real Phoneopia account, not just a name.
  String get _identity => '$myUserId:$myName';

  static (int, String) _parseIdentity(String raw) {
    final i = raw.indexOf(':');
    if (i <= 0) return (0, raw);
    final id = int.tryParse(raw.substring(0, i)) ?? 0;
    return (id, raw.substring(i + 1));
  }

  Future<void> start(String displayName, int userId) async {
    // App bootstrap, account hydration, and the chat screen can all request
    // Nearby at nearly the same time. Starting discovery/advertising again
    // while a connection handshake is in flight tears down the BLE endpoint
    // and leaves both phones stuck at "waiting for endpoint to accept".
    if (_started && myUserId == userId) {
      await refresh();
      return;
    }
    _started = true;
    myName = displayName.trim().isEmpty ? 'Phoneopia User' : displayName.trim();
    myUserId = userId;
    final ok = await ensurePermissions();
    if (!ok) {
      _started = false;
      debugPrint('[Nearby] start() aborted: permissions not granted');
      return;
    }
    // Fire independently, not sequentially — confirmed live that
    // Nearby().startAdvertising()'s native call can simply never resolve
    // back to Dart on some devices (no error, no timeout, it just hangs).
    // Awaiting it before starting discovery meant one hung advertise call
    // permanently blocked discovery from ever running at all on that phone,
    // even though the device would have otherwise worked fine.
    unawaited(_startAdvertising());
    unawaited(_startDiscovery());
    // Both calls above can fail silently and permanently — confirmed live
    // that Play Services' Nearby client can reject startDiscovery() with
    // MISSING_PERMISSION_ACCESS_COARSE_LOCATION even though the OS-level
    // permission genuinely is granted (a stale permission cache in the GMS
    // process, most often right after a fresh install/relaunch). Before
    // this, that single silent failure meant the Find Nearby list just
    // stayed empty forever until the user happened to know to pull-to-
    // refresh. Retry quietly in the background until it actually catches.
    _healthTimer?.cancel();
    // Was 15s — on a fresh install/relaunch where startDiscovery() gets
    // silently rejected (see comment above), that's up to 15s of the Find
    // Nearby list and mid-call handoff both staying completely blind to a
    // device that's sitting right there. Tightened to 5s so that failure
    // mode recovers fast; the peer-connected guard right below already
    // protects any live session from this touching the radio at all.
    _healthTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      // Confirmed live: restarting discovery/advertising while a peer is
      // already connected — including mid-Nearby-call — causes real BLE
      // GATT churn (CREATE_GATT_SERVER_SOCKET_NOT_READY, "MultiplexBleSocket
      // failed to init") that can disrupt the live connection carrying that
      // call's audio, producing exactly the intermittent silence this was
      // meant to fix elsewhere. Only retry while genuinely nothing is
      // connected — once any peer is live, leave the radio alone.
      if (_voiceActive) return;
      if (!advertising) unawaited(_startAdvertising());
      if (!discovering) unawaited(_startDiscovery());
    });
  }

  /// Manual "try again". Used to fully stop+restart advertising/discovery —
  /// that teardown is exactly what was re-triggering the visible WiFi toggle
  /// on every tap AND made refresh slow (the medium has to renegotiate from
  /// scratch). Discovery already runs continuously in the background, so a
  /// refresh only needs to: retry connecting to anyone still sitting in
  /// 'discovered' (never actually got a connectTo, or it silently failed),
  /// and only fall back to a real restart if advertising/discovery somehow
  /// isn't running at all.
  Future<void> refresh() async {
    _reconnectAttempts.clear();
    if (!advertising) unawaited(_startAdvertising());
    if (!discovering) unawaited(_startDiscovery());
    for (final id in peers.keys.toList()) {
      // A peer stuck on 'connecting' with no resolution is a hung attempt,
      // not progress — refresh used to skip it entirely (only handled
      // 'discovered'), which is exactly why tapping refresh did nothing for
      // whichever side was stuck mid-handshake. Reset it and retry.
      final state = peerState[id];
      if (state == 'discovered' || state == 'connecting') {
        connectTo(id);
      }
    }
    notifyListeners();
  }

  Future<void> _startAdvertising() async {
    try {
      advertising = await Nearby()
          .startAdvertising(
            _identity,
            _strategy,
            serviceId: _serviceId,
            onConnectionInitiated: _onConnectionInitiated,
            onConnectionResult: _onConnectionResult,
            onDisconnected: _onDisconnected,
          )
          .timeout(const Duration(seconds: 12));
      notifyListeners();
    } catch (e) {
      // Confirmed live: this native call can simply never resolve back to
      // Dart on some devices — the timeout above turns that into a real
      // exception instead of a permanent hang, so `advertising` stays an
      // accurate false (retryable via refresh()) rather than stuck unknown.
      debugPrint('[Nearby] startAdvertising failed: $e');
    }
  }

  Future<void> _startDiscovery() async {
    try {
      discovering = await Nearby()
          .startDiscovery(
            _identity,
            _strategy,
            serviceId: _serviceId,
            onEndpointFound: (id, name, serviceId) {
              _endpointLostTimers.remove(id)?.cancel();
              final (uid, displayName) = _parseIdentity(name);
              peers[id] = displayName;
              if (uid > 0) peerUserId[id] = uid;
              peerState[id] = peerState[id] ?? 'discovered';
              notifyListeners();
              // Auto-connect — there's no "tap to link" UI anymore, chat itself
              // is the entry point, so the link needs to establish itself the
              // moment two Phoneopia devices find each other.
              if (peerState[id] == 'discovered') {
                // Both phones discover each other at almost the same instant. If
                // both request a connection immediately, Play Services can reject
                // the crossed handshakes. The lower user id initiates first; the
                // other side remains an automatic fallback a moment later.
                final delay = uid > 0 && myUserId > uid
                    ? const Duration(milliseconds: 1400)
                    : Duration.zero;
                Future.delayed(delay, () {
                  if (peerState[id] == 'discovered' && peers.containsKey(id)) {
                    connectTo(id);
                  }
                });
              }
            },
            onEndpointLost: (id) {
              if (id != null) {
                // Discovery loss is not a connection loss. Android frequently
                // stops reporting an advertisement while its already-established
                // Bluetooth link is still healthy; deleting it here made users
                // vanish from Find Nearby despite being connected.
                if (peerState[id] == 'connected') return;
                _endpointLostTimers.remove(id)?.cancel();
                _endpointLostTimers[id] = Timer(
                  const Duration(seconds: 90),
                  () {
                    _endpointLostTimers.remove(id);
                    if (peerState[id] == 'connected') return;
                    peers.remove(id);
                    peerUserId.remove(id);
                    peerState.remove(id);
                    _reconnectAttempts.remove(id);
                    _connectingTimeouts.remove(id)?.cancel();
                    notifyListeners();
                  },
                );
                notifyListeners();
              }
            },
          )
          .timeout(const Duration(seconds: 12));
      notifyListeners();
    } catch (e) {
      debugPrint('[Nearby] startDiscovery failed: $e');
    }
  }

  /// requestConnection()'s Future resolves once the request is issued, not
  /// once the handshake actually finishes — the real result only ever
  /// arrives via onConnectionResult. If the native Bluetooth stack hangs
  /// and that callback simply never fires (seen live: no error, no result,
  /// just permanently stuck on "connecting"), nothing in the try/catch below
  /// ever notices. Force a reset back to 'discovered' — and retry, same as
  /// any other dropped connection — if it's still stuck after a timeout.
  final Map<String, Timer> _connectingTimeouts = {};

  Future<void> connectTo(String endpointId) async {
    final current = peerState[endpointId];
    if (current == 'connected' || current == 'connecting') return;
    peerState[endpointId] = 'connecting';
    notifyListeners();
    _connectingTimeouts[endpointId]?.cancel();
    _connectingTimeouts[endpointId] = Timer(const Duration(seconds: 12), () {
      if (peerState[endpointId] == 'connecting') {
        peerState[endpointId] = 'discovered';
        notifyListeners();
        _onDisconnected(endpointId);
      }
    });
    try {
      debugPrint('[Nearby] requesting connection to $endpointId');
      await Nearby().requestConnection(
        _identity,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      debugPrint('[Nearby] connection request issued for $endpointId');
    } catch (e) {
      debugPrint('[Nearby] connection request failed for $endpointId: $e');
      _connectingTimeouts[endpointId]?.cancel();
      // Play Services returns 8003 when the native link is already alive but
      // Dart missed the earlier result callback (common after the app resumes
      // from background). Treat it as connected so messages/calls use the
      // existing endpoint instead of retrying forever and showing Connecting.
      final alreadyConnected =
          e.toString().contains('8003') ||
          e.toString().contains('ALREADY_CONNECTED_TO_ENDPOINT');
      peerState[endpointId] = alreadyConnected ? 'connected' : 'discovered';
      notifyListeners();
    }
  }

  void _onConnectionInitiated(String id, ConnectionInfo info) {
    // If the OTHER side found us first and initiated the connection before
    // our own discovery ever ran onEndpointFound for them, peers[id]/
    // peerUserId[id] were never populated — the link would go on to connect
    // successfully (onConnectionResult fires, real data flows) while Find
    // Nearby's list stayed completely empty, since it only ever reads from
    // the peers map. ConnectionInfo.endpointName carries the same "uid:name"
    // identity string as discovery, so fill it in here too.
    final (uid, displayName) = _parseIdentity(info.endpointName);
    peers[id] = displayName;
    if (uid > 0) peerUserId[id] = uid;
    if (peerState[id] != 'connected') peerState[id] = 'connecting';
    notifyListeners();
    // Auto-accept — both sides are already inside the trusted Phoneopia app.
    unawaited(
      Nearby()
          .acceptConnection(
            id,
            onPayLoadRecieved: (endpointId, payload) {
              // onConnectionResult's native CONNECTED callback is known
              // unreliable on this library (see connectTo's own 8003/timeout
              // workarounds above) — confirmed live as one side showing
              // "Connected" while the other stayed on "Found — connecting…"
              // even though the link was already carrying real traffic.
              // Receiving an actual payload is undeniable proof the
              // connection IS live regardless of what state the callback
              // left us in, so promote it immediately instead of waiting
              // on a result that may never arrive on this side.
              if (peerState[endpointId] != 'connected') {
                peerState[endpointId] = 'connected';
                _connectingTimeouts[endpointId]?.cancel();
                _connectingTimeouts.remove(endpointId);
                _reconnectAttempts.remove(endpointId);
                notifyListeners();
              }
              if (payload.type == PayloadType.FILE) {
                _pendingFilePayloads[payload.id] = payload;
                _maybeCompleteFile(payload.id);
                return;
              }
              if (payload.type != PayloadType.BYTES || payload.bytes == null)
                return;
              final raw = payload.bytes!;
              if (raw.isEmpty) return;
              if (raw[0] == 0x01) {
                final peerUid = peerUserId[endpointId];
                if (peerUid != null) {
                  _audioChunkCtrl.add(
                    NearbyAudioChunk(
                      fromUserId: peerUid,
                      bytes: raw.sublist(1),
                    ),
                  );
                }
                return;
              }
              final body = raw[0] == 0x00 ? raw.sublist(1) : raw;
              try {
                final data =
                    jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
                if (data['kind'] == 'call') {
                  final peerUid = peerUserId[endpointId];
                  _callSignalCtrl.add({
                    ...data,
                    'from_endpoint': endpointId,
                    if (peerUid != null) 'from_user_id': peerUid,
                    'from_name': peers[endpointId] ?? 'Unknown',
                  });
                  return;
                }
                if (data['kind'] == 'sharing') {
                  final peerUid = peerUserId[endpointId];
                  _sharingSignalCtrl.add({
                    ...data,
                    'from_endpoint': endpointId,
                    if (peerUid != null) 'from_user_id': peerUid,
                    'from_name': peers[endpointId] ?? 'Unknown',
                  });
                  return;
                }
                if (data['kind'] == 'file_meta') {
                  final peerUid = peerUserId[endpointId];
                  final payloadId = int.tryParse(
                    data['payloadId']?.toString() ?? '',
                  );
                  if (payloadId != null && peerUid != null) {
                    _pendingFileMeta[payloadId] = {
                      'fileName': data['fileName'],
                      'mimeType': data['mimeType'],
                      'fromUserId': peerUid,
                      'conversationId': data['conversationId'],
                      'sentAt': data['sentAt'],
                    };
                    _maybeCompleteFile(payloadId);
                  }
                  return;
                }
                final sentAt =
                    DateTime.tryParse(
                      data['at']?.toString() ?? '',
                    )?.toLocal() ??
                    DateTime.now();
                final msg = NearbyMessage(
                  endpointId: endpointId,
                  senderName:
                      peers[endpointId] ??
                      data['from']?.toString() ??
                      'Unknown',
                  text: data['text']?.toString() ?? '',
                  at: sentAt,
                  fromMe: false,
                  conversationId: int.tryParse(
                    data['conversation_id']?.toString() ?? '',
                  ),
                );
                final messages = _messages[endpointId] ??= [];
                messages.add(msg);
                messages.sort((a, b) => a.at.compareTo(b.at));
                if (messages.length > 500)
                  messages.removeRange(0, messages.length - 500);
                _messageCtrl.add(msg);
                notifyListeners();
              } catch (_) {}
            },
            onPayloadTransferUpdate: (endpointId, update) {
              // Fires for both sides — our own outgoing sendFilePayload transfers
              // AND incoming file transfers finishing.
              if (_sendProgressCallbacks.containsKey(update.id) &&
                  update.totalBytes > 0) {
                _sendProgressCallbacks[update.id]?.call(
                  update.bytesTransferred / update.totalBytes,
                );
              }
              if (update.status == PayloadStatus.SUCCESS) {
                _sendResultCtrl.add((update.id, true));
                if (_pendingFilePayloads.containsKey(update.id) ||
                    _pendingFileMeta.containsKey(update.id)) {
                  _completedFilePayloads.add(update.id);
                }
                _maybeCompleteFile(update.id);
              } else if (update.status == PayloadStatus.FAILURE ||
                  update.status == PayloadStatus.CANCELED) {
                _sendResultCtrl.add((update.id, false));
                _pendingFileMeta.remove(update.id);
                _pendingFilePayloads.remove(update.id);
                _completedFilePayloads.remove(update.id);
              }
            },
          )
          .then<void>(
            (accepted) {
              // Native can reject the accept immediately on an OEM Bluetooth stack.
              // Treat that as a normal transient disconnect so the existing bounded
              // reconnect loop retries instead of leaving the peer stuck in
              // "connecting" forever.
              if (!accepted && peerState[id] != 'connected')
                _onDisconnected(id);
            },
            onError: (Object _, StackTrace __) {
              if (peerState[id] != 'connected') _onDisconnected(id);
            },
          ),
    );
  }

  void _onConnectionResult(String id, Status status) {
    _connectingTimeouts[id]?.cancel();
    _connectingTimeouts.remove(id);
    peerState[id] = status == Status.CONNECTED ? 'connected' : 'discovered';
    if (status == Status.CONNECTED) {
      _reconnectAttempts.remove(id);
      _endpointLostTimers.remove(id)?.cancel();
    } else {
      _onDisconnected(id);
      return;
    }
    notifyListeners();
  }

  /// Bluetooth/WiFi Direct links between two phones drop far more than a
  /// normal WiFi connection — walking a few steps out of range, a phone
  /// locking, radio power-saving all trigger a disconnect the peer is
  /// usually still right there for. Auto-retry a few times with backoff
  /// instead of leaving the user to manually re-open Find Nearby every time.
  final Map<String, int> _reconnectAttempts = {};

  void _onDisconnected(String id) {
    _connectingTimeouts[id]?.cancel();
    _connectingTimeouts.remove(id);
    peerState[id] = 'discovered';
    notifyListeners();
    final attempt = (_reconnectAttempts[id] ?? 0) + 1;
    _reconnectAttempts[id] = attempt;
    // The first 8 attempts retry quickly (backoff up to 3s) for a normal
    // transient drop. Past that, don't just give up forever — confirmed
    // live that a peer can keep failing to reconnect for longer than that
    // while still genuinely in range and still "discovered" at the OS
    // level, leaving the user stuck with no further attempts at all unless
    // the OS happens to lose and rediscover the endpoint on its own. Fall
    // back to a slow steady retry instead, for as long as it's still
    // detected. (Widened from 5/800ms/10s — a dropped link was taking
    // noticeably long to recover; more, faster attempts before the slow
    // fallback kicks in gets a normal Bluetooth blip reconnected quicker
    // without retrying so aggressively forever that it burns battery.)
    final delay = attempt <= 8
        ? Duration(milliseconds: attempt * 500 > 3000 ? 3000 : attempt * 500)
        : const Duration(seconds: 6);
    Future.delayed(delay, () {
      if (peerState[id] == 'discovered' && peers.containsKey(id)) {
        connectTo(id);
      }
    });
  }

  // ── Local persistence + server sync ──────────────────────────────────
  // Messages sent over Bluetooth/WiFi Direct don't touch the server at the
  // time they're sent (that's the whole point — no internet needed). They're
  // saved locally here, keyed by the peer's real Phoneopia user id (not the
  // ephemeral endpointId, which changes every session), and pushed to the
  // server once internet comes back so both sides' chat history matches
  // everywhere, not just on the two devices that were actually nearby.
  String _pendingKey(int peerUserId) => 'nearby_pending_$peerUserId';

  Future<void> _persistPending(int peerUserId, String text, DateTime at) async {
    if (peerUserId <= 0) return;
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_pendingKey(peerUserId)) ?? [];
    list.add(jsonEncode({'text': text, 'at': at.toIso8601String()}));
    await p.setStringList(_pendingKey(peerUserId), list);
  }

  /// Messages sent to this peer over Nearby that haven't reached the server
  /// yet — {text, at} pairs, oldest first.
  Future<List<Map<String, dynamic>>> pendingForUser(int peerUserId) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(_pendingKey(peerUserId)) ?? [];
    return list.map((s) => jsonDecode(s) as Map<String, dynamic>).toList();
  }

  Future<void> clearPendingForUser(int peerUserId) async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_pendingKey(peerUserId));
  }

  Future<bool> sendText(
    String endpointId,
    String text, {
    int? conversationId,
  }) async {
    if (text.trim().isEmpty) return false;
    // Add the outgoing bubble and notify BEFORE awaiting the native send —
    // Nearby().sendBytesPayload() is a plugin call to the same Play Services
    // Nearby stack that startAdvertising()/startDiscovery() are documented
    // above as able to hang on indefinitely on some OEM builds. Adding the
    // message only after that await returned meant a genuinely-sent message
    // sat invisible in the chat until the screen was closed and reopened
    // (whose fresh build reads the by-then-updated list), even though the
    // underlying send itself was fine.
    final now = DateTime.now();
    final msg = NearbyMessage(
      endpointId: endpointId,
      senderName: myName,
      text: text,
      at: now,
      fromMe: true,
      conversationId: conversationId,
    );
    final messages = _messages[endpointId] ??= [];
    messages.add(msg);
    messages.sort((a, b) => a.at.compareTo(b.at));
    if (messages.length > 500) messages.removeRange(0, messages.length - 500);
    // AppProvider persists this in the normal conversation. Do not enqueue
    // a second server send: reconnect replay would deliver the same text twice.
    notifyListeners();
    try {
      final payload = utf8.encode(
        jsonEncode({
          'from': myName,
          'text': text,
          'at': now.toUtc().toIso8601String(),
          if (conversationId != null && conversationId > 0)
            'conversation_id': conversationId,
        }),
      );
      await Nearby()
          .sendBytesPayload(endpointId, payload)
          .timeout(const Duration(seconds: 4));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    _started = false;
    _healthTimer?.cancel();
    _healthTimer = null;
    try {
      await Nearby().stopAdvertising();
    } catch (_) {}
    try {
      await Nearby().stopDiscovery();
    } catch (_) {}
    try {
      await Nearby().stopAllEndpoints();
    } catch (_) {}
    advertising = false;
    discovering = false;
    peers.clear();
    peerState.clear();
    notifyListeners();
  }
}
