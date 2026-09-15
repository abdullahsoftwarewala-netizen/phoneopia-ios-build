import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/brand_backdrop.dart';
import '../widgets/brand_logo_box.dart';
import '../widgets/verified_badge.dart';
import 'dev_login_scan_screen.dart';
import '../utils/gdrive_gate.dart';

// ── Country list ──────────────────────────────────────────────────────────────
const _countries = [
  ('🇵🇰', 'Pakistan',      '+92'),
  ('🇺🇸', 'United States', '+1'),
  ('🇬🇧', 'United Kingdom','+44'),
  ('🇦🇪', 'United Arab Emirates', '+971'),
  ('🇸🇦', 'Saudi Arabia',  '+966'),
  ('🇮🇳', 'India',         '+91'),
  ('🇨🇦', 'Canada',        '+1'),
  ('🇦🇺', 'Australia',     '+61'),
  ('🇩🇪', 'Germany',       '+49'),
  ('🇫🇷', 'France',        '+33'),
  ('🇮🇹', 'Italy',         '+39'),
  ('🇹🇷', 'Turkey',        '+90'),
  ('🇧🇷', 'Brazil',        '+55'),
  ('🇷🇺', 'Russia',        '+7'),
  ('🇨🇳', 'China',         '+86'),
  ('🇯🇵', 'Japan',         '+81'),
  ('🇰🇷', 'South Korea',   '+82'),
  ('🇧🇩', 'Bangladesh',    '+880'),
  ('🇲🇾', 'Malaysia',      '+60'),
  ('🇮🇩', 'Indonesia',     '+62'),
  ('🇪🇬', 'Egypt',         '+20'),
  ('🇳🇬', 'Nigeria',       '+234'),
  ('🇵🇭', 'Philippines',   '+63'),
  ('🇸🇬', 'Singapore',     '+65'),
  ('🇳🇱', 'Netherlands',   '+31'),
  ('🇪🇸', 'Spain',         '+34'),
  ('🇶🇦', 'Qatar',         '+974'),
  ('🇴🇲', 'Oman',          '+968'),
  ('🇰🇼', 'Kuwait',        '+965'),
  ('🇧🇭', 'Bahrain',       '+973'),
];

