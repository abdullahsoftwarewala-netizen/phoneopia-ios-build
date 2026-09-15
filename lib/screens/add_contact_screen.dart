import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import '../utils/page_routes.dart';

const _countries = [
  {'flag': '🇵🇰', 'name': 'Pakistan', 'code': '+92'},
  {'flag': '🇺🇸', 'name': 'USA', 'code': '+1'},
  {'flag': '🇬🇧', 'name': 'UK', 'code': '+44'},
  {'flag': '🇸🇦', 'name': 'Saudi Arabia', 'code': '+966'},
  {'flag': '🇦🇪', 'name': 'UAE', 'code': '+971'},
  {'flag': '🇮🇳', 'name': 'India', 'code': '+91'},
  {'flag': '🇧🇩', 'name': 'Bangladesh', 'code': '+880'},
  {'flag': '🇦🇫', 'name': 'Afghanistan', 'code': '+93'},
  {'flag': '🇩🇪', 'name': 'Germany', 'code': '+49'},
  {'flag': '🇨🇦', 'name': 'Canada', 'code': '+1'},
  {'flag': '🇦🇺', 'name': 'Australia', 'code': '+61'},
  {'flag': '🇶🇦', 'name': 'Qatar', 'code': '+974'},
  {'flag': '🇰🇼', 'name': 'Kuwait', 'code': '+965'},
  {'flag': '🇹🇷', 'name': 'Turkey', 'code': '+90'},
  {'flag': '🇲🇾', 'name': 'Malaysia', 'code': '+60'},
];

/// Add a new contact by first/last name + country code + phone number.
/// Detects the user's own number and shows "+<num> (You)".
class AddContactScreen extends StatefulWidget {
  const AddContactScreen({super.key});
  @override
  State<AddContactScreen> createState() => _AddContactScreenState();
}

class _AddContactScreenState extends State<AddContactScreen> {
  final _first = TextEditingController();
  final _last = TextEditingController();
  final _phone = TextEditingController();
  Map<String, String> _country = _countries[0];
  bool _loading = false;
  String? _err;

  @override
  void initState() {
    super.initState();
    _phone.addListener(_onPhoneChanged);
  }

