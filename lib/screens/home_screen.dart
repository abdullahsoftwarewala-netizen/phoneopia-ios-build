import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';
import '../config/app_config.dart';
import '../providers/app_provider.dart';
import 'starred_messages_screen.dart';
import '../utils/open_nearby_chat.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import '../widgets/verified_badge.dart';

import 'active_call_screen.dart';
import 'chat_screen.dart';
import 'new_chat_screen.dart';
import 'settings_screen.dart';
import '../services/nearby_service.dart';
import 'contact_info_screen.dart';
import '../models/models.dart';
import '../utils/page_routes.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().refreshRecents();
      _requestCorePermissions();
      // Ensure the Phoneopia AI chat exists for every user (auto-provision +
      // pin), same as web — some mobile users never got it because it was only
      // created from the New Chat screen. Then refresh so it appears.
      ApiService.post('ai.php?action=setup_bot', {})
          .then((_) {
            if (mounted) context.read<AppProvider>().loadConversations();
          })
          .catchError((_) => <String, dynamic>{});
    });
  }

  // Ask for the permissions that make calls/notifications work when locked.
  // OS dialogs appear once; user grants them and never gets asked again.
  //
  // systemAlertWindow used to be requested here too. Nothing in this app
  // actually draws a system-level overlay (the incoming-call screen is a
  // normal Flutter route, and the locked-screen/backgrounded case already
  // goes through NotificationService's fullScreenIntent notification —
  // see notification_service.dart — which needs its own, separate
  // full-screen-intent permission, not this one). Android has no in-app
  // Allow/Deny dialog for systemAlertWindow at all — .request() for it is
  // implemented as a direct jump into Settings' "draw over other apps"
  // screen, unconditionally, the instant Home first loads after login.
  // That was the actual "app auto-redirects to Settings" behavior being
  // reported — requesting a permission this app never uses for anything.
  Future<void> _requestCorePermissions() async {
    try {
      final notif = await Permission.notification.request();
      // A backgrounded/killed-app incoming call is delivered entirely
      // through this notification — there's no way to ask for it again at
      // the moment a call actually arrives (no foreground UI to ask from).
      // Previously a single denial here was silent forever: no retry, no
      // indication anywhere that calls would now fail to surface while the
      // app isn't in front. Once Android reports it as permanently denied
      // (re-request no longer even shows the OS dialog), that's the one
      // case an explicit in-app Settings prompt is actually correct —
      // matches "only redirect to Settings after permanent denial".
      if (notif.isPermanentlyDenied && mounted) {
        unawaited(_showNotificationPermissionDialog());
      }
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {}
  }

  Future<void> _showNotificationPermissionDialog() async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final open = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: isDark ? AppColors.cardDark : Colors.white,
        title: const Text('Notification permission needed'),
        content: const Text(
          'Incoming calls and messages can\'t be shown while Phoneopia is in '
          'the background without notification permission. Enable it in Settings '
          'to keep receiving calls reliably.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
    if (open == true) unawaited(openAppSettings());
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prov = context.watch<AppProvider>();
    final myId = prov.me?.id;
    final myName = prov.me?.displayName;
    final pendingConv = prov.pendingOpenConvId;
    if (pendingConv != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _openPendingChat(pendingConv),
      );
    }
    return Stack(
      children: [
        Scaffold(
          backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
          appBar: _buildAppBar(isDark, myId, myName),
          body: _tab == 0
              ? const _ChatsTab()
              : _tab == 1
              ? const _CallsTab()
              : const _StatusTab(key: ValueKey('status')),
          floatingActionButton: _tab == 0
              ? FloatingActionButton(
                  onPressed: () => Navigator.push(
                    context,
                    slideRoute(const NewChatScreen()),
                  ),
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  highlightElevation: 4,
                  child: const Icon(Icons.chat_rounded, size: 24),
                )
              : _tab == 1
              ? FloatingActionButton(
                  onPressed: () => Navigator.push(
                    context,
                    slideRoute(const NewChatScreen()),
                  ),
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  highlightElevation: 4,
                  child: const Icon(Icons.add_call, size: 24),
                )
              : FloatingActionButton(
                  onPressed: () => _showStatusSourcePicker(
                    context,
                    onDone: () => context.read<AppProvider>().loadStatuses(),
                  ),
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  elevation: 2,
                  highlightElevation: 4,
                  child: const Icon(Icons.camera_alt_rounded, size: 24),
                ),
          bottomNavigationBar: _buildBottomNav(isDark),
        ),
        if (prov.switchingAccount)
          Positioned.fill(
            child: Material(
              color: Colors.black.withValues(alpha: 0.5),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.cardDark : Colors.white,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 3,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Switching account…',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _openPendingChat(int convId) async {
    final prov = context.read<AppProvider>();
    prov.consumePendingOpenConv();
    Conversation? conv = _findConv(prov, convId);
    // After an account switch the list may not be loaded yet → reload + retry.
    if (conv == null) {
      await prov.loadConversations();
      conv = _findConv(prov, convId);
    }
    if (conv != null && mounted) {
      Navigator.push(context, chatRoute(ChatScreen(conversation: conv)));
    }
  }

  Conversation? _findConv(AppProvider prov, int convId) {
    for (final c in prov.conversations) {
      if (c.id == convId) return c;
    }
    return null;
  }

  PreferredSizeWidget _buildAppBar(bool isDark, int? myId, String? myName) {
    return AppBar(
      backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
      foregroundColor: isDark ? AppColors.t1Dark : AppColors.t1Light,
      title: const SizedBox.shrink(),
      titleSpacing: 0,
      leadingWidth: myId != null ? 156 : 148,
      leading: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/images/logo.png',
                width: 34,
                height: 34,
                fit: BoxFit.contain,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'phoneopia',
                  style: TextStyle(
                    color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    letterSpacing: -0.4,
                  ),
                ),
                if ((myName != null && myName.trim().isNotEmpty) ||
                    myId != null)
                  Text(
                    (myName != null && myName.trim().isNotEmpty)
                        ? myName
                        : 'ID #$myId',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                      height: 1.1,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        PopupMenuButton<String>(
          icon: Icon(
            Icons.more_vert,
            color: isDark ? Colors.white : AppColors.t1Light,
          ),
          color: isDark ? AppColors.cardDark : Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.sm),
          ),
          onSelected: (v) {
            if (v == 'settings')
              Navigator.push(context, slideRoute(const SettingsScreen()));
            if (v == 'new_group') _showNewGroup();
            if (v == 'linked_devices')
              Navigator.pushNamed(context, '/linked_devices');
            if (v == 'starred')
              Navigator.push(
                context,
                slideRoute(const StarredMessagesScreen()),
              );
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'new_group', child: Text('New group')),
            const PopupMenuItem(
              value: 'linked_devices',
              child: Text('Linked devices'),
            ),
            const PopupMenuItem(
              value: 'starred',
              child: Text('Starred messages'),
            ),
            // No "Nearby devices" entry — Nearby is a filter chip in the
            // main list now (All/Unread/Favourites/Groups/Nearby), not a
            // separate screen to open.
            const PopupMenuItem(value: 'settings', child: Text('Settings')),
          ],
        ),
      ],
    );
  }

  Widget _buildBottomNav(bool isDark) => NavigationBar(
    selectedIndex: _tab,
    onDestinationSelected: (i) {
      setState(() => _tab = i);
      final prov = context.read<AppProvider>();
      if (i == 1) prov.loadCalls();
      if (i == 2) prov.loadStatuses();
    },
    backgroundColor: isDark ? AppColors.bg2Dark : Colors.white,
    indicatorColor: AppColors.primaryDim,
    labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    destinations: const [
      NavigationDestination(
        icon: Icon(Icons.chat_bubble_outline),
        selectedIcon: Icon(Icons.chat_bubble, color: AppColors.primary),
        label: 'Chats',
      ),
      NavigationDestination(
        icon: Icon(Icons.call_outlined),
        selectedIcon: Icon(Icons.call, color: AppColors.primary),
        label: 'Calls',
      ),
      NavigationDestination(
        icon: Icon(Icons.radio_button_unchecked),
        selectedIcon: Icon(
          Icons.radio_button_checked,
          color: AppColors.primary,
        ),
        label: 'Updates',
      ),
    ],
  );

  void _showNewGroup() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _NewGroupSheet(),
    );
  }

  void _showNearbyDevices() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _NearbyDevicesSheet(),
    );
  }
}

