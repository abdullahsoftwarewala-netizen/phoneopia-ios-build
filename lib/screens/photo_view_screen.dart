import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Fullscreen photo viewer with screenshots BLOCKED while open
/// (FLAG_SECURE via the phoneopia/secure platform channel).
class PhotoViewScreen extends StatefulWidget {
  final String url;
  final String title;
  const PhotoViewScreen({super.key, required this.url, this.title = ''});

  @override
  State<PhotoViewScreen> createState() => _PhotoViewScreenState();
}

class _PhotoViewScreenState extends State<PhotoViewScreen> {
  static const _secure = MethodChannel('phoneopia/secure');

  @override
  void initState() {
    super.initState();
    _secure.invokeMethod('enable').catchError((_) => null);
  }

  @override
  void dispose() {
    _secure.invokeMethod('disable').catchError((_) => null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, style: const TextStyle(fontSize: 16)),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 14),
            child: Icon(Icons.screenshot_monitor, color: Colors.white38, size: 18),
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.network(
            widget.url,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.broken_image, color: Colors.white24, size: 64),
          ),
        ),
      ),
    );
  }
}
