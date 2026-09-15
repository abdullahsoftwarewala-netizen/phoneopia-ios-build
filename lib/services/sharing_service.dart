import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../config/storage_keys.dart';
import 'api_service.dart';
import 'nearby_service.dart';

enum SharingRole { none, sender, receiver }

enum SharingSessionStatus { idle, connecting, connected, failed, stopped }

/// A nearby Phoneopia Android device seen advertising sharing/receiving
/// availability over the existing Nearby (BLE/Bluetooth) link — same
/// authenticated channel calls already use, tagged 'kind':'sharing'
/// (see NearbyService.onSharingSignal). Never a random unpaired Bluetooth
/// device — only real, currently-connected Phoneopia accounts appear here.
class NearbySharingDevice {
  final int userId;
  final String name;
  final String platform; // always 'android' for now — iOS unsupported
  final bool internetAvailable;
  NearbySharingDevice({
    required this.userId,
    required this.name,
    required this.platform,
    required this.internetAvailable,
  });
}

class IncomingSharingRequest {
  final int requestId;
  final int senderUserId;
  final String senderName;
  final String? senderAvatar;
  final String sessionToken;
  final DateTime expiresAt;
  IncomingSharingRequest({
    required this.requestId,
    required this.senderUserId,
    required this.senderName,
    required this.senderAvatar,
    required this.sessionToken,
    required this.expiresAt,
  });
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// Android-only Bluetooth internet sharing between two Phoneopia devices.
///
/// Real architecture (see MainActivity.kt for the platform-level "why"):
///   1. Discovery/pairing/request-accept ride the existing, already-
///      authenticated Nearby Connections channel (no new Bluetooth stack).
///   2. Actual internet transport is classic Bluetooth PAN — Android gives
///      no public API for an app to drive that programmatically
///      (BluetoothPan.connect() needs BLUETOOTH_PRIVILEGED, which regular
///      apps can never hold), so the sender enables the system's own
///      "Bluetooth Tethering" toggle and the receiver enables "Internet
///      access" for the now-paired device — both one-tap, both guided by
///      this app via deep links, neither fully automatable.
///   3. "Connected" is only ever reported after a real reachability check
///      (native TRANSPORT_BLUETOOTH + live TCP probe) — never assumed.
class SharingService extends ChangeNotifier {
  static final SharingService _i = SharingService._();
  factory SharingService() => _i;
  SharingService._();

  static const _method = MethodChannel('phoneopia/bluetooth_sharing');
  static const _discoveryEvents = EventChannel('phoneopia/bluetooth_sharing_discovery');

  String? _deviceId;
  String? _myName;
  int? _myUserId;
  int? get myUserId => _myUserId;

  SharingRole role = SharingRole.none;
  bool scanning = false;
  final Map<int, NearbySharingDevice> _discovered = {};
  List<NearbySharingDevice> get discoveredDevices => _discovered.values.toList();

  final List<IncomingSharingRequest> _pendingRequests = [];
  List<IncomingSharingRequest> get pendingRequests {
    _pendingRequests.removeWhere((r) => r.isExpired);
    return List.unmodifiable(_pendingRequests);
  }

  int? _outgoingRequestId;
  String? _outgoingRequestPeerName;
  bool get hasOutgoingRequest => _outgoingRequestId != null;
  String? get outgoingRequestPeerName => _outgoingRequestPeerName;

  int? activeSessionId;
  String? _sessionTag; // short Bluetooth-discoverable name tag for this session's pairing step
  SharingSessionStatus sessionStatus = SharingSessionStatus.idle;
  String? sessionPeerName;
  int dataUsageBytes = 0;
  DateTime? sessionStartedAt;

  StreamSubscription? _nearbySignalSub;
  StreamSubscription? _discoverySub;
  Timer? _connectivityPollTimer;

  Future<String> _ensureDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString(StorageKeys.sharingDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4().replaceAll('-', '').substring(0, 32);
      await p.setString(StorageKeys.sharingDeviceId, id);
    }
    _deviceId = id;
    return id;
  }

  Future<bool> ensurePermissions() => NearbyService().ensurePermissions();

