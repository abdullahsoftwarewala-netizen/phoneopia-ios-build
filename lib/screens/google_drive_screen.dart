import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Compulsory Google Drive connection. Opens Google OAuth in browser,
/// then polls status until connected. Used both as a full screen and a gate.
class GoogleDriveScreen extends StatefulWidget {
  final bool gate; // true = compulsory (can't go back until connected)
  const GoogleDriveScreen({super.key, this.gate = false});

  @override
  State<GoogleDriveScreen> createState() => _GoogleDriveScreenState();
}

class _GoogleDriveScreenState extends State<GoogleDriveScreen> {
  bool _loading = true, _connected = false, _connecting = false;
  String? _email;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() { _poll?.cancel(); super.dispose(); }

  Future<void> _refresh() async {
    try {
      var r = await ApiService.gdriveStatus();
      if (r['error'] != null) {
        // Right after a fresh login the token write can still be settling —
        // one short retry avoids a false "not connected" on cold start.
        await Future.delayed(const Duration(milliseconds: 700));
        r = await ApiService.gdriveStatus();
      }
      if (r['error'] != null) {
        // Still failing — force a disk re-read in case the in-memory token
        // cache is stale/empty on this device, then try once more.
        final t = await ApiService.forceReloadToken();
        if (t != null && t.isNotEmpty) r = await ApiService.gdriveStatus();
      }
      setState(() { _connected = r['connected'] == true; _email = r['email']; _loading = false; });
    } catch (_) { setState(() => _loading = false); }
  }

  Future<void> _connect() async {
    setState(() => _connecting = true);
    try {
      var r = await ApiService.gdriveConnect();
      if (r['error'] != null) {
        // Same cold-start token-settling race as _refresh() — retry once.
        await Future.delayed(const Duration(milliseconds: 700));
        r = await ApiService.gdriveConnect();
      }
      String? tokenAtFailure;
      if (r['error'] != null) {
        // Still failing — force a disk re-read in case the in-memory token
        // cache is stale/empty on this device, then try once more.
        tokenAtFailure = await ApiService.forceReloadToken();
        if (tokenAtFailure != null && tokenAtFailure.isNotEmpty) r = await ApiService.gdriveConnect();
      }
      final url = r['url'] as String?;
      if (url == null) {
        setState(() => _connecting = false);
        if (mounted) {
          final hadToken = tokenAtFailure != null && tokenAtFailure.isNotEmpty;
          // Last 8 chars only — enough to test this exact token server-side
          // without exposing the full credential in a UI snackbar.
          final tokenTail = hadToken && tokenAtFailure!.length >= 8
              ? tokenAtFailure.substring(tokenAtFailure.length - 8) : (hadToken ? tokenAtFailure : '');
          final base = r['error']?.toString() ?? 'Could not start Google connection';
          final detail = r['error'] != null
              ? ' (token ${hadToken ? '…$tokenTail' : 'MISSING'} on retry)' : '';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(base + detail)));
        }
        return;
      }
      final opened = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!opened) {
        setState(() => _connecting = false);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not open a browser to connect Google Drive')));
        }
        return;
      }
      // poll until connected
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
        final s = await ApiService.gdriveStatus();
        if (s['connected'] == true) {
          t.cancel();
          if (!mounted) return;
          setState(() { _connected = true; _email = s['email']; _connecting = false; });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Google Drive connected ✅'), backgroundColor: Color(0xFF0E9F6E)));
          if (widget.gate) Navigator.of(context).pop(true);
        }
      });
    } catch (_) { setState(() => _connecting = false); }
  }

  Future<void> _changeAccount() async {
    await ApiService.gdriveDisconnect();
    setState(() { _connected = false; _email = null; });
    _connect();
  }

  Future<void> _confirmClose() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlg) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('Google Drive is required to use Phoneopia. Closing this now will log you out so you can sign in again later.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlg, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(dlg, true), child: const Text('Log out', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok == true && mounted) await context.read<AppProvider>().logout();
  }

  @override
  Widget build(BuildContext context) {
    const green = AppColors.primary;
    return WillPopScope(
      onWillPop: () async => !(widget.gate && !_connected),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Google Drive'),
          automaticallyImplyLeading: !(widget.gate && !_connected),
          actions: widget.gate && !_connected
              ? [IconButton(icon: const Icon(Icons.close), tooltip: 'Log out', onPressed: _confirmClose)]
              : null,
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    Center(
                      child: Container(
                        width: 84, height: 84,
                        decoration: BoxDecoration(color: green.withOpacity(.12), shape: BoxShape.circle),
                        child: const Icon(Icons.add_to_drive, color: Color(0xFF0E9F6E), size: 40),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(_connected ? 'Connected' : 'Connect Google Drive',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(
                      _connected
                          ? (_email ?? 'Your backup account')
                          : 'Phoneopia use karne se pehle Google Drive connect karna zaroori hai — taake aapki chats & media safe backup rahein.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600], fontSize: 14, height: 1.5),
                    ),
                    if (!_connected) ...[
                      const SizedBox(height: 6),
                      const Text('Iske baghair messages bhejna aur calls band rahenge.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFFEF4444), fontSize: 13, fontWeight: FontWeight.w500)),
                    ],
                    const SizedBox(height: 26),
                    if (_connected)
                      OutlinedButton.icon(
                        onPressed: _changeAccount,
                        icon: const Icon(Icons.swap_horiz),
                        label: const Text('Change account'),
                        style: OutlinedButton.styleFrom(padding: const EdgeInsets.all(14)),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: _connecting ? null : _connect,
                        icon: _connecting
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.login),
                        label: Text(_connecting ? 'Waiting for Google…' : 'Connect Google Drive'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: green, foregroundColor: Colors.white,
                          padding: const EdgeInsets.all(15),
                          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                      ),
                    if (_connecting)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: TextButton(onPressed: _refresh, child: const Text("Connect ho gaya? Tap to check")),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}
