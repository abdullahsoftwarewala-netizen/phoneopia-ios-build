import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Real connection status for the authorized Phoneopia WhatsApp service.
/// Private WhatsApp calls/chats are not faked or intercepted here.
class WhatsAppIntegrationScreen extends StatefulWidget {
  const WhatsAppIntegrationScreen({super.key});
  @override
  State<WhatsAppIntegrationScreen> createState() =>
      _WhatsAppIntegrationScreenState();
}

class _WhatsAppIntegrationScreenState extends State<WhatsAppIntegrationScreen> {
  Timer? _timer;
  String _state = 'loading';
  String? _qr;
  int _qrAge = 0;
  String? _error;
  DateTime? _connectedAt;
  bool _busy = false;
  bool _linkRequested = false;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _get(String endpoint) async {
    final value = await ApiService.get('whatsapp-connection.php?action=status',
      params: {'_': '${DateTime.now().millisecondsSinceEpoch}'})
      .timeout(const Duration(seconds: 15));
    _validate(value);
    return value;
  }

  void _validate(Map<String, dynamic> value) {
    if (!mounted || value['success'] != true || value['error'] != null ||
        value['user_id'] != context.read<AppProvider>().me?.id) {
      throw Exception('Unable to verify your WhatsApp session');
    }
  }