  void _listenNearbySignals() {
    _nearbySignalSub ??= NearbyService().onSharingSignal.listen(_onNearbySignal);
  }

  void _onNearbySignal(Map<String, dynamic> data) {
    final kind = data['action']?.toString() ?? '';
    final fromUid = data['from_user_id'] as int?;
    final fromName = data['from_name']?.toString() ?? 'Nearby device';
    if (kind == 'advertise' && fromUid != null) {
      _discovered[fromUid] = NearbySharingDevice(
        userId: fromUid,
        name: (data['device_name'] ?? fromName).toString(),
        platform: (data['platform'] ?? 'android').toString(),
        internetAvailable: data['internet_available'] == true,
      );
      notifyListeners();
    }
  }

  /// Sender flow — open "Share Your Wi-Fi", start advertising availability
  /// and looking for nearby devices in "Receive Wi-Fi" mode.
  Future<bool> startSharing({required String myName, required int myUserId}) async {
    if (!await ensurePermissions()) return false;
    _myName = myName;
    _myUserId = myUserId;
    role = SharingRole.sender;
    scanning = true;
    _discovered.clear();
    _listenNearbySignals();
    final deviceId = await _ensureDeviceId();
    final online = !await ApiService.isOffline();
    await ApiService.post('sharing.php?action=set_availability', {
      'device_id': deviceId,
      'device_name': myName,
      'platform': 'android',
      'sharing_enabled': true,
      'receiving_enabled': false,
      'internet_available': online,
    });
    // Announce ourselves to every already-connected Nearby peer so a
    // receiver already on the "Receive Wi-Fi" screen sees us immediately
    // instead of waiting on the next discovery cycle.
    _broadcastAdvertise(internetAvailable: online);
    notifyListeners();
    return true;
  }

  /// Receiver flow — open "Receive Wi-Fi", advertise that this device is
  /// looking to receive, and start scanning for senders.
  Future<bool> startReceiving({required String myName, required int myUserId}) async {
    if (!await ensurePermissions()) return false;
    _myName = myName;
    _myUserId = myUserId;
    role = SharingRole.receiver;
    scanning = true;
    _discovered.clear();
    _listenNearbySignals();
    final deviceId = await _ensureDeviceId();
    await ApiService.post('sharing.php?action=set_availability', {
      'device_id': deviceId,
      'device_name': myName,
      'platform': 'android',
      'sharing_enabled': false,
      'receiving_enabled': true,
      'internet_available': false,
    });
    unawaited(refreshPendingRequests());
    notifyListeners();
    return true;
  }

  void _broadcastAdvertise({required bool internetAvailable}) {
    for (final id in NearbyService().peerUserId.values.toSet()) {
      unawaited(NearbyService().sendSharingSignal(id, {
        'action': 'advertise',
        'device_name': _myName ?? 'Phoneopia device',
        'platform': 'android',
        'internet_available': internetAvailable,
      }));
    }
  }

  Future<void> stopScanning() async {
    scanning = false;
    role = SharingRole.none;
    _discovered.clear();
    final deviceId = await _ensureDeviceId();
    unawaited(ApiService.post('sharing.php?action=set_availability', {
      'device_id': deviceId,
      'sharing_enabled': false,
      'receiving_enabled': false,
      'internet_available': false,
    }));
    notifyListeners();
  }

  /// Sender selects a discovered receiver and sends a share request.
  Future<bool> sendShareRequest(NearbySharingDevice device) async {
    final deviceId = await _ensureDeviceId();
    // The receiver's own device_id, from their advertise payload — falls
    // back to a placeholder if somehow missing (server still resolves the
    // request by user id either way; device_id is for the pairing step).
    final r = await ApiService.post('sharing.php?action=create_request', {
      'device_id': deviceId,
      'sender_device_name': _myName ?? 'Phoneopia device',
      'receiver_user_id': device.userId,
      'receiver_device_id': _peerDeviceIds[device.userId] ?? 'unknown',
    });
    if (r['error'] != null) return false;
    _outgoingRequestId = r['request_id'] as int?;
    _outgoingRequestPeerName = device.name;
    notifyListeners();
    return true;
  }

