import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';
import '../services/api_service.dart';

/// Live/OTA update — checks the server for a newer APK, downloads it, and
/// launches the system installer. Channel (production/beta) is stored locally.
class UpdateService {
  static final UpdateService _i = UpdateService._();
  factory UpdateService() => _i;
  UpdateService._();

  bool _checkedThisSession = false;

  Future<String> channel() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('update_channel') ?? 'production';
  }

  Future<void> setChannel(String c) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('update_channel', c == 'beta' ? 'beta' : 'production');
  }

  Future<int> currentVersionCode() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return int.tryParse(info.buildNumber) ?? 0;
    } catch (_) { return 0; }
  }

  /// Returns update info {version_name, version_code, apk_url, changelog,
  /// force_update, apk_size} if a newer version exists, else null.
  Future<Map<String, dynamic>?> check() async {
    try {
      final code = await currentVersionCode();
      final ch = await channel();
      final uri = Uri.parse('${ApiService.baseUrl}/appupdate.php').replace(
        queryParameters: {'action': 'check', 'version_code': '$code', 'channel': ch});
      final res = await http.get(uri).timeout(const Duration(seconds: 12));
      final j = jsonDecode(res.body);
      if (j is Map && j['success'] == true && j['update'] == true) {
        return Map<String, dynamic>.from(j);
      }
    } catch (_) {}
    return null;
  }

  /// Check once per app session (called on launch/resume) — returns info or null.
  Future<Map<String, dynamic>?> checkOnce({bool force = false}) async {
    if (_checkedThisSession && !force) return null;
    _checkedThisSession = true;
    return check();
  }

  /// Download the APK (with progress 0..1) and open the installer.
  Future<bool> downloadAndInstall(String apkUrl, {void Function(double)? onProgress, int? versionCode}) async {
    try {
      // Android 8+ needs permission to install from this app.
      try {
        final st = await Permission.requestInstallPackages.status;
        if (!st.isGranted) await Permission.requestInstallPackages.request();
      } catch (_) {}

      final url = apkUrl.startsWith('http') ? apkUrl : '${AppConfig.mediaBase}$apkUrl';
      Directory dir = (await getExternalStorageDirectory()) ?? (await getTemporaryDirectory());
      final path = '${dir.path}/phoneopia_update_${versionCode ?? 'latest'}.apk';
      final f = File(path);
      var complete = false;
      for (var attempt = 0; attempt < 5 && !complete; attempt++) {
        var offset = await f.exists() ? await f.length() : 0;
        final req = http.Request('GET', Uri.parse(url));
        if (offset > 0) req.headers['Range'] = 'bytes=$offset-';
        final resp = await req.send().timeout(const Duration(seconds: 20));
        if (resp.statusCode != 200 && resp.statusCode != 206) return false;
        // Server ignored Range: restart cleanly rather than appending a second APK.
        if (offset > 0 && resp.statusCode == 200) {
          await f.writeAsBytes(const [], flush: true);
          offset = 0;
        }
        final expected = resp.contentLength == null ? 0 : offset + resp.contentLength!;
        var received = offset;
        final sink = f.openWrite(mode: offset > 0 ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in resp.stream.timeout(const Duration(seconds: 25))) {
            sink.add(chunk);
            received += chunk.length;
            if (expected > 0) onProgress?.call((received / expected).clamp(0, .99));
          }
          await sink.flush();
        } catch (_) {
          // Keep the partial file; the next attempt resumes from this byte.
        } finally {
          await sink.close();
        }
        final actual = await f.length();
        complete = expected > 0 ? actual >= expected : actual > 1024 * 1024;
        if (!complete) await Future.delayed(Duration(seconds: attempt + 1));
      }
      if (!complete) return false;
      onProgress?.call(1);

      if (versionCode != null) {
        final p = await SharedPreferences.getInstance();
        await p.setString('pending_install_apk_path', path);
        await p.setInt('pending_install_version_code', versionCode);
      }

      final r = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
      // Remember this so a "tap to install" banner can bring the installer
      // back if the user closes the dialog without actually tapping Install
      // on Android's own confirmation screen (opening ≠ installing).
      return r.type == ResultType.done;
    } catch (_) {
      return false;
    }
  }

  /// Non-null when a downloaded update hasn't actually been installed yet
  /// (current running version is still older than what was downloaded).
  /// Auto-clears itself once the install genuinely happened.
  Future<({String path, int versionCode})?> pendingInstall() async {
    final p = await SharedPreferences.getInstance();
    final path = p.getString('pending_install_apk_path');
    final vc = p.getInt('pending_install_version_code');
    if (path == null || vc == null) return null;
    if (!await File(path).exists()) { await clearPendingInstall(); return null; }
    final current = await currentVersionCode();
    if (current >= vc) { await clearPendingInstall(); return null; }
    return (path: path, versionCode: vc);
  }

  Future<void> clearPendingInstall() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('pending_install_apk_path');
    await p.remove('pending_install_version_code');
  }

  /// Re-open the system installer for an already-downloaded APK.
  Future<bool> reopenInstaller(String path) async {
    try {
      final r = await OpenFilex.open(path, type: 'application/vnd.android.package-archive');
      return r.type == ResultType.done;
    } catch (_) {
      return false;
    }
  }
}
