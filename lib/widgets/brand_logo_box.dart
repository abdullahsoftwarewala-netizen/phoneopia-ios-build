import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Logo tile used on red brand screens (matches web `#splash-icon-wrap`) —
/// the logo image itself is already a full-bleed rounded square (red
/// background, white chat-bubble mark baked in), so it fills this box
/// completely instead of sitting inset inside a separate white tile.
class BrandLogoBox extends StatelessWidget {
  final double size;
  final double logoSize;
  final double radius;

  const BrandLogoBox({
    super.key,
    this.size = 96,
    this.logoSize = 52,
    this.radius = 28,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.asset(
          'assets/images/logo.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            color: AppColors.primary,
            child: Icon(
              Icons.chat_bubble_rounded,
              color: Colors.white,
              size: size * 0.55,
            ),
          ),
        ),
      ),
    );
  }
}