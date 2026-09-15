import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../utils/server_time.dart';

class LinkedDevicesScreen extends StatefulWidget {
  const LinkedDevicesScreen({super.key});
  @override State<LinkedDevicesScreen> createState() => _LinkedDevicesScreenState();
}

class _LinkedDevicesScreenState extends State<LinkedDevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  Future<void> _loadDevices() async {
    setState(() => _loading = true);
    try {
      final r = await ApiService.get('qr.php?action=list_devices');
      final list = r['devices'];
      if (list is List) {
        setState(() { _devices = list.cast<Map<String, dynamic>>(); _loading = false; });
      } else {
        setState(() { _devices = []; _loading = false; });
      }
    } catch (_) {
      setState(() { _devices = []; _loading = false; });
    }
  }

  Future<void> _removeDevice(String deviceId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove device?', style: TextStyle(fontWeight: FontWeight.w700)),
        content: const Text('This device will be logged out and will no longer have access to your account.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiService.post('qr.php?action=remove_device', {'action': 'remove_device', 'device_id': deviceId});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Device removed')));
      }
      _loadDevices();
    } catch (_) {}
  }

  String _formatLastActive(dynamic raw) {
    if (raw == null) return 'Never';
    try {
      final dt = parseServerTime(raw);
      if (dt == null) return 'Never';
      final now = DateTime.now();
      final diff = now.difference(dt);
      if (diff.inMinutes < 1)  return 'Just now';
      if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
      if (diff.inHours < 24)   return 'Today at ${DateFormat('h:mm a').format(dt)}';
      if (diff.inDays == 1)    return 'Yesterday at ${DateFormat('h:mm a').format(dt)}';
      return DateFormat('d MMM, h:mm a').format(dt);
    } catch (_) {
      return raw.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    final linked = _devices.length;
    final max = 4;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        title: const Text('Linked devices', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.t1Light)),
        iconTheme: const IconThemeData(color: AppColors.t1Light),
        elevation: 0,
      ),
      body: RefreshIndicator(
        color: AppColors.primary,
        onRefresh: _loadDevices,
        child: ListView(
          children: [
            // ── Header hero illustration ──
            Container(
              color: Colors.white,
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Column(children: [
                SvgPicture.asset(
                  'assets/images/linked_devices_hero.svg',
                  height: 160,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Use Phoneopia on multiple devices',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111B21)),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Link your phone or computer to sync chats securely.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF667781), height: 1.4),
                ),
                const SizedBox(height: 14),
                if (_loading)
                  const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary))
                else
                  Text(
                    '$linked of $max devices linked.',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111B21)),
                  ),
                const SizedBox(height: 20),
                // Link a device button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: AppColors.primary, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                      foregroundColor: AppColors.primary,
                    ),
                    onPressed: linked >= max
                        ? null
                        : () async {
                            await Navigator.pushNamed(context, '/qr');
                            _loadDevices();
                          },
                    child: const Text('Link a device', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),

            const Divider(height: 1),

            // ── Device list ─────────────────────────────────────────────────
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('LINKED DEVICES', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF667781), letterSpacing: 0.8)),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text('Tap a device to edit or remove it', style: TextStyle(fontSize: 13, color: Color(0xFF667781))),
            ),

            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
              )
            else if (_devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: Center(child: Text('No linked devices yet.\nLink your first device above.', textAlign: TextAlign.center, style: TextStyle(color: Color(0xFF667781), height: 1.6))),
              )
            else
              ..._devices.asMap().entries.map((e) => _DeviceTile(
                device: e.value,
                index: e.key,
                lastActiveStr: _formatLastActive(e.value['last_active'] ?? e.value['created_at']),
                onRemove: () => _removeDevice(e.value['device_id']?.toString() ?? ''),
              )),

            const Divider(height: 1),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              child: Text(
                'Devices can access all account messages. Other users cannot see device names. You can change a device name anytime.',
                style: TextStyle(fontSize: 12, color: Color(0xFF667781), height: 1.6),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

// ── Animated device tile ──────────────────────────────────────────────────────
class _DeviceTile extends StatefulWidget {
  final Map<String, dynamic> device;
  final int index;
  final String lastActiveStr;
  final VoidCallback onRemove;
  const _DeviceTile({required this.device, required this.index, required this.lastActiveStr, required this.onRemove});
  @override State<_DeviceTile> createState() => _DeviceTileState();
}

class _DeviceTileState extends State<_DeviceTile> with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    Future.delayed(Duration(milliseconds: widget.index * 80), () { if (mounted) _c.forward(); });
  }
  @override void dispose() { _c.dispose(); super.dispose(); }

  IconData get _deviceIcon {
    final name = (widget.device['device_name'] ?? widget.device['name'] ?? '').toString().toLowerCase();
    if (name.contains('chrome') || name.contains('firefox') || name.contains('safari') || name.contains('web')) {
      return Icons.laptop_mac_outlined;
    }
    if (name.contains('windows') || name.contains('mac') || name.contains('linux') || name.contains('laptop')) {
      return Icons.laptop_outlined;
    }
    return Icons.devices_other_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.device['device_name'] ?? widget.device['name'] ?? 'Unknown device';
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: _c.value,
        child: Transform.translate(offset: Offset(0, 20 * (1 - _c.value)), child: child),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Container(
          width: 48, height: 48,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: const Color(0xFFF0F2F5),
          ),
          child: Icon(_deviceIcon, color: const Color(0xFF667781), size: 22),
        ),
        title: Text(name.toString(), style: const TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF111B21), fontSize: 15)),
        subtitle: Text('Last active ${widget.lastActiveStr}', style: const TextStyle(fontSize: 12, color: Color(0xFF667781))),
        onTap: () => _showDeviceOptions(context, name.toString()),
      ),
    );
  }

  void _showDeviceOptions(BuildContext ctx, String name) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(margin: const EdgeInsets.only(top: 10, bottom: 4), width: 40, height: 4,
          decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(shape: BoxShape.circle, color: const Color(0xFFF0F2F5)),
              child: Icon(_deviceIcon, color: const Color(0xFF667781), size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Color(0xFF111B21))),
              Text('Last active ${widget.lastActiveStr}', style: const TextStyle(fontSize: 12, color: Color(0xFF667781))),
            ])),
          ]),
        ),
        const Divider(height: 1),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.red),
          title: const Text('Log out', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
          onTap: () { Navigator.pop(ctx); widget.onRemove(); },
        ),
        const SizedBox(height: 8),
      ])),
    );
  }
}
