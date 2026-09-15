import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../config/app_config.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/verified_badge.dart';
import 'active_call_screen.dart';
import 'photo_view_screen.dart';
import 'group_info_screen.dart';
import 'edit_contact_screen.dart';

class ContactInfoScreen extends StatelessWidget {
  final Conversation conversation;
  const ContactInfoScreen({super.key, required this.conversation});

  void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));

  void _launchCall(BuildContext context, bool isVideo) {
    final ou = conversation.otherUser;
    if (ou == null) return;
    context.read<AppProvider>().startOutgoingCallRing();
    Navigator.push(context, MaterialPageRoute(builder: (_) => ActiveCallScreen(
      callerName: conversation.displayName,
      callerAvatar: conversation.displayAvatar.isNotEmpty ? conversation.displayAvatar : null,
      isVideo: false,
      convId: conversation.id,
      isOutgoing: true,
      calleeUserId: ou.id,
    ))).then((_) => context.read<AppProvider>().stopRing());
  }

  void _openAvatar(BuildContext context) {
    if (conversation.displayAvatar.isEmpty) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) =>
        PhotoViewScreen(url: conversation.displayAvatar, title: conversation.displayName)));
  }

  void _editContact(BuildContext context) {
    if (conversation.otherUser == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => EditContactScreen(conversation: conversation)));
  }

  @override
  Widget build(BuildContext context) {
    if (conversation.type == 'group') {
      return GroupInfoScreen(conversation: conversation);
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ou = conversation.otherUser;
    final isAi = conversation.isAiBot;

    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: 280,
          pinned: true,
          backgroundColor: isDark ? AppColors.bg2Dark : AppColors.headerGreen,
          foregroundColor: Colors.white,
          actions: [
            if (!isAi && ou != null)
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white),
                onSelected: (v) {
                  if (v == 'edit') _editContact(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Row(children: [
                    Icon(Icons.edit_outlined, color: AppColors.primary, size: 20),
                    SizedBox(width: 12),
                    Text('Edit contact'),
                  ])),
                ],
              ),
          ],
          flexibleSpace: FlexibleSpaceBar(
            background: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.primaryDark, AppColors.primaryDeeper],
                  begin: Alignment.topCenter, end: Alignment.bottomCenter,
                ),
              ),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const SizedBox(height: 60),
                GestureDetector(
                  onTap: () => _openAvatar(context),
                  child: AvatarWidget(
                    imageUrl: conversation.displayAvatar.isNotEmpty ? conversation.displayAvatar : null,
                    name: conversation.displayName,
                    size: 96,
                    showOnline: true,
                    status: ou?.status ?? 'offline',
                    isAiBot: isAi,
                  ),
                ),
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Flexible(child: Text(
                    conversation.displayName,
                    style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700),
                    textAlign: TextAlign.center,
                  )),
                  if (isAi) ...[
                    const SizedBox(width: 6),
                    const VerifiedBadge(size: 20),
                  ],
                ]),
                if (ou?.phone != null) Text(
                  isAi ? '+92 333 685 4635' : (ou!.phone!),
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (!isAi && ou?.noVoiceCall != true) ...[
                    _actionBtn(Icons.call, 'Audio', () => _launchCall(context, false)),
                    const SizedBox(width: 24),
                  ],
                  if (!isAi && ou?.noVideoCall != true) ...[
                    _actionBtn(Icons.videocam, 'Video', () => _launchCall(context, true)),
                    const SizedBox(width: 24),
                  ],
                  _actionBtn(Icons.photo_library, 'Media', () => _openMedia(context)),
                ]),
              ]),
            ),
          ),
        ),

        SliverList(delegate: SliverChildListDelegate([
          const SizedBox(height: 12),

          if (ou?.statusMessage != null) _infoCard(isDark, children: [
            _infoRow(Icons.info_outline, 'Status', ou!.statusMessage!, isDark),
          ]),

          if (ou?.phone != null && !isAi) _infoCard(isDark, children: [
            _infoRow(Icons.phone, 'Phone', ou!.phone!, isDark),
          ]),
          if (isAi) _infoCard(isDark, children: [
            _infoRow(Icons.phone, 'Phone', '+92 333 685 4635', isDark),
          ]),

          _infoCard(isDark, children: [
            _infoRow(Icons.alternate_email, 'Username', '@${ou?.username ?? conversation.displayName.toLowerCase().replaceAll(' ', '_')}', isDark),
          ]),

          const SizedBox(height: 12),

          _infoCard(isDark, children: [
            InkWell(
              onTap: () => _openMedia(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('Media, links, and docs', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? AppColors.t1Dark : AppColors.t1Light)),
                  const Icon(Icons.arrow_forward_ios, size: 16, color: AppColors.primary),
                ]),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          _infoCard(isDark, children: [
            _optionRow(Icons.notifications_off_outlined, 'Mute notifications', isDark, () async {
              final r = await ApiService.post('conversations.php?action=mute', {'conversation_id': conversation.id})
                  .catchError((_) => <String, dynamic>{});
              if (context.mounted) {
                _toast(context, r['is_muted'] == true ? 'Muted' : 'Unmuted');
              }
            }),
          ]),

          const SizedBox(height: 12),

          if (!isAi) _infoCard(isDark, children: [
            _optionRow(Icons.block, 'Block ${conversation.displayName}', isDark, () async {
              if (ou == null) return;
              await ApiService.post('users.php?action=block', {'user_id': ou.id})
                  .catchError((_) => <String, dynamic>{});
              if (context.mounted) _toast(context, '${conversation.displayName} blocked');
            }, color: AppColors.danger),
          ]),

          const SizedBox(height: 32),
        ])),
      ]),
    );
  }

  void _openMedia(BuildContext context) {
    Navigator.push(context, MaterialPageRoute(builder: (_) =>
        _MediaGalleryScreen(convId: conversation.id, title: conversation.displayName)));
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 48, height: 48,
        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(.2)),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
    ]),
  );

  Widget _infoCard(bool isDark, {required List<Widget> children}) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: isDark ? AppColors.cardDark : Colors.white,
      borderRadius: BorderRadius.circular(14),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(isDark ? 0.24 : 0.05),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );

  Widget _infoRow(IconData icon, String label, String value, bool isDark) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    child: Row(children: [
      Container(
        width: 40, height: 40,
        decoration: BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryDim),
        child: Icon(icon, color: AppColors.primaryDark, size: 20),
      ),
      const SizedBox(width: 16),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 11, color: isDark ? AppColors.t3Dark : AppColors.t3Light)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 15, color: isDark ? AppColors.t1Dark : AppColors.t1Light)),
      ])),
    ]),
  );

  Widget _optionRow(IconData icon, String label, bool isDark, VoidCallback onTap, {Color? color}) => ListTile(
    leading: Icon(icon, color: color ?? (isDark ? AppColors.t2Dark : AppColors.t2Light)),
    title: Text(label, style: TextStyle(fontSize: 15, color: color ?? (isDark ? AppColors.t1Dark : AppColors.t1Light))),
    onTap: onTap,
    dense: false,
  );

  Widget _divider(bool isDark) => Divider(
    height: 1, indent: 72,
    color: isDark ? const Color(0x1F8696A0) : const Color(0x12000000),
  );
}

