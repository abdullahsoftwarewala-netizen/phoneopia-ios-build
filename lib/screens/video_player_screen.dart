import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerScreen extends StatefulWidget {
  final String url;
  const VideoPlayerScreen({super.key, required this.url});
  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late final VideoPlayerController _ctrl;
  bool _ready = false;
  bool _failed = false;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _ctrl.initialize().then(
      (_) {
        if (!mounted) return;
        setState(() => _ready = true);
        _ctrl.play();
      },
      onError: (_, __) {
        if (mounted) setState(() => _failed = true);
      },
    );
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Center(
        child: _failed
            ? const Text(
                'Couldn\'t play this video',
                style: TextStyle(color: Colors.white70),
              )
            : !_ready
            ? const CircularProgressIndicator(color: Colors.white)
            : GestureDetector(
                onTap: () => setState(() => _showControls = !_showControls),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AspectRatio(
                      aspectRatio: _ctrl.value.aspectRatio,
                      child: VideoPlayer(_ctrl),
                    ),
                    if (_showControls) ...[
                      IconButton(
                        iconSize: 64,
                        color: Colors.white,
                        icon: Icon(
                          _ctrl.value.isPlaying
                              ? Icons.pause_circle_filled
                              : Icons.play_circle_filled,
                        ),
                        onPressed: () => setState(
                          () => _ctrl.value.isPlaying
                              ? _ctrl.pause()
                              : _ctrl.play(),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: VideoProgressIndicator(
                          _ctrl,
                          allowScrubbing: true,
                          padding: const EdgeInsets.all(12),
                          colors: const VideoProgressColors(
                            playedColor: Colors.redAccent,
                            bufferedColor: Colors.white30,
                            backgroundColor: Colors.white12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }
}
