import 'package:intl/intl.dart';
import '../models/models.dart';

String formatLastSeen(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  final diff = now.difference(local);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return DateFormat.jm().format(local);
  if (day == today.subtract(const Duration(days: 1))) {
    return 'yesterday ${DateFormat.jm().format(local)}';
  }
  if (now.difference(local).inDays < 7) return DateFormat('EEE h:mm a').format(local);
  return DateFormat('d MMM yyyy').format(local);
}

String presenceLabel(User? user, {bool isGroup = false, int memberCount = 0}) {
  if (isGroup) return memberCount > 0 ? '$memberCount members' : 'Group chat';
  if (user == null) return '';
  if (user.isAiBot) return user.statusMessage ?? 'AI assistant';
  if (user.isOnline || user.status == 'online') return 'online';
  if (user.lastSeen != null) return 'last seen ${formatLastSeen(user.lastSeen!)}';
  if (user.statusMessage != null && user.statusMessage!.trim().isNotEmpty) {
    return user.statusMessage!;
  }
  return 'offline';
}