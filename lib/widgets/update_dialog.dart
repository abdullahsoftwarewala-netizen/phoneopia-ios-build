import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import '../services/update_service.dart';
import '../theme/app_theme.dart';

bool _updateDialogOpen = false;

/// Show the "New update available" dialog. [info] is the server's check result.
/// Slides in from the side (matches the web app's toast animation) instead
/// of the default center fade/scale — feels more like a live notification.
Future<void> showUpdateDialog(BuildContext context, Map<String, dynamic> info) async {
  if (_updateDialogOpen) return;
  _updateDialogOpen = true;
  final force = info['force_update'] == true;
  await showGeneralDialog(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 320),
    pageBuilder: (_, __, ___) => _UpdateDialog(info: info, force: force),
    transitionBuilder: (_, anim, __, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      // Docked sidebar panel, not a floating card — slides in flush from the
      // right edge like a website side-panel notification.
      return SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero).animate(curved),
        child: child,
      );
    },
  );
  _updateDialogOpen = false;
}

class _UpdateDialog extends StatefulWidget {
  final Map<String, dynamic> info;
  final bool force;
  const _UpdateDialog({required this.info, required this.force});
  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double _progress = 0;
  bool _downloading = false;
  bool _failed = false;

  Future<void> _update() async {
    setState(() { _downloading = true; _failed = false; });
    final ok = await UpdateService().downloadAndInstall(
      widget.info['apk_url'].toString(),
      onProgress: (p) { if (mounted) setState(() => _progress = p); },
      versionCode: int.tryParse(widget.info['version_code']?.toString() ?? ''),
    );
    if (!mounted) return;
    if (ok) {
      // Hand off to Android's own package installer — the native Cancel/
      // Install prompt, exactly like tapping a downloaded APK file directly.
      // Our app has no business staying open behind that screen, so close
      // it immediately instead of lingering with a "waiting for you to tap
      // Install" message; Android replaces the app in place once installed.
      SystemNavigator.pop();
    } else {
      setState(() { _downloading = false; _failed = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Fixed white/black/red look, matching the web app's sidebar-style
    // update panel — deliberately not theme/dark-mode-adaptive, same as
    // that panel always looks the same regardless of site theme.
    const bg = Colors.white;
    const text1 = Colors.black;
    const text2 = Color(0xFF4B5563);
    final name = widget.info['version_name']?.toString() ?? '';
    final notes = (widget.info['changelog']?.toString() ?? '').trim();
    final isBeta = widget.info['channel'] == 'beta';
    final pct = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
    final screenH = MediaQuery.of(context).size.height;
    return PopScope(
      canPop: !widget.force && !_downloading,
      child: Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 340,
            // Explicit height (not just a maxHeight constraint) — a
            // shrink-to-fit container left a gap between the panel's bottom
            // edge and the screen edge whenever the content was shorter than
            // the screen, and the boxShadow (not clipped to the rounded
            // corner) showed through that gap as a stray dark triangle
            // poking out past the bottom-left curve.
            height: screenH,
            decoration: const BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.horizontal(left: Radius.circular(18)),
              boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 30, offset: Offset(-6, 0))],
            ),
            child: SafeArea(
              left: false,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 26, 22, 26),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(
                      width: 44, height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.system_update_rounded, color: AppColors.primary, size: 24),
                    ),
                    const Spacer(),
                    if (!widget.force && !_downloading) GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Icon(Icons.close_rounded, size: 22, color: text2),
                    ),
                  ]),
                  const SizedBox(height: 18),
                  Text(widget.force ? 'Update required' : 'New update available',
                    style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: text1, letterSpacing: -0.3)),
                  const SizedBox(height: 8),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('Version $name', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: text2)),
                    if (isBeta) Container(
                      margin: const EdgeInsets.only(left: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: const Text('BETA', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppColors.primary)),
                    ),
                  ]),

                  if (notes.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Container(height: 1, color: const Color(0xFFE5E7EB)),
                    const SizedBox(height: 18),
                    Text(notes, style: const TextStyle(fontSize: 13.5, height: 1.5, color: text2)),
                  ],

                  if (_downloading) ...[
                    const SizedBox(height: 20),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: _progress > 0 ? _progress : null,
                        minHeight: 8,
                        color: AppColors.primary,
                        backgroundColor: AppColors.primary.withOpacity(0.12),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text('Downloading… $pct%',
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: text2)),
                  ],

                  if (_failed) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.primary.withOpacity(0.25)),
                      ),
                      child: Row(children: [
                        const Icon(Icons.error_outline_rounded, color: AppColors.primary, size: 17),
                        const SizedBox(width: 8),
                        const Expanded(child: Text('Download failed. Please try again.',
                          style: TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600))),
                      ]),
                    ),
                  ],

                  if (!_downloading) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary, foregroundColor: Colors.white, elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: _update,
                        icon: Icon(_failed ? Icons.refresh_rounded : Icons.download_rounded, size: 19),
                        label: Text(_failed ? 'Retry' : 'Update now', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ),
                    ),
                    if (!widget.force) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Later', style: TextStyle(color: text2, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
