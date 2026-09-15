import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Generic full-page reader for legal / info content — replaces the old
/// popup dialogs so Settings entries (About, Privacy Policy, Terms, Help)
/// each get a real page instead of a modal.
class LegalScreen extends StatelessWidget {
  final String title;
  final List<LegalSection> sections;
  const LegalScreen({super.key, required this.title, required this.sections});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: Text(title),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final s in sections) ...[
            if (s.heading != null) ...[
              Text(s.heading!, style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w800,
                color: isDark ? AppColors.t1Dark : AppColors.t1Light,
              )),
              const SizedBox(height: 8),
            ],
            Text(s.body, style: TextStyle(
              fontSize: 14, height: 1.55,
              color: isDark ? AppColors.t2Dark : AppColors.t2Light,
            )),
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }
}

class LegalSection {
  final String? heading;
  final String body;
  const LegalSection(this.body, {this.heading});
}
