import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../notifications/notification_service.dart';
import '../storage/storage_service.dart';
import 'websocket_service.dart';

/// A newer release published on the relay (closed channel).
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

/// Closed self-update channel — the release files live on the relay's
/// private disk, NOT on any public link.
///
/// Flow:
///   1. The app sends `update_check` over the ALREADY-AUTHENTICATED
///      WebSocket — only signed-in identities ever reach this point.
///   2. The relay replies `update_info` with the manifest and a one-time
///      download token (single-use, expires in ~10 minutes).
///   3. The APK is fetched from `GET /update/apk?token=…` — the bare URL
///      404s for everyone, so no public link can ever exist or leak.
///
/// Publishing a release is operator-only: PUT the files to
/// `/admin/update/<name>` guarded by the ADMIN_TOKEN server secret.
class UpdateService {
  static const Duration _checkInterval = Duration(hours: 24);

  /// Latest discovered update — the settings screen listens to this to show
  /// the "update available" badge even if the check ran at startup.
  static final ValueNotifier<WaslUpdate?> pending =
      ValueNotifier<WaslUpdate?>(null);

  /// Waits until the WS session is fully authenticated (post-`registered`),
  /// since the relay drops every frame from unauthenticated sockets.
  static Future<bool> _awaitConnected(Duration timeout) async {
    final ws = WebSocketService();
    if (ws.isConnected) return true;
    try {
      await ws.statusStream
          .firstWhere((s) => s == 'connected')
          .timeout(timeout);
      return ws.isConnected;
    } catch (_) {
      return false;
    }
  }

  /// One WS round-trip: send `update_check`, await the `update_info` reply.
  /// Returns the decoded payload or null on timeout/failure.
  static Future<Map<String, dynamic>?> _requestUpdateInfo() async {
    final ws = WebSocketService();
    if (!await _awaitConnected(const Duration(seconds: 10))) return null;
    try {
      final reply = ws.messageStream
          .firstWhere((m) => m['type'] == 'update_info')
          .timeout(const Duration(seconds: 15));
      ws.sendData({'type': 'update_check'});
      return await reply;
    } catch (_) {
      return null;
    }
  }

  /// Fetches the manifest over the authenticated session; returns a
  /// [WaslUpdate] only when the published versionCode is strictly higher.
  static Future<WaslUpdate?> checkForUpdate() async {
    final info = await _requestUpdateInfo();
    if (info == null) return null;
    final manifest = info['manifest'];
    if (manifest is! Map) return null;
    try {
      final remoteCode = (manifest['version_code'] as num?)?.toInt() ?? 0;
      final pkg = await PackageInfo.fromPlatform();
      final localCode = int.tryParse(pkg.buildNumber) ?? 0;
      if (remoteCode <= localCode) {
        pending.value = null;
        return null;
      }
      final update = WaslUpdate(
        versionCode: remoteCode,
        versionName: manifest['version_name']?.toString() ?? '',
        notes: manifest['notes']?.toString() ?? '',
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

  /// Streams the release APK from the closed endpoint, reporting progress
  /// as 0.0–1.0. A FRESH single-use token is minted per download, so a
  /// token found at check time can never go stale before the user taps.
  static Future<File> downloadApk(void Function(double) onProgress) async {
    final info = await _requestUpdateInfo();
    final token = info?['token']?.toString() ?? '';
    if (token.isEmpty) {
      throw Exception('update token unavailable');
    }

    final cfg = await StorageService().getRelayConfig();
    final scheme = (cfg['useWss'] as bool) ? 'https' : 'http';
    final host = cfg['host'] as String;
    final port = cfg['port'] as int;
    final portPart = (port == 443 || port == 80) ? '' : ':$port';
    final uri = Uri.parse('$scheme://$host$portPart/update/apk?token=$token');

    final req = http.Request('GET', uri);
    final res =
        await http.Client().send(req).timeout(const Duration(seconds: 60));
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
