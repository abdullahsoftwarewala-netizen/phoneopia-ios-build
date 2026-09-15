import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import 'active_call_screen.dart';
import 'group_call_screen.dart';
import 'photo_view_screen.dart';
import 'chat_screen.dart';
import '../utils/page_routes.dart';

// ════════════════════════════════════════════════════════════════
//  GROUP INFO — members, admins, past members, admin actions
// ════════════════════════════════════════════════════════════════
class GroupInfoScreen extends StatefulWidget {
  final Conversation conversation;
  const GroupInfoScreen({super.key, required this.conversation});
  @override
  State<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends State<GroupInfoScreen> {
  Conversation? _conv;
  bool _loading = true;
  int get _meId => context.read<AppProvider>().me?.id ?? 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final c = await ApiService.getConversation(widget.conversation.id);
      if (mounted) setState(() { _conv = c ?? widget.conversation; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _conv = widget.conversation; _loading = false; });
    }
  }

  void _toast(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));

  void _startCall(bool video) {
    Navigator.push(context, MaterialPageRoute(builder: (_) => GroupCallScreen(
      convId: _conv!.id,
      groupName: _conv!.name,
      isInitiator: true,
      members: _conv!.members,
    )));
  }

  bool get _amAdmin {
    final c = _conv!;
    if (c.myRole == 'admin') return true;
    for (final m in c.members) {
      if (m.id == _meId && m.isAdmin) return true;
    }
    return false;
  }

  Future<void> _confirm(String title, String body, String okLabel, Color okColor, Future<void> Function() onOk) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      title: Text(title), content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(context, true), child: Text(okLabel, style: TextStyle(color: okColor, fontWeight: FontWeight.w600))),
      ],
    ));
    if (ok == true) await onOk();
  }

  void _memberSheet(GroupMember m) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isSelf = m.id == _meId;
    showModalBottomSheet(context: context, backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        ListTile(
          leading: AvatarWidget(imageUrl: m.avatar, name: m.displayName, size: 40),
          title: Text(m.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(m.isAdmin ? 'Group admin' : 'Member'),
        ),
        const Divider(height: 1),
        if (!isSelf) ListTile(
          leading: const Icon(Icons.chat_bubble_outline),
          title: Text('Message ${m.displayName}'),
          onTap: () { Navigator.pop(context); _messageMember(m); },
        ),
        if (_amAdmin && !isSelf) ListTile(
          leading: Icon(m.isAdmin ? Icons.remove_moderator_outlined : Icons.shield_outlined, color: AppColors.primaryDark),
          title: Text(m.isAdmin ? 'Dismiss as admin' : 'Make group admin'),
          onTap: () async {
            Navigator.pop(context);
            await ApiService.groupMakeAdmin(_conv!.id, m.id, demote: m.isAdmin).catchError((_) => <String, dynamic>{});
            _toast(m.isAdmin ? '${m.displayName} dismissed as admin' : '${m.displayName} is now admin');
            _load();
          },
        ),
        if (_amAdmin && !isSelf) ListTile(
          leading: const Icon(Icons.person_remove_outlined, color: AppColors.danger),
          title: const Text('Remove from group', style: TextStyle(color: AppColors.danger)),
          onTap: () {
            Navigator.pop(context);
            _confirm('Remove member', 'Remove ${m.displayName} from this group?', 'Remove', AppColors.danger, () async {
              await ApiService.groupRemoveMember(_conv!.id, m.id).catchError((_) => <String, dynamic>{});
              _toast('${m.displayName} removed');
              _load();
            });
          },
        ),
        if (!isSelf) ListTile(
          leading: const Icon(Icons.block, color: AppColors.danger),
          title: Text('Block ${m.displayName}', style: const TextStyle(color: AppColors.danger)),
          onTap: () async {
            Navigator.pop(context);
            await ApiService.blockUser(m.id).catchError((_) => <String, dynamic>{});
            _toast('${m.displayName} blocked');
          },
        ),
        const SizedBox(height: 8),
      ])),
    );
  }

  Future<void> _messageMember(GroupMember m) async {
    final r = await ApiService.createConversation(m.id).catchError((_) => <String, dynamic>{});
    final cid = int.tryParse(r['conversation_id']?.toString() ?? '');
    if (cid == null) { _toast('Could not open chat'); return; }
    final c = await ApiService.getConversation(cid);
    if (c != null && mounted) {
      Navigator.push(context, chatRoute(ChatScreen(conversation: c)));
    }
  }

  void _addMembersSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true,
      backgroundColor: Theme.of(context).brightness == Brightness.dark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _AddMemberSheet(convId: _conv!.id, onAdded: _load),
    ).whenComplete(_load);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading || _conv == null) {
      return Scaffold(appBar: AppBar(title: const Text('Group info')), body: const Center(child: CircularProgressIndicator()));
    }
    final c = _conv!;
    final admins = c.members.where((m) => m.isAdmin).toList();
    final regular = c.members.where((m) => !m.isAdmin).toList();
    final ordered = [...admins, ...regular];

    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      body: CustomScrollView(slivers: [
        SliverAppBar(
          expandedHeight: 260, pinned: true,
          backgroundColor: isDark ? AppColors.bg2Dark : AppColors.headerGreen,
          foregroundColor: Colors.white,
          flexibleSpace: FlexibleSpaceBar(background: Container(
            decoration: const BoxDecoration(gradient: LinearGradient(
              colors: [AppColors.primaryLight, AppColors.primaryDeeper],
              begin: Alignment.topCenter, end: Alignment.bottomCenter)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const SizedBox(height: 50),
              GestureDetector(
                onTap: () { if (c.displayAvatar.isNotEmpty) Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewScreen(url: c.displayAvatar, title: c.name))); },
                child: AvatarWidget(imageUrl: c.displayAvatar.isNotEmpty ? c.displayAvatar : null, name: c.name, size: 92),
              ),
              const SizedBox(height: 12),
              Text(c.name, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w700)),
              Text('Group · ${c.members.length} members', style: const TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 16),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                _gActionBtn(Icons.call, 'Audio', () => _startCall(false)),
                const SizedBox(width: 28),
                _gActionBtn(Icons.videocam, 'Video', () => _startCall(true)),
              ]),
            ]),
          )),
        ),
        SliverList(delegate: SliverChildListDelegate([
          const SizedBox(height: 10),
          _card(isDark, [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('About', style: TextStyle(fontSize: 12, color: isDark ? AppColors.t3Dark : AppColors.t3Light)),
                const SizedBox(height: 4),
                Text((c.description?.trim().isNotEmpty ?? false) ? c.description!.trim() : 'No description',
                  style: TextStyle(fontSize: 15, color: isDark ? AppColors.t1Dark : AppColors.t1Light)),
              ])),
          ]),
          const SizedBox(height: 10),
          _card(isDark, [
            ListTile(
              leading: const Icon(Icons.notifications_off_outlined),
              title: const Text('Mute notifications'),
              onTap: () async {
                final r = await ApiService.muteConversation(c.id).catchError((_) => <String, dynamic>{});
                _toast(r['is_muted'] == true ? 'Muted' : 'Unmuted');
              },
            ),
          ]),
          const SizedBox(height: 10),
          Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
            child: Text('${c.members.length} members', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isDark ? AppColors.t2Dark : AppColors.t2Light))),
          _card(isDark, [
            if (_amAdmin) ListTile(
              leading: Container(width: 40, height: 40, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.primaryDim),
                child: const Icon(Icons.person_add_alt_1, color: AppColors.primaryDark, size: 20)),
              title: const Text('Add members', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.primaryDark)),
              onTap: _addMembersSheet,
            ),
            ...ordered.map((m) => _memberTile(isDark, m)),
          ]),
          if (c.pastMembers.isNotEmpty) ...[
            const SizedBox(height: 14),
            Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text('Past members', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: isDark ? AppColors.t2Dark : AppColors.t2Light))),
            _card(isDark, c.pastMembers.map((m) => ListTile(
              leading: Opacity(opacity: .6, child: AvatarWidget(imageUrl: m.avatar, name: m.displayName, size: 40)),
              title: Text(m.displayName),
              subtitle: Text(m.status == 'left' ? 'Left the group' : 'Removed'),
              trailing: _amAdmin ? TextButton(
                onPressed: () async {
                  await ApiService.groupAddMember(c.id, m.id).catchError((_) => <String, dynamic>{});
                  _toast('${m.displayName} added back');
                  _load();
                },
                child: const Text('Add back'),
              ) : null,
            )).toList()),
          ],
          const SizedBox(height: 16),
          _card(isDark, [
            ListTile(
              leading: const Icon(Icons.logout, color: AppColors.danger),
              title: const Text('Exit group', style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w600)),
              onTap: () => _confirm('Exit group', 'Are you sure you want to leave "${c.name}"?', 'Exit', AppColors.danger, () async {
                await ApiService.groupRemoveMember(c.id, _meId).catchError((_) => <String, dynamic>{});
                if (mounted) { Navigator.pop(context); _toast('You left the group'); }
              }),
            ),
          ]),
          const SizedBox(height: 32),
        ])),
      ]),
    );
  }

  Widget _memberTile(bool isDark, GroupMember m) {
    final isSelf = m.id == _meId;
    return ListTile(
      onTap: () => _memberSheet(m),
      onLongPress: () => _memberSheet(m),
      leading: AvatarWidget(imageUrl: m.avatar, name: m.displayName, size: 44, showOnline: true, status: m.isOnline ? 'online' : 'offline'),
      title: Text(isSelf ? '${m.displayName} (You)' : m.displayName, style: const TextStyle(fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
      trailing: m.isAdmin ? Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: AppColors.primaryDim, borderRadius: BorderRadius.circular(10)),
        child: const Text('Admin', style: TextStyle(fontSize: 11, color: AppColors.primaryDark, fontWeight: FontWeight.w600)),
      ) : null,
    );
  }

  Widget _gActionBtn(IconData icon, String label, VoidCallback onTap) => GestureDetector(
    onTap: onTap,
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 48, height: 48, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withOpacity(.2)),
        child: Icon(icon, color: Colors.white, size: 22)),
      const SizedBox(height: 4),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
    ]),
  );

  Widget _card(bool isDark, List<Widget> children) => Container(
    color: isDark ? AppColors.cardDark : Colors.white,
    child: Column(children: children),
  );
}

