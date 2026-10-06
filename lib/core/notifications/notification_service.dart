import 'package:flutter/foundation.dart';
import '../l10n/s.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Privacy-safe local notifications.
///
/// Per the WASL requirements document, notifications must never reveal the
/// message content, the sender identity, or any conversation detail — so every
/// notification body is a fixed generic string. Nothing is sent to external
/// push services; everything is generated locally on the device.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Updated by the app lifecycle observer; notifications are only posted while
  /// the app is not in the foreground to avoid noisy in-app banners.
  static bool appInForeground = true;

  static const String _channelId = 'wasl_messages';
  static String get _channelName => S.notifChannelName;
  static String get _channelDesc => S.notifChannelDesc;

  int _notificationId = 1000;

  Future<void> init() async {
    if (_initialized) return;
    try {
      const androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _plugin.initialize(initSettings);

      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        await androidImpl.createNotificationChannel(
          AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDesc,
            importance: Importance.high,
          ),
        );
        // Android 13+ runtime permission
        await androidImpl.requestNotificationsPermission();
      }
      _initialized = true;
    } catch (e) {
      debugPrint('NotificationService init failed: $e');
    }
  }

  /// Generic update notification — the user opens Settings to act on it.
  Future<void> notifyUpdateAvailable() async {
    if (!_initialized) return;
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
        ),
      );
      await _plugin.show(
        _notificationId++,
        S.updateAvailable,
        S.updateAvailableBody,
        details,
      );
    } catch (e) {
      debugPrint('NotificationService update notification failed: $e');
    }
  }

  /// Show a generic, content-free notification for a newly ingested message.
  /// Callers must not pass message content or sender details.
  Future<void> notifyNewMessage() async {
    if (!_initialized || appInForeground) return;
    try {
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.high,
          priority: Priority.high,
          // Generic text only — zero metadata leakage.
          category: AndroidNotificationCategory.message,
        ),
      );
      await _plugin.show(
        _notificationId++,
        S.notifTitle,
        S.notifBody,
        details,
      );
    } catch (e) {
      debugPrint('NotificationService show failed: $e');
    }
  }
}
