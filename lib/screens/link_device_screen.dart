import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_logo_box.dart';
import '../utils/gdrive_gate.dart';

/// Shown on a NEW device from the login screen. Displays a QR that an already
/// logged-in Phoneopia device scans (Settings → Linked devices → scan) to log
/// this device straight in — no OTP needed.
class LinkDeviceScreen extends StatefulWidget {
  const LinkDeviceScreen({super.key});
  @override
  State<LinkDeviceScreen> createState() => _LinkDeviceScreenState();
}

class _LinkDeviceScreenState extends State<LinkDeviceScreen> {
  String? _qrValue;
  String? _token;
  String? _err;
  bool _loading = true;
  bool _linking = false;
  Timer? _poll;
  int _secsLeft = 120;
  Timer? _countdown;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _countdown?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() { _loading = true; _err = null; _qrValue = null; });
    try {
      final r = await ApiService.get('qr.php?action=generate');
      if (r['success'] == true && r['qr_value'] != null) {
        setState(() {
          _qrValue = r['qr_value'].toString();
          _token = r['token'].toString();
          _secsLeft = int.tryParse(r['expires_in']?.toString() ?? '120') ?? 120;
          _loading = false;
        });
        _startPolling();
        _startCountdown();
      } else {
        setState(() { _err = r['error']?.toString() ?? 'Could not create QR code'; _loading = false; });
      }
    } catch (_) {
      setState(() { _err = 'Network error. Try again.'; _loading = false; });
    }
  }

  void _startCountdown() {
    _countdown?.cancel();
    _countdown = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secsLeft = (_secsLeft - 1).clamp(0, 120));
      if (_secsLeft <= 0) { _poll?.cancel(); _countdown?.cancel(); }
    });
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _linking || _token == null) return;
      try {
        final r = await ApiService.get('qr.php?action=poll', params: {'token': _token!});
        if (!mounted) return;
        if (r['status'] == 'scanned' && r['token'] != null) {
          _poll?.cancel();
          _countdown?.cancel();
          setState(() => _linking = true);
          final ok = await context.read<AppProvider>().loginFromQr(
            r['token'].toString(),
            r['user'] is Map ? Map<String, dynamic>.from(r['user'] as Map) : null,
          );
          if (!mounted) return;
          if (ok) {
            await ensureGDriveThenGoHome(context);
          } else {
            setState(() { _linking = false; _err = 'Login failed. Try again.'; });
          }
        } else if (r['success'] == false) {
          // expired / invalid → stop
          _poll?.cancel();
        }
      } catch (_) {/* keep polling */}
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111B21),
        elevation: 0,
        title: const Text('Link a device', style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const SizedBox(height: 8),
            const BrandLogoBox(size: 64, logoSize: 34, radius: 18),
            const SizedBox(height: 18),
            const Text('Log in by QR code',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111B21))),
            const SizedBox(height: 10),
            const Text(
              'On your other phone that is already logged in:\nSettings → Linked devices → Link a device → scan this code.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: Color(0xFF667781), height: 1.5),
            ),
            const SizedBox(height: 28),

            // QR card
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: const Color(0xFFEDEFF2)),
                boxShadow: [BoxShadow(color: AppColors.primary.withOpacity(0.08), blurRadius: 28, offset: const Offset(0, 12))],
              ),
              child: SizedBox(
                width: 230, height: 230,
                child: Center(child: _buildQrBody()),
              ),
            ),
            const SizedBox(height: 20),

            if (_qrValue != null && _err == null && !_linking)
              Text(
                _secsLeft > 0 ? 'Code expires in ${_secsLeft}s' : 'Code expired',
                style: TextStyle(
                  color: _secsLeft > 0 ? const Color(0xFF8A949B) : AppColors.primary,
                  fontSize: 13, fontWeight: FontWeight.w600,
                ),
              ),
            if (_secsLeft <= 0 || _err != null) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary, foregroundColor: Colors.white, elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _generate,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  label: const Text('New code', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
            const SizedBox(height: 30),
          ]),
        ),
      ),
    );
  }

  Widget _buildQrBody() {
    if (_loading) {
      return const CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5);
    }
    if (_linking) {
      return const Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
        SizedBox(height: 14),
        Text('Logging in…', style: TextStyle(color: Color(0xFF667781), fontWeight: FontWeight.w600)),
      ]);
    }
    if (_err != null) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, color: AppColors.primary, size: 36),
        const SizedBox(height: 8),
        Text(_err!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF667781), fontSize: 13)),
      ]);
    }
    if (_secsLeft <= 0) {
      return const Icon(Icons.qr_code_2_rounded, color: Color(0xFFC4CCD2), size: 120);
    }
    return QrImageView(
      data: _qrValue!,
      version: QrVersions.auto,
      size: 220,
      eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF111B21)),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square, color: Color(0xFF111B21)),
    );
  }
}
