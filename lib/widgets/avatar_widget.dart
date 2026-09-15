import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../config/app_config.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

class AvatarWidget extends StatelessWidget {
  final String? imageUrl;
  final String name;
  final double size;
  final bool showOnline;
  final String status;
  final VoidCallback? onTap;
  final bool isAiBot;

  const AvatarWidget({
    super.key,
    this.imageUrl,
    required this.name,
    this.size = 48,
    this.showOnline = false,
    this.status = 'offline',
    this.onTap,
    this.isAiBot = false,
  });

  /// Relative `/uploads/...` and bare paths → full staging URL.
  static String? resolveUrl(String? path) {
    final s = path?.trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('http') || s.startsWith('data:')) return s;
    return '${AppConfig.mediaBase}${s.startsWith('/') ? '' : '/'}$s';
  }

  bool get _isBot => isAiBot || isPhoneopiaBot(avatar: imageUrl, name: name);

  String get _initials {
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    if (name.isNotEmpty) return name[0].toUpperCase();
    return '?';
  }

  Color get _statusColor {
    switch (status) {
      case 'online': return AppColors.online;
      case 'away':   return AppColors.away;
      case 'busy':   return AppColors.busy;
      default:       return AppColors.offline;
    }
  }

  List<Color> get _gradientColors {
    final seed = name.codeUnits.fold(0, (a, b) => a + b);
    final tones = [
      [AppColors.primary, AppColors.primaryDark],
      [AppColors.primaryDark, AppColors.primaryDeeper],
      [const Color(0xFF3B4A54), const Color(0xFF667781)],
      [const Color(0xFF8696A0), const Color(0xFF54656F)],
    ];
    return tones[seed % tones.length];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget avatar;

    // A real uploaded photo takes priority over the default bot logo, so a bot
    // (incl. Phoneopia AI) shows its custom profile photo once one is set.
    final hasCustomPhoto = imageUrl != null && imageUrl!.isNotEmpty && !imageUrl!.contains('bot-avatar');
    if (_isBot && !hasCustomPhoto) {
      avatar = ClipOval(child: _BotAvatar(size: size));
    } else if (imageUrl != null && imageUrl!.isNotEmpty) {
      final url = resolveUrl(imageUrl!) ?? imageUrl!;
      avatar = ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          width: size,
          height: size,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          placeholder: (ctx, url) => _buildInitialsAvatar(),
          errorWidget: (ctx, url, err) => _buildInitialsAvatar(),
        ),
      );
    } else {
      avatar = _buildInitialsAvatar();
    }

    if (showOnline) {
      avatar = SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            avatar,
            Positioned(
              right: 0, bottom: 0,
              child: Container(
                width: size * 0.28, height: size * 0.28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _statusColor,
                  border: Border.all(
                    color: isDark ? AppColors.bg2Dark : AppColors.cardLight,
                    width: 2,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (onTap != null) {
      return GestureDetector(onTap: onTap, child: avatar);
    }
    return avatar;
  }

  Widget _buildInitialsAvatar() => Container(
    width: size, height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        colors: _gradientColors,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Text(
        _initials,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.36,
          letterSpacing: 0.5,
        ),
      ),
    ),
  );
}

/// Fallback when SVG network load fails — matches web bot-avatar.svg layout.
class _BotAvatar extends StatelessWidget {
  final double size;
  const _BotAvatar({required this.size});

  @override
  Widget build(BuildContext context) {
    final s = size;
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFF87171), Color(0xFF991B1B)],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: s * 0.03),
      ),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: s * 0.28,
            child: Container(
              width: s * 0.47,
              height: s * 0.34,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(s * 0.09),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _botEye(s * 0.078),
                  SizedBox(width: s * 0.05),
                  _botEye(s * 0.078, dark: true),
                  SizedBox(width: s * 0.05),
                  _botEye(s * 0.078),
                ],
              ),
            ),
          ),
          Positioned(
            left: s * 0.22,
            bottom: s * 0.22,
            child: CustomPaint(
              size: Size(s * 0.12, s * 0.1),
              painter: _BotTailPainter(),
            ),
          ),
          Positioned(
            bottom: s * 0.1,
            child: Text(
              'AI',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: s * 0.086,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _botEye(double r, {bool dark = false}) => Container(
    width: r * 2,
    height: r * 2,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: dark ? const Color(0xFFB91C1C) : const Color(0xFFDC2626),
    ),
  );
}

class _BotTailPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, size.height * 0.5)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_) => false;
}