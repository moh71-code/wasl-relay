import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../notifications/notification_service.dart';
import 'websocket_service.dart';

/// FCM push wake-up channel.
///
/// A WebSocket can never reach a killed/frozen app — Android Doze and OEM
/// battery managers kill the process and its socket. FCM is Google Play
/// Services' always-on push channel shared by all apps, so the OS itself
/// can wake this app when the relay buffers ciphertext for it.
///
/// Privacy: pushes are data-only `{type: "wake"}` nudges. They carry no
/// content, no sender id, no metadata — the zero-knowledge design holds
/// end to end. On wake we show the same generic local notification the
/// foreground path uses.
class PushService {
  static final PushService _instance = PushService._internal();
  factory PushService() => _instance;
  PushService._internal();

  String? _token;
  bool _initialized = false;

  /// Runs in a SEPARATE background isolate when a data message arrives
  /// while the app is terminated. Must stay a top-level/static function.
  @pragma('vm:entry-point')
  static Future<void> _backgroundHandler(RemoteMessage message) async {
    try {
      await Firebase.initializeApp();
      final notif = NotificationService();
      await notif.init();
      // This isolate only exists because the app is NOT in the foreground.
      NotificationService.appInForeground = false;
      await notif.notifyNewMessage();
    } catch (e) {
      debugPrint('PushService background handler failed: $e');
    }
  }

  /// Initialize Firebase, grab the device token, and keep the relay updated.
  /// Safe to call on any platform — no-ops outside Android for now.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    // FCM delivery is wired for Android; iOS needs an APNs key in Firebase
    // first, and desktop/web keep the WS-only path.
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(_backgroundHandler);

      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission();
      _token = await messaging.getToken();
      messaging.onTokenRefresh.listen((t) {
        _token = t;
        _sendTokenToRelay();
      });

      // The relay stores tokens in RAM, so a server restart wipes them —
      // re-push after every authenticated (re)connect.
      WebSocketService().statusStream.listen((state) {
        if (state == 'connected') _sendTokenToRelay();
      });
      _sendTokenToRelay();
      debugPrint('PushService: FCM ready');
    } catch (e) {
      // Missing google-services.json etc. — the app keeps working
      // WS-only; pushes simply stay disabled.
      debugPrint('PushService init failed (push disabled): $e');
    }
  }

  void _sendTokenToRelay() {
    final t = _token;
    if (t != null && WebSocketService().isConnected) {
      WebSocketService().sendData({'type': 'fcm_token', 'token': t});
    }
  }
}
