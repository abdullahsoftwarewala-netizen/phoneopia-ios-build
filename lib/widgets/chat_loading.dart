import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class ChatLoadingSkeleton extends StatelessWidget {
  const ChatLoadingSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bubble = isDark ? AppColors.cardDark : Colors.white;
    final shimmer = isDark ? Colors.white12 : Colors.black12;
    return ListView(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      children: [
        _row(bubble, shimmer, alignRight: true, w: 0.55),
        const SizedBox(height: 10),
        _row(bubble, shimmer, alignRight: false, w: 0.62),
        const SizedBox(height: 10),
        _row(bubble, shimmer, alignRight: true, w: 0.42),
        const SizedBox(height: 10),
        _row(bubble, shimmer, alignRight: false, w: 0.48),
      ],
    );
  }

  Widget _row(Color bubble, Color shimmer, {required bool alignRight, required double w}) {
    return Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: w,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: bubble,
            borderRadius: BorderRadius.circular(AppRadii.bubble),
            border: Border.all(color: shimmer),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Container(width: 60, height: 8, decoration: BoxDecoration(color: shimmer, borderRadius: BorderRadius.circular(4))),
              const Spacer(),
              Container(width: 36, height: 8, decoration: BoxDecoration(color: shimmer.withOpacity(.6), borderRadius: BorderRadius.circular(4))),
            ]),
          ),
        ),
      ),
    );
  }
}

class ChatLoadError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ChatLoadError({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 48, color: AppColors.t3Light.withOpacity(.7)),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 15, color: AppColors.t2Light, height: 1.4),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Retry'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.primary,
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}