  void _applyStatus(Map<String, dynamic> value) {
    final connected = value['connected'] == true;
    final qr = value['qr'];
    final age = int.tryParse('${value['qr_age']}');
    setState(() {
      _qr = !connected && qr is String && qr.startsWith('data:image/png;base64,') &&
          (age == null || age < 60) ? qr : null;
      _qrAge = age ?? 0;
      _connectedAt = connected ? DateTime.tryParse('${value['connected_at']}') : null;
      _state = connected ? 'connected' : _qr != null ? 'connecting' :
          _linkRequested ? 'loading' : 'disconnected';
      _error = null;
    });
  }

  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    final generation = _generation;
    try {
      final status = await _get('/status');
      if (!mounted || generation != _generation) return;
      _applyStatus(status);
    } catch (_) {
      if (mounted && generation == _generation)
        setState(() {
          _state = 'error';
          _qr = null;
          _connectedAt = null;
          _error = 'WhatsApp service is temporarily unavailable.';
        });
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _action(String endpoint) async {
    final disconnect = endpoint == '/admin/disconnect';
    if (disconnect) {
      final confirmed = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        title: const Text('Disconnect WhatsApp?'),
        content: const Text('Unlink your WhatsApp account from Phoneopia?'),
        actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Disconnect'))],
      ));
      if (confirmed != true || !mounted) return;
    }
    _generation++;
    _busy = true;
    _linkRequested = !disconnect;
    setState(() {
      _state = 'loading';
      _qr = null;
      _error = null;
    });
    try {
      final result = await ApiService.post('whatsapp-connection.php?action=${disconnect ? 'disconnect' : 'connect'}', {})
          .timeout(const Duration(seconds: 15));
      _validate(result);
      _applyStatus(result);
    } catch (_) {
      if (mounted) setState(() {
        _state = 'error';
        _error = 'Could not update the connection. Please retry.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final title = dark ? AppColors.t1Dark : AppColors.t1Light;
    final body = dark ? AppColors.t3Dark : AppColors.t3Light;
    final card = dark ? AppColors.cardDark : Colors.white;
    return Scaffold(
      backgroundColor: dark ? AppColors.bgDark : const Color(0xFFF6FBF8),
      appBar: AppBar(
        title: const Text('WhatsApp connection'),
        backgroundColor: Colors.transparent,
        foregroundColor: title,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Positioned(
            right: -70,
            top: 20,
            child: Opacity(opacity: .055, child: Image.asset('assets/images/whatsapp_logo.png', width: 260)),
          ),
          ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              _hero(),
              const SizedBox(height: 18),
              _statusCard(card, title, body),
              const SizedBox(height: 18),
              _steps(card, title, body),
              const SizedBox(height: 18),
              _qrCard(card, title, body),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _action(
                  _state == 'connected'
                      ? '/admin/disconnect'
                      : '/admin/reconnect',
                ),
                icon: Icon(
                  _state == 'connected'
                      ? Icons.link_off_rounded
                      : Icons.refresh_rounded,
                ),
                label: Text(_state == 'connected' ? 'Disconnect' : 'Get WhatsApp QR'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _hero() => Container(
    padding: const EdgeInsets.all(22),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF25D366), Color(0xFF128C7E)],
      ),
      borderRadius: BorderRadius.circular(24),
      boxShadow: const [
        BoxShadow(
          color: Color(0x2225D366),
          blurRadius: 18,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: Row(
      children: [
        CircleAvatar(
          backgroundColor: Colors.white,
          radius: 29,
          child: ClipOval(child: Image.asset('assets/images/whatsapp_logo.png', width: 46, height: 46)),
        ),
        SizedBox(width: 14),
        Expanded(
          child: Text(
            'Connect WhatsApp\nto Phoneopia',
            style: TextStyle(
              color: Colors.white,
              fontSize: 21,
              fontWeight: FontWeight.w800,
              height: 1.15,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _statusCard(Color card, Color title, Color body) {
    final connected = _state == 'connected';
    final error = _state == 'error';
    final color = connected
        ? const Color(0xFF16A34A)
        : error
        ? Colors.red
        : const Color(0xFFF59E0B);
    final label = connected
        ? 'Connected'
        : error
        ? 'Connection error'
        : _state == 'loading'
        ? 'Checking connection…'
        : _state == 'disconnected' ? 'Not connected' : 'Waiting for scan';
    return Card(
      color: card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            if (_state == 'loading')
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFF25D366),
                ),
              )
            else
              Icon(
                connected
                    ? Icons.check_circle_rounded
                    : error
                    ? Icons.error_rounded
                    : Icons.radio_button_checked_rounded,
                color: color,
                size: 25,
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: title,
                      fontSize: 16,
                    ),
                  ),
                  if (connected && _connectedAt != null)
                    Text(
                      'Connected ${_connectedAt!.toLocal()}',
                      style: TextStyle(color: body, fontSize: 12, height: 1.5),
                    ),
                  if (error && _error != null)
                    Text(
                      _error!,
                      style: TextStyle(color: body, fontSize: 12, height: 1.5),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _steps(Color card, Color title, Color body) {
    const steps = [
      'Open WhatsApp on your phone.',
      'Go to Settings → Linked Devices.',
      'Choose Link a Device.',
      'Scan the QR code below.',
      'Wait for Phoneopia to confirm the connection.',
    ];
    return Card(
      color: card,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How to connect',
              style: TextStyle(
                color: title,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 14),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 13,
                      backgroundColor: const Color(0xFFE7F8EE),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          color: Color(0xFF128C7E),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        steps[i],
                        style: TextStyle(color: body, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _qrCard(Color card, Color title, Color body) => Card(
    color: card,
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        children: [
          Text(
            _state == 'connected'
                ? 'Connected Successfully'
                : 'Scan to connect',
            style: TextStyle(
              color: title,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _state == 'connected'
                ? 'Your authorized WhatsApp session is active.'
                : 'Use WhatsApp → Linked Devices → Link a Device.',
            textAlign: TextAlign.center,
            style: TextStyle(color: body, fontSize: 12.5),
          ),
          const SizedBox(height: 16),
          if (_state == 'connected')
            const Icon(
              Icons.verified_rounded,
              color: Color(0xFF16A34A),
              size: 72,
            )
          else if (_qr != null)
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: Image.memory(
                base64Decode(_qr!.split(',').last),
                width: 230,
                height: 230,
                gaplessPlayback: true,
              ),
            )
          else if (_state == 'loading')
            const SizedBox(
              width: 42,
              height: 42,
              child: CircularProgressIndicator(color: Color(0xFF25D366)),
            )
          else
            Text(_error ?? 'Tap Get WhatsApp QR to link your account.', textAlign: TextAlign.center),
          if (_qr != null && _state != 'connected')
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'QR refreshes automatically • ${_qrAge >= 60 ? 1 : 60 - _qrAge}s remaining',
                style: TextStyle(color: body, fontSize: 11),
              ),
            ),
        ],
      ),
    ),
  );
}
