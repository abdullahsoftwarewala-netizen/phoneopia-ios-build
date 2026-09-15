import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_backdrop.dart';
import '../widgets/brand_logo_box.dart';
import '../utils/gdrive_gate.dart';
import '../services/call_alert_service.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _fade;
  late Animation<double> _rise;

  static const _titleColor = AppColors.primary;
  static const _subColor = AppColors.t3Light;

  @override
  void initState() {
    super.initState();
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarColor: Colors.white,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
    _scale = Tween(begin: 0.82, end: 1.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutBack));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _rise = Tween(begin: 18.0, end: 0.0).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
    _navigate();
  }

  Future<void> _navigate() async {
    final prov = context.read<AppProvider>();
    // If there's a pending incoming call, skip splash animation entirely —
    // the user needs the call banner NOW, not after a cosmetic delay.
    final hasPendingCall = await CallAlertService().loadPendingCall() != null;
    if (hasPendingCall) {
      try {
        await prov.ready.timeout(const Duration(milliseconds: 800));
      } catch (_) {}
    } else {
      try {
        await prov.ready.timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    if (!mounted) return;
    bool loggedIn = prov.isLoggedIn;
    if (!loggedIn) {
      final prefs = await SharedPreferences.getInstance();
      loggedIn = prefs.getString('phoneopia_token') != null;
    }
    if (!mounted) return;
    if (loggedIn) {
      Navigator.of(context).pushReplacementNamed('/home');
    } else {
      Navigator.of(context).pushReplacementNamed('/login');
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: BrandBackdrop(
        variant: BrandBackdropVariant.light,
        child: SafeArea(
          bottom: false,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: _ctrl,
                builder: (_, __) => Opacity(
                  opacity: _fade.value,
                  child: Column(
                    children: [
                      Expanded(
                        child: Transform.translate(
                          offset: Offset(0, _rise.value),
                          child: Transform.scale(
                            scale: _scale.value,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const BrandLogoBox(),
                                const SizedBox(height: 24),
                                const Text(
                                  'Phoneopia',
                                  style: TextStyle(
                                    fontSize: 34,
                                    fontWeight: FontWeight.w900,
                                    color: _titleColor,
                                    letterSpacing: -1,
                                    height: 1.05,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Connect. Share. Belong.',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w400,
                                    color: _subColor,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 52),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _SplashRingLoader(),
                            const SizedBox(height: 14),
                            Text.rich(
                              TextSpan(
                                text: 'from ',
                                style: TextStyle(fontSize: 13, color: AppColors.t4Light),
                                children: const [
                                  TextSpan(
                                    text: 'Phoneopia',
                                    style: TextStyle(fontWeight: FontWeight.w600, color: _titleColor),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _SplashProgressBar(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SplashRingLoader extends StatefulWidget {
  const _SplashRingLoader();
  @override State<_SplashRingLoader> createState() => _SplashRingLoaderState();
}

class _SplashRingLoaderState extends State<_SplashRingLoader> with SingleTickerProviderStateMixin {
  late AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 750))..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (_, __) => CustomPaint(
          painter: _RingPainter(rotation: _spin.value * 6.28318),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double rotation;
  const _RingPainter({required this.rotation});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 1.5;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = AppColors.primary.withValues(alpha: 0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(rotation);
    canvas.translate(-center.dx, -center.dy);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -1.5708,
      2.2,
      false,
      Paint()
        ..color = AppColors.primary
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.rotation != rotation;
}

class _SplashProgressBar extends StatefulWidget {
  const _SplashProgressBar();
  @override State<_SplashProgressBar> createState() => _SplashProgressBarState();
}

class _SplashProgressBarState extends State<_SplashProgressBar> {
  double _w = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _w = 0.95);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 3,
      color: AppColors.primary.withValues(alpha: 0.12),
      child: AnimatedFractionallySizedBox(
        duration: const Duration(seconds: 2),
        curve: Curves.easeOut,
        widthFactor: _w,
        alignment: Alignment.centerLeft,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppColors.primary.withValues(alpha: 0.75),
                AppColors.primary,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
