import 'package:flutter/material.dart';

/// Smooth chat open — fast but not jarring.
PageRoute<T> chatRoute<T>(Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, __, ___) => page,
  transitionDuration: const Duration(milliseconds: 220),
  reverseTransitionDuration: const Duration(milliseconds: 180),
  transitionsBuilder: (_, a, __, child) => FadeTransition(
    opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
    child: SlideTransition(
      position: Tween(begin: const Offset(0.04, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ),
);

PageRoute<T> slideRoute<T>(Widget page) => PageRouteBuilder<T>(
  pageBuilder: (_, __, ___) => page,
  transitionsBuilder: (_, a, __, child) => SlideTransition(
    position: Tween(begin: const Offset(1, 0), end: Offset.zero)
        .animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
    child: child,
  ),
  transitionDuration: const Duration(milliseconds: 220),
);