  final Map<int, String> _peerDeviceIds = {};

  void cancelOutgoingRequest() {
    _outgoingRequestId = null;
    _outgoingRequestPeerName = null;
    notifyListeners();
  }

  Future<void> refreshPendingRequests() async {
    final r = await ApiService.get('sharing.php?action=list_pending');
    final list = r['requests'];
    if (list is! List) return;
    _pendingRequests.clear();
    for (final row in list) {
      if (row is! Map) continue;
      final id = int.tryParse(row['id']?.toString() ?? '');
      final senderUserId = int.tryParse(row['sender_user_id']?.toString() ?? '');
      final token = row['session_token']?.toString();
      final expiresAt = DateTime.tryParse(row['expires_at']?.toString() ?? '');
      if (id == null || senderUserId == null || token == null || expiresAt == null) continue;
      _pendingRequests.add(IncomingSharingRequest(
        requestId: id,
        senderUserId: senderUserId,
        senderName: (row['sender_name'] ?? row['sender_username'] ?? 'Phoneopia user').toString(),
        senderAvatar: row['sender_avatar']?.toString(),
        sessionToken: token,
        expiresAt: expiresAt,
      ));
    }
    notifyListeners();
  }

  Future<int?> respondToRequest(IncomingSharingRequest request, bool accept) async {
    final r = await ApiService.post('sharing.php?action=respond_request', {
      'request_id': request.requestId,
      'accept': accept,
    });
    _pendingRequests.removeWhere((x) => x.requestId == request.requestId);
    notifyListeners();
    if (r['error'] != null || !accept) return null;
    final sessionId = r['session_id'] as int?;
    if (sessionId != null) {
      activeSessionId = sessionId;
      _sessionTag = _tagFromToken(request.sessionToken);
      sessionStatus = SharingSessionStatus.connecting;
      sessionPeerName = request.senderName;
      sessionStartedAt = DateTime.now();
      notifyListeners();
      unawaited(_pairAndVerify());
    }
    return sessionId;
  }

  /// A short, non-identifying tag derived from the session token — both
  /// sides set it as their temporary Bluetooth-discoverable name so the
  /// receiver can find the exact right physical device during classic
  /// discovery without guessing from a list of arbitrary device names.
  String _tagFromToken(String token) => 'PHX-${token.substring(0, 8)}';

  /// Handles server-relayed SHARING_*/FAILOVER_* events forwarded here by
  /// AppProvider's realtime dispatch — this service doesn't register its
  /// own WS listener, reusing the app's single existing WS/SSE pipeline.
  void handleServerEvent(Map<String, dynamic> data) {
    final type = data['type']?.toString() ?? '';
    switch (type) {
      case 'SHARING_REQUEST':
        unawaited(refreshPendingRequests());
        break;
      case 'SHARING_ACCEPTED':
        final sessionId = data['session_id'] as int?;
        final token = data['session_token']?.toString();
        if (_outgoingRequestId != null && sessionId != null) {
          activeSessionId = sessionId;
          _sessionTag = token != null ? _tagFromToken(token) : null;
          sessionStatus = SharingSessionStatus.connecting;
          sessionPeerName = _outgoingRequestPeerName;
          sessionStartedAt = DateTime.now();
          _outgoingRequestId = null;
          notifyListeners();
          unawaited(_guideSenderSetup());
        }
        break;
      case 'SHARING_DECLINED':
        _outgoingRequestId = null;
        _outgoingRequestPeerName = null;
        notifyListeners();
        break;
      case 'SHARING_STARTED':
        if (activeSessionId != null && data['session_id'] == activeSessionId) {
          sessionStatus = SharingSessionStatus.connected;
          notifyListeners();
        }
        break;
      case 'SHARING_STOPPED':
      case 'SHARING_DISCONNECTED':
        if (activeSessionId != null && data['session_id'] == activeSessionId) {
          _endSessionLocally(failed: type == 'SHARING_DISCONNECTED');
        }
        break;
    }
  }

