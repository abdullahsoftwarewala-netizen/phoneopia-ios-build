import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/nearby_service.dart';
import '../theme/app_theme.dart';
import '../utils/open_nearby_chat.dart';

/// Offline chat with people nearby (Bluetooth/BLE, no internet
/// needed) — Phase 1: text only, direct range, no mesh relay yet.
class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});
  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  final _svc = NearbyService();
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    _init();
    _svc.addListener(_onChange);
  }

  Future<void> _init() async {
    final me = context.read<AppProvider>().me;
    final name = me?.displayName ?? me?.username ?? 'Phoneopia User';
    await _svc.start(name, me?.id ?? 0);
    if (mounted) setState(() => _starting = false);
  }

  void _onChange() { if (mounted) setState(() {}); }

  @override
  void dispose() {
    // Keep discovering/advertising in the background — other chats rely on
    // NearbyService staying up to show "Using Nearby (offline)" and route
    // messages, not just this screen.
    _svc.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ids = _svc.peers.keys.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby (offline)'),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      body: _starting
          ? const Center(child: CircularProgressIndicator())
          : Column(children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                color: AppColors.primary.withOpacity(0.08),
                child: Row(children: [
                  Icon(Icons.bluetooth_searching, color: AppColors.primary, size: 18),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text('Internet ke baghair Bluetooth se nearby Phoneopia users ko connect karein.',
                        style: TextStyle(fontSize: 12.5)),
                  ),
                ]),
              ),
              Expanded(
                child: ids.isEmpty
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.wifi_tethering, size: 56, color: Colors.grey),
                          const SizedBox(height: 12),
                          const Text('Koi nearby user nahi mila abhi tak…',
                              style: TextStyle(color: Colors.grey, fontSize: 14)),
                          const SizedBox(height: 6),
                          Text('Dusre user ka Bluetooth aur Phoneopia active hona chahiye',
                              style: TextStyle(color: Colors.grey[500], fontSize: 12)),
                        ]),
                      )
                    : ListView.builder(
                        itemCount: ids.length,
                        itemBuilder: (_, i) {
                          final id = ids[i];
                          final name = _svc.peers[id] ?? 'Unknown';
                          final state = _svc.peerState[id] ?? 'discovered';
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppColors.primary,
                              child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                                  style: const TextStyle(color: Colors.white)),
                            ),
                            title: Text(name),
                            subtitle: Text(state == 'connected'
                                ? 'Connected — tap to chat'
                                : state == 'connecting' ? 'Connecting…' : 'Nearby'),
                            trailing: state == 'connected'
                                ? const Icon(Icons.chat_bubble, color: AppColors.primary)
                                : state == 'connecting'
                                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.link),
                            onTap: () async {
                              if (state == 'connected') {
                                await openNearbyChat(context, id);
                              } else if (state == 'discovered') {
                                await _svc.connectTo(id);
                              }
                            },
                          );
                        },
                      ),
              ),
            ]),
    );
  }
}

class _NearbyChatScreen extends StatefulWidget {
  final String endpointId;
  final String peerName;
  const _NearbyChatScreen({required this.endpointId, required this.peerName});
  @override
  State<_NearbyChatScreen> createState() => _NearbyChatScreenState();
}

class _NearbyChatScreenState extends State<_NearbyChatScreen> {
  final _svc = NearbyService();
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();

  void _onMsg(NearbyMessage m) {
    if (m.endpointId == widget.endpointId && mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _svc.onMessage.listen(_onMsg);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    _ctrl.clear();
    // sendText() adds the outgoing bubble to its list synchronously before
    // it ever awaits the native Bluetooth send — but this screen only
    // rebuilds via its own setState(), so gating that behind `await
    // sendText(...)` meant a message sat invisible here until the native
    // call finished (which can be slow, or hang outright, on some OEM
    // Bluetooth stacks) — closing and reopening the chat was the only way
    // to see it, since a fresh build() reads the by-then-updated list.
    unawaited(_svc.sendText(widget.endpointId, text));
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final msgs = _svc.messagesFor(widget.endpointId);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peerName),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(20),
          child: Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text('Offline — direct connection', style: TextStyle(fontSize: 11, color: Colors.white70)),
          ),
        ),
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(12),
            itemCount: msgs.length,
            itemBuilder: (_, i) {
              final m = msgs[i];
              return Align(
                alignment: m.fromMe ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: m.fromMe ? AppColors.primary : Colors.grey[200],
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(m.text, style: TextStyle(color: m.fromMe ? Colors.white : Colors.black87)),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  decoration: InputDecoration(
                    hintText: 'Message…',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: AppColors.primary,
                child: IconButton(icon: const Icon(Icons.send, color: Colors.white, size: 18), onPressed: _send),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
