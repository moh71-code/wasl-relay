import 'dart:io';
import 'core/l10n/s.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/crypto/pairing_service.dart';
import 'core/database/database_helper.dart';
import 'core/network/websocket_service.dart';
import 'core/network/push_service.dart';
import 'core/network/update_service.dart';
import 'core/network/message_ingestion_service.dart';
import 'core/notifications/notification_service.dart';
import 'core/storage/storage_service.dart';
import 'core/theme/wasl_theme.dart';
import 'providers/settings_provider.dart';
import 'screens/chats_list_screen.dart';
import 'screens/name_setup_screen.dart';
import 'screens/pin_lock_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    // تهيئة SQLite للأنظمة المكتبية (Windows, Linux, macOS)
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    await Hive.initFlutter();
    await DatabaseHelper.instance.database;

    final storage = StorageService();

    // توليد أو استرجاع المعرف التشفيري الآمن (CSPRNG)
    String? myId = await storage.getUserId();
    if (myId == null || myId.isEmpty) {
      myId = PairingService.generateSecureUserId();
      await storage.saveUserId(myId);
    }

    // التأكد من تهيئة مفاتيح الهوية التشفيرية المحلية
    try {
      await PairingService().ensureIdentityKeys(myId);
    } catch (_) {}

    // تهيئة خدمة استلام وفك تشفير الرسائل والملفات في الخلفية
    MessageIngestionService().init(myId);

    // تهيئة الإشعارات المحلية الآمنة (لا تكشف المحتوى أو المرسل)
    await NotificationService().init();

    // قناة الإيقاظ السحابية (FCM) — توقظ التطبيق عند وصول رسائل وهو مغلق.
    // يجب أن تُهيأ قبل الاتصال حتى تلتقط أول حالة "connected".
    await PushService().init();

    // جلب إعدادات الخادم والاتصال
    final relayConfig = await storage.getRelayConfig();
    WebSocketService().connect(
      myId,
      serverIp: relayConfig['host'] as String,
      serverPort: relayConfig['port'] as int,
      useWss: relayConfig['useWss'] as bool,
    );

    // فحص التحديثات مرة كل 24 ساعة — طلب GET صغير، بلا بيانات مستخدم
    UpdateService.autoCheck();

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ],
        child: WaslApp(currentUserId: myId),
      ),
    );
  } catch (e, stackTrace) {
    // طباعة الخطأ للتحقق
    debugPrint('Error during app initialization: $e');
    debugPrint('Stack trace: $stackTrace');
    
    // تشغيل تطبيق بسيط لإظهار الخطأ
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                      Text(S.initError),
                const SizedBox(height: 8),
                Text('$e', textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WaslApp extends StatefulWidget {
  final String currentUserId;
  const WaslApp({super.key, required this.currentUserId});

  @override
  State<WaslApp> createState() => _WaslAppState();
}

class _WaslAppState extends State<WaslApp> with WidgetsBindingObserver {
  bool _hasDisplayName = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkDisplayName();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Local notifications are suppressed while the app is in the foreground.
    NotificationService.appInForeground =
        state == AppLifecycleState.resumed;
  }

  Future<void> _checkDisplayName() async {
    final name = await StorageService().getDisplayName();
    if (mounted) {
      setState(() => _hasDisplayName = name != null && name.isNotEmpty);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        return MaterialApp(
          title: 'WASL - Premium Secure Messenger',
          debugShowCheckedModeBanner: false,
          locale: settings.locale,
          supportedLocales: const [
            Locale('ar', ''),
            Locale('en', ''),
          ],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          theme: WaslTheme.light(),
          darkTheme: WaslTheme.dark(),
          themeMode: settings.themeMode,
          builder: (context, child) {
            return AppLockGate(child: child ?? const SizedBox.shrink());
          },
          home: _hasDisplayName
              ? ChatsListScreen(currentUserId: widget.currentUserId)
              : NameSetupScreen(
                  onDone: () {
                    context.read<SettingsProvider>().saveDisplayNameFromGate();
                    setState(() => _hasDisplayName = true);
                  },
                ),
        );
      },
    );
  }
}