class _NearbyDevicesSheet extends StatelessWidget {
  const _NearbyDevicesSheet();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ChangeNotifierProvider.value(
      value: NearbyService(),
      child: Consumer<NearbyService>(
        builder: (context, nearby, _) {
          final ids = nearby.peers.keys.toList();
          return Container(
            constraints: const BoxConstraints(maxHeight: 520),
            decoration: BoxDecoration(
              color: dark ? AppColors.cardDark : Colors.white,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(26),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Icon(
                      Icons.wifi_tethering_rounded,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Nearby devices',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: dark
                                  ? AppColors.t1Dark
                                  : AppColors.t1Light,
                            ),
                          ),
                          Text(
                            nearby.advertising || nearby.discovering
                                ? 'Running in background'
                                : 'Starting nearby discovery…',
                            style: TextStyle(
                              fontSize: 12,
                              color: dark
                                  ? AppColors.t3Dark
                                  : AppColors.t3Light,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: nearby.refresh,
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (ids.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 34),
                    child: Column(
                      children: [
                        Icon(
                          Icons.devices_other_rounded,
                          size: 48,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'No nearby devices yet',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: dark ? AppColors.t1Dark : AppColors.t1Light,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          'Keep Phoneopia open or running in the background on both phones.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 12,
                            color: dark ? AppColors.t3Dark : AppColors.t3Light,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: ids.length,
                      itemBuilder: (_, i) {
                        final id = ids[i];
                        final name = nearby.peers[id] ?? 'Phoneopia device';
                        final state = nearby.peerState[id] ?? 'discovered';
                        final connected = state == 'connected';
                        return Card(
                          elevation: 0,
                          color: connected
                              ? AppColors.primaryDim
                              : (dark
                                    ? const Color(0xFF1F2C33)
                                    : const Color(0xFFF4F6F7)),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: connected
                                  ? AppColors.primary
                                  : Colors.blueGrey,
                              child: Text(
                                name.isNotEmpty ? name[0].toUpperCase() : '?',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                            title: Text(
                              name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            subtitle: Text(
                              connected
                                  ? 'Connected • tap to chat'
                                  : state == 'connecting'
                                  ? 'Connecting…'
                                  : 'Nearby device',
                            ),
                            trailing: connected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: AppColors.primary,
                                  )
                                : const Icon(Icons.link_rounded),
                            onTap: () async {
                              if (connected) {
                                await openNearbyChat(
                                  context,
                                  id,
                                  replace: true,
                                );
                              } else {
                                await nearby.connectTo(id);
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ChatsTab extends StatefulWidget {
  final String searchQuery;
  const _ChatsTab({this.searchQuery = ''});
  @override
  State<_ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<_ChatsTab> with WidgetsBindingObserver {
  final _searchCtrl = TextEditingController();
  String _query = '';
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppProvider>().refreshRecents();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.read<AppProvider>().refreshRecents();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchCtrl.dispose();
    super.dispose();
  }

  Widget _filterChip(String label, String key, bool isDark) {
    final sel = _filter == key;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          // Don't wait out the 900ms discovery debounce — a reachable peer
          // not yet promoted into the chat list should show up the instant
          // this tab is opened, not a moment later.
          if (key == 'nearby')
            context.read<AppProvider>().promoteReachableNearbyPeers();
          setState(() => _filter = key);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel
                ? AppColors.primary
                : (isDark ? const Color(0xFF1F2C33) : Colors.white),
            borderRadius: BorderRadius.circular(AppRadii.chip),
            border: Border.all(
              color: sel
                  ? AppColors.primary
                  : (isDark ? AppColors.borderDark : AppColors.borderLight),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: sel
                  ? Colors.white
                  : (isDark ? Colors.white70 : const Color(0xFF54656F)),
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
    final q = widget.searchQuery.isNotEmpty ? widget.searchQuery : _query;
    var convs = prov.conversations;
    if (q.isNotEmpty) {
      final ql = q.toLowerCase();
      convs = convs
          .where(
            (c) =>
                c.displayName.toLowerCase().contains(ql) ||
                (c.lastMessageContent ?? '').toLowerCase().contains(ql),
          )
          .toList();
    }
    if (_filter == 'unread')
      convs = convs.where((c) => c.unreadCount > 0).toList();
    if (_filter == 'fav') convs = convs.where((c) => c.isPinned).toList();
    if (_filter == 'groups')
      convs = convs.where((c) => c.type == 'group').toList();
    if (_filter == 'nearby')
      // isUserNearby, not isUserReachable — a peer still mid-handshake
      // belongs in this tab too, not just ones already fully connected.
      convs = convs
          .where(
            (c) =>
                c.otherUser != null &&
                NearbyService().isUserNearby(c.otherUser!.id),
          )
          .toList();

    // Always show pinned chats on top (then Nearby-reachable, then newest
    // first) — guarantees a pinned chat never sinks to the bottom regardless
    // of upstream ordering, and mirrors AppProvider._sortConversations'
    // grouping so this local re-sort doesn't quietly undo it.
    convs = [...convs]
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        final ar = a.otherUser != null &&
            NearbyService().isUserNearby(a.otherUser!.id);
        final br = b.otherUser != null &&
            NearbyService().isUserNearby(b.otherUser!.id);
        if (ar != br) return ar ? -1 : 1;
        final at = a.lastMessageAt ?? DateTime(2000);
        final bt = b.lastMessageAt ?? DateTime(2000);
        return bt.compareTo(at);
      });

    return Column(
      children: [
        // WhatsApp-style search bar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Container(
            height: 42,
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1F2C33) : const Color(0xFFF0F2F5),
              borderRadius: BorderRadius.circular(AppRadii.input),
            ),
            child: Row(
              children: [
                const SizedBox(width: 14),
                Icon(
                  Icons.search,
                  size: 20,
                  color: isDark ? Colors.white38 : const Color(0xFF667781),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(
                      fontSize: 14.5,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Search chats or contacts...',
                      hintStyle: TextStyle(
                        color: isDark
                            ? Colors.white38
                            : const Color(0xFF8696A0),
                        fontSize: 14.5,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (_query.isNotEmpty)
                  GestureDetector(
                    onTap: () {
                      _searchCtrl.clear();
                      setState(() => _query = '');
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: isDark
                            ? Colors.white38
                            : const Color(0xFF667781),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Filter chips — All / Unread / Favourites / Groups (matches web)
        SizedBox(
          height: 34,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _filterChip('All', 'all', isDark),
              _filterChip('Nearby', 'nearby', isDark),
              _filterChip('Unread', 'unread', isDark),
              _filterChip('Favourites', 'fav', isDark),
              _filterChip('Groups', 'groups', isDark),
            ],
          ),
        ),
        const SizedBox(height: 6),

        if (_filter == 'nearby')
          ListenableBuilder(
            listenable: NearbyService(),
            builder: (_, __) {
              final nearby = NearbyService();
              final found = nearby.peerState.length;
              final label = found == 0
                  ? (nearby.discovering || nearby.advertising
                        ? 'Finding nearby devices…'
                        : 'Starting discovery…')
                  : found == 1
                  ? '1 device found'
                  : '$found devices found';
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: found == 0
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : const Icon(
                              Icons.bluetooth_connected_rounded,
                              size: 14,
                              color: AppColors.primary,
                            ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

        if (convs.isEmpty && !prov.loading)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primaryDim,
                    ),
                    child: const Icon(
                      Icons.chat_bubble_outline_rounded,
                      size: 42,
                      color: AppColors.primaryDark,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _filter == 'unread'
                        ? 'No unread chats'
                        : _filter == 'fav'
                        ? 'No favourites yet'
                        : _filter == 'groups'
                        ? 'No groups yet'
                        : _filter == 'nearby'
                        ? 'No one is nearby right now'
                        : 'No chats yet',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    q.isNotEmpty
                        ? 'Try a different search'
                        : _filter == 'nearby'
                        ? 'Chats will appear here automatically\nwhen another Phoneopia phone is nearby'
                        : 'Start a conversation by tapping the\nchat button below',
                    style: TextStyle(
                      fontSize: 13,
                      color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: RefreshIndicator(
              color: AppColors.primary,
              onRefresh: prov.loadConversations,
              child: ListView.separated(
                itemCount: convs.length,
                separatorBuilder: (_, __) => Divider(
                  height: 0.5,
                  indent: 82,
                  endIndent: 0,
                  color: isDark
                      ? const Color(0xFF2A3942)
                      : const Color(0xFFE9EDEF),
                  thickness: 0.5,
                ),
                itemBuilder: (ctx, i) => _AnimatedConvTile(
                  conv: convs[i],
                  index: i,
                  showNearbyStatus: _filter == 'nearby',
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AnimatedConvTile extends StatelessWidget {
  final Conversation conv;
  final int index;
  final bool showNearbyStatus;
  const _AnimatedConvTile({
    required this.conv,
    required this.index,
    this.showNearbyStatus = false,
  });
  @override
  Widget build(BuildContext context) =>
      _ConvTile(conv: conv, showNearbyStatus: showNearbyStatus);
}

class _ConvTile extends StatelessWidget {
  final Conversation conv;
  final bool showNearbyStatus;
  const _ConvTile({required this.conv, this.showNearbyStatus = false});

  /// "Connected" / "Connecting…" next to the name while the Nearby tab is
  /// open — null (fall back to the normal last-message preview) otherwise,
  /// or if this peer isn't nearby right now after all (list hasn't caught
  /// up with a just-lost connection yet).
  String? _nearbyStatusText(int? otherUserId) {
    if (!showNearbyStatus || otherUserId == null) return null;
    final nearby = NearbyService();
    switch (nearby.nearbyStateForUser(otherUserId)) {
      case 'connected':
        return 'Connected';
      case 'connecting':
        return 'Connecting…';
      case 'discovered':
        return 'Found — connecting…';
      default:
        // The row only exists in this tab because isUserNearby(otherUserId)
        // was true when the list was filtered — that's a broader, looser
        // check than nearbyStateForUser's exact string match (see
        // isUserNearby's own comment), so don't fall through to a blank/stale
        // last-message preview on a brand new Nearby conversation just
        // because the two didn't land on the exact same peerState string.
        return nearby.isUserNearby(otherUserId) ? 'Connecting…' : null;
    }
  }

  String _previewFor(int myId, Conversation c) {
    final type = c.lastMessageType ?? 'text';
    final content = c.lastMessageContent ?? '';
    // "You:" prefix when the last message was sent by me (not for calls/system).
    final mine = (c.lastMessageSender ?? 0) == myId && myId != 0;
    String p(String s) =>
        (mine && type != 'call' && type != 'system') ? 'You: $s' : s;
    switch (type) {
      case 'image':
        return p('📷 Photo');
      case 'audio':
      case 'voice':
        return p('🎙 Voice message');
      case 'video':
        return p('🎥 Video');
      case 'file':
        return p('📎 Document');
      case 'call':
        {
          final sender = c.lastMessageSender ?? 0;
          final raw = content.trim();
          var callType = 'audio', status = 'missed';
          var dur = 0;
          if (raw.contains('|')) {
            final p = raw.split('|');
            callType = p.isNotEmpty ? p[0] : 'audio';
            status = p.length > 1 ? p[1] : 'missed';
            dur = p.length > 2 ? int.tryParse(p[2]) ?? 0 : 0;
          }
          final isOut = sender == myId;
          final answered = status == 'answered' || status == 'completed';
          final ringing = status == 'ringing' || status == 'outgoing';
          final missed =
              !answered &&
              !ringing &&
              (status == 'missed' || status == 'rejected');
          final vid = callType == 'video';
          if (ringing) {
            return isOut
                ? (vid ? '📹 Outgoing video call' : '📞 Outgoing call')
                : (vid ? '📹 Incoming video call' : '📞 Incoming call');
          }
          if (!isOut && missed)
            return vid ? '📹 Missed video call' : '📞 Missed voice call';
          if (answered && dur > 0) {
            final m = dur ~/ 60;
            final s = (dur % 60).toString().padLeft(2, '0');
            return '📞 ${vid ? 'Video' : 'Voice'} call · $m:$s';
          }
          return vid ? '📹 Video call' : '📞 Voice call';
        }
      default:
        return p(content);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prov = context.watch<AppProvider>();
    final live = prov.sanitizeConversation(
      prov.conversationById(conv.id) ?? conv,
    );
    final peerName = prov.peerDisplayName(live);
    final peerAvatar = prov.peerAvatar(live);
    final isAi = live.isAiBot || live.isVerified;
    final myId = prov.me?.id ?? 0;

    return InkWell(
      onTap: () =>
          Navigator.push(context, chatRoute(ChatScreen(conversation: live))),
      onLongPress: () => _showOptions(context, live),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Colors.transparent,
        child: Row(
          children: [
            SizedBox(
              width: 52,
              height: 52,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  AvatarWidget(
                    imageUrl: peerAvatar.isNotEmpty ? peerAvatar : null,
                    name: peerName,
                    size: 52,
                    showOnline: true,
                    status: live.otherUser?.status ?? 'offline',
                    isAiBot: isAi,
                  ),
                  if (live.isPinned)
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.bg2Dark : AppColors.bgLight,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.push_pin,
                          size: 10,
                          color: AppColors.primary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                peerName,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: isDark
                                      ? AppColors.t1Dark
                                      : AppColors.t1Light,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isAi) ...[
                              const SizedBox(width: 4),
                              const VerifiedBadge(size: 16),
                            ],
                          ],
                        ),
                      ),
                      if (live.lastMessageAt != null)
                        Text(
                          _formatTime(live.lastMessageAt!),
                          style: TextStyle(
                            fontSize: 12,
                            color: live.unreadCount > 0
                                ? AppColors.primary
                                : (isDark
                                      ? AppColors.t3Dark
                                      : AppColors.t3Light),
                            fontWeight: live.unreadCount > 0
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Builder(builder: (_) {
                        final nearbyStatus = _nearbyStatusText(
                          live.otherUser?.id,
                        );
                        if (nearbyStatus == null) {
                          return Expanded(
                            child: Text(
                              _previewFor(myId, live),
                              style: TextStyle(
                                fontSize: 13,
                                color: isDark
                                    ? AppColors.t3Dark
                                    : AppColors.t3Light,
                                fontWeight: live.unreadCount > 0
                                    ? FontWeight.w500
                                    : FontWeight.normal,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E88E5).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            nearbyStatus,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF1E88E5),
                            ),
                          ),
                        );
                      }),
                      if (_nearbyStatusText(live.otherUser?.id) != null)
                        const Spacer(),
                      if (live.unreadCount > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: live.isMuted
                                ? Colors.grey
                                : AppColors.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            live.unreadCount > 99
                                ? '99+'
                                : live.unreadCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (live.isMuted && live.unreadCount == 0)
                        const Icon(
                          Icons.volume_off,
                          size: 14,
                          color: AppColors.t3Light,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showOptions(BuildContext context, Conversation tile) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final prov = context.read<AppProvider>();
    final peerName = prov.peerDisplayName(tile);
    final peerAvatar = prov.peerAvatar(tile);
    void snack(String m) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(m), duration: const Duration(seconds: 2)),
    );
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
            ListTile(
              leading: AvatarWidget(
                imageUrl: peerAvatar.isNotEmpty ? peerAvatar : null,
                name: peerName,
                size: 40,
              ),
              title: Text(
                peerName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(
                tile.isMuted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(
                tile.isMuted ? 'Unmute notifications' : 'Mute notifications',
              ),
              onTap: () async {
                Navigator.pop(context);
                final r = await ApiService.muteConversation(
                  tile.id,
                ).catchError((_) => <String, dynamic>{});
                snack(r['is_muted'] == true ? 'Muted' : 'Unmuted');
                prov.loadConversations();
              },
            ),
            ListTile(
              leading: Icon(
                tile.isPinned ? Icons.push_pin_outlined : Icons.push_pin,
              ),
              title: Text(tile.isPinned ? 'Unpin chat' : 'Pin chat'),
              onTap: () async {
                Navigator.pop(context);
                await ApiService.pinConversation(
                  tile.id,
                ).catchError((_) => <String, dynamic>{});
                prov.loadConversations();
              },
            ),
            if (tile.unreadCount > 0)
              ListTile(
                leading: const Icon(Icons.mark_chat_read_outlined),
                title: const Text('Mark as read'),
                onTap: () async {
                  Navigator.pop(context);
                  await ApiService.post('conversations.php?action=mark_read', {
                    'conversation_id': tile.id,
                  }).catchError((_) => <String, dynamic>{});
                  prov.loadConversations();
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(tile.isGroup ? 'Group info' : 'Contact info'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ContactInfoScreen(conversation: tile),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.danger,
              ),
              title: const Text(
                'Delete chat',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: () async {
                Navigator.pop(context);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: isDark ? AppColors.cardDark : Colors.white,
                    title: const Text('Delete chat'),
                    content: Text('Delete this chat with $peerName?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(
                            color: AppColors.danger,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await ApiService.deleteConversation(
                    tile.id,
                  ).catchError((_) => <String, dynamic>{});
                  snack('Chat deleted');
                  prov.loadConversations();
                }
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return DateFormat('HH:mm').format(dt);
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return DateFormat('EEE').format(dt);
    return DateFormat('dd/MM/yy').format(dt);
  }
}

class _CallsTab extends StatefulWidget {
  const _CallsTab();
  @override
  State<_CallsTab> createState() => _CallsTabState();
}

class _CallsTabState extends State<_CallsTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<AppProvider>().loadCalls(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<AppProvider>();
    final myId = prov.me?.id ?? 0;
    final calls = prov.callLogs;

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: prov.loadCalls,
      child: ListView(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                _chip(
                  Icons.call,
                  'New call',
                  () => Navigator.push(
                    context,
                    slideRoute(const NewChatScreen()),
                  ),
                ),
                const SizedBox(width: 12),
                _chip(Icons.group_add, 'New group call', () {}),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              calls.isEmpty ? 'Recent' : 'Recent (${calls.length})',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111B21),
              ),
            ),
          ),
          if (calls.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.call_outlined,
                      size: 56,
                      color: Color(0xFFD1D7DB),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No recent calls',
                      style: TextStyle(color: Color(0xFF667781), fontSize: 15),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Your call history will appear here',
                      style: TextStyle(color: Color(0xFFB0B8BF), fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          else
            ...calls.asMap().entries.map(
              (e) => _CallLogTile(log: e.value, myId: myId, index: e.key),
            ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, VoidCallback onTap) => Expanded(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F2F5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppColors.primary, size: 20),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111B21),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _CallLogTile extends StatefulWidget {
  final Map<String, dynamic> log;
  final int myId;
  final int index;
  const _CallLogTile({
    required this.log,
    required this.myId,
    required this.index,
  });
  @override
  State<_CallLogTile> createState() => _CallLogTileState();
}

class _CallLogTileState extends State<_CallLogTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    Future.delayed(Duration(milliseconds: widget.index * 50), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final log = widget.log;
    final isOutgoing = int.tryParse(log['caller_id'].toString()) == widget.myId;
    final status = log['status'] ?? 'outgoing';
    final isMissed = status == 'missed';
    const isVideo = false;

    final name = isOutgoing
        ? (log['callee_name'] ?? 'Unknown')
        : (log['caller_name'] ?? 'Unknown');
    final avatar = isOutgoing ? log['callee_avatar'] : log['caller_avatar'];

    final iconData = isOutgoing
        ? Icons.call_made_rounded
        : (isMissed ? Icons.phone_rounded : Icons.call_received_rounded);
    final iconColor = isMissed ? Colors.red : AppColors.primary;

    DateTime? dt;
    try {
      dt = DateTime.parse(log['created_at'].toString()).toLocal();
    } catch (_) {}
    final timeStr = dt != null ? DateFormat('d MMM, h:mm a').format(dt) : '';

    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: _c.value,
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - _c.value)),
          child: child,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: AvatarWidget(
          imageUrl: avatar?.toString(),
          name: name.toString(),
          size: 50,
        ),
        title: Text(
          name.toString(),
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: isMissed ? Colors.red : const Color(0xFF111B21),
            fontSize: 15,
          ),
        ),
        subtitle: Row(
          children: [
            Icon(iconData, size: 14, color: iconColor),
            const SizedBox(width: 4),
            Text(
              '$timeStr${log['duration'] != null && int.tryParse(log['duration'].toString())! > 0 ? '  •  ${_fmtDur(int.parse(log['duration'].toString()))}' : ''}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF667781)),
            ),
          ],
        ),
        trailing: GestureDetector(
          onTap: () => _startCall(context, isVideo: isVideo),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primaryDim,
            ),
            child: Icon(Icons.call_rounded, color: AppColors.primary, size: 20),
          ),
        ),
        onTap: () => _startCall(context, isVideo: isVideo),
      ),
    );
  }

  void _startCall(BuildContext ctx, {required bool isVideo}) {
    final log = widget.log;
    final isOutgoing = int.tryParse(log['caller_id'].toString()) == widget.myId;
    final peerId = isOutgoing
        ? int.tryParse(log['callee_id']?.toString() ?? '0') ?? 0
        : int.tryParse(log['caller_id']?.toString() ?? '0') ?? 0;
    if (peerId <= 0) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Cannot call — contact not found'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final name = isOutgoing
        ? (log['callee_name'] ?? 'Unknown')
        : (log['caller_name'] ?? 'Unknown');
    final avatar = isOutgoing ? log['callee_avatar'] : log['caller_avatar'];
    final prov = ctx.read<AppProvider>();
    final convId = prov.conversationIdForPeer(peerId);
    prov.startOutgoingCallRing();
    Navigator.push(
      ctx,
      slideRoute(
        ActiveCallScreen(
          callerName: name.toString(),
          callerAvatar: avatar?.toString(),
          isVideo: false,
          convId: convId,
          isOutgoing: true,
          calleeUserId: peerId,
        ),
      ),
    ).then((_) => prov.stopRing());
  }

  String _fmtDur(int s) {
    if (s < 60) return '${s}s';
    if (s < 3600) return '${s ~/ 60}m ${s % 60}s';
    return '${s ~/ 3600}h ${(s % 3600) ~/ 60}m';
  }
}

// ── Status / Updates Tab ──────────────────────────────────────────────────────
class _StatusTab extends StatefulWidget {
  const _StatusTab({super.key});
  @override
  State<_StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends State<_StatusTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => context.read<AppProvider>().loadStatuses(),
    );
  }

  void _showMyStatusOptions(
    BuildContext ctx,
    Map<String, dynamic> myGroup,
    AppProvider prov,
  ) {
    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            ListTile(
              leading: const Icon(
                Icons.add_circle_outline,
                color: AppColors.primary,
              ),
              title: const Text(
                'Add to status',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _showStatusSourcePicker(ctx, onDone: () => prov.loadStatuses());
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text(
                'Delete status',
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: Colors.red,
                ),
              ),
              onTap: () async {
                Navigator.pop(ctx);
                final statuses = myGroup['statuses'] as List? ?? [];
                for (final s in statuses) {
                  try {
                    await ApiService.post('statuses.php?action=delete', {
                      'id': s['id'],
                    });
                  } catch (_) {}
                }
                prov.loadStatuses();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prov = context.watch<AppProvider>();
    final me = prov.me;
    final groups = prov.statusGroups;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? AppColors.bg2Dark : Colors.white;

    // Separate my status from others
    final myGroup = groups.isNotEmpty && groups.first['is_me'] == true
        ? groups.first
        : null;
    final myStatuses = myGroup != null
        ? (myGroup['statuses'] as List?) ?? []
        : [];
    final otherGroups = groups.where((g) => g['is_me'] != true).toList();
    final unviewed = otherGroups.where((g) => g['all_viewed'] != true).toList();
    final viewed = otherGroups.where((g) => g['all_viewed'] == true).toList();

    if (prov.statusesLoading && groups.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: prov.loadStatuses,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          if (prov.statusesError != null)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Colors.red.shade700,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      prov.statusesError!,
                      style: TextStyle(
                        color: Colors.red.shade800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: prov.loadStatuses,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          // ── My Status ──────────────────────────────────────────────────────
          Container(
            color: surface,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 8,
              ),
              onTap: () {
                if (myStatuses.isNotEmpty) {
                  Navigator.push(
                    context,
                    slideRoute(_StatusViewPage(group: myGroup!)),
                  );
                } else {
                  _showStatusSourcePicker(
                    context,
                    onDone: () => prov.loadStatuses(),
                  );
                }
              },
              leading: GestureDetector(
                onTap: () => _showStatusSourcePicker(
                  context,
                  onDone: () => prov.loadStatuses(),
                ),
                child: Stack(
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: myStatuses.isNotEmpty
                            ? Border.all(color: AppColors.primary, width: 2.5)
                            : Border.all(
                                color: const Color(0xFFD1D7DB),
                                width: 1.5,
                              ),
                        color: const Color(0xFFF0F2F5),
                      ),
                      padding: const EdgeInsets.all(2.5),
                      child: AvatarWidget(
                        imageUrl: me?.avatar,
                        name: me?.displayName ?? 'Me',
                        size: 48,
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary,
                        ),
                        child: const Icon(
                          Icons.add,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              title: const Text(
                'My Status',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111B21),
                ),
              ),
              subtitle: Text(
                myStatuses.isNotEmpty
                    ? 'Tap to view your status'
                    : 'Tap to add status update',
                style: const TextStyle(fontSize: 13, color: Color(0xFF667781)),
              ),
              trailing: myStatuses.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.more_vert,
                        color: Color(0xFF667781),
                      ),
                      onPressed: () =>
                          _showMyStatusOptions(context, myGroup!, prov),
                    )
                  : const Icon(Icons.more_vert, color: Color(0xFF667781)),
            ),
          ),
          const Divider(height: 1),

          // ── Recent updates ─────────────────────────────────────────────────
          if (unviewed.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                'RECENT UPDATES',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF667781),
                  letterSpacing: 0.8,
                ),
              ),
            ),
            ...unviewed.asMap().entries.map(
              (e) =>
                  _StatusGroupTile(group: e.value, index: e.key, viewed: false),
            ),
          ],

          if (viewed.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                'VIEWED UPDATES',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF667781),
                  letterSpacing: 0.8,
                ),
              ),
            ),
            ...viewed.asMap().entries.map(
              (e) => _StatusGroupTile(
                group: e.value,
                index: e.key + unviewed.length,
                viewed: true,
              ),
            ),
          ],

          if (otherGroups.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.circle_outlined,
                      size: 56,
                      color: Color(0xFFD1D7DB),
                    ),
                    SizedBox(height: 12),
                    Text(
                      'No status updates',
                      style: TextStyle(color: Color(0xFF667781), fontSize: 15),
                    ),
                    SizedBox(height: 4),
                    Text(
                      "Your contacts' status updates will appear here",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFFB0B8BF), fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _StatusGroupTile extends StatefulWidget {
  final Map<String, dynamic> group;
  final int index;
  final bool viewed;
  const _StatusGroupTile({
    required this.group,
    required this.index,
    required this.viewed,
  });
  @override
  State<_StatusGroupTile> createState() => _StatusGroupTileState();
}

class _StatusGroupTileState extends State<_StatusGroupTile>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    Future.delayed(Duration(milliseconds: widget.index * 60), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.group['user'] as Map? ?? {};
    final statuses = widget.group['statuses'] as List? ?? [];
    final name = user['display_name'] ?? user['username'] ?? 'Unknown';
    final avatarUrl = user['avatar']?.toString();
    final latest = statuses.isNotEmpty ? statuses.first as Map : null;
    DateTime? dt;
    try {
      dt = latest != null
          ? DateTime.parse(latest['created_at'].toString()).toLocal()
          : null;
    } catch (_) {}
    final timeStr = dt != null ? DateFormat('h:mm a').format(dt) : '';

    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: _c.value,
        child: Transform.translate(
          offset: Offset(0, 12 * (1 - _c.value)),
          child: child,
        ),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        onTap: () => Navigator.push(
          context,
          slideRoute(_StatusViewPage(group: widget.group)),
        ),
        leading: Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: widget.viewed
                  ? const Color(0xFFD1D7DB)
                  : AppColors.primary,
              width: 2.5,
            ),
            color: const Color(0xFFF0F2F5),
          ),
          padding: const EdgeInsets.all(2.5),
          child: AvatarWidget(
            imageUrl: avatarUrl,
            name: name.toString(),
            size: 44,
          ),
        ),
        title: Text(
          name.toString(),
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Color(0xFF111B21),
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          timeStr,
          style: const TextStyle(fontSize: 12, color: Color(0xFF667781)),
        ),
        trailing: statuses.length > 1
            ? Text(
                '${statuses.length}',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF667781),
                  fontWeight: FontWeight.w600,
                ),
              )
            : null,
      ),
    );
  }
}

// ignore: unused_element
class _AiTab extends StatefulWidget {
  const _AiTab();
  @override
  State<_AiTab> createState() => _AiTabState();
}

class _AiTabState extends State<_AiTab> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, String>> _msgs = [];
  bool _loading = false;

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _loading) return;
    _ctrl.clear();
    setState(() {
      _msgs.add({'role': 'user', 'content': text});
      _loading = true;
    });
    _scrollDown();
    try {
      final msgs = _msgs
          .map((m) => {'role': m['role']!, 'content': m['content']!})
          .toList();
      final r = await ApiService.post('ai.php?action=chat', {'messages': msgs});
      if (!mounted) return;
      setState(() {
        _msgs.add({
          'role': 'assistant',
          'content': r['reply']?.toString() ?? 'Sorry, could not respond.',
        });
        _loading = false;
      });
      _scrollDown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _msgs.add({
          'role': 'assistant',
          'content': 'Network error, please try again.',
        });
        _loading = false;
      });
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.hasContentDimensions)
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        if (_msgs.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [AppColors.primary, AppColors.primaryDeeper],
                      ),
                    ),
                    child: const Icon(
                      Icons.auto_awesome,
                      color: Colors.white,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Phoneopia AI',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Ask me anything!',
                    style: TextStyle(
                      fontSize: 14,
                      color: isDark ? AppColors.t3Dark : AppColors.t3Light,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _chip('✍️ Help me write a message'),
                      _chip('🌐 Translate something'),
                      _chip('💡 Summarize a long text'),
                      _chip('😄 Tell me a joke'),
                    ],
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(16),
              itemCount: _msgs.length + (_loading ? 1 : 0),
              itemBuilder: (ctx, i) {
                if (i == _msgs.length) return _typingIndicator(isDark);
                final m = _msgs[i];
                final isUser = m['role'] == 'user';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    mainAxisAlignment: isUser
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (!isUser) ...[
                        Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primaryDeeper,
                          ),
                          child: const Icon(
                            Icons.auto_awesome,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          constraints: const BoxConstraints(maxWidth: 280),
                          decoration: BoxDecoration(
                            color: isUser
                                ? AppColors.primary
                                : (isDark ? AppColors.cardDark : Colors.white),
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(18),
                              topRight: const Radius.circular(18),
                              bottomLeft: Radius.circular(isUser ? 18 : 4),
                              bottomRight: Radius.circular(isUser ? 4 : 18),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(.06),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            m['content'] ?? '',
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.45,
                              color: isUser
                                  ? Colors.white
                                  : (isDark
                                        ? AppColors.t1Dark
                                        : AppColors.t1Light),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        _inputBar(isDark),
      ],
    );
  }

  Widget _chip(String label) => GestureDetector(
    onTap: () {
      _ctrl.text = label;
      _send();
    },
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.primaryDim,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.primary.withOpacity(.3)),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 13, color: AppColors.primaryDark),
      ),
    ),
  );

  Widget _typingIndicator(bool isDark) => Row(
    children: [
      Container(
        width: 32,
        height: 32,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.primaryDeeper,
        ),
        child: const Icon(Icons.auto_awesome, color: Colors.white, size: 16),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? AppColors.cardDark : Colors.white,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(18),
            topRight: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dot(0),
            const SizedBox(width: 4),
            _dot(100),
            const SizedBox(width: 4),
            _dot(200),
          ],
        ),
      ),
    ],
  );

