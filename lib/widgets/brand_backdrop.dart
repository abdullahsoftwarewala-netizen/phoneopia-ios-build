import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum BrandBackdropVariant { brand, light }

/// Full-screen backdrop — brand red or clean white.
class BrandBackdrop extends StatelessWidget {
  final Widget? child;
  final BrandBackdropVariant variant;

  const BrandBackdrop({
    super.key,
    this.child,
    this.variant = BrandBackdropVariant.brand,
  });

  @override
  Widget build(BuildContext context) {
    if (variant == BrandBackdropVariant.light) {
      return Stack(
        fit: StackFit.expand,
        children: [
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFFFFFFFF), Color(0xFFFAFAFA)],
              ),
            ),
          ),
          CustomPaint(painter: _LightDotGridPainter()),
          if (child != null) child!,
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(decoration: BoxDecoration(gradient: AppColors.brandGradient)),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0.92, -0.92),
              radius: 0.72,
              colors: [Colors.white.withValues(alpha: 0.11), Colors.transparent],
            ),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(-0.92, 0.92),
              radius: 0.55,
              colors: [Colors.black.withValues(alpha: 0.06), Colors.transparent],
            ),
          ),
        ),
        CustomPaint(painter: _BrandDotGridPainter()),
        if (child != null) child!,
      ],
    );
  }
}

class _BrandDotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.16);
    const step = 28.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

class _LightDotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF111B21).withValues(alpha: 0.05);
    const step = 28.0;
    for (double x = 0; x < size.width; x += step) {
      for (double y = 0; y < size.height; y += step) {
        canvas.drawCircle(Offset(x, y), 1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_) => false;
}