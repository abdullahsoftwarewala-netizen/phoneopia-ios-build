import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import 'chat_screen.dart';
import 'add_contact_screen.dart';
import 'my_account_qr_screen.dart';
import '../utils/page_routes.dart';

class NewChatScreen extends StatefulWidget {
  const NewChatScreen({super.key});
  @override
  State<NewChatScreen> createState() => _NewChatScreenState();
}

const _kCountries = [
  {'flag': '🇵🇰', 'name': 'Pakistan', 'code': '+92'},
  {'flag': '🇺🇸', 'name': 'USA', 'code': '+1'},
  {'flag': '🇬🇧', 'name': 'UK', 'code': '+44'},
  {'flag': '🇸🇦', 'name': 'Saudi Arabia', 'code': '+966'},
  {'flag': '🇦🇪', 'name': 'UAE', 'code': '+971'},
  {'flag': '🇮🇳', 'name': 'India', 'code': '+91'},
  {'flag': '🇧🇩', 'name': 'Bangladesh', 'code': '+880'},
  {'flag': '🇦🇫', 'name': 'Afghanistan', 'code': '+93'},
  {'flag': '🇩🇪', 'name': 'Germany', 'code': '+49'},
  {'flag': '🇫🇷', 'name': 'France', 'code': '+33'},
  {'flag': '🇨🇦', 'name': 'Canada', 'code': '+1'},
  {'flag': '🇦🇺', 'name': 'Australia', 'code': '+61'},
  {'flag': '🇶🇦', 'name': 'Qatar', 'code': '+974'},
  {'flag': '🇰🇼', 'name': 'Kuwait', 'code': '+965'},
  {'flag': '🇧🇭', 'name': 'Bahrain', 'code': '+973'},
  {'flag': '🇴🇲', 'name': 'Oman', 'code': '+968'},
  {'flag': '🇯🇴', 'name': 'Jordan', 'code': '+962'},
  {'flag': '🇪🇬', 'name': 'Egypt', 'code': '+20'},
  {'flag': '🇳🇬', 'name': 'Nigeria', 'code': '+234'},
  {'flag': '🇿🇦', 'name': 'South Africa', 'code': '+27'},
  {'flag': '🇹🇷', 'name': 'Turkey', 'code': '+90'},
  {'flag': '🇮🇩', 'name': 'Indonesia', 'code': '+62'},
  {'flag': '🇲🇾', 'name': 'Malaysia', 'code': '+60'},
  {'flag': '🇸🇬', 'name': 'Singapore', 'code': '+65'},
];

class _NewChatScreenState extends State<NewChatScreen> {
  final _phoneCtrl = TextEditingController();
  Map<String, String> _country = _kCountries[0]; // Pakistan default
  User? _found;
  bool _loading = false;
  String? _err;

