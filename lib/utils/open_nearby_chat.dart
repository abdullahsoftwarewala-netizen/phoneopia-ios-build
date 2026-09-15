import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../services/api_service.dart';
import '../services/nearby_service.dart';
import '../screens/chat_screen.dart';

Future<void> openNearbyChat(BuildContext context, String endpointId,
    {bool replace = false}) async {
  final nearby = NearbyService();
  final uid = nearby.peerUserId[endpointId];
  if (uid == null || uid <= 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Waiting for this device to share its profile.')));
    return;
  }
  final provider = context.read<AppProvider>();
  final name = nearby.peers[endpointId] ?? 'Phoneopia user';
  var conversation = provider.conversations.where(
    (c) => c.type == 'direct' && c.otherUser?.id == uid).firstOrNull;
  if (conversation == null) {
    try {
      final result = await ApiService.createConversation(uid)
          .timeout(const Duration(seconds: 5));
      final id = int.tryParse('${result['conversation_id']}');
      if (result['success'] == true && id != null && id > 0) {
        conversation = Conversation(id: id, type: 'direct', name: name,
          otherUser: User(id: uid, username: '', displayName: name));
        provider.ensureConvInList(conversation, moveTop: true);
      }
    } catch (_) {}
    conversation ??= provider.ensureNearbyConversation(uid, name);
  }
  if (!context.mounted) return;
  final route = MaterialPageRoute<void>(builder: (_) => ChatScreen(conversation: conversation!));
  if (replace) {
    Navigator.of(context).pushReplacement(route);
  } else {
    Navigator.of(context).push(route);
  }
}