class LoginScreen extends StatefulWidget {
  final bool addingAccount;
  const LoginScreen({super.key, this.addingAccount = false});
  @override State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with TickerProviderStateMixin {
  final _phoneCtrl = TextEditingController();
  final List<TextEditingController> _otpCtrls = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _otpFocus = List.generate(6, (_) => FocusNode());

  (String, String, String) _country = _countries[0];

  bool _otpSent = false;
  bool _loading = false;
  String? _err;
  String _otpMethod = 'whatsapp'; // 'whatsapp' | 'sms'
  String _sentVia = 'whatsapp';
  int _resendSeconds = 0;
  Timer? _resendTimer;

  void _startResendCooldown() {
    _resendTimer?.cancel();
    setState(() => _resendSeconds = 30);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      if (_resendSeconds <= 1) { t.cancel(); setState(() => _resendSeconds = 0); }
      else setState(() => _resendSeconds--);
    });
  }

  bool _otpRequestAccepted(Map<String, dynamic> response) {
    return response['success'] == true ||
        response['dev_otp'] != null ||
        response['delivery_pending'] == true ||
        response['queued'] == true ||
        response['sent'] == true;
  }

  Future<void> _resendOtp() async {
    if (_resendSeconds > 0 || _loading) return;
    setState(() { _loading = true; _err = null; });
    final r = await ApiService.sendOtp(_fullPhone, method: _otpMethod);
    if (!mounted) return;
    if (_otpRequestAccepted(r)) {
      setState(() { _loading = false; _sentVia = r['method']?.toString() ?? _otpMethod; });
      _startResendCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Code resent'), duration: Duration(seconds: 2)));
    } else {
      setState(() { _loading = false; _err = (r['error'] ?? r['message'])?.toString() ?? 'Failed to resend code'; });
    }
  }

  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;
  late AnimationController _floatCtrl;
  late Animation<double> _floatAnim;

  String get _fullPhone => _country.$3 + _phoneCtrl.text.trim().replaceAll(RegExp(r'^0+'), '');

  @override
  void initState() {
    super.initState();
    _fadeCtrl  = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _fadeAnim  = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _floatCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
    _floatAnim = Tween<double>(begin: 0, end: -10).animate(CurvedAnimation(parent: _floatCtrl, curve: Curves.easeInOut));
    _fadeCtrl.forward();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _floatCtrl.dispose();
    _phoneCtrl.dispose();
    _resendTimer?.cancel();
    for (final c in _otpCtrls) c.dispose();
    for (final f in _otpFocus) f.dispose();
    super.dispose();
  }

  void _showCountryPicker() {
    final searchCtrl = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _CountryPickerSheet(
        selected: _country,
        searchCtrl: searchCtrl,
        onSelect: (c) { setState(() => _country = c); Navigator.pop(context); },
      ),
    );
  }

  Future<void> _sendOtp() async {
    final local = _phoneCtrl.text.trim();
    if (local.length < 5) { setState(() => _err = 'Enter a valid phone number'); return; }
    setState(() { _loading = true; _err = null; });
    try {
      final r = await ApiService.sendOtp(_fullPhone, method: _otpMethod);
      if (_otpRequestAccepted(r)) {
        setState(() {
          _otpSent = true;
          _loading = false;
          _sentVia = r['method']?.toString() ?? _otpMethod;
        });
        _startResendCooldown();
        _fadeCtrl.reset(); _fadeCtrl.forward();
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) _otpFocus[0].requestFocus();
        });
      } else {
        setState(() { _err = (r['error'] ?? r['message'])?.toString() ?? 'Failed to send OTP'; _loading = false; });
      }
    } catch (e) {
      setState(() { _err = 'Network error. Try again.'; _loading = false; });
    }
  }

  Future<void> _verifyOtp() async {
    final otp = _otpCtrls.map((c) => c.text).join();
    if (otp.length < 6) { setState(() => _err = 'Enter 6-digit code'); return; }
    setState(() { _loading = true; _err = null; });
    final result = await context.read<AppProvider>().loginWithResult(_fullPhone, otp);
    if (!mounted) return;
    if (result['success'] == true) {
      if (widget.addingAccount) {
        Navigator.of(context).pop(true);
      } else if (result['is_new_user'] == true) {
        Navigator.of(context).pushNamedAndRemoveUntil('/setup', (_) => false);
      } else {
        await ensureGDriveThenGoHome(context);
      }
    } else {
      setState(() {
        _loading = false;
        _err = result['error']?.toString() ?? 'Invalid OTP';
        // Clear all OTP boxes on error so user can retry
        for (final c in _otpCtrls) c.clear();
      });
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) _otpFocus[0].requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: BrandBackdrop(
        variant: BrandBackdropVariant.light,
        child: SafeArea(
            child: Stack(children: [
            FadeTransition(
              opacity: _fadeAnim,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(children: [
                  const SizedBox(height: 28),

                  // ── Brand icon (floating) ─────────────────────────────
                  AnimatedBuilder(
                    animation: _floatAnim,
                    builder: (_, child) => Transform.translate(
                      offset: Offset(0, _floatAnim.value),
                      child: child,
                    ),
                    child: const BrandLogoBox(size: 88, logoSize: 48, radius: 24),
                  ),

                  const SizedBox(height: 14),

                  // ── Brand name ────────────────────────────────────────
                  const Text(
                    'Phoneopia',
                    style: TextStyle(
                      color: Color(0xFF111B21), fontSize: 30,
                      fontWeight: FontWeight.w900, letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Connect. Share. Belong.',
                    style: TextStyle(color: Color(0xFF667781), fontSize: 14, fontWeight: FontWeight.w500),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 12),

                  // ── Developer credit ──────────────────────────────────
                  Container(
                    padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
                    decoration: BoxDecoration(
                      color: AppColors.primary.withOpacity(0.07),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppColors.primary.withOpacity(0.15)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const CircleAvatar(
                        radius: 12,
                        backgroundImage: AssetImage('assets/images/rehanallahwala.jpg'),
                      ),
                      const SizedBox(width: 7),
                      const Text('By Rehan Allahwala',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF111B21))),
                      const SizedBox(width: 4),
                      const VerifiedBadge(size: 14),
                    ]),
                  ),

                  const SizedBox(height: 20),

                  // ── Feature chips ─────────────────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _featureChip(Icons.bolt_rounded,       'Fast'),
                      const SizedBox(width: 10),
                      _featureChip(Icons.auto_awesome_rounded,'AI'),
                      const SizedBox(width: 10),
                      _featureChip(Icons.lock_rounded,        'Secure'),
                    ],
                  ),

                  const SizedBox(height: 32),

                  // ── Auth card ─────────────────────────────────────────
                  Container(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadii.card),
                      border: Border.all(color: const Color(0xFFEDEFF2), width: 1),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.primary.withOpacity(0.07),
                          blurRadius: 28, offset: const Offset(0, 12),
                        ),
                      ],
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      // Green top accent line (like web .auth-panel::before)
                      Container(
                        height: 2.5,
                        margin: const EdgeInsets.only(bottom: 22),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(2),
                          gradient: const LinearGradient(colors: [
                            Colors.transparent,
                            AppColors.primary,
                            AppColors.primaryDark,
                            Colors.transparent,
                          ]),
                        ),
                      ),

                      Text(
                        _otpSent ? 'Verification Code' : 'Enter Your Phone',
                        style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w800,
                          color: Color(0xFF111B21), letterSpacing: -0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _otpSent ? 'Code sent to $_fullPhone' : 'Enter your number to get started',
                        style: const TextStyle(fontSize: 13, color: Color(0xFF667781)),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),

                      // OTP sent — show WhatsApp delivery notice
                      if (_otpSent) ...[
                        Container(
                          margin: const EdgeInsets.only(bottom: 14),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          decoration: BoxDecoration(
                            color: AppColors.primaryDim,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppColors.primary.withOpacity(0.4)),
                          ),
                          child: Row(children: [
                            Icon(_sentVia == 'sms' ? Icons.sms_rounded : Icons.chat_bubble_rounded,
                                color: AppColors.primary, size: 20),
                            const SizedBox(width: 10),
                            Expanded(child: Text(
                              _sentVia == 'sms' ? 'Code sent via SMS' : 'Code sent to your WhatsApp',
                              style: const TextStyle(color: AppColors.primary, fontSize: 13, fontWeight: FontWeight.w600),
                            )),
                          ]),
                        ),
                      ],

                      if (!_otpSent) ...[
                        // ── Phone input row ─────────────────────────────
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            color: const Color(0xFFF7F8FA),
                            border: Border.all(color: const Color(0xFFE4E7EB), width: 1.2),
                          ),
                          child: Row(children: [
                            // Country code button
                            GestureDetector(
                              onTap: _showCountryPicker,
                              child: Container(
                                margin: const EdgeInsets.all(6),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: const Color(0xFFE4E7EB), width: 1),
                                ),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Text(_country.$1, style: const TextStyle(fontSize: 20)),
                                  const SizedBox(width: 6),
                                  Text(_country.$3, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF111B21))),
                                  const SizedBox(width: 2),
                                  const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: AppColors.primary),
                                ]),
                              ),
                            ),
                            // Number field
                            Expanded(
                              child: TextField(
                                controller: _phoneCtrl,
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Color(0xFF111B21), letterSpacing: 0.5),
                                decoration: const InputDecoration(
                                  hintText: '3XX XXXXXXX',
                                  hintStyle: TextStyle(color: Color(0xFF9AA5AD), fontWeight: FontWeight.w500, letterSpacing: 0.5),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  contentPadding: EdgeInsets.only(right: 14),
                                ),
                                onChanged: (_) => setState(() { _err = null; }),
                                onSubmitted: (_) => _sendOtp(),
                              ),
                            ),
                          ]),
                        ),

                        const SizedBox(height: 14),

                        // ── Delivery method toggle (WhatsApp / SMS) ──────
                        Row(children: [
                          Expanded(
                            child: _methodChip(
                              icon: Icons.chat_bubble_rounded,
                              label: 'WhatsApp',
                              selected: _otpMethod == 'whatsapp',
                              onTap: () => setState(() => _otpMethod = 'whatsapp'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _methodChip(
                              icon: Icons.sms_rounded,
                              label: 'SMS',
                              selected: _otpMethod == 'sms',
                              onTap: () => setState(() => _otpMethod = 'sms'),
                            ),
                          ),
                        ]),
                      ] else ...[
                        // ── OTP boxes ───────────────────────────────────
                        Row(
                          children: [
                            for (int i = 0; i < 6; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              Expanded(child: _otpBox(i)),
                            ],
                          ],
                        ),
                      ],

                      // ── Error message ───────────────────────────────
                      if (_err != null) ...[
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEF4444).withOpacity(0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFEF4444).withOpacity(0.2)),
                          ),
                          child: Row(children: [
                            const Icon(Icons.error_outline, color: Color(0xFFEF4444), size: 16),
                            const SizedBox(width: 8),
                            Flexible(child: Text(_err!, style: const TextStyle(color: Color(0xFFEF4444), fontSize: 13))),
                          ]),
                        ),
                      ],

                      const SizedBox(height: 22),

                      // ── Submit button ────────────────────────────────
                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: AppColors.primary,
                            disabledForegroundColor: Colors.white,
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          onPressed: _loading ? null : (_otpSent ? _verifyOtp : _sendOtp),
                          child: _loading
                              ? const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5)),
                                    SizedBox(width: 10),
                                    Text('Working...', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                  ],
                                )
                              : Text(
                                  _otpSent ? 'Verify & Login' : 'Send OTP',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                                ),
                        ),
                      ),

                      if (_otpSent) ...[
                        const SizedBox(height: 14),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 4,
                          runSpacing: 0,
                          children: [
                            TextButton(
                              onPressed: () => setState(() { _otpSent = false; _err = null; for (final c in _otpCtrls) c.clear(); }),
                              child: const Text('← Change Number',
                                  style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13)),
                            ),
                            TextButton(
                              onPressed: _loading ? null : () {
                                setState(() => _otpMethod = _sentVia == 'sms' ? 'whatsapp' : 'sms');
                                _sendOtp();
                              },
                              child: Text(
                                _sentVia == 'sms' ? 'Send via WhatsApp instead' : 'Send via SMS instead',
                                style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ),
                            TextButton(
                              onPressed: (_loading || _resendSeconds > 0) ? null : _resendOtp,
                              child: Text(
                                _resendSeconds > 0 ? 'Resend code in ${_resendSeconds}s' : 'Resend Code',
                                style: TextStyle(
                                  color: _resendSeconds > 0 ? const Color(0xFF8A949B) : AppColors.primary,
                                  fontWeight: FontWeight.w600, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ]),
                  ),

                  const SizedBox(height: 28),
                  Text.rich(
                    TextSpan(
                      text: 'By continuing you agree to our ',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF8A949B),
                        height: 1.45,
                      ),
                      children: [
                        TextSpan(
                          text: 'Terms',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () => launchUrl(Uri.parse('https://phoneopia.com/legal'), mode: LaunchMode.externalApplication),
                        ),
                        const TextSpan(
                          text: ' & ',
                          style: TextStyle(color: Color(0xFF8A949B)),
                        ),
                        TextSpan(
                          text: 'Privacy Policy',
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontWeight: FontWeight.w700,
                          ),
                          recognizer: TapGestureRecognizer()
                            ..onTap = () => launchUrl(Uri.parse('https://phoneopia.com/privacy'), mode: LaunchMode.externalApplication),
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                ]),
              ),
            ),
            // Back button when adding account
            if (widget.addingAccount) Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 2, left: 4),
                child: IconButton(
                  icon: const Icon(Icons.arrow_back_rounded, color: Color(0xFF111B21)),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            // 3-dot menu LAST so it sits above the scroll view and receives taps.
            if (!_otpSent && !widget.addingAccount) Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 2, right: 6),
                child: PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert, color: Color(0xFF111B21)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  color: Colors.white,
                  onSelected: (v) {
                    if (v == 'link') Navigator.of(context).pushNamed('/link_device');
                    if (v == 'scan') Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DevLoginScanScreen()));
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'link',
                      child: Row(children: [
                        Icon(Icons.qr_code_2_rounded, color: AppColors.primary, size: 20),
                        SizedBox(width: 12),
                        Text('Link as a device', style: TextStyle(fontWeight: FontWeight.w600)),
                      ]),
                    ),
                    const PopupMenuItem(
                      value: 'scan',
                      child: Row(children: [
                        Icon(Icons.qr_code_scanner_rounded, color: AppColors.primary, size: 20),
                        SizedBox(width: 12),
                        Text('Scan to log in', style: TextStyle(fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ],
                ),
              ),
            ),
            ]),
          ),
        ),
    );
  }

  Widget _methodChip({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          color: selected ? AppColors.primaryDim : const Color(0xFFF7F8FA),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.primary : const Color(0xFFE4E7EB),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 17, color: selected ? AppColors.primary : const Color(0xFF667781)),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.primary : const Color(0xFF667781),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _featureChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primaryDim,
        borderRadius: BorderRadius.circular(AppRadii.chip),
        border: Border.all(color: AppColors.primary.withOpacity(0.22), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: AppColors.primary, size: 15),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _otpBox(int i) {
    final filled = _otpCtrls[i].text.isNotEmpty;
    return SizedBox(
      height: 54,
      child: TextField(
        controller: _otpCtrls[i],
        focusNode: _otpFocus[i],
        keyboardType: TextInputType.number,
        autofillHints: const [AutofillHints.oneTimeCode],
        textAlign: TextAlign.center,
        maxLength: 1,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Color(0xFF111B21)),
        decoration: InputDecoration(
          counterText: '',
          filled: true,
          fillColor: filled ? AppColors.primaryDim : Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: filled ? AppColors.primary : Colors.transparent),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: filled ? AppColors.primary : AppColors.borderLight, width: filled ? 2 : 1),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.primary, width: 2),
          ),
          contentPadding: EdgeInsets.zero,
        ),
        onChanged: (v) {
          setState(() { _err = null; });
          if (v.isNotEmpty) {
            if (i < 5) {
              _otpFocus[i + 1].requestFocus();
            }
          } else if (i > 0) {
            _otpFocus[i - 1].requestFocus();
          }
        },
      ),
    );
  }
}

