import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/group_call_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';

/// Multi-party group voice call (mesh). The initiator rings the whole group via
/// group_call_invite; members who accept open this screen with isInitiator=false
/// (which sends group_join). Mesh peer-connections are managed by GroupCallService.
class GroupCallScreen extends StatefulWidget {
  final int convId;
  final String groupName;
  final bool isInitiator;
  final List<GroupMember> members;
  const GroupCallScreen({
    super.key,
    required this.convId,
    required this.groupName,
    required this.isInitiator,
    this.members = const [],
  });
  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  final _svc = GroupCallService();
  late void Function(Map<String, dynamic>) _wsHandler;
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  bool _muted = false;
  bool _speaker = true;
  bool _ending = false;

  int get _meId => context.read<AppProvider>().me?.id ?? 0;

  @override
  void initState() {
    super.initState();
    _wsHandler = _onWs;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final prov = context.read<AppProvider>();
      prov.setInActiveCallUi(true);
      _svc.setSender(prov.sendWs);
      _svc.onChange = () { if (mounted) setState(() {}); };
      prov.addWsListener(_wsHandler);
      try { await _svc.initLocal(); } catch (_) {}
      if (widget.isInitiator) {
        prov.sendWs({'type': 'group_call_invite', 'conversation_id': widget.convId, 'call_type': 'audio'});
      } else {
        prov.sendWs({'type': 'group_join', 'conversation_id': widget.convId});
      }
      _startTimer();
    });
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed += const Duration(seconds: 1));
    });
  }

  void _onWs(Map<String, dynamic> data) {
    final type = data['type']?.toString();
    final from = int.tryParse(data['from_user_id']?.toString() ?? '') ?? 0;
    switch (type) {
      case 'group_join':
        // Only react to joins for THIS group; existing members offer the joiner.
        final cid = int.tryParse(data['conversation_id']?.toString() ?? '') ?? 0;
        if (cid == widget.convId && from > 0 && from != _meId) {
          unawaited(_svc.offerPeer(from));
        }
        break;
      case 'group_offer':
        if (from > 0) unawaited(_svc.handleOffer(from, data['sdp']?.toString() ?? '', data['sdp_type']?.toString() ?? 'offer'));
        break;
      case 'group_answer':
        if (from > 0) unawaited(_svc.handleAnswer(from, data['sdp']?.toString() ?? '', data['sdp_type']?.toString() ?? 'answer'));
        break;
      case 'group_ice':
        if (from > 0) unawaited(_svc.handleIce(from, data));
        break;
      case 'group_leave':
        if (from > 0) _svc.removePeer(from);
        break;
    }
  }

  Future<void> _leave() async {
    if (_ending) return;
    _ending = true;
    _timer?.cancel();
    final prov = context.read<AppProvider>();
    try { prov.sendWs({'type': 'group_leave', 'conversation_id': widget.convId}); } catch (_) {}
    prov.removeWsListener(_wsHandler);
    prov.setInActiveCallUi(false);
    prov.setActiveCallPeer(null);
    await _svc.end();
    if (mounted) Navigator.of(context).pop();
  }

  void _toggleMute() { setState(() => _muted = !_muted); _svc.setMuted(_muted); }
  void _toggleSpeaker() { setState(() => _speaker = !_speaker); _svc.setSpeaker(_speaker); }

  String _name(int id) {
    final m = widget.members.where((x) => x.id == id);
    if (m.isNotEmpty) return m.first.displayName;
    return 'Participant';
  }

  String? _avatar(int id) {
    final m = widget.members.where((x) => x.id == id);
    if (m.isNotEmpty) return m.first.avatar;
    return null;
  }

  String get _timeLabel {
    final m = _elapsed.inMinutes.toString().padLeft(2, '0');
    final s = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peers = _svc.peerIds.toList()..sort();
    final connected = _svc.connectedCount;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) { if (!didPop) _leave(); },
      child: Scaffold(
        backgroundColor: const Color(0xFF0D2014),
        body: SafeArea(
          child: Column(children: [
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(widget.groupName,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 6),
            Text(
              connected == 0
                  ? (widget.isInitiator ? 'Ringing group…' : 'Connecting…')
                  : '$_timeLabel · ${connected + 1} in call',
              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: GridView.count(
                crossAxisCount: peers.length <= 1 ? 1 : 2,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                mainAxisSpacing: 16,
                crossAxisSpacing: 16,
                children: [
                  _tile(_meId, you: true),
                  for (final p in peers) _tile(p),
                ],
              ),
            ),
            // Controls
            Padding(
              padding: const EdgeInsets.only(bottom: 28, top: 8),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _ctrl(_muted ? Icons.mic_off : Icons.mic, _muted ? 'Unmute' : 'Mute', _toggleMute,
                  bg: _muted ? Colors.white : Colors.white24, fg: _muted ? Colors.black : Colors.white),
                const SizedBox(width: 26),
                _ctrl(_speaker ? Icons.volume_up : Icons.volume_down, 'Speaker', _toggleSpeaker,
                  bg: Colors.white24, fg: Colors.white),
                const SizedBox(width: 26),
                _ctrl(Icons.call_end, 'Leave', _leave, bg: const Color(0xFFEF4444), fg: Colors.white),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _tile(int id, {bool you = false}) {
    final connected = you || _svc.remoteStreams.containsKey(id);
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: connected ? AppColors.primary.withOpacity(0.6) : Colors.white12, width: 1.5),
      ),
      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        AvatarWidget(imageUrl: you ? null : _avatar(id), name: you ? 'You' : _name(id), size: 64),
        const SizedBox(height: 12),
        Text(you ? 'You' : _name(id),
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
        const SizedBox(height: 4),
        Text(connected ? 'Connected' : 'Calling…',
          style: TextStyle(color: connected ? AppColors.primaryLight : Colors.white54, fontSize: 12)),
      ]),
    );
  }

  Widget _ctrl(IconData icon, String label, VoidCallback onTap, {required Color bg, required Color fg}) {
    return Column(children: [
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 62, height: 62,
          decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
          child: Icon(icon, color: fg, size: 28),
        ),
      ),
      const SizedBox(height: 8),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
    ]);
  }
}
