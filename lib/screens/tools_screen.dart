import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';
import '../services/api_service.dart';
import '../services/update_service.dart';
import '../widgets/update_dialog.dart';
import '../theme/app_theme.dart';

class ToolsScreen extends StatefulWidget {
  const ToolsScreen({super.key});
  @override
  State<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends State<ToolsScreen> {
  bool _loading = true;
  bool _arEnabled = false;
  String _training = '';
  String? _username;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await ApiService.toolsConfig();
      final c = r['config'] ?? {};
      _arEnabled = (c['autoreply_enabled'].toString() == '1');
      _training = c['autoreply_training']?.toString() ?? '';
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('phoneopia_user');
      if (raw != null) {
        final m = jsonDecode(raw.replaceAll("'", '"'));
        if (m is Map) _username = m['username']?.toString();
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  void _snack(String m, [bool ok = true]) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(m),
          backgroundColor: ok ? AppColors.primary : AppColors.danger,
          behavior: SnackBarBehavior.floating,
        ),
      );

  // ─────────────────────────── AUTO REPLY ───────────────────────────
  Future<void> _openAutoReply() async {
    final ctrl = TextEditingController(text: _training);
    bool on = _arEnabled;
    await _sheet(
      'Auto Reply',
      'AI aapke messages ka jawab khud dega — apne hisaab se train karein.',
      (ctx, setS) => [
        TextField(
          controller: ctrl,
          maxLines: 5,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText:
                'Apne / business ke baare mein likhein:\n- Naam, kya bechte ho\n- Timing, delivery\n- Kaise jawab dena hai',
          ),
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Auto reply',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('Jab koi message bheje, AI khud jawab dega'),
          value: on,
          activeColor: AppColors.primary,
          onChanged: (v) => setS(() => on = v),
        ),
        const SizedBox(height: 6),
        _saveBtn('Save', () async {
          final t = ctrl.text.trim();
          if (on && t.isEmpty) {
            _snack('Pehle train karein (info likhein)', false);
            return;
          }
          final r = await ApiService.toolsSaveAutoreply(on, t);
          if (r['config'] != null) {
            setState(() {
              _arEnabled = on;
              _training = t;
            });
            if (mounted) Navigator.pop(ctx);
            _snack(on ? 'Auto reply ON ✅' : 'Saved');
          } else {
            _snack(r['error']?.toString() ?? 'Failed', false);
          }
        }),
      ],
    );
  }

  // ─────────────────────────── SWITCH TO BUSINESS (full business OS) ──
  // Mirrors the web "Switch to Business Profile": free website
  // (phoneopia.com/yourname), site admin, products & orders — all backed
  // by /api/biz so mobile and web share the same business.
  Future<void> _openBusinessProfile() async {
    _snack('Loading…');
    try {
      final r = await ApiService.get('biz.php?action=get');
      final biz = r['business'];
      if (!mounted) return;
      if (biz is Map) {
        _bizDashboard(Map<String, dynamic>.from(biz));
      } else {
        _bizSetupForm(null);
      }
    } catch (_) {
      _snack('Could not load business. Check your connection.', false);
    }
  }

  Future<void> _openUrl(String? url) async {
    if (url == null || url.isEmpty) return;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      Clipboard.setData(ClipboardData(text: url));
      _snack('Link copied ✅');
    }
  }

  void _bizSetupForm(Map<String, dynamic>? p) {
    final name = TextEditingController(
      text: p?['business_name']?.toString() ?? '',
    );
    final cat = TextEditingController(text: p?['category']?.toString() ?? '');
    final bio = TextEditingController(text: p?['bio']?.toString() ?? '');
    final phone = TextEditingController(
      text: p?['biz_phone']?.toString() ?? '',
    );
    final email = TextEditingController(
      text: p?['biz_email']?.toString() ?? '',
    );
    final addr = TextEditingController(text: p?['address']?.toString() ?? '');
    final editing = p != null;
    _sheet(
      editing ? 'Edit business details' : 'Switch to Business',
      'Get a free website (phoneopia.com/yourname), take orders, and manage everything from Phoneopia.',
      (ctx, setS) => [
        _field(name, 'Business name *', Icons.store),
        _field(cat, 'Category (Restaurant, Shop…)', Icons.category_outlined),
        _field(bio, 'About', Icons.info_outline),
        _field(phone, 'Phone', Icons.phone_outlined),
        _field(email, 'Email', Icons.email_outlined),
        _field(addr, 'Address', Icons.location_on_outlined),
        const SizedBox(height: 8),
        _saveBtn(editing ? 'Save' : 'Create business profile', () async {
          final n = name.text.trim();
          if (n.isEmpty) {
            _snack('Business name required', false);
            return;
          }
          final resp = await ApiService.post('biz.php?action=create', {
            'business_name': n,
            'category': cat.text.trim(),
            'bio': bio.text.trim(),
            'biz_phone': phone.text.trim(),
            'biz_email': email.text.trim(),
            'address': addr.text.trim(),
          });
          if (resp['business'] is Map) {
            if (mounted) Navigator.pop(ctx);
            _snack(editing ? 'Saved ✅' : 'Business profile created 🎉');
            _bizDashboard(Map<String, dynamic>.from(resp['business']));
          } else {
            _snack(resp['error']?.toString() ?? 'Failed', false);
          }
        }),
      ],
    );
  }

  void _bizDashboard(Map<String, dynamic> b) {
    final slug = b['site_slug']?.toString();
    final siteUrl = b['site_url']?.toString();
    final apiKey = b['api_key']?.toString() ?? '';
    _sheet(
      'Business — ${b['business_name'] ?? ''}',
      'Manage your website, orders and details.',
      (ctx, setS) => [
        if (slug != null && slug.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primaryDim,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your website is live',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  siteUrl ?? '',
                  style: const TextStyle(
                    color: AppColors.primaryDark,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('View site'),
                        onPressed: () => _openUrl(siteUrl),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(
                          Icons.admin_panel_settings_outlined,
                          size: 16,
                        ),
                        label: const Text('Site admin'),
                        onPressed: () => _openUrl('$siteUrl/admin'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          _saveBtn('🌐  Create your free website', () {
            Navigator.pop(ctx);
            _bizSiteForm();
          }),
          const SizedBox(height: 12),
        ],
        _dashBtn(Icons.shopping_bag_outlined, 'View orders', () {
          Navigator.pop(ctx);
          _bizOrders();
        }),
        _dashBtn(Icons.inventory_2_outlined, 'Products', () {
          Navigator.pop(ctx);
          _bizProducts();
        }),
        _dashBtn(Icons.edit_outlined, 'Edit business details', () {
          Navigator.pop(ctx);
          _bizSetupForm(b);
        }),
        const SizedBox(height: 12),
        if (apiKey.isNotEmpty)
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: apiKey));
              _snack('API key copied ✅');
            },
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.grey.withOpacity(.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  const Icon(Icons.key, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      apiKey,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  const Icon(Icons.copy, size: 15, color: Colors.grey),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _dashBtn(IconData ic, String label, VoidCallback onTap) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.all(13),
          alignment: Alignment.centerLeft,
        ),
        icon: Icon(ic, size: 18),
        label: Text(label),
        onPressed: onTap,
      ),
    ),
  );

  void _bizSiteForm() {
    final slug = TextEditingController();
    String tmpl = 'auto';
    const templates = {
      'auto': 'Auto (recommended)',
      'phoneopia': 'Phoneopia (red)',
      'ocean': 'Ocean (blue)',
      'emerald': 'Emerald (green)',
      'violet': 'Violet',
      'sunset': 'Sunset',
      'slate': 'Slate (dark)',
    };
    _sheet(
      'Create your website',
      'Pick a web address and design. Your site: phoneopia.com/yourname',
      (ctx, setS) => [
        _field(slug, 'Site name (e.g. yourname)', Icons.link),
        const SizedBox(height: 4),
        DropdownButtonFormField<String>(
          value: tmpl,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Design template',
          ),
          items: templates.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: (v) => setS(() => tmpl = v ?? 'auto'),
        ),
        const SizedBox(height: 12),
        _saveBtn('Publish website', () async {
          final s = slug.text.trim();
          if (s.length < 3) {
            _snack('Site name at least 3 letters', false);
            return;
          }
          final r = await ApiService.post('biz.php?action=create_site', {
            'slug': s,
            'template': tmpl,
          });
          if (r['site_url'] != null) {
            if (mounted) Navigator.pop(ctx);
            _bizSiteLive(r);
          } else {
            _snack(r['error']?.toString() ?? 'Failed', false);
          }
        }),
      ],
    );
  }

  void _bizSiteLive(Map<String, dynamic> r) {
    _sheet(
      'Website is live 🎉',
      'Save your admin login — you\'ll need it to manage products & orders.',
      (ctx, setS) => [
        SelectableText(
          r['site_url']?.toString() ?? '',
          style: const TextStyle(
            color: AppColors.primaryDark,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.primaryDim,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Admin login',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              _credRow('Panel', r['admin_url']?.toString() ?? '', isUrl: true),
              _credRow('Username', r['admin_user']?.toString() ?? ''),
              _credRow('Password', r['admin_pass']?.toString() ?? ''),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _saveBtn('Done', () async {
          if (mounted) Navigator.pop(ctx);
          _openBusinessProfile();
        }),
      ],
    );
  }

  Widget _credRow(String label, String value, {bool isUrl = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: Colors.grey[700]),
          ),
        ),
        Expanded(
          child: isUrl
              ? InkWell(
                  onTap: () => _openUrl(value),
                  child: Text(
                    value,
                    style: const TextStyle(
                      color: AppColors.primaryDark,
                      fontSize: 12.5,
                    ),
                  ),
                )
              : SelectableText(
                  value,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
        ),
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: const Icon(Icons.copy, size: 15, color: Colors.grey),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: value));
            _snack('Copied ✅');
          },
        ),
      ],
    ),
  );

  Future<void> _bizOrders() async {
    _snack('Loading orders…');
    List orders = [];
    try {
      final r = await ApiService.get('biz.php?action=orders');
      orders = (r['orders'] as List?) ?? [];
    } catch (_) {}
    if (!mounted) return;
    _sheet(
      'Orders',
      orders.isEmpty ? 'No orders yet.' : '${orders.length} order(s).',
      (ctx, setS) => [
        if (orders.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Share your website link so customers can order.',
              style: TextStyle(color: Colors.grey[600]),
            ),
          )
        else
          ...orders.map((o) {
            final total = double.tryParse('${o['total'] ?? 0}') ?? 0;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.withOpacity(.2)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '#${o['id']}  ${o['customer_name'] ?? 'Customer'}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.grey.withOpacity(.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${o['status'] ?? ''}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  if ((o['customer_phone'] ?? '').toString().isNotEmpty)
                    Text(
                      '${o['customer_phone']}',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey[600]),
                    ),
                  if (total > 0)
                    Text(
                      'Rs ${total.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: AppColors.primaryDark,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            );
          }),
      ],
    );
  }

  Future<void> _bizProducts() async {
    _snack('Loading products…');
    List products = [];
    try {
      final r = await ApiService.get('biz.php?action=products');
      products = (r['products'] as List?) ?? [];
    } catch (_) {}
    if (!mounted) return;
    final name = TextEditingController();
    final price = TextEditingController();
    final desc = TextEditingController();
    _sheet(
      'Products',
      'Add products that appear on your website.',
      (ctx, setS) => [
        if (products.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'No products yet.',
              style: TextStyle(color: Colors.grey[600]),
            ),
          )
        else
          ...products.map((p) {
            final pr = double.tryParse('${p['price'] ?? 0}') ?? 0;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text('${p['name']}'),
              subtitle: pr > 0 ? Text('Rs ${pr.toStringAsFixed(0)}') : null,
              trailing: IconButton(
                icon: const Icon(
                  Icons.delete_outline,
                  color: AppColors.danger,
                  size: 20,
                ),
                onPressed: () async {
                  await ApiService.post('biz.php?action=delete_product', {
                    'id': p['id'],
                  });
                  Navigator.pop(ctx);
                  _bizProducts();
                },
              ),
            );
          }),
        const Divider(),
        _field(name, 'Product name', Icons.inventory_2_outlined),
        _field(price, 'Price (Rs)', Icons.sell_outlined),
        _field(desc, 'Short description', Icons.notes_outlined),
        const SizedBox(height: 4),
        _saveBtn('+ Add product', () async {
          final n = name.text.trim();
          if (n.isEmpty) {
            _snack('Name required', false);
            return;
          }
          final r = await ApiService.post('biz.php?action=add_product', {
            'name': n,
            'price':
                double.tryParse(
                  price.text.trim().replaceAll(RegExp(r'[^0-9.]'), ''),
                ) ??
                0,
            'description': desc.text.trim(),
          });
          if (r['id'] != null) {
            Navigator.pop(ctx);
            _snack('Product added ✅');
            _bizProducts();
          } else {
            _snack(r['error']?.toString() ?? 'Failed', false);
          }
        }),
      ],
    );
  }

  // ─────────────────────────── SHAREABLE LINK ───────────────────────
  Future<void> _shareLink() async {
    final link = '${AppConfig.mediaBase}/?chat=${_username ?? ''}';
    await _sheet(
      'Reach more customers',
      'Share this link — anyone who taps it opens a chat with you.',
      (ctx, setS) => [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.primaryDim,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  link,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, color: AppColors.primaryDark),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: link));
                  _snack('Link copied ✅');
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _saveBtn('Share link', () async {
          final wa = Uri.parse(
            'https://wa.me/?text=${Uri.encodeComponent("Chat with me on Phoneopia: $link")}',
          );
          if (await canLaunchUrl(wa)) {
            await launchUrl(wa, mode: LaunchMode.externalApplication);
          } else {
            Clipboard.setData(ClipboardData(text: link));
            _snack('Link copied ✅');
          }
          if (mounted) Navigator.pop(ctx);
        }),
      ],
    );
  }

  // ─────────────────────────── LIST MANAGERS (quick replies / labels / catalogue) ───
  Future<void> _openListManager({
    required String key,
    required String title,
    required String desc,
    required String addHint,
    required IconData icon,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> items = prefs.getStringList(key) ?? [];
    final ctrl = TextEditingController();
    if (!mounted) return;
    await _sheet(
      title,
      desc,
      (ctx, setS) => [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: addHint,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              style: IconButton.styleFrom(backgroundColor: AppColors.primary),
              icon: const Icon(Icons.add),
              onPressed: () async {
                final v = ctrl.text.trim();
                if (v.isEmpty) return;
                items = [...items, v];
                await prefs.setStringList(key, items);
                ctrl.clear();
                setS(() {});
              },
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'Nothing yet — add above.',
              style: TextStyle(color: Colors.grey[600]),
            ),
          )
        else
          ...items.asMap().entries.map(
            (e) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon, color: AppColors.primaryDark, size: 20),
              title: Text(e.value),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                onPressed: () async {
                  items = [...items]..removeAt(e.key);
                  await prefs.setStringList(key, items);
                  setS(() {});
                },
              ),
              onTap: () {
                Clipboard.setData(ClipboardData(text: e.value));
                _snack('Copied');
              },
            ),
          ),
      ],
    );
  }

  Future<void> _helpCentre() async {
    final uri = Uri.parse(
      'mailto:alyan@rehanfoundation.com?subject=Phoneopia%20Business%20Help',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _snack('Email: alyan@rehanfoundation.com');
    }
  }

  // ─────────────────────────── SHARED UI HELPERS ────────────────────
  Future<void> _sheet(
    String title,
    String desc,
    List<Widget> Function(BuildContext, StateSetter) body,
  ) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.only(
            left: 18,
            right: 18,
            top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 18,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.withOpacity(.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: TextStyle(color: Colors.grey[600], fontSize: 13),
                ),
                const SizedBox(height: 16),
                ...body(ctx, setS),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, IconData icon) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      controller: c,
      decoration: InputDecoration(
        border: const OutlineInputBorder(),
        labelText: hint,
        prefixIcon: Icon(icon, size: 20),
      ),
    ),
  );

  Widget _saveBtn(String label, VoidCallback onTap) => SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.all(14),
      ),
      onPressed: onTap,
      child: Text(label),
    ),
  );

  Widget _tool(
    IconData ic,
    Color c,
    String title,
    String desc, {
    Widget? trailing,
    VoidCallback? onTap,
    VoidCallback? onLongPress,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: isDark ? AppColors.cardDark : Colors.white,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(ic, color: c, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      desc,
                      style: TextStyle(
                        color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              trailing ??
                  Icon(
                    Icons.chevron_right,
                    color: isDark ? AppColors.t3Dark : AppColors.t4Light,
                    size: 22,
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
    child: Text(
      t,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: AppColors.t3Light,
        letterSpacing: 0.8,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Keep this screen friendly and focused: only the two useful controls are
    // exposed; legacy business/transcription handlers remain unused.
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: Text(
          'Tools',
          style: TextStyle(
            color: isDark ? AppColors.t1Dark : AppColors.t1Light,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _section('AUTOMATION'),
                _tool(
                  Icons.smart_toy,
                  const Color(0xFF0E9F6E),
                  'Auto Reply',
                  'AI khud jawab de',
                  trailing: Text(
                    _arEnabled ? 'ON' : 'OFF',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _arEnabled ? AppColors.primary : Colors.grey,
                    ),
                  ),
                  onTap: _openAutoReply,
                ),
                _section('APP'),
                _tool(
                  Icons.system_update_outlined,
                  const Color(0xFF2563EB),
                  'Check for Updates',
                  'Latest Phoneopia version dekhein',
                  onTap: _checkForUpdate,
                ),
              ],
            ),
    );
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        title: Text(
          'Business tools',
          style: TextStyle(
            color: isDark ? AppColors.t1Dark : AppColors.t1Light,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
        foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
        surfaceTintColor: Colors.transparent,
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _section('AUTOMATION'),
                const SizedBox(height: 4),
                _tool(
                  Icons.smart_toy,
                  const Color(0xFF0E9F6E),
                  'Auto Reply',
                  'AI khud jawab de — apne hisaab se train karein',
                  trailing: Text(
                    _arEnabled ? 'ON' : 'OFF',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _arEnabled ? AppColors.primary : Colors.grey,
                    ),
                  ),
                  onTap: _openAutoReply,
                ),
                const SizedBox(height: 8),
                _section('BUSINESS TOOLS'),
                const SizedBox(height: 4),
                _tool(
                  Icons.campaign_outlined,
                  const Color(0xFF0EA5E9),
                  'Reach more customers',
                  'Create a shareable link to your chat',
                  onTap: _shareLink,
                ),

                _section('SUPPORT'),
                _tool(
                  Icons.help_outline,
                  const Color(0xFF64748B),
                  'Business help centre',
                  'Get help, contact us',
                  onTap: _helpCentre,
                ),

                _section('APP'),
                _tool(
                  Icons.system_update_outlined,
                  const Color(0xFF2563EB),
                  'Updates',
                  'Check for the latest version',
                  onTap: _checkForUpdate,
                ),
              ],
            ),
    );
  }

  // White/black/red — same palette as the update panel itself, distinct
  // from _snack()'s red-background toast used everywhere else in this
  // screen (that inverted look was the actual mismatch being reported).
  void _updateSnack(String m, IconData icon) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(icon, color: AppColors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  m,
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: Colors.white,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
        ),
      );

  Future<void> _checkForUpdate() async {
    _updateSnack('Checking for update…', Icons.system_update_outlined);
    final info = await UpdateService().checkOnce(force: true);
    if (!mounted) return;
    if (info == null) {
      _updateSnack('You\'re on the latest version', Icons.check_circle_outline);
      return;
    }
    await showUpdateDialog(context, info);
  }
}
