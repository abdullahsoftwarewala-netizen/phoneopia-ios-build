import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';
import '../config/app_config.dart';
import '../services/api_service.dart';
import 'audio_play_button.dart';
import 'avatar_widget.dart';

// Voice transcription line shown under a voice/audio bubble (when transcription is ON)
class _TranscriptLine extends StatefulWidget {
  final int messageId;
  final Color textColor;
  final Color bgColor;
  const _TranscriptLine({
    required this.messageId,
    required this.textColor,
    required this.bgColor,
  });
  @override
  State<_TranscriptLine> createState() => _TranscriptLineState();
}

class _TranscriptLineState extends State<_TranscriptLine> {
  String? _text;
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    ApiService.transcriptionNotifier.addListener(_onToggle);
    if (ApiService.transcriptionOn)
      _load();
    else
      _loading = false;
  }

  @override
  void dispose() {
    ApiService.transcriptionNotifier.removeListener(_onToggle);
    super.dispose();
  }

  void _onToggle() {
    if (!ApiService.transcriptionOn) {
      if (mounted)
        setState(() {
          _loading = false;
          _text = null;
        });
      return;
    }
    if (_text == null && !_loading) _load();
  }

  Future<void> _load() async {
    if (!ApiService.transcriptionOn) return;
    final cached = ApiService.transcriptCache[widget.messageId];
    if (cached != null) {
      if (mounted)
        setState(() {
          _text = cached;
          _loading = false;
        });
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      final r = await ApiService.toolsTranscribe(widget.messageId);
      if (!ApiService.transcriptionOn) return;
      final t = r['text']?.toString();
      if (t != null && t.isNotEmpty)
        ApiService.transcriptCache[widget.messageId] = t;
      if (mounted)
        setState(() {
          _text = t;
          _loading = false;
        });
    } catch (_) {
      if (mounted)
        setState(() {
          _loading = false;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ApiService.transcriptionOn) return const SizedBox.shrink();
    if (_loading) {
      return Container(
        color: widget.bgColor,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: widget.textColor.withOpacity(.4),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              'Transcribing…',
              style: TextStyle(
                fontSize: 12,
                color: widget.textColor.withOpacity(.55),
              ),
            ),
          ],
        ),
      );
    }
    if (_text == null || _text!.isEmpty) return const SizedBox.shrink();
    return Container(
      color: widget.bgColor,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Text(
        '“${_text!}”',
        style: TextStyle(
          fontSize: 13,
          height: 1.4,
          color: widget.textColor.withOpacity(.85),
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final Message message;
  final bool isMine;
  final bool showAvatar;
  final bool isGroup;
  final VoidCallback? onLongPress;
  final VoidCallback? onImageTap;
  final VoidCallback? onVideoTap;
  final void Function(String option)? onPollVote;
  final void Function(String handle)? onContactMessage;
  final VoidCallback? onCallTap;
  final void Function(int msgId, String emoji)? onAddReaction;
  final void Function(int msgId)? onRemoveReaction;
  final void Function(int msgId)? onShowReactionDetails;
  final VoidCallback? onRetry;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMine,
    this.showAvatar = false,
    this.isGroup = false,
    this.onLongPress,
    this.onImageTap,
    this.onVideoTap,
    this.onPollVote,
    this.onContactMessage,
    this.onCallTap,
    this.onAddReaction,
    this.onRemoveReaction,
    this.onShowReactionDetails,
    this.onRetry,
  });

  Widget _systemBubble(BuildContext context, bool isDark) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 40),
    child: Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isDark ? AppColors.cardDark : Colors.black.withOpacity(.06),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          message.content ?? '',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            color: isDark ? AppColors.t2Dark : AppColors.t2Light,
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (message.isDeleted) return _deletedBubble(context);
    if (message.type == 'system') return _systemBubble(context, isDark);

    return GestureDetector(
      onLongPress: onLongPress,
      child: Padding(
        padding: EdgeInsets.only(
          left: isMine ? 64 : 8,
          right: isMine ? 8 : 64,
          top: 2,
          bottom: 6,
        ),
        child: Row(
          mainAxisAlignment: isMine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isMine && showAvatar) ...[
              _senderAvatar(isDark),
              const SizedBox(width: 6),
            ] else if (!isMine)
              const SizedBox(width: 34),
            Flexible(
              child: Column(
                crossAxisAlignment: isMine
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [
                  if (!isMine &&
                      isGroup &&
                      showAvatar &&
                      message.senderName != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 2),
                      child: Text(
                        message.senderName!,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: _senderColor(message.senderId),
                        ),
                      ),
                    ),
                  _bubble(context, isDark),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static const _nameColors = [
    AppColors.primary,
    AppColors.primaryDark,
    AppColors.primaryDeeper,
    Color(0xFF1DA1F2),
    Color(0xFF9B59B6),
    Color(0xFFE74C3C),
    Color(0xFFF39C12),
    Color(0xFF16A085),
    Color(0xFF2980B9),
  ];

  Color _senderColor(int senderId) =>
      _nameColors[senderId % _nameColors.length];

  Widget _senderAvatar(bool isDark) => AvatarWidget(
    imageUrl: message.senderAvatar,
    name: message.senderName ?? '?',
    size: 28,
    isAiBot: isPhoneopiaBot(
      username: message.senderUsername,
      avatar: message.senderAvatar,
      name: message.senderName,
    ),
  );

  Widget _bubble(BuildContext context, bool isDark) {
    Color bgColor;
    Color textColor;
    if (isMine) {
      bgColor = isDark ? AppColors.sentBubbleDark : AppColors.sentBubbleLight;
      textColor = isDark ? AppColors.t1Dark : AppColors.t1Light;
    } else {
      bgColor = isDark ? AppColors.recvBubbleDark : AppColors.recvBubbleLight;
      textColor = isDark ? AppColors.t1Dark : AppColors.t1Light;
    }

    final bubbleShape = BorderRadius.only(
      topLeft: const Radius.circular(AppRadii.bubble),
      topRight: const Radius.circular(AppRadii.bubble),
      bottomLeft: Radius.circular(
        isMine ? AppRadii.bubble : AppRadii.bubbleTail,
      ),
      bottomRight: Radius.circular(
        isMine ? AppRadii.bubbleTail : AppRadii.bubble,
      ),
    );

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: message.isImage ? null : bgColor,
        borderRadius: bubbleShape,
        border: message.isImage
            ? null
            : Border.all(
                color: isMine
                    ? (isDark ? AppColors.borderDark : AppColors.borderLight)
                    : (isDark ? AppColors.borderDark : AppColors.borderLight),
              ),
        boxShadow: AppShadows.bubble(isDark),
      ),
      child: ClipRRect(
        borderRadius: bubbleShape,
        child: _bubbleContent(context, textColor, bgColor, isDark),
      ),
    );
  }

  Widget _bubbleContent(
    BuildContext context,
    Color textColor,
    Color bgColor,
    bool isDark,
  ) {
    final content = _buildMainContent(context, textColor, bgColor, isDark);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        content,
        if (message.reactions.isNotEmpty)
          _reactionsRow(textColor, bgColor, isDark),
      ],
    );
  }

  Widget _buildMainContent(
    BuildContext context,
    Color textColor,
    Color bgColor,
    bool isDark,
  ) {
    if (message.type == 'call') return _callContent(isDark);
    if (message.isImage) return _imageContent(context);
    if (message.isVideo) return _videoContent(context);
    if (message.isAudio) return _audioContent(textColor, bgColor);
    if (message.isFile) return _fileContent(textColor, bgColor);
    // Rich cards (WhatsApp style) for structured text messages.
    // Any parsing failure must NOT crash the chat list — fall back to plain text.
    final c = message.content ?? '';
    try {
      if (c.startsWith('👤 Contact:'))
        return _contactCard(c, textColor, isDark);
      if (c.startsWith('📍') && c.contains('http'))
        return _locationCard(c, textColor, isDark);
      if (c.startsWith('📊 *Poll:*')) return _pollCard(c, textColor, isDark);
      if (c.startsWith('📅 *Event:*')) return _eventCard(c, textColor, isDark);
    } catch (_) {
      return _textContent(textColor);
    }
    return _textContent(textColor);
  }

  Widget _reactionsRow(Color textColor, Color bgColor, bool isDark) {
    if (message.reactions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 4, left: 10, right: 10, bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        children: message.reactions.entries.map((entry) {
          final emoji = entry.key;
          final data = entry.value;
          int count = 0;
          bool mine = false;
          if (data is List) {
            count = data.length;
          } else if (data is int) {
            count = data;
          } else if (data is Map) {
            count = data['count'] as int? ?? 0;
            mine = data['mine'] == true;
          }
          return GestureDetector(
            onTap: () => onShowReactionDetails?.call(message.id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: mine
                    ? AppColors.primary.withOpacity(0.15)
                    : (isDark
                          ? Colors.white.withOpacity(0.08)
                          : Colors.black.withOpacity(0.05)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: mine
                      ? AppColors.primary.withOpacity(0.3)
                      : Colors.transparent,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(emoji, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 4),
                  Text(
                    count.toString(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: textColor.withOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // ── Contact card ─────────────────────────────────────────────
  Widget _contactCard(String c, Color textColor, bool isDark) {
    final lines = c.split('\n');
    final name = (lines.isNotEmpty ? lines[0] : '')
        .replaceFirst('👤 Contact:', '')
        .trim();
    final handle = lines.length > 1 ? lines[1].trim() : '';
    return Container(
      width: 240,
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: AppColors.primaryDim,
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: AppColors.primaryDark,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14.5,
                          color: textColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        handle,
                        style: TextStyle(
                          fontSize: 12,
                          color: textColor.withOpacity(.6),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 10),
            child: Align(
              alignment: Alignment.centerRight,
              child: _timeRow(color: textColor.withOpacity(.55)),
            ),
          ),
          Divider(height: 1, color: textColor.withOpacity(.12)),
          InkWell(
            onTap: onContactMessage == null || handle.isEmpty
                ? null
                : () => onContactMessage!(handle),
            child: const SizedBox(
              height: 40,
              width: double.infinity,
              child: Center(
                child: Text(
                  'Message',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Location card ────────────────────────────────────────────
  Widget _locationCard(String c, Color textColor, bool isDark) {
    final url = RegExp(r'https?://\S+').firstMatch(c)?.group(0) ?? '';
    return InkWell(
      onTap: url.isEmpty
          ? null
          : () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      child: Container(
        width: 240,
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 110,
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(14),
                ),
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withOpacity(.25),
                    AppColors.primaryDark.withOpacity(.35),
                  ],
                ),
              ),
              child: const Center(
                child: Icon(
                  Icons.location_on_rounded,
                  color: Color(0xFFE53935),
                  size: 44,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Location shared — tap to open',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: textColor.withOpacity(.75),
                      ),
                    ),
                  ),
                  _timeRow(color: textColor.withOpacity(.55)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Poll card ────────────────────────────────────────────────
  Widget _pollCard(String c, Color textColor, bool isDark) {
    final lines = c.split('\n');
    final q = (lines.isNotEmpty ? lines[0] : '')
        .replaceFirst('📊 *Poll:*', '')
        .trim();
    final options = lines
        .where((l) => l.startsWith('⬜'))
        .map((l) => l.substring(1).trim())
        .toList();
    return Container(
      width: 250,
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            q,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 15,
              color: textColor,
            ),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Icon(
                Icons.poll_outlined,
                size: 13,
                color: textColor.withOpacity(.5),
              ),
              const SizedBox(width: 4),
              Text(
                'Tap an option to vote',
                style: TextStyle(
                  fontSize: 11.5,
                  color: textColor.withOpacity(.5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...options.map(
            (o) => InkWell(
              onTap: onPollVote == null ? null : () => onPollVote!(o),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.radio_button_unchecked,
                          size: 18,
                          color: textColor.withOpacity(.45),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            o,
                            style: TextStyle(fontSize: 14, color: textColor),
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 26, top: 4),
                      child: Container(
                        height: 4,
                        decoration: BoxDecoration(
                          color: textColor.withOpacity(.12),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _timeRow(color: textColor.withOpacity(.55)),
          ),
        ],
      ),
    );
  }

  // ── Event card ───────────────────────────────────────────────
  Widget _eventCard(String c, Color textColor, bool isDark) {
    final lines = c.split('\n');
    final title = (lines.isNotEmpty ? lines[0] : '')
        .replaceFirst('📅 *Event:*', '')
        .trim();
    final when = lines.length > 1 ? lines[1].replaceFirst('🗓', '').trim() : '';
    return Container(
      width: 240,
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: const Color(0xFFE6526F).withOpacity(.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.event_rounded,
                  color: Color(0xFFE6526F),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14.5,
                        color: textColor,
                      ),
                    ),
                    if (when.isNotEmpty)
                      Text(
                        when,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: textColor.withOpacity(.65),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: _timeRow(color: textColor.withOpacity(.55)),
          ),
        ],
      ),
    );
  }

  String get _timeStr => DateFormat('h:mm a').format(message.createdAt);

  Widget _timeRow({Color? color, bool dark = false}) {
    final c = color ?? (dark ? Colors.white70 : const Color(0xFF667781));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_timeStr, style: TextStyle(fontSize: 11, color: c)),
        if (isMine) ...[const SizedBox(width: 3), _statusIcon(color: c)],
      ],
    );
  }

  Widget _textContent(Color textColor) => Padding(
    padding: const EdgeInsets.only(left: 10, right: 10, top: 5, bottom: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: Text(
            message.content ?? '',
            style: TextStyle(color: textColor, fontSize: 14.5, height: 1.3),
          ),
        ),
        const SizedBox(width: 8),
        _timeRow(color: textColor.withOpacity(0.55)),
      ],
    ),
  );

  Widget _callContent(bool isDark) {
    final parts = (message.content ?? 'audio|missed|0').split('|');
    final callType = parts.isNotEmpty ? parts[0] : 'audio';
    final status = parts.length > 1 ? parts[1] : 'missed';
    final dur = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    final isAnswered = status == 'answered' || status == 'completed';
    final isMissed =
        !isAnswered && (status == 'missed' || status == 'rejected');
    final iconData = isMine
        ? Icons.call_made_rounded
        : (isAnswered
              ? Icons.call_received_rounded
              : (callType == 'video'
                    ? Icons.videocam_rounded
                    : Icons.phone_rounded));
    final typeLabel = (!isMine && isMissed)
        ? (callType == 'video' ? 'Missed video call' : 'Missed voice call')
        : (callType == 'video' ? 'Video call' : 'Voice call');
    final statusLabel = isAnswered
        ? (dur > 0
              ? '${dur ~/ 60}:${(dur % 60).toString().padLeft(2, '0')}'
              : 'Answered')
        : (!isMine && isMissed)
        ? 'Tap to call back'
        : (status == 'rejected' ? 'Declined' : 'No answer');
    final titleColor = isDark ? AppColors.t1Dark : AppColors.t1Light;
    final subColor = isDark ? AppColors.t2Dark : const Color(0xFF667781);
    return GestureDetector(
      onTap: onCallTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isMine
                    ? AppColors.primary.withOpacity(0.15)
                    : (isMissed
                          ? const Color(0xFFFF2D55).withOpacity(0.12)
                          : subColor.withOpacity(0.12)),
              ),
              child: Icon(
                iconData,
                color: isMine
                    ? AppColors.primary
                    : (isMissed ? const Color(0xFFFF2D55) : subColor),
                size: 18,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  typeLabel,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: titleColor,
                  ),
                ),
                Text(
                  statusLabel,
                  style: TextStyle(fontSize: 11, color: subColor),
                ),
              ],
            ),
            const SizedBox(width: 24),
            Text(
              _timeStr,
              style: TextStyle(fontSize: 10, color: subColor.withOpacity(0.75)),
            ),
          ],
        ),
      ),
    );
  }

  String? get _imageSrc {
    // While an outgoing image is still uploading, show the picked local file so
    // the user sees the picture instantly (with a sending spinner over it).
    final lp = message.localPath;
    if (lp != null && lp.isNotEmpty) return lp;
    final f = message.fileUrl;
    if (f != null && f.isNotEmpty) return f;
    final c = message.content ?? '';
    if (c.startsWith('data:image')) return c;
    if (c.startsWith('http')) return c;
    return null;
  }

  Uint8List? _decodeDataUrl(String url) {
    try {
      final i = url.indexOf(',');
      if (i < 0) return null;
      return base64Decode(url.substring(i + 1));
    } catch (_) {
      return null;
    }
  }

  Widget _imageSkeleton() => Container(
    width: 220,
    height: 180,
    decoration: BoxDecoration(
      color: const Color(0xFFE9EDEF),
      borderRadius: BorderRadius.circular(11),
    ),
    child: const Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Color(0xFF8696A0),
        ),
      ),
    ),
  );

  Widget _imageError() => Container(
    width: 220,
    height: 140,
    decoration: BoxDecoration(
      color: const Color(0xFFE9EDEF),
      borderRadius: BorderRadius.circular(11),
    ),
    child: const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.broken_image_outlined, color: Color(0xFF8696A0), size: 36),
        SizedBox(height: 6),
        Text(
          'Image unavailable',
          style: TextStyle(fontSize: 11, color: Color(0xFF8696A0)),
        ),
      ],
    ),
  );

  Widget _buildImageWidget(String src) {
    if (src.startsWith('data:image')) {
      final bytes = _decodeDataUrl(src);
      if (bytes == null) return _imageError();
      return Image.memory(
        bytes,
        width: 220,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _imageError(),
      );
    }
    // Local file path of an outgoing image still being uploaded.
    if (!src.startsWith('http')) {
      return Image.file(
        File(src),
        width: 220,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => _imageSkeleton(),
      );
    }
    return CachedNetworkImage(
      imageUrl: src,
      width: 220,
      fit: BoxFit.cover,
      memCacheWidth: 440,
      fadeInDuration: const Duration(milliseconds: 180),
      placeholder: (_, __) => _imageSkeleton(),
      errorWidget: (_, __, ___) => _imageError(),
    );
  }

  Widget _imageContent(BuildContext context) {
    final src = _imageSrc;
    final isBotImage = message.senderUsername == 'phoneopia_ai';
    return GestureDetector(
      onTap: src == null ? null : onImageTap,
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMine ? 18 : 4),
          bottomRight: Radius.circular(isMine ? 4 : 18),
        ),
        child: Stack(
          children: [
            if (src == null) _imageError() else _buildImageWidget(src),
            // Uploading overlay — dim the picture + spinner so the user can see
            // the photo is being sent (not just a frozen "📷 Photo").
            if (src != null && message.status == 'sending')
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.32),
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.6,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            if (isBotImage && src != null)
              Positioned(
                bottom: 9,
                right: 9,
                child: Container(
                  width: 28,
                  height: 28,
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.88),
                    borderRadius: BorderRadius.circular(7),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 6,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Image.asset(
                    'assets/images/logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => const Icon(
                      Icons.smart_toy_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 6,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _timeRow(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _videoContent(BuildContext context) {
    final url = message.fileUrl;
    final uploading = message.status == 'sending';
    return GestureDetector(
      onTap: (url == null || url.isEmpty || uploading) ? null : onVideoTap,
      child: ClipRRect(
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(isMine ? 18 : 4),
          bottomRight: Radius.circular(isMine ? 4 : 18),
        ),
        child: Container(
          width: 220,
          height: 220,
          color: const Color(0xFF2B2F33),
          child: Stack(
            alignment: Alignment.center,
            children: [
              const Icon(
                Icons.movie_creation_outlined,
                color: Colors.white24,
                size: 56,
              ),
              if (uploading)
                const SizedBox(
                  width: 34,
                  height: 34,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: Colors.white,
                  ),
                )
              else if (url == null || url.isEmpty)
                const Icon(Icons.error_outline, color: Colors.white54, size: 32)
              else
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              Positioned(
                bottom: 6,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black45,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: _timeRow(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Voice messages sent from web keep the audio URL inside JSON content
  String get _audioUrl {
    // Nearby/offline voice notes are stored on-device. Prefer that local copy
    // over a server URL so they remain playable with no internet connection.
    final local = message.localPath;
    if (local != null && local.isNotEmpty) return local;
    final f = message.fileUrl;
    if (f != null && f.isNotEmpty) return f;
    try {
      final d = jsonDecode(message.content ?? '');
      final u = d['audio_url']?.toString() ?? '';
      if (u.isEmpty) return '';
      return u.startsWith('http') ? u : '${AppConfig.mediaBase}$u';
    } catch (_) {
      return '';
    }
  }

  int get _audioDurationSecs {
    if (message.duration != null && message.duration! > 0)
      return message.duration!;
    try {
      final d = jsonDecode(message.content ?? '');
      final fromJson = int.tryParse(d['duration']?.toString() ?? '');
      if (fromJson != null && fromJson > 0) return fromJson;
    } catch (_) {}
    return 0;
  }

  Widget _audioContent(Color textColor, Color bgColor) {
    final dur = _audioDurationSecs;
    final audio = Container(
      color: bgColor,
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 300),
      child: VoiceMessageBar(
        url: _audioUrl,
        durationSecs: dur,
        textColor: textColor,
        waveColor: AppColors.primary,
        waveMutedColor: AppColors.primary.withOpacity(.22),
        timeRow: _timeRow(color: textColor.withOpacity(.55)),
      ),
    );
    if (message.id == 0) return audio;
    return ValueListenableBuilder<bool>(
      valueListenable: ApiService.transcriptionNotifier,
      builder: (_, on, __) {
        if (!on) return audio;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            audio,
            _TranscriptLine(
              messageId: message.id,
              textColor: textColor,
              bgColor: bgColor,
            ),
          ],
        );
      },
    );
  }

  Widget _avatarFallback(String name, double size, {bool isMine = false}) =>
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isMine
              ? AppColors.primary.withOpacity(.2)
              : AppColors.primaryDim,
        ),
        child: Center(
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(
              fontSize: size * 0.38,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
            ),
          ),
        ),
      );

  Widget _fileContent(Color textColor, Color bgColor) => Container(
    color: bgColor,
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppColors.primaryDim,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.insert_drive_file,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.fileName ?? 'File',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Tap to download',
                    style: TextStyle(
                      fontSize: 11,
                      color: textColor.withOpacity(.5),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _timeRow(color: textColor.withOpacity(0.6)),
        ),
      ],
    ),
  );

  Widget _deletedBubble(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      left: isMine ? 60 : 8,
      right: isMine ? 8 : 60,
      top: 2,
      bottom: 2,
    ),
    child: Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.grey.withOpacity(.15),
          borderRadius: BorderRadius.circular(AppRadii.bubble),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 14, color: Colors.grey.shade500),
            const SizedBox(width: 6),
            Text(
              'Message deleted',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _statusIcon({Color? color}) {
    final c = color ?? AppColors.t3Light;
    switch (message.status) {
      case 'read':
        return Icon(Icons.done_all, size: 13, color: AppColors.primary);
      case 'delivered':
        return Icon(Icons.done_all, size: 13, color: c);
      case 'sending':
        return Icon(Icons.access_time, size: 11, color: c);
      case 'failed':
        return GestureDetector(
          onTap: onRetry,
          behavior: HitTestBehavior.opaque,
          child: const Padding(
            padding: EdgeInsets.only(left: 1),
            child: Icon(Icons.error, size: 14, color: Color(0xFFE53935)),
          ),
        );
      default:
        return Icon(Icons.done, size: 13, color: c);
    }
  }
}
