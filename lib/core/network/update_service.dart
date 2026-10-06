import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../notifications/notification_service.dart';
import '../storage/storage_service.dart';

/// A newer release published on GitHub.
class WaslUpdate {
  final int versionCode;
  final String versionName;
  final String notes;
  const WaslUpdate({
    required this.versionCode,
    required this.versionName,
    required this.notes,
  });
}

/// Self-update over GitHub Releases — no Play Store involved.
///
/// Release workflow: create a GitHub release on the public repo with two
/// assets — `version.json` (`{"version_code": N, "version_name": "x.y.z",
/// "notes": "…"}`) and `wasl-release.apk`. The `releases/latest/download/…`
/// URLs below always resolve to the newest release, so the app never needs
/// a hardcoded version or API token.
///
/// Installing still requires the user's explicit approval ("install from
/// this source") once per device — nothing is installed silently. Updates
/// only apply when the signing key matches the installed build.
class UpdateService {
  static const String _manifestUrl =
      'https://github.com/moh71-code/wasl-relay/releases/latest/download/version.json';
  static const String _apkUrl =
      'https://github.com/moh71-code/wasl-relay/releases/latest/download/wasl-release.apk';

  static const Duration _checkInterval = Duration(hours: 24);

  /// Latest discovered update — the settings screen listens to this to show
  /// the "update available" badge even if the check ran at startup.
  static final ValueNotifier<WaslUpdate?> pending = ValueNotifier<WaslUpdate?>(null);

  /// Fetches the release manifest; returns a [WaslUpdate] only when the
  /// published versionCode is strictly higher than the installed build.
  static Future<WaslUpdate?> checkForUpdate() async {
    try {
      final bust = DateTime.now().millisecondsSinceEpoch;
      final res = await http
          .get(Uri.parse('$_manifestUrl?cb=$bust'))
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;

      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final remoteCode = (j['version_code'] as num?)?.toInt() ?? 0;

      final info = await PackageInfo.fromPlatform();
      final localCode = int.tryParse(info.buildNumber) ?? 0;
      if (remoteCode <= localCode) {
        pending.value = null;
        return null;
      }

      final update = WaslUpdate(
        versionCode: remoteCode,
        versionName: j['version_name']?.toString() ?? '',
        notes: j['notes']?.toString() ?? '',
      );
      pending.value = update;
      return update;
    } catch (_) {
      return null;
    }
  }

  /// Cold-start check, throttled to once per [_checkInterval]; posts a
  /// generic local notification when a newer build exists.
  static Future<void> autoCheck() async {
    try {
      final storage = StorageService();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - await storage.getLastUpdateCheck() <
          _checkInterval.inMilliseconds) {
        return;
      }
      await storage.setLastUpdateCheck(now);
      final update = await checkForUpdate();
      if (update != null) {
        await NotificationService().notifyUpdateAvailable();
      }
    } catch (_) {}
  }

  /// Streams the release APK to the temp directory, reporting progress as
  /// 0.0–1.0. Any stale download from a previous attempt is overwritten.
  static Future<File> downloadApk(void Function(double) onProgress) async {
    final req = http.Request('GET', Uri.parse(_apkUrl));
    final res = await http.Client()
        .send(req)
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) {
      throw Exception('APK download failed: HTTP ${res.statusCode}');
    }

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/wasl_update.apk');
    final sink = file.openWrite();
    final total = res.contentLength ?? 0;
    var received = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return file;
  }

  /// Hands the APK to the system package installer. The user sees the
  /// standard Android install screen and must approve it.
  static Future<void> install(File apk) async {
    await OpenFilex.open(apk.path);
  }
}