  Future<void> _pairAndVerify() async {
    // Receiver side: classic-Bluetooth-discover the sender's physical
    // device — matched by the temporary discoverable name both sides tag
    // themselves with for this session (see _tagFromToken) — then pair.
    final tag = _sessionTag;
    if (tag == null) {
      _endSessionLocally(failed: true);
      return;
    }
    String? matchedAddress;
    await _discoverySub?.cancel();
    _discoverySub = _discoveryEvents.receiveBroadcastStream().listen((event) {
      if (event is! Map) return;
      final name = event['name']?.toString() ?? '';
      final address = event['address']?.toString();
      if (name == tag && address != null && matchedAddress == null) {
        matchedAddress = address;
        unawaited(_method.invokeMethod('pairDevice', address));
      }
    });
    try {
      await _method.invokeMethod('startClassicDiscovery');
    } catch (_) {}

    _connectivityPollTimer?.cancel();
    var attempts = 0;
    _connectivityPollTimer = Timer.periodic(const Duration(seconds: 3), (t) async {
      attempts++;
      final ok = await _checkRealInternet();
      if (ok) {
        t.cancel();
        await _discoverySub?.cancel();
        _discoverySub = null;
        try { await _method.invokeMethod('stopClassicDiscovery'); } catch (_) {}
        sessionStatus = SharingSessionStatus.connected;
        notifyListeners();
        final sid = activeSessionId;
        if (sid != null) {
          unawaited(ApiService.post('sharing.php?action=report_session_status', {'session_id': sid, 'status': 'connected'}));
        }
      } else if (attempts > 40) { // ~2 minutes
        t.cancel();
        await _discoverySub?.cancel();
        _discoverySub = null;
        try { await _method.invokeMethod('stopClassicDiscovery'); } catch (_) {}
        _endSessionLocally(failed: true);
      }
    });
  }

  Future<void> _guideSenderSetup() async {
    // Sender side: tag this device as discoverable under the session's name
    // so the receiver's classic-Bluetooth scan can find and pair it. The
    // rest (enabling Bluetooth Tethering) needs the user's one tap — the UI
    // screen calls openTetheringSettings() for that.
    final tag = _sessionTag;
    if (tag != null) {
      try { await _method.invokeMethod('setDiscoverableName', tag); } catch (_) {}
    }
  }

  Future<bool> _checkRealInternet() async {
    try {
      return await _method.invokeMethod('checkBluetoothInternet') == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> openTetheringSettings() async {
    try { await _method.invokeMethod('openBluetoothTetheringSettings'); } catch (_) {}
  }

  Future<void> openBluetoothSettings() async {
    try { await _method.invokeMethod('openBluetoothSettings'); } catch (_) {}
  }

  Future<void> stopSession() async {
    final sid = activeSessionId;
    if (sid != null) {
      unawaited(ApiService.post('sharing.php?action=stop_session', {'session_id': sid}));
    }
    _endSessionLocally(failed: false);
  }

  void _endSessionLocally({required bool failed}) {
    _connectivityPollTimer?.cancel();
    _connectivityPollTimer = null;
    try { _method.invokeMethod('stopClassicDiscovery'); } catch (_) {}
    activeSessionId = null;
    sessionStatus = failed ? SharingSessionStatus.failed : SharingSessionStatus.idle;
    sessionPeerName = null;
    dataUsageBytes = 0;
    sessionStartedAt = null;
    notifyListeners();
  }

  /// Full teardown — called on logout/account switch, matching
  /// NearbyService's own stop() lifecycle.
  Future<void> stop() async {
    await _nearbySignalSub?.cancel();
    _nearbySignalSub = null;
    await _discoverySub?.cancel();
    _discoverySub = null;
    _connectivityPollTimer?.cancel();
    _connectivityPollTimer = null;
    try { await _method.invokeMethod('stopClassicDiscovery'); } catch (_) {}
    role = SharingRole.none;
    scanning = false;
    _discovered.clear();
    _pendingRequests.clear();
    activeSessionId = null;
    sessionStatus = SharingSessionStatus.idle;
  }
}
