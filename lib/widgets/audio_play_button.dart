import 'dart:async';
import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import '../theme/app_theme.dart';
import '../config/app_config.dart';

/// Shared voice player — one message at a time, with progress + speed.
class VoicePlayerService {
  static final VoicePlayerService i = VoicePlayerService._();
  VoicePlayerService._() {
    unawaited(player.setReleaseMode(ReleaseMode.stop));
    unawaited(player.setPlayerMode(PlayerMode.mediaPlayer));
    player.onPlayerComplete.listen((_) => _resetPlaying());
    player.onPositionChanged.listen((p) => positionMs.value = p.inMilliseconds);
    player.onDurationChanged.listen((d) => durationMs.value = d.inMilliseconds);
    player.onPlayerStateChanged.listen((state) {
      if (state == PlayerState.completed) {
        _resetPlaying();
      }
    });
  }

  final AudioPlayer player = AudioPlayer();
  String? currentUrl;
  final ValueNotifier<String?> playingUrl = ValueNotifier(null);
  final ValueNotifier<int> positionMs = ValueNotifier(0);
  final ValueNotifier<int> durationMs = ValueNotifier(0);
  final ValueNotifier<double> speed = ValueNotifier(1.0);

  static const speeds = [1.0, 1.5, 2.0, 2.5, 3.0];

  void _resetPlaying() {
    playingUrl.value = null;
    positionMs.value = 0;
  }

  String _ensureAbsoluteUrl(String url) {
    if (url.startsWith('http://') || url.startsWith('https://') || url.startsWith('data:')) {
      return url;
    }
    // Prepend media base URL for media files
    if (url.startsWith('/')) {
      return '${AppConfig.mediaBase}$url';
    }
    return '${AppConfig.mediaBase}/$url';
  }

  String speedLabel([double? v]) {
    final s = v ?? speed.value;
    return s == s.roundToDouble() ? '${s.toInt()}x' : '${s}x';
  }

  Future<void> cycleSpeed() async {
    final idx = speeds.indexOf(speed.value);
    final next = speeds[(idx < 0 ? 0 : idx + 1) % speeds.length];
    speed.value = next;
    try { await player.setPlaybackRate(next); } catch (_) {}
  }

  Future<void> toggle(String url) async {
    if (url.isEmpty) return;
    if (playingUrl.value == url) {
      await player.pause();
      playingUrl.value = null;
      return;
    }
    playingUrl.value = url;
    positionMs.value = 0;
    if (currentUrl != url) {
      // Reset — otherwise the loading spinner never shows for the 2nd+
      // voice note, since durationMs still holds the previous track's value.
      durationMs.value = 0;
    }
    try {
      if (currentUrl != url) {
        currentUrl = url;
        await player.stop();
        // Nearby voice notes are local files; server voice notes are URLs.
        // UrlSource cannot play an Android filesystem path reliably, which
        // made received offline voice messages appear but remain silent.
        final isLocal = url.startsWith('/') || url.startsWith('file://');
        if (isLocal) {
          final path = url.startsWith('file://') ? Uri.parse(url).toFilePath() : url;
          debugPrint('VoicePlayerService: Playing local file $path');
          await player.play(DeviceFileSource(path));
        } else {
          final absoluteUrl = _ensureAbsoluteUrl(url);
          debugPrint('VoicePlayerService: Playing $absoluteUrl');
          await player.play(UrlSource(absoluteUrl));
        }
        await player.setPlaybackRate(speed.value);
      } else {
        await player.resume();
        await player.setPlaybackRate(speed.value);
      }
    } catch (e) {
      debugPrint('VoicePlayerService error: $e');
      _resetPlaying();
      currentUrl = null;
    }
  }

  static String fmtDuration(int secs) {
    if (secs <= 0) return '0:00';
    final m = secs ~/ 60;
    final s = secs % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  static String fmtMs(int ms) => fmtDuration((ms / 1000).round());
}

/// WhatsApp-style voice message row: play · waveform · speed · duration.
class VoiceMessageBar extends StatelessWidget {
  final String url;
  final int durationSecs;
  final Color textColor;
  final Color waveColor;
  final Color waveMutedColor;
  final Widget? timeRow;

  const VoiceMessageBar({
    super.key,
    required this.url,
    required this.durationSecs,
    required this.textColor,
    required this.waveColor,
    required this.waveMutedColor,
    this.timeRow,
  });