  Widget _dot(int delay) => TweenAnimationBuilder<double>(
    tween: Tween(begin: .3, end: 1),
    duration: const Duration(milliseconds: 600),
    builder: (_, v, c) => Opacity(opacity: v, child: c),
    child: Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.primary,
      ),
    ),
  );

  Widget _inputBar(bool isDark) => Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
    decoration: BoxDecoration(
      color: isDark ? AppColors.bg2Dark : Colors.white,
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(.06),
          blurRadius: 8,
          offset: const Offset(0, -2),
        ),
      ],
    ),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _ctrl,
            onSubmitted: (_) => _send(),
            decoration: InputDecoration(
              hintText: 'Ask Phoneopia AI...',
              filled: true,
              fillColor: isDark ? AppColors.panelDark : AppColors.bgLight,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _send,
          child: Container(
            width: 46,
            height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary,
            ),
            child: const Icon(
              Icons.send_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
      ],
    ),
  );
}

// ── Status Source Picker ──────────────────────────────────────────────────────
void _showStatusSourcePicker(BuildContext ctx, {VoidCallback? onDone}) {
  showModalBottomSheet(
    context: ctx,
    backgroundColor: Colors.transparent,
    builder: (_) => Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Text(
            'Add Status Update',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111B21),
            ),
          ),
          const SizedBox(height: 20),
          _statusSourceTile(
            ctx,
            Icons.camera_alt_rounded,
            'Camera',
            'Take a photo or video',
            fromCamera: true,
            onDone: onDone,
          ),
          const SizedBox(height: 10),
          _statusSourceTile(
            ctx,
            Icons.photo_library_rounded,
            'Gallery',
            'Choose from your photos & videos',
            fromCamera: false,
            onDone: onDone,
          ),
          const SizedBox(height: 10),
          _statusSourceTile(
            ctx,
            Icons.text_fields_rounded,
            'Text',
            'Create a text status',
            fromCamera: false,
            textOnly: true,
            onDone: onDone,
          ),
        ],
      ),
    ),
  );
}