// ── Media gallery — images/videos/files shared in this chat ──
class _MediaGalleryScreen extends StatefulWidget {
  final int convId;
  final String title;
  const _MediaGalleryScreen({required this.convId, required this.title});
  @override State<_MediaGalleryScreen> createState() => _MediaGalleryScreenState();
}

class _MediaGalleryScreenState extends State<_MediaGalleryScreen> {
  List<Map<String, dynamic>> _media = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiService.get('conversations.php?action=media', params: {'id': widget.convId.toString()});
      if (r['success'] == true && r['media'] is List) {
        _media = (r['media'] as List).map((m) => Map<String, dynamic>.from(m)).toList();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _abs(String? p) {
    if (p == null || p.isEmpty) return '';
    if (p.startsWith('http')) return p;
    return '${AppConfig.mediaBase}${p.startsWith('/') ? '' : '/'}$p';
  }

  @override
  Widget build(BuildContext context) {
    final images = _media.where((m) => m['type'] == 'image').toList();
    return Scaffold(
      appBar: AppBar(title: Text('Media — ${widget.title}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : images.isEmpty
              ? const Center(child: Text('No media yet'))
              : GridView.builder(
                  padding: const EdgeInsets.all(4),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3, mainAxisSpacing: 4, crossAxisSpacing: 4),
                  itemCount: images.length,
                  itemBuilder: (_, i) {
                    final url = _abs(images[i]['file_path']?.toString());
                    return GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) =>
                          PhotoViewScreen(url: url, title: widget.title))),
                      child: Image.network(url, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(color: Colors.grey.shade300)),
                    );
                  },
                ),
    );
  }
}
