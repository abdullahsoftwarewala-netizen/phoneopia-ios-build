import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'brand_backdrop.dart';
import 'brand_logo_box.dart';

/// Empty-state welcome — white panel matching web `.chat-welcome`.
class ChatWelcomeWidget extends StatelessWidget {
  const ChatWelcomeWidget({super.key});

  static const _features = [
    (Icons.shield_rounded, 'Private & Secure', 'End-to-end encrypted messages'),
    (Icons.bolt_rounded, 'Lightning Fast', 'Real-time delivery, zero delays'),
    (Icons.public_rounded, 'Available worldwide', 'Chat from anywhere'),
  ];

  @override
  Widget build(BuildContext context) {
    return BrandBackdrop(
      variant: BrandBackdropVariant.light,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 96),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 96),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const BrandLogoBox(size: 88, logoSize: 48, radius: 24),
                  const SizedBox(height: 22),
                  const Text(
                    'Phoneopia',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: AppColors.primary,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Send and receive messages without keeping your phone online.\nUse Phoneopia from anywhere.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.65,
                      color: AppColors.t3Light,
                    ),
                  ),
                  const SizedBox(height: 28),
                  for (final f in _features) _FeatureCard(f.$1, f.$2, f.$3),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.borderLight),
                      boxShadow: AppShadows.card(false),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_rounded, size: 14, color: AppColors.primary),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text.rich(
                            const TextSpan(
                              style: TextStyle(fontSize: 12, color: AppColors.t3Light),
                              children: [
                                TextSpan(text: 'Your personal messages are '),
                                TextSpan(
                                  text: 'end-to-end encrypted',
                                  style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.t1Light),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _FeatureCard(this.icon, this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.borderLight),
        boxShadow: AppShadows.card(false),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.borderLight),
              boxShadow: AppShadows.card(false),
            ),
            child: Icon(icon, size: 18, color: AppColors.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.t1Light)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.t3Light, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}