  final _filterCtrl = TextEditingController();
  List<User> _contacts = [];
  bool _loadingContacts = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _filterCtrl.addListener(() => setState(() {}));
  }

  Future<void> _loadContacts() async {
    try {
      var r = await ApiService.get('users.php?action=contacts');
      if (r['success'] != true) {
        // A failed fetch (stale auth token right after a fresh install +
        // login, a brief network hiccup) looked identical to "you have no
        // contacts" — nothing distinguished the two, and there was no
        // retry. Try once more shortly before actually showing empty.
        await Future.delayed(const Duration(seconds: 2));
        if (!mounted) return;
        r = await ApiService.get('users.php?action=contacts');
      }
      final list = (r['contacts'] as List?) ?? [];
      if (mounted)
        setState(() {
          _contacts = list
              .map((c) => User.fromJson(Map<String, dynamic>.from(c)))
              .toList();
          _loadingContacts = false;
        });
    } catch (_) {
      if (mounted) setState(() => _loadingContacts = false);
    }
  }

  List<User> get _filteredContacts {
    final q = _filterCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return _contacts;
    final qd = q.replaceAll(RegExp(r'\D'), '');
    return _contacts
        .where(
          (u) =>
              u.displayName.toLowerCase().contains(q) ||
              (qd.isNotEmpty &&
                  (u.phone ?? '').replaceAll(RegExp(r'\D'), '').contains(qd)),
        )
        .toList();
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final raw = _phoneCtrl.text.trim();
    if (raw.isEmpty) return;
    setState(() {
      _loading = true;
      _err = null;
      _found = null;
    });
    final fullPhone = '${_country['code']}$raw';
    try {
      final r = await ApiService.get(
        'users.php?action=search_by_phone',
        params: {'phone': fullPhone},
      );
      if (!mounted) return;
      if (r['success'] == true && r['user'] != null) {
        setState(() {
          _found = User.fromJson(Map<String, dynamic>.from(r['user']));
          _loading = false;
        });
      } else {
        setState(() {
          _err = 'No user found with this number';
          _loading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _err = 'Network error';
        _loading = false;
      });
    }
  }

  Future<void> _openChat(User user) async {
    final prov = context.read<AppProvider>();
    Conversation? existing;
    for (final c in prov.conversations) {
      if (c.type == 'direct' && c.otherUser?.id == user.id) {
        existing = c;
        break;
      }
    }
    if (existing != null) {
      if (mounted)
        Navigator.pushReplacement(
          context,
          chatRoute(ChatScreen(conversation: existing)),
        );
      return;
    }
    try {
      final r = await ApiService.createConversation(user.id);
      // Server returns conversation_id (not the full object)
      final convId = int.tryParse(r['conversation_id']?.toString() ?? '');
      if (r['success'] == true && convId != null) {
        await prov.loadConversations();
        Conversation? found;
        for (final c in prov.conversations) {
          if (c.id == convId) {
            found = c;
            break;
          }
        }
        final conv =
            found ??
            Conversation(
              id: convId,
              type: 'direct',
              name: user.displayName,
              otherUser: user,
            );
        prov.ensureConvInList(conv);
        if (mounted)
          Navigator.pushReplacement(
            context,
            chatRoute(ChatScreen(conversation: conv)),
          );
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(r['error']?.toString() ?? 'Could not open chat'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Network error')));
      }
    }
  }

  void _showCountryPicker() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Text(
              'Select Country',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: isDark ? AppColors.t1Dark : AppColors.t1Light,
              ),
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _kCountries.length,
              itemBuilder: (ctx, i) {
                final c = _kCountries[i];
                final sel =
                    c['code'] == _country['code'] &&
                    c['name'] == _country['name'];
                return ListTile(
                  leading: Text(
                    c['flag']!,
                    style: const TextStyle(fontSize: 24),
                  ),
                  title: Text(
                    c['name']!,
                    style: TextStyle(
                      fontWeight: sel ? FontWeight.w700 : FontWeight.normal,
                      color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                    ),
                  ),
                  trailing: Text(
                    c['code']!,
                    style: TextStyle(
                      color: sel
                          ? AppColors.primary
                          : (isDark ? AppColors.t3Dark : AppColors.t3Light),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  onTap: () {
                    setState(() {
                      _country = c;
                      _found = null;
                      _err = null;
                    });
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'New Chat',
          style: TextStyle(
            color: isDark ? AppColors.t1Dark : AppColors.t1Light,
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: IconThemeData(
          color: isDark ? AppColors.t1Dark : AppColors.t1Light,
        ),
      ),
      body: Column(
        children: [
          // Shareable account QR sits above Add Contact, so either person can
          // show their code or use the camera button on the QR screen.
          Container(
            color: isDark ? AppColors.cardDark : Colors.white,
            child: ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(
                    colors: [Color(0xFFE81235), Color(0xFFB9072A)],
                  ),
                ),
                child: const Icon(
                  Icons.qr_code_2_rounded,
                  color: Colors.white,
                  size: 29,
                ),
              ),
              title: const Text(
                'My Account QR',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                'Show your QR or scan someone else',
                style: TextStyle(
                  color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                  fontSize: 12,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: AppColors.primary,
              ),
              onTap: () => Navigator.push(
                context,
                slideRoute(const MyAccountQrScreen()),
              ),
            ),
          ),
          const Divider(height: 1),
          // New contact + AI shortcut
          Container(
            color: isDark ? AppColors.cardDark : Colors.white,
            child: ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primaryDim,
                ),
                child: const Icon(
                  Icons.person_add_alt_1,
                  color: AppColors.primaryDark,
                ),
              ),
              title: const Text(
                'New contact',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Add by name & number',
                style: TextStyle(
                  color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                  fontSize: 12,
                ),
              ),
              trailing: const Icon(
                Icons.chevron_right,
                color: AppColors.primary,
              ),
              onTap: () async {
                final added = await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AddContactScreen()),
                );
                if (added == true && mounted) {
                  context.read<AppProvider>().loadConversations();
                  _loadContacts();
                }
              },
            ),
          ),
          Container(
            color: isDark ? AppColors.cardDark : Colors.white,
            child: ListTile(
              leading: AvatarWidget(
                imageUrl: '/uploads/avatars/phoneopia_ai_logo.jpg',
                name: 'Phoneopia AI',
                size: 48,
                isAiBot: true,
              ),
              title: const Text(
                'Phoneopia AI',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                'Your smart AI assistant',
                style: TextStyle(
                  color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                  fontSize: 12,
                ),
              ),
              trailing: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primaryDim,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text(
                  'AI',
                  style: TextStyle(
                    color: AppColors.primaryDark,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              onTap: () async {
                final prov = context.read<AppProvider>();
                final r = await ApiService.post('ai.php?action=setup_bot', {});
                if (r['success'] == true) {
                  await prov.loadConversations();
                  final conv = prov.conversations.firstWhere(
                    (c) => c.otherUser?.isAiBot == true,
                    orElse: () =>
                        Conversation.fromJson(Map<String, dynamic>.from(r)),
                  );
                  if (mounted)
                    Navigator.pushReplacement(
                      context,
                      chatRoute(ChatScreen(conversation: conv)),
                    );
                }
              },
            ),
          ),
          const Divider(height: 1),

          // Search existing contacts
          Container(
            color: isDark ? AppColors.cardDark : Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: SizedBox(
              height: 46,
              child: TextField(
                controller: _filterCtrl,
                style: TextStyle(
                  color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                ),
                decoration: InputDecoration(
                  hintText: 'Search contacts…',
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 20,
                    color: AppColors.primary,
                  ),
                  filled: true,
                  fillColor: isDark ? AppColors.panelDark : AppColors.bgLight,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: AppColors.primary,
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),

          // Existing contacts list
          Expanded(
            child: _loadingContacts
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.primary),
                  )
                : _filteredContacts.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primaryDim,
                          ),
                          child: const Icon(
                            Icons.contacts_outlined,
                            size: 34,
                            color: AppColors.primaryDark,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _contacts.isEmpty ? 'No contacts yet' : 'No matches',
                          style: TextStyle(
                            fontSize: 15,
                            color: isDark
                                ? AppColors.t3Dark
                                : AppColors.t3Light,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Tap “New contact” to add one',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Colors.grey.shade400,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _filteredContacts.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 76),
                    itemBuilder: (_, i) {
                      final u = _filteredContacts[i];
                      return Container(
                        color: isDark ? AppColors.cardDark : Colors.white,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          leading: AvatarWidget(
                            imageUrl: u.avatar,
                            name: u.displayName,
                            size: 48,
                            showOnline: true,
                            status: u.status,
                          ),
                          title: Text(
                            u.displayName,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? AppColors.t1Dark
                                  : AppColors.t1Light,
                            ),
                          ),
                          subtitle: Text(
                            u.phone ?? '',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: isDark
                                  ? AppColors.t3Dark
                                  : AppColors.t3Light,
                            ),
                          ),
                          onTap: () => _openChat(u),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