Widget _statusSourceTile(
  BuildContext ctx,
  IconData icon,
  String title,
  String subtitle, {
  required bool fromCamera,
  bool textOnly = false,
  VoidCallback? onDone,
}) {
  return InkWell(
    onTap: () async {
      Navigator.pop(ctx);
      if (textOnly) {
        final result = await Navigator.push(
          ctx,
          slideRoute(_StatusComposePage(file: null, isVideo: false)),
        );
        if (result == true) onDone?.call();
      } else {
        final picker = ImagePicker();
        XFile? file;
        bool isVideo = false;
        if (fromCamera) {
          final choice = await showDialog<String>(
            context: ctx,
            builder: (d) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Camera'),
              content: const Text('What would you like to capture?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d, 'photo'),
                  child: const Text('Photo'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(d, 'video'),
                  child: const Text('Video'),
                ),
              ],
            ),
          );
          if (choice == 'photo') {
            file = await picker.pickImage(
              source: ImageSource.camera,
              imageQuality: 85,
            );
          } else if (choice == 'video') {
            file = await picker.pickVideo(
              source: ImageSource.camera,
              maxDuration: const Duration(seconds: 30),
            );
            isVideo = true;
          }
        } else {
          final choice = await showDialog<String>(
            context: ctx,
            builder: (d) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Text('Gallery'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d, 'photo'),
                  child: const Text('Photo'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(d, 'video'),
                  child: const Text('Video'),
                ),
              ],
            ),
          );
          if (choice == 'photo') {
            file = await picker.pickImage(
              source: ImageSource.gallery,
              imageQuality: 85,
            );
          } else if (choice == 'video') {
            file = await picker.pickVideo(source: ImageSource.gallery);
            isVideo = true;
          }
        }
        if (file != null && ctx.mounted) {
          final result = await Navigator.push(
            ctx,
            slideRoute(_StatusComposePage(file: file, isVideo: isVideo)),
          );
          if (result == true) onDone?.call();
        }
      }
    },
    borderRadius: BorderRadius.circular(14),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F2F5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primaryDim,
            ),
            child: Icon(icon, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111B21),
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF667781),
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFFD1D7DB)),
        ],
      ),
    ),
  );
}

