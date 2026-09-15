import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';

/// Full-page contact editor — renames how a person shows up for you only
/// (like WhatsApp's "Edit contact"), checks whether their number is a real
/// Phoneopia account, and can save the same name/number to the phone's
/// native address book.
class EditContactScreen extends StatefulWidget {
  final Conversation conversation;
  const EditContactScreen({super.key, required this.conversation});
  @override State<EditContactScreen> createState() => _EditContactScreenState();
}

class _EditContactScreenState extends State<EditContactScreen> {
  late TextEditingController _firstCtrl;
  late TextEditingController _lastCtrl;
  late TextEditingController _phoneCtrl;
  String _countryCode = '+92';
  bool _saving = false;
  bool _syncing = false;

  bool? _existsOnPhoneopia; // null = checking
  bool _checkingExists = true;

  @override
  void initState() {
    super.initState();
    final prov = context.read<AppProvider>();
    final ou = widget.conversation.otherUser;
    final current = prov.nicknameFor(ou?.id ?? 0) ?? widget.conversation.displayName;
    final parts = current.trim().split(RegExp(r'\s+'));
    _firstCtrl = TextEditingController(text: parts.isNotEmpty ? parts.first : '');
    _lastCtrl = TextEditingController(text: parts.length > 1 ? parts.sublist(1).join(' ') : '');

    final rawPhone = ou?.phone ?? '';
    final match = RegExp(r'^(\+\d{1,4})(.*)$').firstMatch(rawPhone.trim());
    if (match != null) {
      _countryCode = match.group(1)!;
      _phoneCtrl = TextEditingController(text: match.group(2)!.trim());
    } else {
      _phoneCtrl = TextEditingController(text: rawPhone);
    }

    _checkExists();
  }

  Future<void> _checkExists() async {
    final phone = ('$_countryCode${_phoneCtrl.text.trim()}').trim();
    if (phone.isEmpty || phone == _countryCode) {
      setState(() { _existsOnPhoneopia = false; _checkingExists = false; });
      return;
    }
    setState(() => _checkingExists = true);
    try {
      final results = await ApiService.searchUsers(phone);
      final digits = phone.replaceAll(RegExp(r'\D'), '');
      final found = results.any((u) => (u.phone ?? '').replaceAll(RegExp(r'\D'), '').endsWith(digits.length > 7 ? digits.substring(digits.length - 7) : digits));
      if (mounted) setState(() { _existsOnPhoneopia = found; _checkingExists = false; });
    } catch (_) {
      if (mounted) setState(() { _existsOnPhoneopia = null; _checkingExists = false; });
    }
  }

  String get _fullName => '${_firstCtrl.text.trim()} ${_lastCtrl.text.trim()}'.trim();

  Future<void> _save() async {
    final ou = widget.conversation.otherUser;
    if (ou == null || _fullName.isEmpty) return;
    setState(() => _saving = true);
    await context.read<AppProvider>().setNickname(ou.id, _fullName);
    if (mounted) {
      setState(() => _saving = false);
      Navigator.pop(context);
    }
  }

  Future<void> _syncToPhone() async {
    if (_fullName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a name first'), behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _syncing = true);
    try {
      final granted = await FlutterContacts.requestPermission();
      if (!granted) {
        if (mounted) {
          setState(() => _syncing = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Contacts permission denied'), behavior: SnackBarBehavior.floating));
        }
        return;
      }
      final contact = Contact()
        ..name.first = _firstCtrl.text.trim()
        ..name.last = _lastCtrl.text.trim()
        ..phones = [Phone('$_countryCode${_phoneCtrl.text.trim()}')];
      await contact.insert();
      if (mounted) {
        setState(() => _syncing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved to phone contacts ✅'), behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _syncing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not sync: $e'), behavior: SnackBarBehavior.floating));
      }
    }
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: const Text('Edit contact'),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Save', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Expanded(child: _field(isDark, label: 'First name', controller: _firstCtrl)),
            const SizedBox(width: 12),
            Expanded(child: _field(isDark, label: 'Last name', controller: _lastCtrl)),
          ]),
          const SizedBox(height: 16),
          _fieldStatic(isDark, label: 'Full name', value: _fullName.isEmpty ? '—' : _fullName),
          const SizedBox(height: 16),
          Text('Phone number', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? AppColors.t3Dark : AppColors.t3Light)),
          const SizedBox(height: 6),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: isDark ? AppColors.cardDark : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? AppColors.borderDark : AppColors.borderLight),
              ),
              child: Text(_countryCode, style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => _checkExists(),
                style: TextStyle(color: isDark ? AppColors.t1Dark : AppColors.t1Light),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: isDark ? AppColors.cardDark : Colors.white,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? AppColors.borderDark : AppColors.borderLight)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? AppColors.borderDark : AppColors.borderLight)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.6)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Icon(
              _checkingExists ? Icons.hourglass_top_rounded : (_existsOnPhoneopia == true ? Icons.check_circle : Icons.info_outline),
              size: 16,
              color: _checkingExists ? (isDark ? AppColors.t3Dark : AppColors.t3Light) : (_existsOnPhoneopia == true ? AppColors.primary : (isDark ? AppColors.t3Dark : AppColors.t3Light)),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(
              _checkingExists
                  ? 'Checking Phoneopia…'
                  : (_existsOnPhoneopia == true ? 'This number exists on Phoneopia' : 'This number is not on Phoneopia'),
              style: TextStyle(fontSize: 12.5, color: isDark ? AppColors.t3Dark : AppColors.t3Light),
            )),
          ]),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _syncing ? null : _syncToPhone,
              icon: _syncing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync_rounded, color: AppColors.primary),
              label: const Text('Sync to phone', style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 14),
                side: const BorderSide(color: AppColors.primary),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(bool isDark, {required String label, required TextEditingController controller}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? AppColors.t3Dark : AppColors.t3Light)),
      const SizedBox(height: 6),
      TextField(
        controller: controller,
        onChanged: (_) => setState(() {}),
        style: TextStyle(color: isDark ? AppColors.t1Dark : AppColors.t1Light),
        decoration: InputDecoration(
          filled: true,
          fillColor: isDark ? AppColors.cardDark : Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? AppColors.borderDark : AppColors.borderLight)),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? AppColors.borderDark : AppColors.borderLight)),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 1.6)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
    ]);
  }

  Widget _fieldStatic(bool isDark, {required String label, required String value}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? AppColors.t3Dark : AppColors.t3Light)),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: isDark ? AppColors.bg2Dark : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(value, style: TextStyle(color: isDark ? AppColors.t1Dark : AppColors.t1Light, fontWeight: FontWeight.w600)),
      ),
    ]);
  }
}
