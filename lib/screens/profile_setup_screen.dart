import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/brand_backdrop.dart';
import '../utils/gdrive_gate.dart';

class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});
  @override State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> with SingleTickerProviderStateMixin {
  final _nameCtrl = TextEditingController();
  bool _uploading = false;
  bool _saving    = false;
  String? _err;
  String? _avatarUrl;

  late AnimationController _fadeCtrl;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _fadeCtrl.forward();
    // Pre-fill with "Your name"
    final me = context.read<AppProvider>().me;
    if (me != null) _nameCtrl.text = me.displayName.contains('+') ? '' : me.displayName;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 512);
    if (xfile == null) return;
    setState(() { _uploading = true; _err = null; });
    try {
      final bytes = await xfile.readAsBytes();
      // Force a guaranteed valid extension — xfile.name from some Android
      // gallery pickers lacks one, producing a malformed avatar URL the
      // server can't serve correctly.
      final r = await ApiService.uploadAvatar(bytes, 'avatar.jpg');
      if (r['success'] == true && mounted) {
        final raw = r['avatar']?.toString();
        setState(() { _avatarUrl = AvatarWidget.resolveUrl(raw) ?? raw; _uploading = false; });
        if (r['user'] is Map) {
          await context.read<AppProvider>().applyUserPayload(Map<String, dynamic>.from(r['user'] as Map));
        } else {
          await context.read<AppProvider>().refreshMe();
        }
      } else {
        setState(() { _uploading = false; _err = 'Failed to upload photo'; });
      }
    } catch (_) {
      if (mounted) setState(() { _uploading = false; _err = 'Upload failed'; });
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.length < 2) { setState(() => _err = 'Name must be at least 2 characters'); return; }
    setState(() { _saving = true; _err = null; });
    try {
      final r = await ApiService.updateProfile({'display_name': name});
      if (r['success'] == true) {
        await context.read<AppProvider>().refreshMe();
        if (mounted) await ensureGDriveThenGoHome(context);
      } else if (mounted) {
        setState(() {
          _saving = false;
          _err = r['error']?.toString() ?? 'Failed to save. Try again.';
        });
      }
    } catch (_) {
      if (mounted) setState(() { _saving = false; _err = 'Failed to save. Try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = context.watch<AppProvider>().me;
    final avatarUrl = AvatarWidget.resolveUrl(_avatarUrl ?? me?.avatar);

    return Scaffold(
      body: BrandBackdrop(
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeCtrl,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                const SizedBox(height: 40),

                // Header
                const Icon(Icons.waving_hand_rounded, color: Colors.white, size: 40),
                const SizedBox(height: 16),
                const Text(
                  'Welcome to Phoneopia!',
                  style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Set up your profile to get started',
                  style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14),
                  textAlign: TextAlign.center,
                ),

                const SizedBox(height: 40),

                // Avatar picker
                GestureDetector(
                  onTap: _uploading ? null : _pickAvatar,
                  child: Stack(alignment: Alignment.center, children: [
                    Container(
                      width: 110, height: 110,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withOpacity(0.2),
                        border: Border.all(color: Colors.white.withOpacity(0.6), width: 3),
                        image: avatarUrl != null
                            ? DecorationImage(image: NetworkImage(avatarUrl), fit: BoxFit.cover)
                            : null,
                      ),
                      child: avatarUrl == null
                          ? const Icon(Icons.person, color: Colors.white, size: 52)
                          : null,
                    ),
                    if (_uploading) Container(
                      width: 110, height: 110,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.black38),
                      child: const CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                    ),
                    Positioned(
                      bottom: 4, right: 4,
                      child: Container(
                        width: 32, height: 32,
                        decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primary),
                        child: const Icon(Icons.camera_alt, color: Colors.white, size: 16),
                      ),
                    ),
                  ]),
                ),

                const SizedBox(height: 10),
                Text(
                  _avatarUrl != null ? 'Photo uploaded!' : 'Tap to add a profile photo',
                  style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13),
                ),

                const SizedBox(height: 36),

                // Name card
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 24, offset: const Offset(0, 8))],
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('Your Name', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF667781))),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _nameCtrl,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Color(0xFF111B21)),
                      decoration: InputDecoration(
                        hintText: 'Enter your display name',
                        hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                        filled: true,
                        fillColor: const Color(0xFFF0F2F5),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.primary, width: 2),
                        ),
                        prefixIcon: const Icon(Icons.person_outline, color: AppColors.primary),
                      ),
                      onSubmitted: (_) => _save(),
                    ),
                    if (_err != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(children: [
                          const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 15),
                          const SizedBox(width: 6),
                          Flexible(child: Text(_err!, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 12))),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                        onPressed: (_saving || _uploading) ? null : _save,
                        child: _saving
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                            : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Text('Enter Phoneopia', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                SizedBox(width: 8),
                                Icon(Icons.arrow_forward_rounded, size: 18),
                              ]),
                      ),
                    ),
                  ]),
                ),

                const SizedBox(height: 20),
                TextButton(
                  onPressed: () => ensureGDriveThenGoHome(context),
                  child: Text('Skip for now', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13)),
                ),
                const SizedBox(height: 32),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
