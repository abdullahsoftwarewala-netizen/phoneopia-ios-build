import 'package:flutter/material.dart';

/// Blue verified tick for Phoneopia AI (matches web #1D9BF0).
class VerifiedBadge extends StatelessWidget {
  final double size;
  const VerifiedBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    // Verified blue badges are disabled globally for now.
    return const SizedBox.shrink();
  }
}
