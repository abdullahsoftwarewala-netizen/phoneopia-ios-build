import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/verified_badge.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_loading.dart';
import '../widgets/animated_message.dart';
import '../utils/presence_text.dart';
import '../services/nearby_service.dart';
import '../services/bluetooth_service_native.dart';
import 'contact_info_screen.dart';
import 'video_player_screen.dart';
import 'active_call_screen.dart';
import 'group_call_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:geolocator/geolocator.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conversation;
  const ChatScreen({super.key, required this.conversation});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

String? _nonEmpty(String? s) => (s != null && s.isNotEmpty) ? s : null;

class _ChatScreenState extends State<ChatScreen> {
  late Conversation _conv;
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  final _recorder = AudioRecorder();
  bool _showEmoji = false;
  bool _isTyping = false;
  bool _sendLock = false;
  Timer? _typingTimer;
  bool _isRecording = false;
  int _recSecs = 0;
  Timer? _recTimer;
  String? _recPath;
  bool _loadingOlder = false;
  bool _hasMore = true;
  bool _showScrollBtn = false;
  Message? _replyTo;

  // Connectivity label + draft persistence — so an unsent message never
  // just vanishes, and it's always clear which transport a message will
  // actually go out over.
  List<ConnectivityResult> _connectivity = [];
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _offlineRecheckTimer;
  StreamSubscription<NearbyMessage>? _nearbySub;
  Timer? _draftSaveTimer;
  String get _draftKey => 'chat_draft_${conv.id}';

  // Slash-command popup (Phoneopia Business bot only)
  bool _showSlash = false;
  List<Map<String, String>> _slashItems = [];
  static const List<Map<String, String>> _slashAll = [
    {
      'cmd': '/addproduct',
      'icon': '🛍️',
      'desc': "Add a product — I'll ask the details",
    },
    {'cmd': '/products', 'icon': '📦', 'desc': 'List your products'},
    {'cmd': '/orders', 'icon': '🧾', 'desc': 'Recent orders'},
    {'cmd': '/site', 'icon': '🌐', 'desc': 'Your website link & status'},
    {
      'cmd': '/completesite',
      'icon': '✅',
      'desc': "What's left to finish your site",
    },
    {'cmd': '/editinfo', 'icon': '✏️', 'desc': 'Update phone, email, address'},
    {'cmd': '/cancel', 'icon': '❌', 'desc': 'Stop the current step'},
    {'cmd': '/help', 'icon': '❔', 'desc': 'Show all commands'},
  ];
  bool get _isBusinessBot {
    final u = conv.otherUser;
    if (u == null) return false;
    return u.username == 'phoneopia_business' ||
        conv.displayName.toLowerCase().contains('phoneopia business');
  }

  void _updateSlash(String v) {
    if (!_isBusinessBot || !v.startsWith('/')) {
      if (_showSlash) setState(() => _showSlash = false);
      return;
    }
    final q = v.substring(1).toLowerCase();
    final items = _slashAll
        .where((c) => c['cmd']!.substring(1).startsWith(q))
        .toList();
    setState(() {
      _slashItems = items;
      _showSlash = items.isNotEmpty;
    });
  }

  void _pickSlash(Map<String, String> c) {
    _ctrl.text = c['cmd']!;
    setState(() => _showSlash = false);
    _send();
  }

  Conversation get conv => _conv;

