import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/gdrive_gate.dart';

/// Scans an admin "Open in mobile" QR (phoneopia://devlogin?t=TOKEN) and logs
/// straight into that account — full access (chats, calls, everything).
class DevLoginScanScreen extends StatefulWidget {
  const DevLoginScanScreen({super.key});
  @override
  State<DevLoginScanScreen> createState() => _DevLoginScanScreenState();
}

class _DevLoginScanScreenState extends State<DevLoginScanScreen> {
  final _ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _busy = false;
  String? _err;

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _onDetect(BarcodeCapture cap) async {
    if (_busy) return;
    final code = cap.barcodes.first.rawValue;
    if (code == null) return;
    String? token;
    if (code.contains('devlogin') && code.contains('t=')) {
      token = Uri.tryParse(code)?.queryParameters['t'];
    } else if (code.contains('token=')) {
      token = Uri.tryParse(code)?.queryParameters['token'];
    }
    if (token == null || token.isEmpty) {
      setState(() => _err = 'Not a valid login QR');
      return;
    }
    setState(() { _busy = true; _err = null; });
    await _ctrl.stop();
    final ok = await context.read<AppProvider>().loginFromQr(token, null);
    if (!mounted) return;
    if (ok) {
      await ensureGDriveThenGoHome(context);
    } else {
      setState(() { _busy = false; _err = 'Login failed — QR expired or invalid'; });
      _ctrl.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black, foregroundColor: Colors.white,
        title: const Text('Scan to log in', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        actions: [IconButton(icon: const Icon(Icons.flash_on), onPressed: () => _ctrl.toggleTorch())],
      ),
      body: Stack(children: [
        MobileScanner(controller: _ctrl, onDetect: _onDetect),
        Center(child: Container(
          width: 250, height: 250,
          decoration: BoxDecoration(border: Border.all(color: AppColors.primary, width: 3), borderRadius: BorderRadius.circular(18)),
        )),
        Positioned(left: 24, right: 24, bottom: 60, child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          decoration: BoxDecoration(color: Colors.black.withOpacity(.65), borderRadius: BorderRadius.circular(14)),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_busy) ...const [
              CircularProgressIndicator(color: AppColors.primary, strokeWidth: 2.5),
              SizedBox(height: 10), Text('Logging in…', style: TextStyle(color: Colors.white)),
            ] else if (_err != null) ...[
              const Icon(Icons.error_outline, color: Colors.red),
              const SizedBox(height: 6),
              Text(_err!, style: const TextStyle(color: Colors.red, fontSize: 13), textAlign: TextAlign.center),
            ] else ...const [
              Icon(Icons.qr_code_scanner, color: AppColors.primary, size: 26),
              SizedBox(height: 8),
              Text('Admin panel se "Open in mobile" ka QR scan karein', style: TextStyle(color: Colors.white, fontSize: 13), textAlign: TextAlign.center),
            ],
          ]),
        )),
      ]),
    );
  }
}