// ── Country Picker Bottom Sheet ───────────────────────────────────────────────
class _CountryPickerSheet extends StatefulWidget {
  final (String, String, String) selected;
  final TextEditingController searchCtrl;
  final void Function((String, String, String)) onSelect;
  const _CountryPickerSheet({required this.selected, required this.searchCtrl, required this.onSelect});
  @override State<_CountryPickerSheet> createState() => _CountryPickerSheetState();
}

class _CountryPickerSheetState extends State<_CountryPickerSheet> {
  late List<(String, String, String)> _filtered;

  @override
  void initState() {
    super.initState();
    _filtered = _countries.toList();
    widget.searchCtrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    widget.searchCtrl.removeListener(_onSearch);
    super.dispose();
  }

  void _onSearch() {
    final q = widget.searchCtrl.text.toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? _countries.toList()
          : _countries.where((c) => c.$2.toLowerCase().contains(q) || c.$3.contains(q)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(children: [
        // Handle
        Container(
          margin: const EdgeInsets.only(top: 12, bottom: 4),
          width: 40, height: 4,
          decoration: BoxDecoration(color: const Color(0xFFD1D7DB), borderRadius: BorderRadius.circular(2)),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Text('Select Country', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111B21))),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            controller: widget.searchCtrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Search country...',
              prefixIcon: const Icon(Icons.search, color: AppColors.primary),
              filled: true,
              fillColor: const Color(0xFFF0F2F5),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            itemCount: _filtered.length,
            itemBuilder: (_, i) {
              final c = _filtered[i];
              final isSel = c.$3 == widget.selected.$3 && c.$2 == widget.selected.$2;
              return ListTile(
                leading: Text(c.$1, style: const TextStyle(fontSize: 24)),
                title: Text(c.$2, style: TextStyle(
                  fontWeight: isSel ? FontWeight.w700 : FontWeight.w400,
                  color: const Color(0xFF111B21),
                )),
                trailing: Text(c.$3, style: const TextStyle(
                  color: AppColors.primary, fontWeight: FontWeight.w700, fontSize: 15,
                )),
                selected: isSel,
                selectedTileColor: AppColors.primaryDim,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                onTap: () => widget.onSelect(c),
              );
            },
          ),
        ),
      ]),
    );
  }
}