  @override
  void initState() {
    super.initState();
    _conv = widget.conversation;
    final prov = context.read<AppProvider>();
    final live = prov.conversationById(widget.conversation.id);
    if (live != null) _conv = prov.sanitizeConversation(live);
    prov.ensureConvInList(_conv);
    prov.setActiveChat(conv.id);
    unawaited(prov.refreshConversationMeta(conv.id));
    prov.loadMessages(
      conv.id,
      refresh: true,
      silent: prov.messagesFor(conv.id).isNotEmpty,
    );
    prov.markRead(conv.id);
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollDown(animate: false),
    );
    _restoreDraft();
    Connectivity().checkConnectivity().then((r) {
      if (!mounted) return;
      setState(() => _connectivity = r);
      _refreshTrueOfflineState();
    });
    _connSub = Connectivity().onConnectivityChanged.listen((r) {
      if (!mounted) return;
      setState(() => _connectivity = r);
      _refreshTrueOfflineState();
    });
    // onConnectivityChanged only fires on a transport change (wifi<->mobile),
    // not when a flaky connection quietly recovers on the SAME network — a
    // single bad ping at the moment this screen opened could otherwise leave
    // this device reading "offline" (and preferring Nearby) for the rest of
    // the chat, while the other person's phone — never having had that one
    // bad ping — correctly shows "Using WiFi". Re-verify periodically so a
    // transient hiccup self-heals instead of sticking for the whole session.
    _offlineRecheckTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refreshTrueOfflineState(),
    );
    // Incoming Bluetooth/WiFi Direct messages are already bridged into the
    // right conversation globally by AppProvider — this screen just needs
    // to scroll down when a new one lands while it's open.
    _nearbySub = NearbyService().onMessage.listen((m) {
      final ou = conv.otherUser;
      if (ou == null || !mounted) return;
      if (NearbyService().peerUserId[m.endpointId] != ou.id) return;
      _scrollDown();
    });
    NearbyService().addListener(_onNearbyChanged);
  }

  void _onNearbyChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _restoreDraft() async {
    final p = await SharedPreferences.getInstance();
    final saved = p.getString(_draftKey);
    if (saved != null && saved.isNotEmpty && mounted) {
      _ctrl.text = saved;
      _ctrl.selection = TextSelection.collapsed(offset: saved.length);
    }
  }

  void _saveDraft(String v) {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 400), () async {
      final p = await SharedPreferences.getInstance();
      if (v.trim().isEmpty) {
        await p.remove(_draftKey);
      } else {
        await p.setString(_draftKey, v);
      }
    });
  }

  Future<void> _clearDraft() async {
    _draftSaveTimer?.cancel();
    final p = await SharedPreferences.getInstance();
    await p.remove(_draftKey);
  }

  // connectivity_plus can report a stale/wrong "no connection" on some OEM
  // ROMs (confirmed live: a real, Android-validated LTE connection while
  // the plugin still said offline) — that false reading silently broke
  // this chat's offline banner AND blocked Nearby calls before they even
  // tried. Only trust "offline" once a real quick ping to our own server
  // also fails.
  bool _trulyOffline = false;
  bool _launchingCall = false;
  void _refreshTrueOfflineState() {
    ApiService.isOffline().then((v) {
      // The ping can complete after this chat route has been popped. Keep the
      // lifecycle check separate from setState so a late result can never
      // touch a defunct Element (seen as the red Flutter assertion screen).
      if (!mounted) return;
      if (_trulyOffline == v) return;
      setState(() => _trulyOffline = v);
    });
  }

  /// "Using WiFi" / "Using Mobile Data" / "Offline — save karke bhej denge"
  /// — matched against Nearby status separately in the app bar subtitle.
  String get _connectivityLabel {
    if (!_trulyOffline) {
      if (_connectivity.contains(ConnectivityResult.wifi)) return 'Using WiFi';
      if (_connectivity.contains(ConnectivityResult.mobile))
        return 'Using Mobile Data';
      if (_connectivity.contains(ConnectivityResult.ethernet))
        return 'Using Internet';
      // The real ping confirmed we're online, but connectivity_plus didn't
      // identify which transport — still genuinely connected, so this must
      // NOT fall through to the offline text below.
      return 'Using Internet';
    }
    final ou = conv.otherUser;
    if (ou != null && NearbyService().isUserReachable(ou.id))
      return 'Using Nearby';
    return 'Offline — message saved, will send when back online';
  }

  bool get _isOffline => _trulyOffline;

  @override
  void dispose() {
    context.read<AppProvider>().setActiveChat(null);
    _ctrl.dispose();
    _scroll.dispose();
    _focus.dispose();
    _typingTimer?.cancel();
    _recTimer?.cancel();
    _recorder.dispose();
    _connSub?.cancel();
    _offlineRecheckTimer?.cancel();
    _nearbySub?.cancel();
    NearbyService().removeListener(_onNearbyChanged);
    _draftSaveTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    final pos = _scroll.position;
    // Normal chronological list: older messages are at the top.
    if (pos.pixels <= 120 && _hasMore && !_loadingOlder) {
      _loadOlderMessages();
    }
    final away = pos.maxScrollExtent - pos.pixels > 400;
    if (away != _showScrollBtn) setState(() => _showScrollBtn = away);
  }

  Future<void> _loadOlderMessages() async {
    final prov = context.read<AppProvider>();
    final msgs = prov.messagesFor(conv.id);
    if (msgs.isEmpty) return;
    setState(() => _loadingOlder = true);
    final oldest = msgs.first.id;
    final older = await ApiService.getMessages(conv.id, before: oldest);
    setState(() {
      _loadingOlder = false;
      _hasMore = older.length >= 50;
    });
    if (older.isEmpty) return;
    final prevExtent = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    final prevPixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final combined = [...older, ...msgs];
    prov.setMessages(conv.id, combined);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        final newExtent = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(prevPixels + (newExtent - prevExtent));
      }
    });
  }

  void _scrollDown({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || !_scroll.position.hasContentDimensions) return;
      if (animate) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      } else {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
      // A newly-inserted date divider (first message of a new day) changes
      // the list's layout height across an extra frame — scrolling right
      // after the frame that added the message can land short of the true
      // bottom, making a just-sent message look like it "didn't show" when
      // it's actually sitting just out of view. Nudge again once that
      // settles to guarantee it's fully revealed.
      Future.delayed(const Duration(milliseconds: 300), () {
        if (_scroll.hasClients && _scroll.position.hasContentDimensions) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    });
  }

  void _onTextChanged(String v) {
    _updateSlash(v);
    _saveDraft(v);
    final prov = context.read<AppProvider>();
    if (v.isNotEmpty && !_isTyping) {
      _isTyping = true;
      prov.sendTyping(conv.id, true);
    }
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 2), () {
      if (_isTyping) {
        _isTyping = false;
        prov.sendTyping(conv.id, false);
      }
    });
  }

  // "draw a cat", "cat ki image banao", "/image sunset" — image-intent detection
  bool _isImagePrompt(String t) {
    final l = t.toLowerCase();
    if (l.startsWith('/image') || l.startsWith('/img')) return true;
    final wantsImage = RegExp(
      r'\b(image|photo|picture|pic|tasveer|tasvir|drawing|wallpaper|logo)\b',
    ).hasMatch(l);
    final makeVerb = RegExp(
      r'\b(banao|banado|bana|generate|create|draw|make|design)\b',
    ).hasMatch(l);
    return wantsImage && makeVerb;
  }

  // Long-press send → schedule this message for a future time.
  Future<void> _scheduleMessage() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(hours: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Schedule message — pick a date',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(hours: 1))),
      helpText: 'Pick a time',
    );
    if (time == null || !mounted) return;
    final when = DateTime(
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    );
    if (when.isBefore(now)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pick a future time'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final r = await ApiService.post('scheduled.php?action=create', {
      'conversation_id': conv.id,
      'content': text,
      'scheduled_ts': when.millisecondsSinceEpoch ~/ 1000,
    });
    if (!mounted) return;
    if (r['success'] == true) {
      _ctrl.clear();
      final label = TimeOfDay.fromDateTime(when).format(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏰ Scheduled for ${when.day}/${when.month} at $label'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(r['error']?.toString() ?? 'Could not schedule'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _showScheduledSheet() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheet) {
            return FutureBuilder<Map<String, dynamic>>(
              future: ApiService.get('scheduled.php?action=list'),
              builder: (_, snap) {
                final all = (snap.data?['items'] as List?) ?? [];
                final items = all
                    .where(
                      (e) =>
                          (e['conversation_id']?.toString() ==
                          conv.id.toString()),
                    )
                    .toList();
                return SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.schedule,
                              color: AppColors.primary,
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              'Scheduled messages',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (snap.connectionState == ConnectionState.waiting)
                          const Padding(
                            padding: EdgeInsets.all(20),
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Center(
                              child: Text(
                                'No scheduled messages.\nLong-press send to schedule one.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Color(0xFF8A949B)),
                              ),
                            ),
                          )
                        else
                          ...items.map(
                            (e) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                e['content']?.toString() ?? '',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '⏰ ${e['scheduled_at'] ?? ''}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: AppColors.danger,
                                ),
                                onPressed: () async {
                                  await ApiService.post(
                                    'scheduled.php?action=cancel',
                                    {'id': e['id']},
                                  );
                                  setSheet(() {});
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _sendLock) return;
    _sendLock = true;
    Future.delayed(const Duration(milliseconds: 400), () => _sendLock = false);
    _ctrl.clear();
    unawaited(_clearDraft());
    if (_showSlash) setState(() => _showSlash = false);
    _isTyping = false;
    final replyId = _replyTo?.id;
    if (_replyTo != null) setState(() => _replyTo = null);
    context.read<AppProvider>().sendTyping(conv.id, false);

    // sendMessage() itself prefers a direct Bluetooth/WiFi Direct link over
    // the server when the peer is reachable that way right now — no need to
    // duplicate that routing decision here.
    //
    // sendMessage() adds the optimistic "sending" bubble to the list and
    // calls notifyListeners() synchronously before it ever awaits the actual
    // network call — but awaiting the whole call here before scrolling meant
    // the just-sent bubble sat rendered but off-screen for as long as the
    // network round-trip took, looking like the message "didn't send" until
    // the user left and re-entered the chat (whose initial mount does its
    // own scroll-to-bottom). Scroll right away against the optimistic state;
    // let the network call finish in the background.
    final sendFuture = context.read<AppProvider>().sendMessage(
      conv.id,
      text,
      replyToId: replyId,
    );
    // Force this route to consume the provider's synchronous optimistic
    // insert immediately even on OEM builds that coalesce ChangeNotifier
    // frames while the keyboard is closing.
    if (mounted) setState(() {});
    unawaited(sendFuture);
    _scrollDown();
    Future.delayed(const Duration(milliseconds: 80), () {
      if (mounted) _scrollDown(animate: false);
    });

    // AI bot — image generation or chat reply
    if (conv.isAiBot) {
      final prov = context.read<AppProvider>();
      if (_isImagePrompt(text)) {
        prov.setLocalTyping(conv.id, true); // typing bubble while generating
        try {
          // Strip command words so "make a picture of a galaxy" → "a galaxy"
          var prompt = text
              .replaceFirst(RegExp(r'^/im(a)?g(e)?\s*'), '')
              .replaceAll(
                RegExp(
                  r'\b(make|create|generate|draw|design|paint|send|show|please|plz|pls|banao?|bana\s?do|chahiye|of|kar|karo)\b',
                  caseSensitive: false,
                ),
                ' ',
              )
              .replaceAll(
                RegExp(
                  r'\b(pic|picture|image|photo|tasveer|tasvir)\b',
                  caseSensitive: false,
                ),
                ' ',
              )
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          if (prompt.isEmpty) prompt = text;
          final url = await ApiService.aiGenerateImage(prompt);
          if (url != null && url.isNotEmpty) {
            final saved = await ApiService.post('ai.php?action=save_image', {
              'conversation_id': conv.id,
              'image_data': url,
            });
            if (saved['success'] == true && saved['message'] != null) {
              prov.addMessage(
                conv.id,
                Message.fromJson(Map<String, dynamic>.from(saved['message'])),
              );
            }
          } else {
            throw Exception('no image');
          }
        } catch (_) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Image generation failed — thodi der baad try karo',
                ),
              ),
            );
          }
        }
        prov.setLocalTyping(conv.id, false);
        if (mounted) _scrollDown();
        return;
      }
      prov.setLocalTyping(conv.id, true);
      Future.delayed(const Duration(milliseconds: 400), () async {
        try {
          final r = await ApiService.aiBotReply(conv.id, text);
          if (r['success'] == true && r['message'] != null) {
            final msg = Message.fromJson(
              Map<String, dynamic>.from(r['message']),
            );
            prov.addMessage(conv.id, msg);
          }
        } catch (_) {}
        prov.setLocalTyping(conv.id, false);
        if (mounted) _scrollDown();
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    Navigator.pop(context);
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: source, imageQuality: 85);
    if (xfile == null) return;
    final bytes = await xfile.readAsBytes();
    final prov = context.read<AppProvider>();
    if (mounted) _scrollDown(); // jump to the instant preview right away
    await prov.uploadAndSendFile(
      conv.id,
      bytes,
      xfile.name,
      'image',
      localPath: xfile.path,
    );
    if (mounted) _scrollDown();
  }

  void _showAttachMenu() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
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
              const SizedBox(height: 18),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 4,
                mainAxisSpacing: 18,
                children: [
                  _attachBtn(
                    Icons.insert_drive_file_rounded,
                    'Document',
                    const Color(0xFF7F66FF),
                    _pickDocument,
                  ),
                  _attachBtn(
                    Icons.camera_alt_rounded,
                    'Camera',
                    const Color(0xFFFF2E74),
                    () => _pickImage(ImageSource.camera),
                  ),
                  _attachBtn(
                    Icons.photo_rounded,
                    'Gallery',
                    const Color(0xFFBF59CF),
                    () => _pickImage(ImageSource.gallery),
                  ),
                  _attachBtn(
                    Icons.headphones_rounded,
                    'Audio',
                    const Color(0xFFFF8A2A),
                    _pickAudioFile,
                  ),
                  _attachBtn(
                    Icons.location_on_rounded,
                    'Location',
                    const Color(0xFF1FA855),
                    _sendLocation,
                  ),
                  _attachBtn(
                    Icons.person_rounded,
                    'Contact',
                    const Color(0xFF009DE2),
                    _sendContact,
                  ),
                  _attachBtn(
                    Icons.bar_chart_rounded,
                    'Poll',
                    const Color(0xFFFFBC38),
                    _createPoll,
                  ),
                  _attachBtn(
                    Icons.event_rounded,
                    'Event',
                    const Color(0xFFE6526F),
                    _createEvent,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _comingSoon(String what) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$what — coming soon'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── Location ────────────────────────────────────────────────
  Future<void> _sendLocation() async {
    Navigator.pop(context);
    final prov = context.read<AppProvider>();
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied)
        perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permission required')),
          );
        }
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Getting location...'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 20));
      await prov.sendMessage(
        conv.id,
        '📍 My location:\nhttps://maps.google.com/?q=${pos.latitude},${pos.longitude}',
      );
      if (mounted) _scrollDown();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not get location — GPS on hai?')),
        );
      }
    }
  }

  // ── Contact ─────────────────────────────────────────────────
  void _sendContact() {
    Navigator.pop(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final convs = context
        .read<AppProvider>()
        .conversations
        .where(
          (c) => c.type == 'direct' && c.otherUser != null && c.id != conv.id,
        )
        .toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Share contact',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: convs.length,
                itemBuilder: (_, i) {
                  final u = convs[i].otherUser!;
                  return ListTile(
                    leading: AvatarWidget(
                      imageUrl: convs[i].displayAvatar.isNotEmpty
                          ? convs[i].displayAvatar
                          : null,
                      name: u.displayName,
                      size: 40,
                    ),
                    title: Text(u.displayName),
                    subtitle: Text(u.phone ?? '@${u.username}'),
                    onTap: () async {
                      Navigator.pop(context);
                      await context.read<AppProvider>().sendMessage(
                        conv.id,
                        '👤 Contact: ${u.displayName}\n${u.phone ?? '@${u.username}'}',
                      );
                      if (mounted) _scrollDown();
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  // ── Poll ── full styled page (not a popup) ──────────────────
  Future<void> _createPoll() async {
    Navigator.pop(context);
    final body = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _CreatePollPage()),
    );
    if (body == null || !mounted) return;
    await context.read<AppProvider>().sendMessage(conv.id, body);
    if (mounted) _scrollDown();
  }

  // ── Event ── full styled page ───────────────────────────────
  Future<void> _createEvent() async {
    Navigator.pop(context);
    final body = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _CreateEventPage()),
    );
    if (body == null || !mounted) return;
    await context.read<AppProvider>().sendMessage(conv.id, body);
    if (mounted) _scrollDown();
  }

  Future<void> _pickAudioFile() async {
    Navigator.pop(context);
    final res = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      withData: true,
    );
    final f = res?.files.firstOrNull;
    if (f?.bytes == null) return;
    final prov = context.read<AppProvider>();
    await prov.uploadAndSendFile(
      conv.id,
      f!.bytes!,
      f.name,
      'audio',
      localPath: f.path,
    );
    if (mounted) _scrollDown();
  }

  Widget _attachBtn(
    IconData icon,
    String label,
    Color color,
    VoidCallback onTap,
  ) => GestureDetector(
    onTap: onTap,
    child: Column(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withOpacity(.12),
          ),
          child: Icon(icon, color: color, size: 26),
        ),
        const SizedBox(height: 6),
        Text(label, style: TextStyle(fontSize: 12, color: color)),
      ],
    ),
  );

  Future<void> _pickDocument() async {
    Navigator.pop(context);
    final res = await FilePicker.platform.pickFiles(withData: true);
    final f = res?.files.firstOrNull;
    if (f?.bytes == null) return;
    final prov = context.read<AppProvider>();
    await prov.uploadAndSendFile(
      conv.id,
      f!.bytes!,
      f.name,
      'file',
      localPath: f.path,
    );
    if (mounted) _scrollDown();
  }

  // Open chat from a shared contact card ("+92300..." or "@username")
  Future<void> _openChatWithHandle(String handle) async {
    final prov = context.read<AppProvider>();
    try {
      Map<String, dynamic>? userJson;
      if (handle.startsWith('@')) {
        final r = await ApiService.get(
          'users.php?action=search',
          params: {'q': handle.substring(1)},
        );
        final list = (r['users'] as List?) ?? [];
        if (list.isNotEmpty) userJson = Map<String, dynamic>.from(list.first);
      } else {
        final r = await ApiService.get(
          'users.php?action=search_by_phone',
          params: {'phone': handle},
        );
        if (r['user'] != null) userJson = Map<String, dynamic>.from(r['user']);
      }
      if (userJson == null) throw Exception('not found');
      final user = User.fromJson(userJson);
      final cr = await ApiService.createConversation(user.id);
      final convId = int.tryParse(cr['conversation_id']?.toString() ?? '');
      if (convId == null) throw Exception('no conv');
      await prov.loadConversations();
      final target = prov.conversations.firstWhere(
        (c) => c.id == convId,
        orElse: () => Conversation(
          id: convId,
          type: 'direct',
          name: user.displayName,
          otherUser: user,
        ),
      );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => ChatScreen(conversation: target)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('User nahi mila')));
      }
    }
  }

  Uint8List? _decodeImageDataUrl(String url) {
    try {
      final i = url.indexOf(',');
      if (i < 0) return null;
      return base64Decode(url.substring(i + 1));
    } catch (_) {
      return null;
    }
  }

  void _openImage(String url) {
    if (url.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            foregroundColor: Colors.white,
          ),
          body: InteractiveViewer(
            child: Center(
              child: url.startsWith('data:image')
                  ? Image.memory(
                      _decodeImageDataUrl(url) ?? Uint8List(0),
                      fit: BoxFit.contain,
                    )
                  : CachedNetworkImage(imageUrl: url, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prov = context.watch<AppProvider>();
    _conv =
        prov.conversationById(widget.conversation.id) ??
        prov.conversations
            .where(
              (c) =>
                  c.type == 'direct' &&
                  c.otherUser?.id == widget.conversation.otherUser?.id,
            )
            .firstOrNull ??
        prov.sanitizeConversation(widget.conversation);
    final peerName = prov.peerDisplayName(_conv);
    final peerAvatar = prov.peerAvatar(_conv);
    // Render oldest -> newest. Keeping the viewport non-reversed makes the
    // visual order unambiguous on both sender and receiver; sorting a render
    // copy also protects the UI from
    // any out-of-order SSE/Nearby delivery that arrives between provider
    // updates.
    final messages = List<Message>.from(prov.messagesFor(conv.id))
      ..sort((a, b) {
        final byTime = a.createdAt.compareTo(b.createdAt);
        if (byTime != 0) return byTime;
        if (a.id < 0 && b.id >= 0) return 1;
        if (a.id >= 0 && b.id < 0) return -1;
        return a.id.compareTo(b.id);
      });
    final loadingMsgs = prov.messagesLoading(conv.id);
    final msgError = prov.messagesError(conv.id);
    final isTyping = prov.isTyping(conv.id);
    final isRemoteRecording = prov.isRecording(conv.id);
    final me = prov.me;
    final showActivity = isTyping || isRemoteRecording;
    if (showActivity) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollDown();
      });
    }

    // Chat wallpaper: user choice overrides the default; null/default falls back
    // to the standard light/dark chat background.
    const wallpaperColors = {
      'green': Color(0xFFFEE2E2),
      'blue': Color(0xFFD6EAF8),
      'beige': Color(0xFFF5ECD7),
      'pink': Color(0xFFF8D7E3),
      'dark': Color(0xFF0B141A),
    };
    final wp = prov.chatWallpaper;
    final chatBg = (wp != null && wallpaperColors.containsKey(wp))
        ? wallpaperColors[wp]!
        : (isDark ? AppColors.bgDark : const Color(0xFFEFE9DE));

    return Scaffold(
      backgroundColor: chatBg,
      appBar: _buildAppBar(isDark, peerName: peerName, peerAvatar: peerAvatar),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                loadingMsgs && messages.isEmpty
                    ? const ChatLoadingSkeleton()
                    : msgError != null && messages.isEmpty
                    ? ChatLoadError(
                        message: msgError,
                        onRetry: () =>
                            prov.loadMessages(conv.id, refresh: true),
                      )
                    : messages.isEmpty && !showActivity && !_loadingOlder
                    ? Center(
                        child: Text(
                          'No messages yet',
                          style: TextStyle(
                            color: isDark
                                ? AppColors.t3Dark
                                : AppColors.t3Light,
                            fontSize: 14,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
                        cacheExtent: 800,
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: true,
                        itemCount:
                            messages.length +
                            (showActivity ? 1 : 0) +
                            (_loadingOlder ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (i >= messages.length) {
                            if (showActivity && i == messages.length) {
                              return isRemoteRecording
                                  ? _recordingBubble(
                                      isDark,
                                      peerName: peerName,
                                      peerAvatar: peerAvatar,
                                    )
                                  : _typingBubble(
                                      isDark,
                                      peerName: peerName,
                                      peerAvatar: peerAvatar,
                                    );
                            }
                            if (_loadingOlder) {
                              return const Padding(
                                padding: EdgeInsets.all(12),
                                child: Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                ),
                              );
                            }
                            return const SizedBox.shrink();
                          }
                          final ci = i;
                          final msg = messages[ci];
                          final isMine = msg.senderId == me?.id;
                          final showAvatar =
                              !isMine &&
                              (ci == 0 ||
                                  messages[ci - 1].senderId != msg.senderId);
                          final showDateSeparator =
                              ci == 0 ||
                              !_sameDay(
                                messages[ci - 1].createdAt,
                                msg.createdAt,
                              );
                          final bubble = AnimatedMessageEntry(
                            key: ValueKey(prov.messageUiKey(msg)),
                            index: ci,
                            animate: !isMine,
                            child: MessageBubble(
                              message: msg,
                              isMine: isMine,
                              showAvatar: showAvatar,
                              isGroup: conv.type == 'group',
                              onLongPress: () => _showMsgOptions(msg, isMine),
                              onImageTap: msg.isImage
                                  ? () => _openImage(msg.fileUrl ?? '')
                                  : null,
                              onVideoTap:
                                  msg.isVideo && (msg.fileUrl ?? '').isNotEmpty
                                  ? () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => VideoPlayerScreen(
                                          url: msg.fileUrl!,
                                        ),
                                      ),
                                    )
                                  : null,
                              onCallTap: msg.type == 'call' && !conv.isAiBot
                                  ? () {
                                      final parts =
                                          (msg.content ?? 'audio|missed|0')
                                              .split('|');
                                      _launchCall(
                                        parts.isNotEmpty && parts[0] == 'video',
                                      );
                                    }
                                  : null,
                              onPollVote: (opt) async {
                                await context.read<AppProvider>().sendMessage(
                                  conv.id,
                                  '🗳️ Vote: $opt',
                                );
                                _scrollDown();
                              },
                              onContactMessage: _openChatWithHandle,
                              onAddReaction: (msgId, emoji) {
                                ApiService.reactToMessage(
                                  msgId,
                                  emoji,
                                ).catchError((_) => <String, dynamic>{});
                              },
                              onShowReactionDetails: (msgId) =>
                                  _showReactionDetails(msg),
                              onRetry: msg.status == 'failed'
                                  ? () => context
                                        .read<AppProvider>()
                                        .retrySendMessage(conv.id, msg.id)
                                  : null,
                            ),
                          );
                          if (!showDateSeparator) return bubble;
                          return Column(
                            children: [
                              _dateSeparator(isDark, msg.createdAt),
                              bubble,
                            ],
                          );
                        },
                      ),
                // Scroll-to-bottom button (like web)
                if (_showScrollBtn)
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: GestureDetector(
                      onTap: () => _scrollDown(),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isDark ? AppColors.cardDark : Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(.22),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          size: 28,
                          color: isDark
                              ? Colors.white70
                              : const Color(0xFF54656F),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (_showSlash && !_isRecording) _slashMenu(isDark),
          if (_replyTo != null) _replyBar(isDark),
          if (_showEmoji && !_isRecording) _emojiSheet(isDark),
          _isRecording ? _recordingBar(isDark) : _inputBar(isDark),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
    bool isDark, {
    required String peerName,
    required String peerAvatar,
  }) {
    final ou = conv.otherUser;
    final fg = isDark ? AppColors.t1Dark : AppColors.t1Light;
    final sub = isDark ? AppColors.t2Dark : AppColors.t3Light;
    return AppBar(
      backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
      foregroundColor: fg,
      surfaceTintColor: Colors.transparent,
      leadingWidth: 36,
      leading: BackButton(color: fg, onPressed: () => Navigator.pop(context)),
      title: GestureDetector(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ContactInfoScreen(conversation: conv),
          ),
        ),
        child: Row(
          children: [
            AvatarWidget(
              imageUrl: peerAvatar.isNotEmpty ? peerAvatar : null,
              name: peerName,
              size: 38,
              showOnline: true,
              status: ou?.status ?? 'offline',
              isAiBot: conv.isAiBot,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          peerName,
                          style: TextStyle(
                            color: fg,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (conv.isAiBot || conv.isVerified) ...[
                        const SizedBox(width: 4),
                        const VerifiedBadge(size: 15),
                      ],
                    ],
                  ),
                  ListenableBuilder(
                    listenable: NearbyService(),
                    builder: (_, __) {
                      final viaNearby =
                          _trulyOffline &&
                          ou != null &&
                          NearbyService().isUserReachable(ou.id);
                      final viaWhatsapp = ou?.isWhatsappShadow == true;
                      return Text(
                        viaNearby
                            ? 'Using Nearby (offline)'
                            : viaWhatsapp
                            ? 'Synced from WhatsApp'
                            : presenceLabel(
                                ou,
                                isGroup: conv.type == 'group',
                                memberCount: conv.memberCount,
                              ),
                        style: TextStyle(
                          color: viaNearby || viaWhatsapp
                              ? AppColors.primary
                              : ((ou?.isOnline == true)
                                    ? AppColors.online
                                    : sub),
                          fontSize: 12,
                          fontWeight: viaNearby || viaWhatsapp
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // No calls with the AI bot or bots that admin disabled calls for
        if (!conv.isAiBot && conv.otherUser?.noVoiceCall != true)
          IconButton(
            icon: Icon(Icons.call_outlined, color: fg),
            onPressed: _startAudioCall,
          ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_vert, color: fg, size: conv.isAiBot ? 18 : 22),
          padding: conv.isAiBot ? EdgeInsets.zero : const EdgeInsets.all(8),
          constraints: conv.isAiBot
              ? const BoxConstraints(minWidth: 28, minHeight: 28)
              : const BoxConstraints(minWidth: 40, minHeight: 40),
          color: isDark ? AppColors.cardDark : Colors.white,
          onSelected: (v) {
            if (v == 'info')
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ContactInfoScreen(conversation: conv),
                ),
              );
            if (v == 'scheduled') _showScheduledSheet();
            if (v == 'search') {}
            if (v == 'mute') {}
            if (v == 'clear') _confirmClearChat();
          },
          itemBuilder: (_) {
            return [
              const PopupMenuItem(value: 'info', child: Text('Contact info')),
              const PopupMenuItem(
                value: 'scheduled',
                child: Text('Scheduled messages'),
              ),
              const PopupMenuItem(value: 'search', child: Text('Search')),
              const PopupMenuItem(
                value: 'mute',
                child: Text('Mute notifications'),
              ),
              const PopupMenuItem(value: 'clear', child: Text('Clear chat')),
              // No manual "Enable Bluetooth" / "Use Nearby" entries — Nearby
              // now auto-discovers and auto-connects entirely in the
              // background (see NearbyService.start/_startDiscovery), and
              // this is the same chat either way, so there's nothing left
              // for the user to tap to "switch on" here.
            ];
          },
        ),
      ],
    );
  }

  Future<void> _enableBluetooth() async {
    final already = await BluetoothServiceNative.isEnabled();
    if (already) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Bluetooth pehle se on hai — nearby device dhoonda ja raha hai',
            ),
          ),
        );
      }
      // Already on — (re)kick discovery so it starts looking right away
      // instead of waiting for the next periodic cycle.
      final me = context.read<AppProvider>().me;
      if (me != null) {
        unawaited(
          NearbyService().start(
            me.displayName.isNotEmpty ? me.displayName : me.username,
            me.id,
          ),
        );
      }
      return;
    }
    final shown = await BluetoothServiceNative.requestEnable();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            shown
                ? 'Android ka Bluetooth prompt khul gaya — "Allow" par tap karein'
                : 'Bluetooth prompt nahi khul saka — Settings se manually on karein',
          ),
        ),
      );
    }
  }

  Future<void> _confirmClearChat() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppColors.cardDark : Colors.white,
        title: const Text('Clear chat?'),
        content: const Text(
          'This deletes all messages in this chat on this device. '
          'It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppProvider>().clearConversationMessages(conv.id);
  }

  Future<void> _useBluetoothForNearby() async {
    final ou = conv.otherUser;
    if (ou == null) return;
    String? endpointId;
    for (final e in NearbyService().peerUserId.entries) {
      if (e.value == ou.id) {
        endpointId = e.key;
        break;
      }
    }
    if (endpointId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Yeh user abhi Bluetooth range mein detect nahi hua'),
          ),
        );
      }
      return;
    }
    await NearbyService().connectTo(endpointId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Bluetooth se connect ho raha hai…'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _startAudioCall() => _launchCall(false);
  void _startVideoCall() => _launchCall(false);

  void _launchCall(bool isVideo) {
    if (_launchingCall) return;
    _launchingCall = true;
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) _launchingCall = false;
    });
    try {
    // Refresh conv from live state in case it went stale while in background
    final liveConv = context.read<AppProvider>().conversationById(conv.id);
    if (liveConv != null) _conv = context.read<AppProvider>().sanitizeConversation(liveConv);
    // Group chats → multi-party mesh call (no single callee).
    if (conv.type == 'group') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupCallScreen(
            convId: conv.id,
            groupName: conv.name,
            isInitiator: true,
            members: conv.members,
          ),
        ),
      );
      return;
    }
    context.read<AppProvider>().startOutgoingCallRing();
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ActiveCallScreen(
          callerName: context.read<AppProvider>().peerDisplayName(conv),
          callerAvatar: _nonEmpty(context.read<AppProvider>().peerAvatar(conv)),
          isVideo: isVideo,
          convId: conv.id,
          isOutgoing: true,
          calleeUserId: conv.otherUser?.id,
          // Only route the call over Nearby when there's genuinely no internet —
          // it's much lower quality/laggier than the normal WebRTC call, so it
          // must never be picked just because the peer also happens to be in
          // Bluetooth/WiFi-Direct range while both sides have perfectly good WiFi.
          viaNearby:
              _trulyOffline &&
              conv.otherUser != null &&
              NearbyService().isUserReachable(conv.otherUser!.id),
        ),
        transitionsBuilder: (_, a, __, child) => SlideTransition(
          position: Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 450),
      ),
    ).then((_) {
      _launchingCall = false;
      context.read<AppProvider>().stopRing();
    });
    } catch (_) {
      _launchingCall = false;
    }
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _dateLabel(DateTime dt) {
    final now = DateTime.now();
    final local = dt.toLocal();
    if (_sameDay(local, now)) return 'Today';
    final yesterday = now.subtract(const Duration(days: 1));
    if (_sameDay(local, yesterday)) return 'Yesterday';
    if (now.difference(local).inDays < 7)
      return DateFormat('EEEE').format(local);
    if (local.year == now.year) return DateFormat('d MMMM').format(local);
    return DateFormat('d MMMM yyyy').format(local);
  }

  Widget _dateSeparator(bool isDark, DateTime dt) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 40),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? AppColors.cardDark : Colors.black.withOpacity(.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          _dateLabel(dt),
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: isDark ? AppColors.t2Dark : AppColors.t2Light,
          ),
        ),
      ),
    ),
  );

  Widget _typingBubble(
    bool isDark, {
    required String peerName,
    required String peerAvatar,
  }) => Padding(
    padding: const EdgeInsets.only(left: 14, bottom: 8),
    child: Row(
      children: [
        AvatarWidget(
          imageUrl: peerAvatar.isNotEmpty ? peerAvatar : null,
          name: peerName,
          size: 28,
          isAiBot: conv.isAiBot,
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.recvBubbleDark
                : AppColors.recvBubbleLight,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppRadii.bubble),
              topRight: Radius.circular(AppRadii.bubble),
              bottomRight: Radius.circular(AppRadii.bubble),
              bottomLeft: Radius.circular(AppRadii.bubbleTail),
            ),
            boxShadow: AppShadows.bubble(isDark),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _BounceDot(delay: 0, dark: isDark),
              const SizedBox(width: 5),
              _BounceDot(delay: 160, dark: isDark),
              const SizedBox(width: 5),
              _BounceDot(delay: 320, dark: isDark),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _recordingBubble(
    bool isDark, {
    required String peerName,
    required String peerAvatar,
  }) => Padding(
    padding: const EdgeInsets.only(left: 14, bottom: 8),
    child: Row(
      children: [
        AvatarWidget(
          imageUrl: peerAvatar.isNotEmpty ? peerAvatar : null,
          name: peerName,
          size: 28,
          isAiBot: conv.isAiBot,
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark
                ? AppColors.recvBubbleDark
                : AppColors.recvBubbleLight,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(AppRadii.bubble),
              topRight: Radius.circular(AppRadii.bubble),
              bottomRight: Radius.circular(AppRadii.bubble),
              bottomLeft: Radius.circular(AppRadii.bubbleTail),
            ),
            boxShadow: AppShadows.bubble(isDark),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _PulsingMicIcon(),
              const SizedBox(width: 7),
              Text(
                'recording audio…',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: isDark
                      ? const Color(0xFFF87171)
                      : const Color(0xFFEF4444),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _slashMenu(bool isDark) => Container(
    constraints: const BoxConstraints(maxHeight: 260),
    margin: const EdgeInsets.fromLTRB(10, 0, 10, 0),
    decoration: BoxDecoration(
      color: isDark ? AppColors.cardDark : Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: isDark ? AppColors.borderDark : AppColors.borderLight,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(.12),
          blurRadius: 16,
          offset: const Offset(0, -2),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: ListView(
        padding: EdgeInsets.zero,
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
            child: Text(
              'BUSINESS COMMANDS',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: isDark ? AppColors.t3Dark : AppColors.t3Light,
              ),
            ),
          ),
          ..._slashItems.map(
            (c) => InkWell(
              onTap: () => _pickSlash(c),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 26,
                      child: Text(
                        c['icon']!,
                        style: const TextStyle(fontSize: 17),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c['cmd']!,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14.5,
                              color: isDark
                                  ? AppColors.t1Dark
                                  : AppColors.t1Light,
                            ),
                          ),
                          Text(
                            c['desc']!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppColors.t3Dark
                                  : AppColors.t3Light,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  // One accent colour per transport — makes it obvious at a glance whether
  // a chat is going over WiFi, mobile data, a direct Nearby/Bluetooth link,
  // or is offline, without having to read the label text.
  Color _connectivityColor(String label, bool offline) {
    if (offline) return AppColors.danger;
    if (label == 'Using WiFi') return const Color(0xFF2563EB); // blue
    if (label == 'Using Mobile Data') return const Color(0xFF16A34A); // green
    if (label == 'Using Nearby (offline)')
      return const Color(0xFF7C3AED); // purple/bluetooth
    if (label == 'Using Internet') return const Color(0xFF0EA5E9); // cyan
    return AppColors.t3Light;
  }

  Widget _connectivityStrip(bool isDark) => ListenableBuilder(
    listenable: NearbyService(),
    builder: (_, __) {
      final label = _connectivityLabel;
      final offline = _isOffline && label.startsWith('Offline');
      final color = _connectivityColor(label, offline);
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        child: GestureDetector(
          onTap: () => _showConnectionDetails(isDark, label, color, offline),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withOpacity(isDark ? 0.16 : 0.10),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.18),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  offline
                      ? Icons.cloud_off_rounded
                      : label == 'Using WiFi'
                      ? Icons.wifi_rounded
                      : label == 'Using Nearby (offline)'
                      ? Icons.bluetooth_connected_rounded
                      : label == 'Using Mobile Data'
                      ? Icons.signal_cellular_alt_rounded
                      : Icons.public_rounded,
                  size: 12,
                  color: color,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 11,
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                Icon(
                  Icons.info_outline_rounded,
                  size: 11,
                  color: color.withOpacity(0.6),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  void _showConnectionDetails(
    bool isDark,
    String label,
    Color color,
    bool offline,
  ) {
    final ou = conv.otherUser;
    final viaNearby = label == 'Using Nearby (offline)';
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      offline
                          ? Icons.cloud_off_rounded
                          : label == 'Using WiFi'
                          ? Icons.wifi_rounded
                          : viaNearby
                          ? Icons.bluetooth_connected_rounded
                          : Icons.signal_cellular_alt_rounded,
                      color: color,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connection Details',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _detailRow(
                isDark,
                'Route',
                viaNearby
                    ? 'Direct (Bluetooth/WiFi Direct)'
                    : (offline ? 'None — messages queued' : 'Phoneopia server'),
                viaNearby ? Icons.route_rounded : Icons.dns_rounded,
              ),
              _detailRow(
                isDark,
                'Encryption',
                'End-to-end (HTTPS/TLS)',
                Icons.lock_rounded,
              ),
              if (viaNearby)
                _detailRow(
                  isDark,
                  'Nearby peer',
                  ou != null && NearbyService().isUserReachable(ou.id)
                      ? 'Connected'
                      : 'Not connected',
                  Icons.people_alt_rounded,
                )
              else
                _detailRow(
                  isDark,
                  'Server reachability',
                  offline ? 'Unreachable' : 'Reachable',
                  Icons.cloud_rounded,
                ),
              _detailRow(
                isDark,
                'Message delivery',
                offline
                    ? 'Queued — will send when a route is available'
                    : 'Live',
                Icons.send_rounded,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _detailRow(bool isDark, String label, String value, IconData icon) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: isDark ? AppColors.t3Dark : AppColors.t3Light,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppColors.t3Dark : AppColors.t3Light,
              ),
            ),
            const Spacer(),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.end,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Colors.white : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      );

  Widget _inputBar(bool isDark) => DecoratedBox(
    decoration: BoxDecoration(
      color: isDark ? AppColors.bg2Dark : Colors.white,
      border: Border(
        top: BorderSide(
          color: isDark ? AppColors.borderDark : AppColors.borderLight,
        ),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_trulyOffline &&
                conv.otherUser != null &&
                NearbyService().isUserReachable(conv.otherUser!.id))
              _nearbyComposerBar(isDark)
            else
              _connectivityStrip(isDark),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.cardDark : Colors.white,
                      borderRadius: BorderRadius.circular(AppRadii.input),
                      border: Border.all(
                        color: isDark
                            ? AppColors.borderDark
                            : AppColors.borderLight,
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        IconButton(
                          icon: Icon(
                            _showEmoji
                                ? Icons.keyboard
                                : Icons.emoji_emotions_outlined,
                            color: isDark
                                ? AppColors.t3Dark
                                : AppColors.t3Light,
                          ),
                          onPressed: () {
                            setState(() => _showEmoji = !_showEmoji);
                            if (_showEmoji)
                              _focus.unfocus();
                            else
                              _focus.requestFocus();
                          },
                        ),
                        Expanded(
                          child: TextField(
                            controller: _ctrl,
                            focusNode: _focus,
                            onChanged: _onTextChanged,
                            maxLines: 5,
                            minLines: 1,
                            textCapitalization: TextCapitalization.sentences,
                            style: TextStyle(
                              fontSize: 15,
                              color: isDark
                                  ? AppColors.t1Dark
                                  : AppColors.t1Light,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Message',
                              hintStyle: TextStyle(
                                color: isDark
                                    ? AppColors.t3Dark
                                    : AppColors.t3Light,
                              ),
                              border: InputBorder.none,
                              filled: false,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.attach_file,
                            color: isDark
                                ? AppColors.t3Dark
                                : AppColors.t3Light,
                          ),
                          onPressed: _showAttachMenu,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _ctrl,
                  builder: (_, val, __) {
                    final hasText = val.text.trim().isNotEmpty;
                    final noVoice =
                        conv.otherUser?.noVoiceNote ==
                        true; // admin disabled voice notes
                    return GestureDetector(
                      onTap: hasText
                          ? _send
                          : (noVoice ? null : _startVoiceRecord),
                      onLongPress: hasText ? _scheduleMessage : null,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 48,
                        height: 48,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary,
                        ),
                        child: Icon(
                          (hasText || noVoice) ? Icons.send_rounded : Icons.mic,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  /// Inline Nearby controls belong to the normal chat composer.  Keep this
  /// lightweight so the chat still feels like a regular chat when no peer is
  /// nearby, while making the direct Wi-Fi/Bluetooth route obvious when it is
  /// available.
  Widget _nearbyComposerBar(bool isDark) {
    final peer = conv.otherUser;
    final nearby = NearbyService();
    final connected = peer != null && nearby.isUserReachable(peer.id);
    final discovered =
        peer != null &&
        nearby.peerUserId.entries.any(
          (e) => e.value == peer.id && nearby.peerState[e.key] == 'discovered',
        );
    final accent = const Color(0xFF159B68);
    final muted = isDark ? Colors.white70 : const Color(0xFF52636A);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      margin: const EdgeInsets.only(bottom: 7),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: connected
            ? accent.withOpacity(isDark ? .20 : .09)
            : (isDark ? Colors.white10 : const Color(0xFFF4F8F6)),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: connected
              ? accent.withOpacity(.35)
              : (isDark ? Colors.white12 : const Color(0xFFDDE9E3)),
        ),
      ),
      child: Row(
        children: [
          Icon(
            connected ? Icons.wifi_rounded : Icons.wifi_find_rounded,
            size: 18,
            color: connected ? accent : muted,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected ? 'Using Nearby' : 'Nearby over Wi‑Fi / Bluetooth',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: connected ? accent : muted,
                  ),
                ),
                Text(
                  connected
                      ? 'Messages and files can send directly'
                      : 'Use direct chat when this contact is nearby',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: muted),
                ),
              ],
            ),
          ),
          if (connected) ...[
            if (peer.noVoiceCall != true)
              _nearbyActionIcon(
                Icons.call_rounded,
                'Call',
                () => _launchCall(false),
                accent,
              ),
            _nearbyActionIcon(
              Icons.attach_file_rounded,
              'File',
              _showAttachMenu,
              accent,
            ),
          ] else
            TextButton(
              onPressed: peer == null
                  ? null
                  : (discovered ? _useBluetoothForNearby : _enableBluetooth),
              style: TextButton.styleFrom(
                foregroundColor: accent,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(
                discovered ? 'Connect' : 'Enable',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _nearbyActionIcon(
    IconData icon,
    String label,
    VoidCallback onTap,
    Color color,
  ) => Tooltip(
    message: label,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(icon, size: 19, color: color),
      ),
    ),
  );

  // ── Voice recording ──────────────────────────────────────────

  Widget _recordingBar(bool isDark) => DecoratedBox(
    decoration: BoxDecoration(
      color: isDark ? AppColors.bg2Dark : Colors.white,
      border: Border(
        top: BorderSide(
          color: isDark ? AppColors.borderDark : AppColors.borderLight,
        ),
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // Cancel
            GestureDetector(
              onTap: _cancelVoiceRecord,
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isDark ? Colors.white12 : Colors.grey.shade200),
                ),
                child: const Icon(
                  Icons.delete_outline,
                  color: Colors.red,
                  size: 22,
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Timer + waveform
            Expanded(
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: isDark ? AppColors.cardDark : Colors.white,
                  borderRadius: BorderRadius.circular(AppRadii.input),
                  border: Border.all(
                    color: isDark
                        ? AppColors.borderDark
                        : AppColors.borderLight,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const _PulsingRecDot(),
                    const SizedBox(width: 8),
                    Text(
                      _formatRecDuration(_recSecs),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.red,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const _RecordingWaveBars(),
                    const SizedBox(width: 10),
                    const Text(
                      'Recording…',
                      style: TextStyle(fontSize: 13, color: Color(0xFF667781)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
            // Send
            GestureDetector(
              onTap: _stopAndSendVoice,
              child: Container(
                width: 48,
                height: 48,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.primary,
                ),
                child: const Icon(
                  Icons.send_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  String _formatRecDuration(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _startVoiceRecord() async {
    final hasPermission = await _recorder.hasPermission();
    if (!hasPermission) return;
    final dir = await getTemporaryDirectory();
    _recPath = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(
      // A native AAC-LC MediaCodec bug on at least one real device (confirmed
      // live via logcat: "csd0 too small" followed by "MPEG4Writer: Stop()
      // called but track is not started or stopped") — the resulting file/
      // track genuinely never started, so _recorder.stop() below returns
      // nothing usable and the whole send silently no-ops: no bubble, no
      // error, nothing. Explicit sampleRate alone didn't clear it; csd0 (AAC's
      // AudioSpecificConfig) encodes sample-rate index AND channel count, so
      // pin numChannels too rather than leave it to the device's own default.
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
        numChannels: 1,
      ),
      path: _recPath!,
    );
    setState(() {
      _isRecording = true;
      _recSecs = 0;
    });
    context.read<AppProvider>().sendRecording(conv.id, true);
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _recSecs++);
    });
  }

  Future<void> _stopAndSendVoice() async {
    _recTimer?.cancel();
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    context.read<AppProvider>().sendRecording(conv.id, false);
    if (path == null || _recSecs < 1) return;
    final file = File(path);
    if (!file.existsSync()) return;
    final bytes = await file.readAsBytes();
    final filename = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    if (mounted)
      context.read<AppProvider>().uploadAndSendFile(
        conv.id,
        bytes,
        filename,
        'audio',
        durationSecs: _recSecs,
        localPath: path,
      );
  }

  Future<void> _cancelVoiceRecord() async {
    _recTimer?.cancel();
    await _recorder.stop();
    setState(() {
      _isRecording = false;
      _recSecs = 0;
    });
    context.read<AppProvider>().sendRecording(conv.id, false);
  }

  static const _emojis = [
    '😀',
    '😂',
    '🥰',
    '😍',
    '🤩',
    '😘',
    '😊',
    '🙂',
    '😎',
    '🤔',
    '😅',
    '😭',
    '😤',
    '🥳',
    '🎉',
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '🤍',
    '💖',
    '💯',
    '🔥',
    '✨',
    '⭐',
    '🎊',
    '👏',
    '👍',
    '👎',
    '🙌',
    '🤝',
    '✌️',
    '🤞',
    '🤙',
    '💪',
    '🙏',
    '👋',
    '😋',
    '🤤',
    '😏',
    '🤗',
    '😇',
    '🐱',
    '🐶',
    '🦊',
    '🐻',
    '🐼',
    '🐨',
    '🐯',
    '🦁',
    '🐮',
    '🐸',
    '🐙',
    '🦋',
    '🌸',
    '🌺',
    '🍕',
    '🍔',
    '🍟',
    '🍣',
    '🍜',
    '🍩',
    '🎂',
    '☕',
    '🧃',
    '🍺',
    '🥂',
    '🚀',
    '🌈',
    '🌙',
    '⛅',
    '🌊',
  ];

  Widget _emojiSheet(bool isDark) => Container(
    height: 260,
    color: isDark ? AppColors.cardDark : Colors.white,
    child: Column(
      children: [
        Container(
          height: 1,
          color: isDark ? const Color(0x1F8696A0) : const Color(0x12000000),
        ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(8),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 8,
              childAspectRatio: 1,
            ),
            itemCount: _emojis.length,
            itemBuilder: (ctx, i) => GestureDetector(
              onTap: () {
                final pos = _ctrl.selection.base.offset;
                final text = _ctrl.text;
                if (pos < 0) {
                  _ctrl.text = text + _emojis[i];
                } else {
                  _ctrl.text =
                      text.substring(0, pos) + _emojis[i] + text.substring(pos);
                  _ctrl.selection = TextSelection.collapsed(
                    offset: pos + _emojis[i].length,
                  );
                }
              },
              child: Center(
                child: Text(_emojis[i], style: const TextStyle(fontSize: 24)),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _replyBar(bool isDark) => Container(
    padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
    color: isDark ? AppColors.bg2Dark : const Color(0xFFE7E1D8),
    child: Row(
      children: [
        Container(
          width: 3,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _replyTo!.senderName ?? 'Message',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
              Text(
                _replyTo!.isImage
                    ? '📷 Photo'
                    : _replyTo!.isAudio
                    ? '🎤 Voice message'
                    : (_replyTo!.content ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: () => setState(() => _replyTo = null),
        ),
      ],
    ),
  );

  void _showDeleteUndoSnack(int msgId) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('This message was deleted'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () =>
              context.read<AppProvider>().undoDeleteMessage(conv.id, msgId),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteMessage(Message msg, bool isMine) async {
    if (msg.id <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please wait — message is still sending'),
          ),
        );
      }
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'Delete message?',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            if (isMine)
              ListTile(
                leading: const Icon(
                  Icons.delete_forever_outlined,
                  color: AppColors.danger,
                ),
                title: const Text(
                  'Delete for everyone',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Removes this message for all participants',
                ),
                onTap: () => Navigator.pop(context, 'all'),
              ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: isDark ? AppColors.t2Dark : AppColors.t2Light,
              ),
              title: const Text(
                'Delete for me',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: const Text('Only removes it from your chat'),
              onTap: () => Navigator.pop(context, 'me'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    final ok = context.read<AppProvider>().deleteMessage(
      conv.id,
      msg.id,
      forAll: choice == 'all',
    );
    if (!mounted) return;
    if (ok) {
      _showDeleteUndoSnack(msg.id);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete message. Try again.')),
      );
    }
  }

  void _showMsgOptions(Message msg, bool isMine) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 10),
            // WhatsApp-style quick reaction row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: ['👍', '❤️', '😂', '😮', '😢', '🙏']
                    .map(
                      (em) => GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          ApiService.reactToMessage(msg.id, em)
                              .then((_) {
                                // Refresh messages to show the new reaction
                                context.read<AppProvider>().loadMessages(
                                  conv.id,
                                  refresh: true,
                                  silent: true,
                                );
                              })
                              .catchError((_) => <String, dynamic>{});
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isDark
                                ? Colors.white.withOpacity(.06)
                                : const Color(0xFFF0F2F5),
                          ),
                          child: Center(
                            child: Text(
                              em,
                              style: const TextStyle(fontSize: 22),
                            ),
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
            const SizedBox(height: 8),
            Divider(
              height: 1,
              color: isDark ? Colors.white12 : const Color(0xFFE9EDEF),
            ),
            _msgOption(
              Icons.reply,
              'Reply',
              () => setState(() => _replyTo = msg),
            ),
            if (msg.isText)
              _msgOption(Icons.copy, 'Copy', () {
                Clipboard.setData(ClipboardData(text: msg.content ?? ''));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Copied'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }),
            _msgOption(
              msg.isStarred ? Icons.star : Icons.star_border,
              msg.isStarred ? 'Unstar' : 'Star',
              () async {
                await ApiService.toggleStar(
                  msg.id,
                ).catchError((_) => <String, dynamic>{});
                if (mounted)
                  context.read<AppProvider>().loadMessages(
                    conv.id,
                    refresh: true,
                  );
              },
            ),
            _msgOption(Icons.forward, 'Forward', () => _showForwardSheet(msg)),
            _msgOption(Icons.delete_outline, 'Delete', () {
              Future.microtask(() => _confirmDeleteMessage(msg, isMine));
            }, color: AppColors.danger),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _reactorName(int userId) {
    final me = context.read<AppProvider>().me;
    if (me != null && userId == me.id) return 'You';
    final ou = conv.otherUser;
    if (ou != null && userId == ou.id) return ou.displayName;
    for (final m in conv.members) {
      if (m.id == userId) return m.displayName;
    }
    return 'User';
  }

  void _showReactionDetails(Message msg) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Reactions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in msg.reactions.entries)
                    for (final uid
                        in ((entry.value is Map
                                ? (entry.value['users'] as List?)
                                : null) ??
                            const []))
                      Builder(
                        builder: (_) {
                          final userId = int.tryParse(uid.toString()) ?? 0;
                          final mine =
                              context.read<AppProvider>().me?.id == userId;
                          return ListTile(
                            leading: Text(
                              entry.key,
                              style: const TextStyle(fontSize: 22),
                            ),
                            title: Text(
                              _reactorName(userId),
                              style: TextStyle(
                                color: isDark
                                    ? AppColors.t1Dark
                                    : AppColors.t1Light,
                              ),
                            ),
                            trailing: mine
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      color: AppColors.danger,
                                      size: 20,
                                    ),
                                    tooltip: 'Remove',
                                    onPressed: () {
                                      Navigator.pop(sheetCtx);
                                      ApiService.reactToMessage(
                                            msg.id,
                                            entry.key,
                                          )
                                          .catchError(
                                            (_) => <String, dynamic>{},
                                          )
                                          .whenComplete(() {
                                            if (mounted)
                                              context
                                                  .read<AppProvider>()
                                                  .loadMessages(
                                                    conv.id,
                                                    refresh: true,
                                                    silent: true,
                                                  );
                                          });
                                    },
                                  )
                                : null,
                          );
                        },
                      ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  void _showForwardSheet(Message msg) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final convs = context
        .read<AppProvider>()
        .conversations
        .where((c) => c.id != conv.id)
        .toList();
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.cardDark : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadii.sheet),
        ),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text(
              'Forward to...',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: convs.length,
                itemBuilder: (_, i) {
                  final c = convs[i];
                  return ListTile(
                    leading: AvatarWidget(
                      imageUrl: c.displayAvatar.isNotEmpty
                          ? c.displayAvatar
                          : null,
                      name: c.displayName,
                      size: 40,
                    ),
                    title: Text(c.displayName),
                    onTap: () async {
                      Navigator.pop(context);
                      await ApiService.post('messages.php?action=send_json', {
                        'conversation_id': c.id,
                        'content': msg.content,
                        'type': msg.type,
                        'file_path': msg.fileUrl,
                        'file_name': msg.fileName,
                        'is_forwarded': true,
                      }).catchError((_) => <String, dynamic>{});
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Forwarded to ${c.displayName}'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _msgOption(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? color,
  }) => ListTile(
    leading: Icon(icon, color: color),
    title: Text(label, style: color != null ? TextStyle(color: color) : null),
    onTap: () {
      Navigator.pop(context);
      onTap();
    },
    dense: true,
  );
}

class _PulsingRecDot extends StatefulWidget {
  const _PulsingRecDot();
  @override
  State<_PulsingRecDot> createState() => _PulsingRecDotState();
}

class _PulsingRecDotState extends State<_PulsingRecDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.55,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, __) => Container(
      width: 8 * _anim.value,
      height: 8 * _anim.value,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.red.withValues(alpha: _anim.value),
      ),
    ),
  );
}

class _PulsingMicIcon extends StatefulWidget {
  const _PulsingMicIcon();
  @override
  State<_PulsingMicIcon> createState() => _PulsingMicIconState();
}

class _PulsingMicIconState extends State<_PulsingMicIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(
      begin: 0.7,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, __) => Icon(
      Icons.mic,
      size: 16 * _anim.value,
      color: const Color(0xFFEF4444).withValues(alpha: _anim.value),
    ),
  );
}

class _RecordingWaveBars extends StatefulWidget {
  const _RecordingWaveBars();
  @override
  State<_RecordingWaveBars> createState() => _RecordingWaveBarsState();
}

class _RecordingWaveBarsState extends State<_RecordingWaveBars>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  static const _heights = [0.35, 0.55, 0.85, 0.6, 1.0, 0.7, 0.45];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ctrl,
    builder: (_, __) => SizedBox(
      height: 22,
      width: 56,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(_heights.length, (i) {
          final phase = (_ctrl.value + i * 0.12) % 1.0;
          final h =
              _heights[i] *
              (0.45 + 0.55 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2));
          return Container(
            width: 3,
            height: 22 * h,
            decoration: BoxDecoration(
              color: const Color(0xFFEF4444).withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    ),
  );
}

class _BounceDot extends StatefulWidget {
  final int delay;
  final bool dark;
  const _BounceDot({required this.delay, this.dark = false});
  @override
  State<_BounceDot> createState() => _BounceDotState();
}

class _BounceDotState extends State<_BounceDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _anim = Tween<double>(
      begin: 0,
      end: -6,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _anim,
    builder: (_, __) => Transform.translate(
      offset: Offset(0, _anim.value),
      child: Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.dark
              ? const Color(0xFF8696A0)
              : const Color(0xFF667781),
        ),
      ),
    ),
  );
}

// ── Create Poll page (WhatsApp-style) ──────────────────────────
class _CreatePollPage extends StatefulWidget {
  const _CreatePollPage();
  @override
  State<_CreatePollPage> createState() => _CreatePollPageState();
}

class _CreatePollPageState extends State<_CreatePollPage> {
  final _q = TextEditingController();
  final List<TextEditingController> _opts = [
    TextEditingController(),
    TextEditingController(),
  ];
  bool _multi = false;

  @override
  void dispose() {
    _q.dispose();
    for (final c in _opts) c.dispose();
    super.dispose();
  }

  void _send() {
    final q = _q.text.trim();
    final opts = _opts
        .map((c) => c.text.trim())
        .where((o) => o.isNotEmpty)
        .toList();
    if (q.isEmpty || opts.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sawal aur kam se kam 2 options likho')),
      );
      return;
    }
    Navigator.pop(
      context,
      '📊 *Poll:* $q\n${opts.map((o) => '⬜ $o').join('\n')}\n\n_Reply karke vote karo_',
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        backgroundColor: isDark ? AppColors.bg2Dark : AppColors.headerGreen,
        foregroundColor: Colors.white,
        title: const Text('Create poll'),
        actions: [
          TextButton(
            onPressed: _send,
            child: const Text(
              'SEND',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Question',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.t3Dark : AppColors.t3Light,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: isDark ? AppColors.cardDark : Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              controller: _q,
              decoration: const InputDecoration(
                hintText: 'Ask a question',
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Options',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark ? AppColors.t3Dark : AppColors.t3Light,
            ),
          ),
          const SizedBox(height: 6),
          ...List.generate(
            _opts.length,
            (i) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark ? AppColors.cardDark : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _opts[i],
                        decoration: InputDecoration(
                          hintText: 'Option ${i + 1}',
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                    if (_opts.length > 2)
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => setState(() => _opts.removeAt(i)),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (_opts.length < 6)
            TextButton.icon(
              onPressed: () =>
                  setState(() => _opts.add(TextEditingController())),
              icon: const Icon(Icons.add, color: AppColors.primary),
              label: const Text(
                'Add option',
                style: TextStyle(color: AppColors.primary),
              ),
            ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              color: isDark ? AppColors.cardDark : Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SwitchListTile(
              value: _multi,
              onChanged: (v) => setState(() => _multi = v),
              title: const Text('Allow multiple answers'),
              activeColor: AppColors.primary,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Create Event page ──────────────────────────────────────────
class _CreateEventPage extends StatefulWidget {
  const _CreateEventPage();
  @override
  State<_CreateEventPage> createState() => _CreateEventPageState();
}

class _CreateEventPageState extends State<_CreateEventPage> {
  final _name = TextEditingController();
  DateTime? _date;
  TimeOfDay? _time;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _send() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Event ka naam likho')));
      return;
    }
    final whenParts = <String>[];
    if (_date != null)
      whenParts.add('${_date!.day}/${_date!.month}/${_date!.year}');
    if (_time != null) whenParts.add(_time!.format(context));
    final when = whenParts.isEmpty ? 'TBD' : whenParts.join(' — ');
    Navigator.pop(context, '📅 *Event:* $name\n🗓 $when');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        backgroundColor: isDark ? AppColors.bg2Dark : AppColors.headerGreen,
        foregroundColor: Colors.white,
        title: const Text('Create event'),
        actions: [
          TextButton(
            onPressed: _send,
            child: const Text(
              'SEND',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            decoration: BoxDecoration(
              color: isDark ? AppColors.cardDark : Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(
                hintText: 'Event name',
                border: InputBorder.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: isDark ? AppColors.cardDark : Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(
                    Icons.calendar_today,
                    color: AppColors.primary,
                  ),
                  title: Text(
                    _date == null
                        ? 'Pick date'
                        : '${_date!.day}/${_date!.month}/${_date!.year}',
                  ),
                  onTap: () async {
                    final d = await showDatePicker(
                      context: context,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                      initialDate: DateTime.now(),
                    );
                    if (d != null) setState(() => _date = d);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(
                    Icons.access_time,
                    color: AppColors.primary,
                  ),
                  title: Text(
                    _time == null ? 'Pick time' : _time!.format(context),
                  ),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.now(),
                    );
                    if (t != null) setState(() => _time = t);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
