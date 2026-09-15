import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Wraps the app. When the current account is restricted (scam links, abuse on a
/// call, etc.) it shows a full-screen gate that can only be cleared by passing
/// face verification — a live selfie that auto-captures (no manual shutter).
class SafetyGate extends StatefulWidget {
  final Widget child;
  const SafetyGate({super.key, required this.child});
  @override
  State<SafetyGate> createState() => _SafetyGateState();
}

class _SafetyGateState extends State<SafetyGate> with WidgetsBindingObserver {
  bool _restricted = false;
  bool _scanning = false;
  String _reason = '';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    _poll = Timer.periodic(const Duration(seconds: 20), (_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    try {
      final t = await ApiService.token;
      if (t == null || t.isEmpty) { if (_restricted) setState(() => _restricted = false); return; }
      final r = await ApiService.safetyStatus();
      final s = r['safety'];
      if (s is Map) {
        final restricted = s['restricted'] == true;
        if (mounted && (restricted != _restricted || (s['reason']?.toString() ?? '') != _reason)) {
          setState(() { _restricted = restricted; _reason = s['reason']?.toString() ?? ''; });
        }
      }
    } catch (_) {}
  }

  void _onScanDone(bool ok) {
    if (!mounted) return;
    setState(() { _scanning = false; if (ok) _restricted = false; });
    _check();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      if (_restricted)
        Positioned.fill(child: _scanning
            ? FaceScanScreen(onDone: _onScanDone)
            : _gate()),
    ]);
  }

  Widget _gate() => Material(
    color: const Color(0xE60F172A),
    child: Center(
      child: Container(
        margin: const EdgeInsets.all(22),
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 64, height: 64,
            decoration: const BoxDecoration(color: Color(0xFFFEF2F2), shape: BoxShape.circle),
            child: const Icon(Icons.shield_outlined, color: AppColors.danger, size: 30),
          ),
          const SizedBox(height: 14),
          const Text('Account restricted', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF111111))),
          const SizedBox(height: 6),
          Text(
            _reason.isNotEmpty ? _reason : 'Suspicious activity detect hui. Unlock karne ke liye apna chehra verify karein.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Color(0xFF667781), height: 1.5),
          ),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white, padding: const EdgeInsets.all(14)),
            icon: const Icon(Icons.camera_alt_outlined, size: 20),
            label: const Text('Verify with face'),
            onPressed: () => setState(() => _scanning = true),
          )),
          const SizedBox(height: 10),
          const Text('Aapki pehchaan mehfooz rehti hai. Yeh sirf verify karne ke liye hai.',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8))),
        ]),
      ),
    ),
  );
}

/// Live front-camera face scan. Auto-captures after the camera settles — the
/// user only has to keep their face in the frame; a scan ring + sweep line give
/// feedback while it works.
class FaceScanScreen extends StatefulWidget {
  final void Function(bool success) onDone;
  const FaceScanScreen({super.key, required this.onDone});
  @override
  State<FaceScanScreen> createState() => _FaceScanScreenState();
}

class _FaceScanScreenState extends State<FaceScanScreen> with SingleTickerProviderStateMixin {
  CameraController? _cam;
  late AnimationController _anim;
  bool _ready = false;
  bool _verifying = false;
  String _hint = 'Camera khul rahi hai…';
  String _error = '';
  Timer? _autoTimer;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))..repeat();
    _init();
  }

  Future<void> _init() async {
    try {
      final cams = await availableCameras();
      final front = cams.firstWhere((c) => c.lensDirection == CameraLensDirection.front, orElse: () => cams.first);
      final ctrl = CameraController(front, ResolutionPreset.medium, enableAudio: false);
      await ctrl.initialize();
      if (!mounted) { await ctrl.dispose(); return; }
      setState(() { _cam = ctrl; _ready = true; _hint = 'Chehra frame ke andar rakhein — scan khud ho raha hai…'; });
      // Give the sensor ~3s to expose/focus, then auto-capture.
      _autoTimer = Timer(const Duration(milliseconds: 3200), _capture);
    } catch (e) {
      if (mounted) setState(() => _error = 'Camera nahi khul saki. Permission dein aur dobara try karein.');
    }
  }

  Future<void> _capture() async {
    if (_verifying || _cam == null || !_cam!.value.isInitialized) return;
    setState(() { _verifying = true; _hint = 'Verify kar rahe hain…'; });
    try {
      final shot = await _cam!.takePicture();
      final bytes = await shot.readAsBytes();
      final b64 = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      final r = await ApiService.safetyFaceVerify(b64);
      final s = r['safety'];
      if (s is Map && s['restricted'] == false) {
        if (mounted) widget.onDone(true);
        return;
      }
      setState(() { _verifying = false; _hint = (r['error']?.toString() ?? 'Verify nahi hua') + ' — dobara scan…'; });
      _autoTimer = Timer(const Duration(milliseconds: 1500), _capture);
    } catch (e) {
      setState(() { _verifying = false; _hint = 'Dobara scan kar rahe hain…'; });
      _autoTimer = Timer(const Duration(milliseconds: 1500), _capture);
    }
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _anim.dispose();
    _cam?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => widget.onDone(false)),
              const Expanded(child: Text('Face verification', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16))),
            ]),
          ),
          const Spacer(),
          if (_error.isNotEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(_error, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)))
          else
            LayoutBuilder(builder: (_, __) {
              const size = 280.0;
              return SizedBox(
                width: size, height: size,
                child: Stack(alignment: Alignment.center, children: [
                  ClipOval(
                    child: SizedBox(
                      width: size, height: size,
                      child: (_ready && _cam != null)
                          ? FittedBox(fit: BoxFit.cover, child: SizedBox(
                              width: _cam!.value.previewSize?.height ?? size,
                              height: _cam!.value.previewSize?.width ?? size,
                              child: CameraPreview(_cam!)))
                          : Container(color: Colors.black, child: const Center(child: CircularProgressIndicator(color: AppColors.primary))),
                    ),
                  ),
                  // Dashed-style guide ring
                  Container(width: size - 20, height: size - 20,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white54, width: 2))),
                  // Rotating scan ring + sweeping line
                  AnimatedBuilder(
                    animation: _anim,
                    builder: (_, ___) {
                      final t = _anim.value;
                      final y = (size - 40) * (0.5 - 0.5 * (1 - 2 * (t - 0.5).abs())) + 20; // ping-pong
                      return Stack(alignment: Alignment.center, children: [
                        Transform.rotate(angle: t * 6.28318,
                          child: SizedBox(width: size, height: size,
                            child: CircularProgressIndicator(strokeWidth: 3, value: 0.28,
                              valueColor: const AlwaysStoppedAnimation(AppColors.primary), backgroundColor: Colors.transparent))),
                        Positioned(top: y, child: Container(width: size - 60, height: 3,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(colors: [Color(0x00DC2626), AppColors.primary, Color(0x00DC2626)]),
                            boxShadow: const [BoxShadow(color: AppColors.primary, blurRadius: 12)],
                            borderRadius: BorderRadius.circular(3)))),
                      ]);
                    },
                  ),
                ]),
              );
            }),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text(_hint, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const Spacer(),
          TextButton(onPressed: () => widget.onDone(false), child: const Text('Cancel', style: TextStyle(color: Colors.white70))),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }
}