  @override
  Widget build(BuildContext context) {
    final svc = VoicePlayerService.i;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 10, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _PlayButton(url: url),
              const SizedBox(width: 10),
              Expanded(
                child: ValueListenableBuilder<String?>(
                  valueListenable: svc.playingUrl,
                  builder: (_, playing, __) {
                    final isActive = playing == url;
                    return ValueListenableBuilder<int>(
                      valueListenable: svc.positionMs,
                      builder: (_, pos, __) {
                        return ValueListenableBuilder<int>(
                          valueListenable: svc.durationMs,
                          builder: (_, durMs, __) {
                            final totalMs = durMs > 0
                                ? durMs
                                : (durationSecs > 0 ? durationSecs * 1000 : 0);
                            final progress = totalMs > 0 && isActive
                                ? (pos / totalMs).clamp(0.0, 1.0)
                                : 0.0;
                            return _Waveform(
                              progress: progress,
                              active: isActive,
                              color: waveColor,
                              mutedColor: waveMutedColor,
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              _SpeedChip(url: url, textColor: textColor),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 50),
            child: ValueListenableBuilder<String?>(
              valueListenable: svc.playingUrl,
              builder: (_, playing, __) {
                final isActive = playing == url;
                return ValueListenableBuilder<int>(
                  valueListenable: svc.positionMs,
                  builder: (_, pos, __) {
                    return ValueListenableBuilder<int>(
                      valueListenable: svc.durationMs,
                      builder: (_, durMs, __) {
                        final elapsed = isActive ? VoicePlayerService.fmtMs(pos) : '0:00';
                        final totalSecs = durationSecs > 0
                            ? durationSecs
                            : (durMs > 0 ? (durMs / 1000).round() : 0);
                        final totalLabel = VoicePlayerService.fmtDuration(totalSecs);
                        final durStyle = TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: textColor.withOpacity(.7),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        );
                        return Row(
                          children: [
                            Text(
                              isActive ? '$elapsed / $totalLabel' : totalLabel,
                              style: durStyle,
                            ),
                            if (totalSecs > 0) ...[
                              const SizedBox(width: 6),
                              Text(
                                '(${totalSecs >= 60 ? '${totalSecs ~/ 60}m ${totalSecs % 60}s' : '${totalSecs}s'})',
                                style: TextStyle(fontSize: 10.5, color: textColor.withOpacity(.45)),
                              ),
                            ],
                            const Spacer(),
                            if (timeRow != null) timeRow!,
                          ],
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  final String url;
  const _PlayButton({required this.url});

  @override
  Widget build(BuildContext context) {
    final svc = VoicePlayerService.i;
    return ValueListenableBuilder<String?>(
      valueListenable: svc.playingUrl,
      builder: (_, playing, __) {
        final isPlaying = playing == url;
        return GestureDetector(
          onTap: url.isEmpty ? null : () {
            debugPrint('VoiceMessageBar: Playing URL: $url');
            svc.toggle(url);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.primary,
              boxShadow: [
                BoxShadow(
                  color: AppColors.primary.withOpacity(.28),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ValueListenableBuilder<String?>(
              valueListenable: svc.playingUrl,
              builder: (_, playing, __) {
                return ValueListenableBuilder<int>(
                  valueListenable: svc.durationMs,
                  builder: (_, durMs, __) {
                    final isLoading = playing == url && svc.positionMs.value == 0 && durMs == 0;
                    if (isLoading) {
                      return const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      );
                    }
                    return Icon(
                      isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 22,
                    );
                  },
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _SpeedChip extends StatelessWidget {
  final String url;
  final Color textColor;
  const _SpeedChip({required this.url, required this.textColor});

  @override
  Widget build(BuildContext context) {
    final svc = VoicePlayerService.i;
    return ValueListenableBuilder<String?>(
      valueListenable: svc.playingUrl,
      builder: (_, playing, __) {
        return ValueListenableBuilder<double>(
          valueListenable: svc.speed,
          builder: (_, spd, __) {
            return GestureDetector(
              onTap: () => svc.cycleSpeed(),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: playing == url
                      ? AppColors.primary.withOpacity(.12)
                      : textColor.withOpacity(.06),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: playing == url
                        ? AppColors.primary.withOpacity(.35)
                        : textColor.withOpacity(.12),
                  ),
                ),
                child: Text(
                  svc.speedLabel(spd),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: playing == url ? AppColors.primary : textColor.withOpacity(.55),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Waveform extends StatelessWidget {
  final double progress;
  final bool active;
  final Color color;
  final Color mutedColor;

  const _Waveform({
    required this.progress,
    required this.active,
    required this.color,
    required this.mutedColor,
  });

  static const _heights = [
    0.35, 0.55, 0.85, 0.65, 1.0, 0.75, 0.45, 0.92, 0.68, 0.38,
    0.72, 1.0, 0.52, 0.82, 0.42, 0.64, 0.95, 0.58, 0.78, 0.36,
    0.88, 0.62, 1.0, 0.48, 0.74, 0.54, 0.92, 0.66, 0.44, 0.86,
    0.58, 0.80, 0.50, 0.70, 0.40, 0.90,
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: LayoutBuilder(builder: (_, c) {
        final barW = 2.5;
        final gap = (c.maxWidth - _heights.length * barW) / (_heights.length - 1);
        final playedBars = (progress * _heights.length).floor();
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: List.generate(_heights.length, (i) {
            final played = active && i <= playedBars;
            return Padding(
              padding: EdgeInsets.only(right: i < _heights.length - 1 ? gap : 0),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: barW,
                height: 30 * _heights[i],
                decoration: BoxDecoration(
                  color: played ? color : mutedColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            );
          }),
        );
      }),
    );
  }
}

/// Legacy export — use VoiceMessageBar for new code.
class AudioPlayButton extends StatelessWidget {
  final String url;
  final double size;
  const AudioPlayButton({super.key, required this.url, this.size = 38});

  @override
  Widget build(BuildContext context) => _PlayButton(url: url);
}
