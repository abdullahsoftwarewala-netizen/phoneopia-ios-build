import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../services/account_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import 'login_screen.dart';
import 'home_screen.dart';

class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key});
  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

class _AccountsScreenState extends State<AccountsScreen> {
  final _accounts = AccountService();
  List<StoredAccount> _list = [];
  int? _activeId;
  bool _loading = true;
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    _list = await _accounts.loadAccounts();
    _activeId = await _accounts.activeUserId() ?? context.read<AppProvider>().me?.id;
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _switchTo(StoredAccount a) async {
    if (a.userId == _activeId || _switching) return;
    setState(() => _switching = true);   // show overlay so a single tap is enough
    final ok = await context.read<AppProvider>().switchToAccount(a.userId);
    if (!mounted) return;
    setState(() => _switching = false);
    if (ok) {
      // Full rebuild on the new account — pop to a fresh HomeScreen so no screen
      // keeps the previous account's cached _me / chats (the "old account still
      // shows after switching" bug). This is the auto-reload.
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not switch account'), behavior: SnackBarBehavior.floating),
      );
    }
  }

  Future<void> _addAccount() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen(addingAccount: true)),
    );
    await _reload();
  }

  Future<void> _remove(StoredAccount a) async {
    final isActive = a.userId == _activeId;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dlg) => AlertDialog(
        title: const Text('Remove account?'),
        content: Text('Remove ${a.displayName} from this device?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlg, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dlg, true),
            child: const Text('Remove', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await context.read<AppProvider>().removeAccount(a.userId);
    if (!mounted) return;
    if (isActive) {
      Navigator.pop(context);
    } else {
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: Text('Accounts', style: TextStyle(
          fontWeight: FontWeight.w700,
          color: isDark ? AppColors.t1Dark : AppColors.t1Light,
        )),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
      ),
      body: Stack(children: [
        _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text(
                  'Add more accounts and switch anytime. Messages from all accounts can notify you.',
                  style: TextStyle(fontSize: 13, color: isDark ? AppColors.t3Dark : AppColors.t3Light, height: 1.4),
                ),
                const SizedBox(height: 16),
                ..._list.map((a) => _accountTile(a, isDark)),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _addAccount,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Add another account'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.primary,
                    side: const BorderSide(color: AppColors.primary),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ],
            ),
        if (_switching)
          Positioned.fill(child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
              SizedBox(height: 14),
              Text('Switching account…', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ])),
          )),
      ]),
    );
  }

  Widget _accountTile(StoredAccount a, bool isDark) {
    final active = a.userId == _activeId;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: isDark ? AppColors.cardDark : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: active ? AppColors.primary : (isDark ? Colors.white12 : const Color(0xFFE7EBEE)),
          width: active ? 1.5 : 1,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: AvatarWidget(imageUrl: a.avatar, name: a.displayName, size: 46),
        title: Text(a.displayName, style: TextStyle(
          fontWeight: FontWeight.w600,
          color: isDark ? AppColors.t1Dark : AppColors.t1Light,
        )),
        subtitle: Text(
          'ID #${a.userId} · @${a.username}',
          style: TextStyle(fontSize: 12, color: isDark ? AppColors.t3Dark : AppColors.t3Light),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.primaryDim,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text('Active', style: TextStyle(color: AppColors.primary, fontSize: 11, fontWeight: FontWeight.w700)),
              )
            else
              TextButton(onPressed: () => _switchTo(a), child: const Text('Use')),
            IconButton(
              icon: Icon(Icons.delete_outline, color: isDark ? AppColors.t3Dark : AppColors.t3Light, size: 20),
              onPressed: () => _remove(a),
            ),
          ],
        ),
        onTap: active ? null : () => _switchTo(a),
      ),
    );
  }
}