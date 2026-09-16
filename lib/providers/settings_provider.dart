import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../core/database/database_helper.dart';
import '../core/network/websocket_service.dart';
import '../core/storage/storage_service.dart';

class SettingsProvider extends ChangeNotifier {
  static const String settingsBoxName = 'app_settings';
  late Box _box;

  ThemeMode _themeMode = ThemeMode.dark;
  Locale _locale = const Locale('ar');

  String _relayHost = '127.0.0.1';
  int _relayPort = 8765;
  bool _useWss = false;

  bool _sendReadReceipts = true;
  bool _autoDownloadMedia = true;
  int? _defaultEphemeralTtl;
  String _defaultEphemeralTrigger = 'send'; // 'send' or 'read'

  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;
  bool get isArabic => _locale.languageCode == 'ar';

  String get relayHost => _relayHost;
  int get relayPort => _relayPort;
  bool get useWss => _useWss;

  bool get sendReadReceipts => _sendReadReceipts;
  bool get autoDownloadMedia => _autoDownloadMedia;
  int? get defaultEphemeralTtl => _defaultEphemeralTtl;
  String get defaultEphemeralTrigger => _defaultEphemeralTrigger;

  SettingsProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _box = await Hive.openBox(settingsBoxName);

    final isDark = _box.get('is_dark', defaultValue: true);
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;

    final langCode = _box.get('lang_code', defaultValue: 'ar');
    _locale = Locale(langCode);

    // Load Relay config from secure storage / hive
    final storage = StorageService();
    final relay = await storage.getRelayConfig();
    _relayHost = relay['host'] as String;
    _relayPort = relay['port'] as int;
    _useWss = relay['useWss'] as bool;

    // Load Privacy preferences
    final privacy = await storage.getPrivacySettings();
    _sendReadReceipts = privacy['sendReadReceipts'] as bool;
    _autoDownloadMedia = privacy['autoDownloadMedia'] as bool;
    _defaultEphemeralTtl = privacy['defaultEphemeralTtl'] as int?;
    _defaultEphemeralTrigger = privacy['defaultEphemeralTrigger'] as String;

    // Configure WebSocket with loaded settings
    WebSocketService().configure(
      host: _relayHost,
      port: _relayPort,
      useWss: _useWss,
    );

    notifyListeners();
  }

  Future<void> toggleTheme(bool isDark) async {
    _themeMode = isDark ? ThemeMode.dark : ThemeMode.light;
    await _box.put('is_dark', isDark);
    notifyListeners();
  }

  Future<void> changeLanguage(String langCode) async {
    _locale = Locale(langCode);
    await _box.put('lang_code', langCode);
    notifyListeners();
  }

  Future<void> updateRelayConfig({
    required String host,
    required int port,
    required bool useWss,
    String? currentUserId,
  }) async {
    _relayHost = host.trim();
    _relayPort = port;
    _useWss = useWss;

    final storage = StorageService();
    await storage.saveRelayConfig(host: _relayHost, port: _relayPort, useWss: _useWss);

    WebSocketService().configure(host: _relayHost, port: _relayPort, useWss: _useWss);

    if (currentUserId != null && currentUserId.isNotEmpty) {
      WebSocketService().connect(
        currentUserId,
        serverIp: _relayHost,
        serverPort: _relayPort,
        useWss: _useWss,
      );
    }

    notifyListeners();
  }

  Future<void> setReadReceipts(bool enabled) async {
    _sendReadReceipts = enabled;
    await _savePrivacySettings();
    notifyListeners();
  }

  Future<void> setAutoDownloadMedia(bool enabled) async {
    _autoDownloadMedia = enabled;
    await _savePrivacySettings();
    notifyListeners();
  }

  Future<void> setDefaultEphemeral(int? ttlMs, String trigger) async {
    _defaultEphemeralTtl = ttlMs;
    _defaultEphemeralTrigger = trigger;
    await _savePrivacySettings();
    notifyListeners();
  }

  Future<void> _savePrivacySettings() async {
    await StorageService().savePrivacySettings(
      sendReadReceipts: _sendReadReceipts,
      autoDownloadMedia: _autoDownloadMedia,
      defaultEphemeralTtl: _defaultEphemeralTtl,
      defaultEphemeralTrigger: _defaultEphemeralTrigger,
    );
  }

  /// Complete Zeroize Wipe: Purge SQLite, FlutterSecureStorage, Hive boxes, and local files
  Future<void> performSecureZeroize() async {
    // 1. Wipe SQLite
    await DatabaseHelper.instance.secureZeroizeDatabase();

    // 2. Wipe FlutterSecureStorage
    await StorageService().wipeAllSecureKeys();

    // 3. Clear Hive boxes
    try {
      await _box.clear();
      if (Hive.isBoxOpen('settings')) {
        await Hive.box('settings').clear();
      }
      if (Hive.isBoxOpen('encrypted_messages')) {
        await Hive.box('encrypted_messages').clear();
      }
      if (Hive.isBoxOpen('contacts')) {
        await Hive.box('contacts').clear();
      }
      if (Hive.isBoxOpen('chats')) {
        await Hive.box('chats').clear();
      }
    } catch (_) {}

    // 4. Delete temp and documents files
    try {
      final docDir = await getApplicationDocumentsDirectory();
      if (await docDir.exists()) {
        final files = docDir.listSync();
        for (var f in files) {
          try {
            if (f is File) f.deleteSync();
          } catch (_) {}
        }
      }
      final tmpDir = await getTemporaryDirectory();
      if (await tmpDir.exists()) {
        final files = tmpDir.listSync();
        for (var f in files) {
          try {
            if (f is File) f.deleteSync();
          } catch (_) {}
        }
      }
    } catch (_) {}

    // 5. Disconnect WebSocket
    WebSocketService().disconnect();

    notifyListeners();
  }
}