// Search + add members to a group
class _AddMemberSheet extends StatefulWidget {
  final int convId;
  final VoidCallback onAdded;
  const _AddMemberSheet({required this.convId, required this.onAdded});
  @override
  State<_AddMemberSheet> createState() => _AddMemberSheetState();
}

class _AddMemberSheetState extends State<_AddMemberSheet> {
  List<User> _results = [];
  bool _searching = false;

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) { setState(() => _results = []); return; }
    setState(() => _searching = true);
    try { _results = await ApiService.searchUsers(q.trim()); } catch (_) {}
    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(height: MediaQuery.of(context).size.height * .7, child: Column(children: [
        const SizedBox(height: 12),
        const Text('Add members', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        Padding(padding: const EdgeInsets.all(12),
          child: TextField(autofocus: true, decoration: const InputDecoration(hintText: 'Search by name or username', prefixIcon: Icon(Icons.search)), onChanged: _search)),
        if (_searching) const LinearProgressIndicator(),
        Expanded(child: ListView(children: _results.map((u) => ListTile(
          leading: AvatarWidget(imageUrl: u.avatar, name: u.displayName, size: 42),
          title: Text(u.displayName),
          subtitle: u.username != null ? Text('@${u.username}') : null,
          trailing: const Icon(Icons.add_circle_outline, color: AppColors.primary),
          onTap: () async {
            await ApiService.groupAddMember(widget.convId, u.id).catchError((_) => <String, dynamic>{});
            widget.onAdded();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${u.displayName} added')));
              Navigator.pop(context);
            }
          },
        )).toList())),
      ])),
    );
  }
}
