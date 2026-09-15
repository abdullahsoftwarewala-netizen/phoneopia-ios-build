import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../providers/app_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/avatar_widget.dart';
import 'active_call_screen.dart';

/// Shown to the CALLER when the call goes unanswered or is declined.
/// iPhone/WhatsApp style: name + "No answer", big circular avatar,
/// and Cancel / Record voice message / Call again actions.
class MissedCallScreen extends StatelessWidget {
  final String name;
  final String? avatar;
  final bool isVideo;
  final int convId;
  final int? calleeUserId;
  final String reason; // 'No answer' or 'Declined'

  const MissedCallScreen({
    super.key,
    required this.name,
    required this.avatar,
    required this.isVideo,
    required this.convId,
    required this.calleeUserId,
    this.reason = 'No answer',
  });

  void _callAgain(BuildContext context) {
    final prov = context.read<AppProvider>();
    prov.setInActiveCallUi(false);
    prov.setActiveCallPeer(null);
    prov.startOutgoingCallRing();
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => ActiveCallScreen(
      callerName: name, callerAvatar: avatar, isVideo: false,
      convId: convId, isOutgoing: true, calleeUserId: calleeUserId,
    ))).then((_) => prov.stopRing());
  }

  Future<void> _recordVoice(BuildContext context) async {
    // Hand off to chat — user can record a voice note there
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = avatar != null && avatar!.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        if (hasPhoto) Positioned.fill(
          child: Image.network(avatar!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
        ),
        Positioned.fill(child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 35, sigmaY: 35),
          child: Container(color: Colors.black.withOpacity(hasPhoto ? .55 : .92)),
        )),
        SafeArea(child: Column(children: [
          const SizedBox(height: 50),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(name,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 8),
          Text(reason, style: const TextStyle(color: Colors.white60, fontSize: 17)),
          const Spacer(flex: 2),
          // Big circular avatar
          Container(
            decoration: BoxDecoration(shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(.4), blurRadius: 30, spreadRadius: 4)]),
            child: AvatarWidget(imageUrl: avatar, name: name, size: 200),
          ),
          const Spacer(flex: 3),
          // Actions row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _action(Icons.close, 'Cancel', Colors.white, const Color(0xFF2A2A2A),
                  () => Navigator.pop(context)),
              _action(Icons.mic, 'Record voice\nmessage', Colors.white, const Color(0xFF2A2A2A),
                  () => _recordVoice(context)),
              _action(Icons.call, 'Call again', Colors.white, AppColors.primary,
                  () => _callAgain(context)),
            ]),
          ),
          const SizedBox(height: 60),
        ])),
      ]),
    );
  }

  Widget _action(IconData icon, String label, Color iconColor, Color bg, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: SizedBox(width: 96, child: Column(children: [
        Container(
          width: 66, height: 66,
          decoration: BoxDecoration(shape: BoxShape.circle, color: bg),
          child: Icon(icon, color: iconColor, size: 28),
        ),
        const SizedBox(height: 10),
        Text(label, textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
      ])),
    );
}