// ── Status Compose Page ───────────────────────────────────────────────────────
class _StatusComposePage extends StatefulWidget {
  final XFile? file;
  final bool isVideo;
  const _StatusComposePage({required this.file, required this.isVideo});
  @override
  State<_StatusComposePage> createState() => _StatusComposePageState();
}

class _StatusComposePageState extends State<_StatusComposePage> {
  final _captionCtrl = TextEditingController();
  bool _posting = false;
  Color _bgColor = AppColors.primary;
  VideoPlayerController? _videoCtrl;

  static const _bgColors = [
    AppColors.primary,
    Color(0xFF0037FF),
    Color(0xFFD4006B),
    Color(0xFF8B0000),
    Color(0xFF1A1A1A),
    Color(0xFF5C3317),
  ];

  @override
  void initState() {
    super.initState();
    if (widget.isVideo && widget.file != null) {
      _videoCtrl = VideoPlayerController.file(File(widget.file!.path))
        ..setLooping(true)
        ..initialize().then((_) {
          if (mounted) {
            _videoCtrl!.play();
            setState(() {});
          }
        });
    }
  }

  @override
  void dispose() {
    _captionCtrl.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  Future<void> _post() async {
    setState(() => _posting = true);
    try {
      String? mediaUrl;
      String type = 'text';
      if (widget.file != null) {
        final bytes = await widget.file!.readAsBytes();
        final filename = widget.file!.name;
        final uploadRes = await ApiService.uploadStatusMedia(bytes, filename);
        if (uploadRes['success'] != true)
          throw Exception(uploadRes['error'] ?? 'Upload failed');
        final raw = uploadRes['url']?.toString() ?? '';
        if (raw.isEmpty) throw Exception('Media upload returned no URL');
        mediaUrl = raw.startsWith('/') ? '${AppConfig.mediaBase}$raw' : raw;
        type = widget.isVideo ? 'video' : 'image';
      }
      final colorHex =
          '#${_bgColor.value.toRadixString(16).substring(2).toUpperCase()}';
      final postRes = await ApiService.post('statuses.php?action=post', {
        'content': _captionCtrl.text.trim(),
        'type': type,
        if (mediaUrl != null) 'media_url': mediaUrl,
        'bg_color': colorHex,
      });
      if (postRes['success'] == false || postRes['error'] != null) {
        throw Exception(
          postRes['error']?.toString() ?? 'Could not publish status',
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _posting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isVideo
                  ? 'Video could not be posted. Please try again.'
                  : 'Post could not be published. Please try again.',
            ),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isText = widget.file == null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Background — image or colored
          Positioned.fill(
            child: isText
                ? AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    color: _bgColor,
                    child: const SizedBox.expand(),
                  )
                : widget.isVideo
                ? (_videoCtrl?.value.isInitialized == true
                      ? Center(
                          child: AspectRatio(
                            aspectRatio: _videoCtrl!.value.aspectRatio,
                            child: VideoPlayer(_videoCtrl!),
                          ),
                        )
                      : const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ))
                : Image.file(File(widget.file!.path), fit: BoxFit.contain),
          ),
          // Text overlay for text status
          if (isText)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: TextField(
                  controller: _captionCtrl,
                  maxLines: 5,
                  minLines: 1,
                  textAlign: TextAlign.center,
                  autofocus: true,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Type a status...',
                    hintStyle: TextStyle(color: Colors.white60, fontSize: 22),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
          // Top bar
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    if (isText) ...[
                      for (final c in _bgColors)
                        GestureDetector(
                          onTap: () => setState(() => _bgColor = c),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            width: _bgColor == c ? 28 : 22,
                            height: _bgColor == c ? 28 : 22,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c,
                              border: _bgColor == c
                                  ? Border.all(color: Colors.white, width: 2.5)
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          // Bottom bar
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              padding: EdgeInsets.fromLTRB(
                12,
                8,
                12,
                MediaQuery.of(context).viewInsets.bottom +
                    MediaQuery.of(context).padding.bottom +
                    12,
              ),
              child: Row(
                children: [
                  if (!isText)
                    Expanded(
                      child: TextField(
                        controller: _captionCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          hintText: 'Add a caption...',
                          hintStyle: const TextStyle(color: Colors.white60),
                          filled: true,
                          fillColor: Colors.white12,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                        ),
                      ),
                    )
                  else
                    const Expanded(child: SizedBox()),
                  const SizedBox(width: 10),
                  _posting
                      ? const SizedBox(
                          width: 52,
                          height: 52,
                          child: Center(
                            child: CircularProgressIndicator(
                              color: AppColors.primary,
                            ),
                          ),
                        )
                      : GestureDetector(
                          onTap: _post,
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.primary,
                            ),
                            child: const Icon(
                              Icons.send_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Status View Page ──────────────────────────────────────────────────────────
class _StatusViewPage extends StatefulWidget {
  final Map<String, dynamic> group;
  const _StatusViewPage({required this.group});
  @override
  State<_StatusViewPage> createState() => _StatusViewPageState();
}

class _StatusViewPageState extends State<_StatusViewPage>
    with SingleTickerProviderStateMixin {
  int _current = 0;
  late AnimationController _progressCtrl;
  VideoPlayerController? _videoCtrl;

  @override
  void initState() {
    super.initState();
    _progressCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _progressCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
    _initStatus();
    _markViewed();
  }

  void _initStatus() {
    final statuses = _statuses;
    if (statuses.isEmpty) return;
    final st = statuses[_current];
    final type = (st['type'] ?? 'text').toString();
    final base = ApiService.baseUrl.replaceAll('/api', '');
    final raw = st['media_url']?.toString() ?? '';
    final url = raw.startsWith('http')
        ? raw
        : (raw.isNotEmpty ? '$base/$raw' : '');
    if (type == 'video' && url.isNotEmpty) {
      _videoCtrl?.dispose();
      _videoCtrl = VideoPlayerController.networkUrl(Uri.parse(url))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {});
            _videoCtrl!.play();
            _videoCtrl!.setLooping(false);
            // Use actual video duration for progress bar
            final dur = _videoCtrl!.value.duration;
            _progressCtrl.duration = dur.inSeconds > 0
                ? dur
                : const Duration(seconds: 15);
            _progressCtrl.reset();
            _progressCtrl.forward();
          }
        });
    } else {
      _videoCtrl?.dispose();
      _videoCtrl = null;
      _progressCtrl.duration = const Duration(seconds: 5);
      _progressCtrl.reset();
      _progressCtrl.forward();
    }
  }

  @override
  void dispose() {
    _progressCtrl.dispose();
    _videoCtrl?.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _statuses {
    final raw = widget.group['statuses'] as List? ?? [];
    return raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  void _next() {
    if (_current < _statuses.length - 1) {
      setState(() => _current++);
      _initStatus();
      _markViewed();
    } else {
      Navigator.pop(context);
    }
  }

  void _prev() {
    if (_current > 0) {
      setState(() => _current--);
      _initStatus();
    }
  }

  Widget _buildStatusContent(
    String type,
    String? mediaUrl,
    Color bgColor,
    String content,
  ) {
    if (type == 'image' && mediaUrl != null) {
      return CachedNetworkImage(
        imageUrl: mediaUrl,
        fit: BoxFit.contain,
        placeholder: (_, __) => const ColoredBox(
          color: Colors.black,
          child: Center(
            child: CircularProgressIndicator(
              color: Colors.white54,
              strokeWidth: 2,
            ),
          ),
        ),
        errorWidget: (_, __, ___) => const ColoredBox(
          color: Colors.black,
          child: Center(
            child: Icon(
              Icons.broken_image_rounded,
              color: Colors.white38,
              size: 56,
            ),
          ),
        ),
      );
    }
    if (type == 'video') {
      final ctrl = _videoCtrl;
      if (ctrl != null && ctrl.value.isInitialized) {
        return ColoredBox(
          color: Colors.black,
          child: Center(
            child: AspectRatio(
              aspectRatio: ctrl.value.aspectRatio,
              child: VideoPlayer(ctrl),
            ),
          ),
        );
      }
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: CircularProgressIndicator(
            color: Colors.white54,
            strokeWidth: 2,
          ),
        ),
      );
    }
    // Text status
    return Container(
      color: bgColor,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Text(
            content,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w600,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }

  void _markViewed() {
    final statuses = _statuses;
    if (statuses.isEmpty) return;
    final sid = statuses[_current]['id'];
    if (sid != null) {
      ApiService.post('statuses.php?action=view', {
        'status_id': sid,
      }).catchError((_) => <String, dynamic>{});
    }
  }

  @override
  Widget build(BuildContext context) {
    final statuses = _statuses;
    if (statuses.isEmpty) return const Scaffold(backgroundColor: Colors.black);
    final status = statuses[_current];
    final type = status['type'] ?? 'text';
    final user = widget.group['user'] as Map? ?? {};
    final name = user['display_name'] ?? user['username'] ?? 'Unknown';
    final avatarUrl = user['avatar']?.toString();
    final mediaUrl = status['media_url']?.toString();
    final content = status['content']?.toString() ?? '';
    final bgHex = status['bg_color']?.toString() ?? '#DC2626';
    DateTime? dt;
    try {
      dt = DateTime.parse(status['created_at'].toString()).toLocal();
    } catch (_) {}
    final timeStr = dt != null ? DateFormat('h:mm a').format(dt) : '';
    Color bgColor = AppColors.primary;
    try {
      bgColor = Color(int.parse('0xFF${bgHex.replaceAll('#', '')}'));
    } catch (_) {}

    final fullMediaUrl = mediaUrl != null
        ? (mediaUrl.startsWith('/')
              ? '${AppConfig.mediaBase}$mediaUrl'
              : mediaUrl)
        : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) {
          final w = MediaQuery.of(context).size.width;
          if (d.localPosition.dx < w / 3)
            _prev();
          else
            _next();
        },
        child: Stack(
          children: [
            // Content
            Positioned.fill(
              child: _buildStatusContent(type, fullMediaUrl, bgColor, content),
            ),
            // Dim for readability
            if (type == 'image')
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.black.withOpacity(.5),
                        Colors.transparent,
                        Colors.transparent,
                        Colors.black.withOpacity(.5),
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
            // Progress bars
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              right: 8,
              child: AnimatedBuilder(
                animation: _progressCtrl,
                builder: (_, __) => Row(
                  children: List.generate(
                    statuses.length,
                    (i) => Expanded(
                      child: Container(
                        height: 2.5,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        child: LinearProgressIndicator(
                          value: i < _current
                              ? 1
                              : i == _current
                              ? _progressCtrl.value
                              : 0,
                          backgroundColor: Colors.white38,
                          valueColor: const AlwaysStoppedAnimation(
                            Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // Top user info
            Positioned(
              top: MediaQuery.of(context).padding.top + 22,
              left: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    AvatarWidget(
                      imageUrl: avatarUrl,
                      name: name.toString(),
                      size: 38,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                              shadows: [Shadow(blurRadius: 4)],
                            ),
                          ),
                          Text(
                            timeStr,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
            ),
            // Caption for image statuses
            if (type == 'image' && content.isNotEmpty)
              Positioned(
                bottom: MediaQuery.of(context).padding.bottom + 24,
                left: 16,
                right: 16,
                child: Text(
                  content,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black87)],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// Extension on AppProvider for AI chat
extension AiChat on AppProvider {
  Future<Map<String, dynamic>> aiBotChat(
    List<Map<String, String>> history,
    String lastMsg,
  ) {
    return ApiService.post('ai.php?action=chat', {'messages': history});
  }
}

// ── Group Creation Sheet ──────────────────────────────────────────────────────

class _NewGroupSheet extends StatefulWidget {
  const _NewGroupSheet();
  @override
  State<_NewGroupSheet> createState() => _NewGroupSheetState();
}

class _NewGroupSheetState extends State<_NewGroupSheet> {
  final _searchCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  List<User> _results = [];
  final List<User> _selected = [];
  bool _loading = false;
  bool _step2 = false;
  bool _creating = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }
    setState(() => _loading = true);
    try {
      final users = await ApiService.searchUsers(q.trim());
      setState(() {
        _results = users;
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  void _toggle(User user) {
    setState(() {
      if (_selected.any((u) => u.id == user.id)) {
        _selected.removeWhere((u) => u.id == user.id);
      } else {
        _selected.add(user);
      }
    });
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _selected.isEmpty) return;
    setState(() => _creating = true);
    try {
      final r = await ApiService.createGroup(
        name,
        _selected.map((u) => u.id).toList(),
      );
      if (!mounted) return;
      if (r['success'] == true && r['conversation'] != null) {
        final conv = Conversation.fromJson(
          Map<String, dynamic>.from(r['conversation']),
        );
        final prov = context.read<AppProvider>();
        await prov.loadConversations();
        if (mounted) {
          Navigator.pop(context);
          Navigator.push(context, chatRoute(ChatScreen(conversation: conv)));
        }
      } else {
        setState(() => _creating = false);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(r['error']?.toString() ?? 'Failed to create group'),
              backgroundColor: AppColors.danger,
            ),
          );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _creating = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Network error'),
            backgroundColor: AppColors.danger,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.bg2Dark : Colors.white;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  if (_step2)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: () => setState(() => _step2 = false),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  Expanded(
                    child: Text(
                      _step2 ? 'New Group' : 'Add Members',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                      ),
                    ),
                  ),
                  if (!_step2 && _selected.isNotEmpty)
                    GestureDetector(
                      onTap: () => setState(() => _step2 = true),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary,
                          borderRadius: BorderRadius.circular(22),
                        ),
                        child: const Text(
                          'Next',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  if (_step2)
                    _creating
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.primary,
                            ),
                          )
                        : GestureDetector(
                            onTap: _create,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(22),
                              ),
                              child: const Text(
                                'Create',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (!_step2) ...[
              // Search bar
              Container(
                margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                decoration: BoxDecoration(
                  color: isDark ? AppColors.panelDark : AppColors.bgLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  onChanged: _search,
                  decoration: InputDecoration(
                    hintText: 'Search members...',
                    prefixIcon: const Icon(
                      Icons.search,
                      color: AppColors.primary,
                      size: 20,
                    ),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                  ),
                ),
              ),
              // Selected chips
              if (_selected.isNotEmpty)
                SizedBox(
                  height: 56,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: _selected.length,
                    itemBuilder: (_, i) {
                      final u = _selected[i];
                      return Container(
                        margin: const EdgeInsets.only(right: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primaryDim,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: AppColors.primary.withOpacity(.3),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              u.displayName,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.primaryDark,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () => _toggle(u),
                              child: const Icon(
                                Icons.close,
                                size: 14,
                                color: AppColors.primaryDark,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              // User list
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                      )
                    : _results.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.group_add,
                              size: 52,
                              color: Colors.grey.shade300,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Search to add people',
                              style: TextStyle(
                                color: Colors.grey.shade400,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: scrollCtrl,
                        itemCount: _results.length,
                        itemBuilder: (_, i) {
                          final user = _results[i];
                          final isChosen = _selected.any(
                            (u) => u.id == user.id,
                          );
                          return ListTile(
                            leading: AvatarWidget(
                              imageUrl: user.avatar,
                              name: user.displayName,
                              size: 46,
                              showOnline: true,
                              status: user.status,
                            ),
                            title: Text(
                              user.displayName,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: isDark
                                    ? AppColors.t1Dark
                                    : AppColors.t1Light,
                              ),
                            ),
                            subtitle: Text(
                              user.phone ?? '@${user.username}',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark
                                    ? AppColors.t3Dark
                                    : AppColors.t3Light,
                              ),
                            ),
                            trailing: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isChosen
                                    ? AppColors.primary
                                    : Colors.transparent,
                                border: Border.all(
                                  color: isChosen
                                      ? AppColors.primary
                                      : Colors.grey.shade400,
                                  width: 2,
                                ),
                              ),
                              child: isChosen
                                  ? const Icon(
                                      Icons.check,
                                      size: 14,
                                      color: Colors.white,
                                    )
                                  : null,
                            ),
                            onTap: () => _toggle(user),
                          );
                        },
                      ),
              ),
            ] else ...[
              // Step 2: group name
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      // Group icon placeholder
                      Container(
                        width: 90,
                        height: 90,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primaryDim,
                          border: Border.all(
                            color: AppColors.primary.withOpacity(.3),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.group,
                          size: 44,
                          color: AppColors.primaryDark,
                        ),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _nameCtrl,
                        autofocus: true,
                        textCapitalization: TextCapitalization.words,
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? AppColors.t1Dark : AppColors.t1Light,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Group name',
                          labelStyle: const TextStyle(color: AppColors.primary),
                          hintText: 'Enter group name...',
                          filled: true,
                          fillColor: isDark
                              ? AppColors.panelDark
                              : AppColors.bgLight,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: const BorderSide(
                              color: AppColors.primary,
                              width: 1.5,
                            ),
                          ),
                          prefixIcon: const Icon(
                            Icons.edit,
                            color: AppColors.primary,
                            size: 20,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Members preview
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Members (${_selected.length})',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                            color: isDark
                                ? AppColors.t3Dark
                                : AppColors.t3Light,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      ..._selected.map(
                        (u) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: AvatarWidget(
                            imageUrl: u.avatar,
                            name: u.displayName,
                            size: 40,
                          ),
                          title: Text(
                            u.displayName,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            u.phone ?? '@${u.username}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
