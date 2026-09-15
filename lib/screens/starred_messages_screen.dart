import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import 'chat_screen.dart';
import '../utils/page_routes.dart';

class StarredMessagesScreen extends StatefulWidget {
  const StarredMessagesScreen({super.key});
  @override
  State<StarredMessagesScreen> createState() => _StarredMessagesScreenState();
}

class _StarredMessagesScreenState extends State<StarredMessagesScreen> {
  List<Message> _messages = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _messages = await ApiService.getStarredMessages();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  String _preview(Message m) {
    if (m.content != null && m.content!.trim().isNotEmpty) return m.content!.trim();
    return switch (m.type) {
      'image' => '📷 Photo',
      'video' => '🎬 Video',
      'audio' || 'voice' => '🎤 Audio',
      'file' => '📎 ${m.fileName ?? 'File'}',
      _ => m.type,
    };
  }

  Future<void> _openChat(Message m) async {
    final prov = context.read<AppProvider>();
    Conversation? conv;
    try {
      conv = prov.conversations.firstWhere((c) => c.id == m.conversationId);
    } catch (_) {
      final loaded = await ApiService.getConversation(m.conversationId);
      if (loaded != null) conv = loaded;
    }
    if (!mounted) return;
    if (conv == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chat not found')));
      return;
    }
    final chat = conv;
    Navigator.push(context, chatRoute(ChatScreen(conversation: chat)));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? AppColors.bgDark : AppColors.bgLight,
      appBar: AppBar(
        backgroundColor: isDark ? AppColors.bg2Dark : AppColors.headerGreen,
        foregroundColor: Colors.white,
        title: const Text('Starred messages', style: TextStyle(fontWeight: FontWeight.w700)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
          : _messages.isEmpty
              ? Center(child: Text(
                  'No starred messages yet.\nLong-press a message and tap Star.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: isDark ? AppColors.t3Dark : AppColors.t3Light, height: 1.5)))
              : RefreshIndicator(
                  color: AppColors.primary,
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _messages.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      indent: 72,
                      color: isDark ? Colors.white12 : const Color(0xFFE9EDEF)),
                    itemBuilder: (_, i) {
                      final m = _messages[i];
                      final when = DateFormat('d MMM, h:mm a').format(m.createdAt);
                      return ListTile(
                        leading: const Icon(Icons.star, color: Color(0xFFF59E0B), size: 22),
                        title: Text(m.senderName ?? 'Unknown',
                          style: TextStyle(fontWeight: FontWeight.w600,
                            color: isDark ? AppColors.t1Dark : AppColors.t1Light)),
                        subtitle: Text(_preview(m),
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: isDark ? AppColors.t2Dark : AppColors.t2Light)),
                        trailing: Text(when, style: TextStyle(fontSize: 11,
                          color: isDark ? AppColors.t3Dark : AppColors.t3Light)),
                        onTap: () => _openChat(m),
                      );
                    },
                  ),
                ),
    );
  }
}