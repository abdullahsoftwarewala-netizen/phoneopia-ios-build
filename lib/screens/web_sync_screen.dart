import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';

class WebSyncScreen extends StatefulWidget {
  const WebSyncScreen({super.key});
  @override State<WebSyncScreen> createState() => _WebSyncScreenState();
}

class _WebSyncScreenState extends State<WebSyncScreen> {
  final _ctrl = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates);
  bool _scanned = false;
  bool _processing = false;
  String? _err;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_scanned || _processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;

    // Only handle phoneopia://sync?code=... QRs
    if (!raw.contains('phoneopia://sync')) return;

    final code = Uri.parse(raw).queryParameters['code'] ?? '';
    if (code.isEmpty) {
      setState(() => _err = 'Invalid QR code');
      return;
    }

    setState(() { _scanned = true; _processing = true; _err = null; });
    await _ctrl.stop();

    try {
      final r = await ApiService.post('sync.php?action=consume', {'code': code});
      if (!mounted) return;

      if (r['success'] != true) {
        setState(() { _processing = false; _scanned = false; _err = r['error']?.toString() ?? 'Sync failed'; });
        await _ctrl.start();
        return;
      }

      final newToken = r['token']?.toString() ?? '';
      final userMap  = r['user'] as Map<String, dynamic>? ?? {};

      if (newToken.isEmpty) {
        setState(() { _processing = false; _scanned = false; _err = 'No token received'; });
        await _ctrl.start();
        return;
      }

      // Save new token and reload everything
      await ApiService.setToken(newToken);
      final prov = context.read<AppProvider>();
      await Future.wait([
        prov.refreshMe(),
        prov.loadConversations(),
        prov.loadCalls(),
      ]);

      if (mounted) _showSuccess(userMap);
    } catch (e) {
      if (!mounted) return;
      setState(() { _processing = false; _scanned = false; _err = 'Error: $e'; });
      await _ctrl.start();
    }
  }

  void _showSuccess(Map<String, dynamic> user) {
    final name   = user['display_name']?.toString() ?? user['username']?.toString() ?? 'User';
    final avatar = user['avatar']?.toString();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dlg) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
            width: 64, height: 64,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryDim),
            child: const Icon(Icons.check_circle_rounded, color: AppColors.primary, size: 42),
          ),
          const SizedBox(height: 16),
          const Text('Sync Complete!', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111B21))),
          const SizedBox(height: 8),
          AvatarWidget(imageUrl: avatar, name: name, size: 52),
          const SizedBox(height: 8),
          Text('Logged in as $name', style: const TextStyle(fontSize: 14, color: Color(0xFF667781))),
          const SizedBox(height: 4),
          const Text('All chats, messages and call logs have been synced.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF667781))),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: () {
              Navigator.pop(dlg);
              Navigator.pop(context);
              Navigator.pop(context); // pop settings too — go back to home
            },
            child: const Text('Go to Chats', style: TextStyle(fontWeight: FontWeight.w600)),
          )),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Web to App Sync', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      ),
      body: Stack(children: [
        // Scanner
        MobileScanner(controller: _ctrl, onDetect: _onDetect),

        // Overlay frame
        Positioned.fill(child: CustomPaint(painter: _ScanOverlayPainter())),

        // Instructions
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 48),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Colors.transparent, Colors.black.withValues(alpha: 0.85)],
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
              ),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_processing)
                const CircularProgressIndicator(color: AppColors.primary)
              else if (_err != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(color: Colors.red.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(10)),
                  child: Text(_err!, style: const TextStyle(color: Colors.white, fontSize: 13)),
                )
              else ...[
                const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 32),
                const SizedBox(height: 10),
                const Text('Scan the QR from web', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                const Text(
                  'On the web: Settings → Sync → My Chats to App',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ]),
          ),
        ),
      ]),
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final dimPaint = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final r = size.width * 0.65 / 2;
    final cx = size.width / 2;
    final cy = size.height * 0.42;
    final rect = Rect.fromCenter(center: Offset(cx, cy), width: r * 2, height: r * 2);

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, dimPaint);

    // Corner brackets
    final cp = Paint()..color = AppColors.primary..strokeWidth = 3.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    final bLen = 22.0;
    final rad  = 16.0;
    final l = rect.left; final t = rect.top; final ri = rect.right; final b = rect.bottom;
    // Top-left
    canvas.drawLine(Offset(l + rad, t), Offset(l + rad + bLen, t), cp);
    canvas.drawLine(Offset(l, t + rad), Offset(l, t + rad + bLen), cp);
    canvas.drawArc(Rect.fromLTWH(l, t, rad * 2, rad * 2), -3.14, 1.57, false, cp);
    // Top-right
    canvas.drawLine(Offset(ri - rad - bLen, t), Offset(ri - rad, t), cp);
    canvas.drawLine(Offset(ri, t + rad), Offset(ri, t + rad + bLen), cp);
    canvas.drawArc(Rect.fromLTWH(ri - rad * 2, t, rad * 2, rad * 2), -1.57, 1.57, false, cp);
    // Bottom-left
    canvas.drawLine(Offset(l + rad, b), Offset(l + rad + bLen, b), cp);
    canvas.drawLine(Offset(l, b - rad - bLen), Offset(l, b - rad), cp);
    canvas.drawArc(Rect.fromLTWH(l, b - rad * 2, rad * 2, rad * 2), 1.57, 1.57, false, cp);
    // Bottom-right
    canvas.drawLine(Offset(ri - rad - bLen, b), Offset(ri - rad, b), cp);
    canvas.drawLine(Offset(ri, b - rad - bLen), Offset(ri, b - rad), cp);
    canvas.drawArc(Rect.fromLTWH(ri - rad * 2, b - rad * 2, rad * 2, rad * 2), 0, 1.57, false, cp);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
