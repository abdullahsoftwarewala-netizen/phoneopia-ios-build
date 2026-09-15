import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../utils/page_routes.dart';
import 'qr_scan_screen.dart';

/// Shareable Phoneopia identity QR. This is deliberately a Phoneopia-only
/// payload; it never exposes a phone number or authentication token.
class MyAccountQrScreen extends StatelessWidget {
  const MyAccountQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final user = context.watch<AppProvider>().me;
    final username = user?.username.trim() ?? '';
    final value = 'phoneopia://connect?username=$username';
    final name = (user?.displayName.trim().isNotEmpty == true)
        ? user!.displayName
        : username;

    return Scaffold(
      backgroundColor: dark ? AppColors.bgDark : const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: const Text(
          'My Account QR',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Scan Phoneopia QR',
            icon: const Icon(Icons.camera_alt_rounded),
            onPressed: () async {
              final added = await Navigator.push<bool>(
                context,
                slideRoute(const QrScanScreen()),
              );
              if (added == true && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Contact added successfully')),
                );
              }
            },
          ),
        ],
      ),
      body: username.isEmpty
          ? const Center(child: Text('Account information is not ready yet'))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              child: Column(
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(22, 28, 22, 30),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFE81235), Color(0xFFB9072A)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFE81235).withOpacity(.25),
                          blurRadius: 24,
                          offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        const Text(
                          'Share your Phoneopia',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Scan this QR to add me instantly',
                          style: TextStyle(
                            color: Colors.white.withOpacity(.82),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 22),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: QrImageView(
                            data: value,
                            version: QrVersions.auto,
                            size: 230,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Color(0xFF111827),
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Color(0xFF111827),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '@$username',
                          style: TextStyle(
                            color: Colors.white.withOpacity(.86),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