  void _onPhoneChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _first.dispose();
    _last.dispose();
    _phone.dispose();
    super.dispose();
  }

  String get _fullPhone => '${_country['code']}${_phone.text.trim().replaceAll(RegExp(r'^0+'), '')}';

  bool get _isSelf {
    final mine = (context.read<AppProvider>().me?.phone ?? '').replaceAll(RegExp(r'\D'), '').replaceAll(RegExp(r'^0+'), '');
    final entered = _fullPhone.replaceAll(RegExp(r'\D'), '').replaceAll(RegExp(r'^0+'), '');
    return mine.isNotEmpty && mine == entered;
  }

  void _pickCountry() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(child: ListView(shrinkWrap: true, children: [
        const SizedBox(height: 10),
        for (final c in _countries)
          ListTile(
            leading: Text(c['flag']!, style: const TextStyle(fontSize: 22)),
            title: Text(c['name']!),
            trailing: Text(c['code']!, style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
            onTap: () { setState(() => _country = c); Navigator.pop(context); },
          ),
      ])),
    );
  }

  Future<void> _add() async {
    final num = _phone.text.trim();
    if (num.length < 5) { setState(() => _err = 'Enter a valid phone number'); return; }
    if (_isSelf) { setState(() => _err = "That's your own number"); return; }
    setState(() { _loading = true; _err = null; });
    final name = [_first.text.trim(), _last.text.trim()].where((s) => s.isNotEmpty).join(' ').trim();
    try {
      final r = await ApiService.post('users.php?action=add_contact_by_phone', {
        'phone': _fullPhone,
        'nickname': name,
      });
      if (!mounted) return;
      if (r['is_self'] == true) {
        setState(() { _loading = false; _err = "That's your own number"; });
        return;
      }
      if (r['success'] == true && r['user'] != null) {
        final user = User.fromJson(Map<String, dynamic>.from(r['user']));
        final prov = context.read<AppProvider>();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r['existing'] == true ? 'Already in contacts' : '✅ ${user.displayName} added'),
          behavior: SnackBarBehavior.floating));
        // Open the chat with the new contact.
        String? openChatError;
        try {
          final cr = await ApiService.createConversation(user.id);
          final convId = int.tryParse(cr['conversation_id']?.toString() ?? '');
          if (convId != null) {
            await prov.loadConversations();
            final conv = prov.conversationById(convId) ??
                Conversation(id: convId, type: 'direct', name: user.displayName, otherUser: user);
            prov.ensureConvInList(conv);
            if (mounted) Navigator.pushReplacement(context, chatRoute(ChatScreen(conversation: conv)));
            return;
          }
          openChatError = cr['error']?.toString();
        } catch (_) {
          openChatError = 'Network error';
        }
        // Getting here means the contact WAS added but the chat couldn't be
        // opened automatically — silently popping back with no explanation
        // used to look exactly like nothing had happened at all, which is
        // why re-adding the same contact only ever surfaced "Already in
        // contacts" with still no chat in sight. Surface it instead, and
        // still refresh the contacts/conversations list so it's reachable
        // from "New Chat" even though we couldn't jump straight to it.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Contact save ho gaya, magar chat khulne mein masla hua'
                '${openChatError != null ? ' ($openChatError)' : ''} — "New Chat" list se khol lein.'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4)));
          Navigator.pop(context, true);
        }
      } else {
        setState(() { _loading = false; _err = r['error']?.toString() ?? 'Could not add contact'; });
      }
    } catch (_) {
      if (mounted) setState(() { _loading = false; _err = 'Network error. Try again.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final t1 = isDark ? AppColors.t1Dark : AppColors.t1Light;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: t1,
        surfaceTintColor: Colors.transparent,
        title: Text('New contact', style: TextStyle(color: t1, fontWeight: FontWeight.w700)),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _label('First name', isDark),
        _input(_first, 'First name', Icons.person_outline, isDark),
        const SizedBox(height: 14),
        _label('Last name', isDark),
        _input(_last, 'Last name (optional)', Icons.person_outline, isDark),
        const SizedBox(height: 14),
        _label('Phone number', isDark),
        Row(children: [
          GestureDetector(
            onTap: _pickCountry,
            child: Container(
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: isDark ? AppColors.panelDark : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withOpacity(.3)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_country['flag']!, style: const TextStyle(fontSize: 20)),
                const SizedBox(width: 6),
                Text(_country['code']!, style: TextStyle(fontWeight: FontWeight.w700, color: t1)),
                const Icon(Icons.expand_more, size: 18, color: AppColors.primary),
              ]),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: SizedBox(height: 54, child: TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            style: TextStyle(fontSize: 16, color: t1),
            decoration: InputDecoration(
              hintText: '3XX XXXXXXX',
              filled: true,
              fillColor: isDark ? AppColors.panelDark : Colors.white,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
            ),
          ))),
        ]),

        // Live preview — shows "(You)" for your own number.
        if (_phone.text.trim().isNotEmpty) Padding(
          padding: const EdgeInsets.only(top: 10, left: 4),
          child: Text(
            _isSelf ? '$_fullPhone (You)' : _fullPhone,
            style: TextStyle(
              color: _isSelf ? AppColors.primary : (isDark ? AppColors.t3Dark : AppColors.t3Light),
              fontWeight: _isSelf ? FontWeight.w700 : FontWeight.w500, fontSize: 13.5),
          ),
        ),

        if (_err != null) Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(_err!, style: const TextStyle(color: AppColors.danger, fontSize: 13))),
          ]),
        ),

        const SizedBox(height: 24),
        SizedBox(
          height: 52,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary, foregroundColor: Colors.white, elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: (_loading || _isSelf) ? null : _add,
            child: _loading
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                : const Text('Add contact', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }

  Widget _label(String t, bool isDark) => Padding(
    padding: const EdgeInsets.only(bottom: 6, left: 2),
    child: Text(t, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? AppColors.t3Dark : AppColors.t3Light)),
  );

  Widget _input(TextEditingController c, String hint, IconData icon, bool isDark) => TextField(
    controller: c,
    style: TextStyle(color: isDark ? AppColors.t1Dark : AppColors.t1Light),
    textCapitalization: TextCapitalization.words,
    decoration: InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: AppColors.primary, size: 20),
      filled: true,
      fillColor: isDark ? AppColors.panelDark : Colors.white,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.5)),
    ),
  );
}
