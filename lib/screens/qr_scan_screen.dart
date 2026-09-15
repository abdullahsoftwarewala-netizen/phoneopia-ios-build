import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../models/models.dart';

class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});
  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final _ctrl = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
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
    final code = capture.barcodes.first.rawValue;
    if (code == null) return;

    // Extract token from QR value
    String token;
    if (code.contains('token=')) {
      token = Uri.parse(code).queryParameters['token'] ?? code;
    } else if (code.startsWith('phoneopia://')) {
      token = Uri.parse(code).queryParameters['token'] ?? code.split('/').last;
    } else {
      token = code.trim();
    }

    if (token.isEmpty) return;

    // Phoneopia account QR: phoneopia://user/<username>. Add the scanned
    // account through the normal contacts API; web-device QR keeps its
    // existing flow below.
    final uri = Uri.tryParse(code.trim());
    final isAccountQr =
        uri?.scheme == 'phoneopia' &&
        (uri?.host == 'user' ||
            uri?.host == 'connect' ||
            (uri?.pathSegments.isNotEmpty ?? false));
    if (isAccountQr) {
      final username =
          (uri?.queryParameters['username'] ??
                  (uri!.host == 'user'
                      ? uri.pathSegments.join('/')
                      : uri.pathSegments.last))
              .trim()
              .toLowerCase();
      if (username.isEmpty) return;
      setState(() {
        _scanned = true;
        _processing = true;
      });
      await _ctrl.stop();
      try {
        final found = await ApiService.get(
          'users.php?action=by_username',
          params: {'username': username},
        );
        final raw = found['user'];
        if (found['success'] == true && raw is Map) {
          final user = User.fromJson(Map<String, dynamic>.from(raw));
          final added = await ApiService.post('users.php?action=add_contact', {
            'contact_id': user.id,
          });
          if (!mounted) return;
          if (added['success'] == true) {
            Navigator.pop(context, true);
          } else {
            setState(() {
              _err = added['error']?.toString() ?? 'Could not add contact';
              _processing = false;
              _scanned = false;
            });
            _ctrl.start();
          }
        } else {
          if (!mounted) return;
          setState(() {
            _err = found['error']?.toString() ?? 'Phoneopia account not found';
            _processing = false;
            _scanned = false;
          });
          _ctrl.start();
        }
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _err = 'Network error. Try again.';
          _processing = false;
          _scanned = false;
        });
        _ctrl.start();
      }
      return;
    }

    setState(() {
      _scanned = true;
      _processing = true;
    });
    await _ctrl.stop();

    try {
      final r = await ApiService.post('qr.php?action=scan', {'token': token});
      if (!mounted) return;
      if (r['success'] == true) {
        _showSuccess();
      } else {
        setState(() {
          _err = r['error']?.toString() ?? 'QR code expired or invalid';
          _processing = false;
          _scanned = false;
        });
        _ctrl.start();
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _err = 'Network error. Try again.';
        _processing = false;
        _scanned = false;
      });
      _ctrl.start();
    }
  }

  void _showSuccess() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primaryDim,
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: AppColors.primary,
                size: 44,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Web Linked!',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111B21),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your web browser is now logged in. You can close this scanner.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Color(0xFF667781), fontSize: 14),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              onPressed: () {
                Navigator.pop(context); // close dialog
                Navigator.pop(context); // go back to home
              },
              child: const Text(
                'Done',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text(
          'Scan QR Code',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on, color: Colors.white),
            onPressed: () => _ctrl.toggleTorch(),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (ctx, constraints) {
          const scanSize = 260.0;
          final cx = constraints.maxWidth / 2;
          final cy = constraints.maxHeight * 0.42; // slightly above center

          return Stack(
            children: [
              // Camera
              MobileScanner(controller: _ctrl, onDetect: _onDetect),

              // Dark overlay with exact hole matching frame below
              CustomPaint(
                painter: _ScanOverlayPainter(
                  cx: cx,
                  cy: cy,
                  scanSize: scanSize,
                ),
                size: Size(constraints.maxWidth, constraints.maxHeight),
              ),

              // Green corner frame — exact same position as overlay hole
              Positioned(
                left: cx - scanSize / 2,
                top: cy - scanSize / 2,
                child: SizedBox(
                  width: scanSize,
                  height: scanSize,
                  child: CustomPaint(painter: _CornerFramePainter()),
                ),
              ),

              // Instruction panel below frame
              Positioned(
                left: 24,
                right: 24,
                top: cy + scanSize / 2 + 28,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_processing) ...[
                        const CircularProgressIndicator(
                          color: AppColors.primary,
                          strokeWidth: 2.5,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Linking web session...',
                          style: TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ] else if (_err != null) ...[
                        const Icon(
                          Icons.error_outline,
                          color: Colors.red,
                          size: 24,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _err!,
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 13,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ] else ...[
                        const Icon(
                          Icons.qr_code_scanner,
                          color: AppColors.primary,
                          size: 28,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Point your camera at the QR code\non the Phoneopia web page',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              // Label above frame
              Positioned(
                left: 0,
                right: 0,
                top: cy - scanSize / 2 - 44,
                child: const Text(
                  'Scan QR Code',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ScanOverlayPainter extends CustomPainter {
  final double cx, cy, scanSize;
  const _ScanOverlayPainter({
    required this.cx,
    required this.cy,
    required this.scanSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.6);
    final rect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: scanSize,
      height: scanSize,
    );
    final path = Path()
      ..addRect(Offset.zero & size)
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_) => false;
}

class _CornerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const r = 16.0;
    const len = 28.0;
    final w = size.width, h = size.height;
    // Top-left
    canvas.drawLine(const Offset(r, 0), const Offset(r + len, 0), paint);
    canvas.drawLine(const Offset(0, r), const Offset(0, r + len), paint);
    canvas.drawArc(
      Rect.fromLTWH(0, 0, r * 2, r * 2),
      -3.14,
      3.14 / 2,
      false,
      paint,
    );
    // Top-right
    canvas.drawLine(Offset(w - r - len, 0), Offset(w - r, 0), paint);
    canvas.drawLine(Offset(w, r), Offset(w, r + len), paint);
    canvas.drawArc(
      Rect.fromLTWH(w - r * 2, 0, r * 2, r * 2),
      -3.14 / 2,
      3.14 / 2,
      false,
      paint,
    );
    // Bottom-left
    canvas.drawLine(Offset(r, h), Offset(r + len, h), paint);
    canvas.drawLine(Offset(0, h - r - len), Offset(0, h - r), paint);
    canvas.drawArc(
      Rect.fromLTWH(0, h - r * 2, r * 2, r * 2),
      3.14 / 2,
      3.14 / 2,
      false,
      paint,
    );
    // Bottom-right
    canvas.drawLine(Offset(w - r - len, h), Offset(w - r, h), paint);
    canvas.drawLine(Offset(w, h - r - len), Offset(w, h - r), paint);
    canvas.drawArc(
      Rect.fromLTWH(w - r * 2, h - r * 2, r * 2, r * 2),
      0,
      3.14 / 2,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
