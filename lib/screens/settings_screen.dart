import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import 'linked_devices_screen.dart';
import 'legal_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _uploadingAvatar = false;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted)
        setState(() => _appVersion = '${info.version} (${info.buildNumber})');
    });
  }

  void _snack(String msg, {bool ok = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: ok ? AppColors.primary : AppColors.danger,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _showAvatarOptions() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Profile photo',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(
                  Icons.photo_library_outlined,
                  color: AppColors.primary,
                ),
                title: const Text('Choose from gallery'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _pickAvatar(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.camera_alt_outlined,
                  color: AppColors.primary,
                ),
                title: const Text('Take a photo'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _pickAvatar(ImageSource.camera);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickAvatar(ImageSource source) async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: source, imageQuality: 90);
    if (xfile == null) return;
    // Let the user crop the picked photo (square) before uploading.
    final cropped = await ImageCropper().cropImage(
      sourcePath: xfile.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 88,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop photo',
          toolbarColor: AppColors.primary,
          toolbarWidgetColor: Colors.white,
          activeControlsWidgetColor: AppColors.primary,
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
        IOSUiSettings(title: 'Crop photo', aspectRatioLockEnabled: true),
      ],
    );
    if (cropped == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final bytes = await File(cropped.path).readAsBytes();
      final r = await ApiService.uploadAvatar(bytes, 'avatar.jpg');
      if (r['success'] == true && mounted) {
        final prov = context.read<AppProvider>();
        if (r['user'] is Map) {
          await prov.applyUserPayload(
            Map<String, dynamic>.from(r['user'] as Map),
          );
        } else {
          await prov.refreshMe();
        }
        _snack('Profile photo updated');
      } else if (mounted) {
        _snack(r['error']?.toString() ?? 'Upload failed', ok: false);
      }
    } catch (_) {
      if (mounted) _snack('Upload failed', ok: false);
    }
    if (mounted) setState(() => _uploadingAvatar = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prov = context.watch<AppProvider>();
    final me = prov.me;

    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'My Account',
          style: TextStyle(
            color: isDark ? AppColors.t1Dark : AppColors.t1Light,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: IconThemeData(
          color: isDark ? AppColors.t1Dark : AppColors.t1Light,
        ),
      ),
      body: ListView(
        children: [
          // Profile hero
          Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [AppColors.primary, AppColors.primaryDark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(.24),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 72,
                  height: 72,
                  child: Stack(
                    children: [
                      _uploadingAvatar
                          ? Container(
                              width: 72,
                              height: 72,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primaryDim,
                              ),
                              child: const CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppColors.primary,
                              ),
                            )
                          : AvatarWidget(
                              imageUrl: me?.avatar,
                              name: me?.displayName ?? '',
                              size: 72,
                            ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: GestureDetector(
                          onTap: _showAvatarOptions,
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.primary,
                            ),
                            child: const Icon(
                              Icons.camera_alt,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        me?.displayName ?? '',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '@${me?.username ?? 'user'}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withOpacity(.9),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        me?.statusMessage ?? 'Hey there! I am using Phoneopia.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.white.withOpacity(.78),
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const EditProfileScreen())),
                        child: const Text('Edit username', style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(
                    Icons.edit_outlined,
                    color: Colors.white,
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const EditProfileScreen(),
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // Profile and linked devices
          _section('Profile', isDark, [
            _tile(
              Icons.person_outline,
              'Profile',
              'Name, avatar, status',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EditProfileScreen()),
              ),
            ),
            _tile(
              Icons.lock_outline,
              'Privacy',
              'Last seen, profile photo',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PrivacySettingsScreen(),
                ),
              ),
            ),
            _tile(
              Icons.devices_outlined,
              'Linked devices',
              'Manage linked devices',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const LinkedDevicesScreen()),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // Appearance
          _section('Appearance', isDark, [
            _themeSelector(isDark, prov),
            _tile(
              Icons.wallpaper,
              'Chat Wallpaper',
              _wallpaperLabel(prov.chatWallpaper),
              isDark,
              () => _pickWallpaper(context, prov),
            ),
            _tile(
              Icons.text_fields,
              'Font Size',
              _fontLabel(prov.fontScale),
              isDark,
              () => _pickFontSize(context, prov),
            ),
          ]),

          const SizedBox(height: 12),

          // Notifications
          _section('Notifications', isDark, [
            _tile(
              Icons.notifications_outlined,
              'Notifications',
              'Message, group & calls',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NotificationSettingsScreen(),
                ),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // Nearby is fully automatic now (auto-discover, auto-connect, same
          // chat as the regular conversation) — no separate screen to open.

          // Help
          _section('Help', isDark, [
            _tile(
              Icons.help_outline,
              'Help Center',
              'FAQ and support',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalScreen(
                    title: 'Help Center',
                    sections: [
                      LegalSection(
                        'Frequently asked questions',
                        heading: 'FAQ',
                      ),
                      LegalSection(
                        'Q: How do I change my display name?\nA: Go to Settings and tap your profile at the top.\n\n'
                        'Q: Why didn\'t I get my OTP?\nA: Try switching between WhatsApp and SMS delivery on the login screen, or wait a minute and request again.\n\n'
                        'Q: How do I back up my chats?\nA: Chats sync automatically to the server as long as you\'re logged in — no manual backup needed.\n\n'
                        'Q: How do I report a problem?\nA: Email support so we can help — include your username and a short description of the issue.',
                      ),
                      LegalSection('Contact', heading: 'Still need help?'),
                      const LegalSection(
                        'Reach us at support@rehanschool.net and we\'ll get back to you.',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _tile(
              Icons.privacy_tip_outlined,
              'Privacy Policy',
              'How we handle your data',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalScreen(
                    title: 'Privacy Policy',
                    sections: [
                      LegalSection(
                        'Phoneopia collects only what\'s needed to provide messaging and calling: your phone number, '
                        'display name, profile photo, and the messages/media you send. Messages are stored so they can '
                        'sync across your devices and are only visible to conversation participants.',
                        heading: 'What we collect',
                      ),
                      LegalSection(
                        'Your phone number is used to verify your account via OTP and to let contacts find you. '
                        'It is never shown to other users unless you choose to share it.',
                        heading: 'Phone number',
                      ),
                      LegalSection(
                        'Voice and video calls are relayed peer-to-peer where possible. Call metadata (who called whom, '
                        'when, and for how long) is kept in your call history.',
                        heading: 'Calls',
                      ),
                      LegalSection(
                        'We do not sell your data to third parties. Data is used solely to operate and improve Phoneopia.',
                        heading: 'Data sharing',
                      ),
                      LegalSection(
                        'You can delete your account and associated data at any time from Settings. '
                        'Contact support@rehanschool.net for data requests.',
                        heading: 'Your control',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _tile(
              Icons.description_outlined,
              'Terms of Service',
              'Rules for using Phoneopia',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const LegalScreen(
                    title: 'Terms of Service',
                    sections: [
                      LegalSection(
                        'By using Phoneopia you agree to use the service responsibly and not to send spam, harassment, '
                        'illegal content, or attempt to disrupt the service for other users.',
                        heading: 'Acceptable use',
                      ),
                      LegalSection(
                        'You are responsible for the content you send and the accounts you create. Do not impersonate '
                        'others or misuse the phone-number verification system.',
                        heading: 'Your account',
                      ),
                      LegalSection(
                        'We may suspend or remove accounts that violate these terms or abuse the platform, '
                        'including automated/bulk messaging outside of the official bot integrations.',
                        heading: 'Enforcement',
                      ),
                      LegalSection(
                        'Phoneopia is provided as-is. We work to keep the service reliable but can\'t guarantee '
                        'uninterrupted availability.',
                        heading: 'Availability',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _tile(
              Icons.info_outline,
              'About',
              'App version & legal',
              isDark,
              () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LegalScreen(
                    title: 'About Phoneopia',
                    sections: [
                      LegalSection(
                        _appVersion.isEmpty
                            ? 'Version —'
                            : 'Version $_appVersion',
                        heading: 'Phoneopia',
                      ),
                      const LegalSection(
                        'A fast, beautiful, and private messaging app — chat, call, and create with AI, all in one.',
                      ),
                      const LegalSection(
                        '© 2026 Phoneopia. Made by RehanSchool. All rights reserved.',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          // Logout
          Container(
            color: isDark ? AppColors.cardDark : Colors.white,
            child: ListTile(
              leading: const Icon(Icons.logout, color: AppColors.danger),
              title: const Text(
                'Log out',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () => _confirmLogout(context),
            ),
          ),

          const SizedBox(height: 40),

          Center(
            child: Column(
              children: [
                const Text(
                  'Phoneopia',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  _appVersion.isEmpty ? 'Version —' : 'Version $_appVersion',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Made by RehanSchool',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, bool isDark, List<Widget> tiles) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.primaryDark,
          ),
        ),
      ),
      Container(
        color: isDark ? AppColors.cardDark : Colors.white,
        child: Column(children: tiles),
      ),
    ],
  );

  Widget _tile(
    IconData icon,
    String title,
    String sub,
    bool isDark,
    VoidCallback onTap,
  ) => ListTile(
    leading: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.primaryDim,
      ),
      child: Icon(icon, color: AppColors.primaryDark, size: 20),
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: isDark ? AppColors.t1Dark : AppColors.t1Light,
      ),
    ),
    subtitle: Text(
      sub,
      style: TextStyle(
        fontSize: 13,
        color: isDark ? AppColors.t3Dark : AppColors.t3Light,
      ),
    ),
    trailing: const Icon(
      Icons.arrow_forward_ios,
      size: 14,
      color: AppColors.t3Light,
    ),
    onTap: onTap,
  );

  // Was an inline ExpansionTile — every OTHER picker in this screen (font
  // size, wallpaper) already uses a bottom sheet, and only this one didn't.
  // That inconsistency wasn't just cosmetic: a tap issued right as the
  // accordion's SizeTransition was still growing landed on whatever ended up
  // under that pixel once the list finished settling into its final layout,
  // not the option the user actually saw and aimed for — confirmed live, a
  // tap on "Dark" fired a split second into the expand animation missed
  // entirely and no theme change happened. A bottom sheet doesn't have this
  // failure mode: it's an overlay, so the content underneath never moves
  // while it's opening.
  Widget _themeSelector(bool isDark, AppProvider prov) {
    return _tile(
      Icons.palette_outlined,
      'Theme',
      prov.themeMode == ThemeMode.dark
          ? 'Dark'
          : prov.themeMode == ThemeMode.light
          ? 'Light'
          : 'System default',
      isDark,
      () => _pickTheme(context, prov, isDark),
    );
  }

  void _pickTheme(BuildContext context, AppProvider prov, bool isDark) {
    final opts = [
      (ThemeMode.system, 'System default', Icons.brightness_auto),
      (ThemeMode.light, 'Light', Icons.light_mode),
      (ThemeMode.dark, 'Dark', Icons.dark_mode),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Theme',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                ),
              ),
            ),
            ...opts.map(
              (o) => ListTile(
                leading: Icon(
                  o.$3,
                  size: 20,
                  color: prov.themeMode == o.$1
                      ? AppColors.primary
                      : (isDark ? AppColors.t2Dark : AppColors.t2Light),
                ),
                title: Text(
                  o.$2,
                  style: TextStyle(
                    color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                  ),
                ),
                trailing: prov.themeMode == o.$1
                    ? const Icon(Icons.check, color: AppColors.primary)
                    : null,
                onTap: () {
                  prov.setTheme(o.$1);
                  Navigator.pop(context);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Font size ──────────────────────────────────────────────
  String _fontLabel(double s) => s <= 0.85
      ? 'Small'
      : s >= 1.2
      ? 'Large'
      : 'Medium';
  void _pickFontSize(BuildContext context, AppProvider prov) {
    final opts = [('Small', 0.85), ('Medium', 1.0), ('Large', 1.2)];
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Font Size',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
            ...opts.map(
              (o) => RadioListTile<double>(
                value: o.$2,
                groupValue: prov.fontScale,
                activeColor: AppColors.primary,
                title: Text(o.$1, style: TextStyle(fontSize: 15 * o.$2)),
                onChanged: (v) {
                  prov.setFontScale(v!);
                  Navigator.pop(context);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Chat wallpaper ─────────────────────────────────────────
  static const Map<String, (String, Color)> wallpapers = {
    'default': ('Default', Color(0xFFECE5DD)),
    'green': ('Rose', Color(0xFFFEE2E2)),
    'blue': ('Sky', Color(0xFFD6EAF8)),
    'beige': ('Sand', Color(0xFFF5ECD7)),
    'pink': ('Blossom', Color(0xFFF8D7E3)),
    'dark': ('Dark', Color(0xFF0B141A)),
  };
  String _wallpaperLabel(String? id) =>
      wallpapers[id ?? 'default']?.$1 ?? 'Default';
  void _pickWallpaper(BuildContext context, AppProvider prov) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  'Chat Wallpaper',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
              ),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: wallpapers.entries.map((e) {
                  final sel = (prov.chatWallpaper ?? 'default') == e.key;
                  return GestureDetector(
                    onTap: () {
                      prov.setChatWallpaper(e.key);
                      Navigator.pop(context);
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 64,
                          height: 92,
                          decoration: BoxDecoration(
                            color: e.value.$2,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: sel ? AppColors.primary : Colors.black12,
                              width: sel ? 3 : 1,
                            ),
                          ),
                          child: sel
                              ? const Icon(
                                  Icons.check,
                                  color: AppColors.primary,
                                )
                              : null,
                        ),
                        const SizedBox(height: 4),
                        Text(e.value.$1, style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showInfo(BuildContext ctx, String title, String body) {
    showDialog(
      context: ctx,
      builder: (dlg) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlg),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _showSecurity(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (dlg) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Security',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle, color: AppColors.primary, size: 20),
                SizedBox(width: 10),
                Expanded(child: Text('End-to-end encryption active')),
              ],
            ),
            SizedBox(height: 12),
            Row(
              children: [
                Icon(Icons.lock, color: AppColors.primary, size: 20),
                SizedBox(width: 10),
                Expanded(child: Text('All messages are secured')),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlg),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _syncContacts(BuildContext ctx) async {
    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(
        content: Text('Syncing contacts…'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    final added = await ctx.read<AppProvider>().syncPhoneContacts();
    if (!ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(
          added > 0
              ? '$added contact${added == 1 ? '' : 's'} added from your phone'
              : 'No new Phoneopia contacts found',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _confirmClearHistory(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (dlg) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Clear chat history?',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        content: const Text(
          'This will delete all messages on this device. Messages on server and other devices are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlg),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dlg);
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text('Chat history cleared'),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
            child: const Text(
              'Clear',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text(
          'You will need your phone number and OTP to log back in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dlgCtx);
              context.read<AppProvider>().logout();
            },
            child: const Text(
              'Log out',
              style: TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Edit Profile — full page (was a bottom-sheet popup) ────────────────
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});
  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _nameCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _statusCtrl = TextEditingController();
  Timer? _usernameTimer;
  bool? _usernameIsAvailable;
  String _usernameHint = '';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    // Pull the CURRENT account fresh from the server so the form never shows
    // a stale/previous account's name & status (e.g. after a QR login).
    await context.read<AppProvider>().refreshMe();
    if (!mounted) return;
    final me = context.read<AppProvider>().me;
    _nameCtrl.text = me?.displayName ?? '';
    _usernameCtrl.text = me?.username ?? '';
    _statusCtrl.text = me?.statusMessage ?? '';
    setState(() => _loading = false);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _usernameCtrl.dispose();
    _statusCtrl.dispose();
    _usernameTimer?.cancel();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Display name is required'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final username = _usernameCtrl.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,24}$').hasMatch(username)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Username: 3–24 lowercase letters, numbers or underscores')));
      return;
    }
    if (_usernameIsAvailable == false) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This username is not available')));
      return;
    }
    setState(() => _saving = true);
    final ok = await context.read<AppProvider>().updateProfile({
      'display_name': name,
      'username': username,
      'status_message': _statusCtrl.text.trim(),
    });
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Profile updated' : 'Could not update profile'),
        backgroundColor: ok ? AppColors.primary : AppColors.danger,
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (ok && mounted) Navigator.pop(context);
  }

  void _scheduleUsernameCheck(String value) {
    _usernameTimer?.cancel();
    final username = value.trim().toLowerCase();
    setState(() {
      _usernameIsAvailable = null;
      _usernameHint = username.length < 3 ? 'Use at least 3 characters' : 'Checking…';
    });
    if (username.length < 3) return;
    _usernameTimer = Timer(const Duration(milliseconds: 450), () async {
      final result = await ApiService.usernameAvailable(username);
      if (!mounted || _usernameCtrl.text.trim().toLowerCase() != username) return;
      setState(() {
        _usernameIsAvailable = result['available'] == true;
        _usernameHint = _usernameIsAvailable! ? 'Available' : (result['reason']?.toString() ?? 'Not available');
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: const Text('Edit Profile'),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _usernameCtrl,
                  onChanged: _scheduleUsernameCheck,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    prefixIcon: const Icon(Icons.alternate_email_rounded),
                    suffixIcon: _usernameIsAvailable == null ? null : Icon(_usernameIsAvailable! ? Icons.check_circle : Icons.cancel, color: _usernameIsAvailable! ? AppColors.primary : AppColors.danger),
                    helperText: _usernameHint.isEmpty ? 'Your unique @username' : _usernameHint,
                    helperStyle: TextStyle(color: _usernameIsAvailable == false ? AppColors.danger : AppColors.primary),
                  ),
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _statusCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Status message',
                    prefixIcon: Icon(Icons.info_outline),
                  ),
                  maxLength: 120,
                ),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Save Changes'),
                ),
              ],
            ),
    );
  }
}

// ── Privacy settings — full page (was a bottom-sheet popup) ────────────
class PrivacySettingsScreen extends StatefulWidget {
  const PrivacySettingsScreen({super.key});
  @override
  State<PrivacySettingsScreen> createState() => _PrivacySettingsScreenState();
}

class _PrivacySettingsScreenState extends State<PrivacySettingsScreen> {
  static const _choices = [
    ('everyone', 'Everyone'),
    ('contacts', 'My contacts'),
    ('nobody', 'Nobody'),
  ];

  late String _lastSeen;
  late String _profilePhoto;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final me = context.read<AppProvider>().me;
    _lastSeen = me?.privacyLastSeen ?? 'everyone';
    _profilePhoto = me?.privacyProfilePhoto ?? 'everyone';
  }

  Future<void> _pickValue(
    String title,
    String current,
    Future<void> Function(String value) onChosen,
  ) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (pickerCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: isDark ? AppColors.t1Dark : AppColors.t1Light,
              ),
            ),
            const SizedBox(height: 8),
            ..._choices.map(
              (c) => ListTile(
                title: Text(c.$2),
                trailing: current == c.$1
                    ? const Icon(Icons.check, color: AppColors.primary)
                    : null,
                onTap: () async {
                  Navigator.pop(pickerCtx);
                  if (c.$1 != current) await onChosen(c.$1);
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _row(
    bool isDark, {
    required String label,
    required String value,
    VoidCallback? onTap,
  }) => ListTile(
    onTap: onTap,
    title: Text(
      label,
      style: TextStyle(
        fontWeight: FontWeight.w500,
        color: isDark ? AppColors.t1Dark : AppColors.t1Light,
      ),
    ),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(color: AppColors.primary, fontSize: 13),
        ),
        const SizedBox(width: 4),
        Icon(
          Icons.arrow_forward_ios,
          size: 12,
          color: isDark ? AppColors.t3Dark : AppColors.t3Light,
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: const Text('Privacy'),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Text(
              'Control who can see your info',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppColors.t3Dark : AppColors.t3Light,
              ),
            ),
          ),
          _row(
            isDark,
            label: 'Last seen',
            value: User.privacyLabel(_lastSeen),
            onTap: _saving
                ? null
                : () => _pickValue('Last seen', _lastSeen, (v) async {
                    setState(() => _saving = true);
                    final ok = await context.read<AppProvider>().updatePrivacy(
                      lastSeen: v,
                    );
                    if (!mounted) return;
                    setState(() {
                      if (ok) _lastSeen = v;
                      _saving = false;
                    });
                    _snackHere(
                      ok
                          ? 'Last seen privacy updated'
                          : 'Could not save privacy',
                      ok,
                    );
                  }),
          ),
          _row(
            isDark,
            label: 'Profile photo',
            value: User.privacyLabel(_profilePhoto),
            onTap: _saving
                ? null
                : () => _pickValue('Profile photo', _profilePhoto, (v) async {
                    setState(() => _saving = true);
                    final ok = await context.read<AppProvider>().updatePrivacy(
                      profilePhoto: v,
                    );
                    if (!mounted) return;
                    setState(() {
                      if (ok) _profilePhoto = v;
                      _saving = false;
                    });
                    _snackHere(
                      ok
                          ? 'Profile photo privacy updated'
                          : 'Could not save privacy',
                      ok,
                    );
                  }),
          ),
          if (_saving)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _snackHere(String msg, bool ok) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: ok ? AppColors.primary : AppColors.danger,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}

// ── Notification settings — full page (was a bottom-sheet popup) ───────
class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});
  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  // These toggles were already non-functional placeholders in the popup
  // version (value: true, onChanged: (_) {}) — carried over as-is, just in
  // a full page now instead of a sheet.
  bool _messages = true;
  bool _groups = true;
  bool _calls = true;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: const Text('Notifications'),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: ListView(
        children: [
          SwitchListTile(
            value: _messages,
            onChanged: (v) => setState(() => _messages = v),
            title: Text(
              'Message notifications',
              style: TextStyle(
                color: isDark ? AppColors.t1Dark : AppColors.t1Light,
              ),
            ),
            activeColor: AppColors.primary,
          ),
          SwitchListTile(
            value: _groups,
            onChanged: (v) => setState(() => _groups = v),
            title: Text(
              'Group notifications',
              style: TextStyle(
                color: isDark ? AppColors.t1Dark : AppColors.t1Light,
              ),
            ),
            activeColor: AppColors.primary,
          ),
          SwitchListTile(
            value: _calls,
            onChanged: (v) => setState(() => _calls = v),
            title: Text(
              'Call notifications',
              style: TextStyle(
                color: isDark ? AppColors.t1Dark : AppColors.t1Light,
              ),
            ),
            activeColor: AppColors.primary,
          ),
        ],
      ),
    );
  }
}
