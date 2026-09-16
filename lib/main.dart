import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/crypto/pairing_service.dart';
import 'core/database/database_helper.dart';
import 'core/network/websocket_service.dart';
import 'core/storage/storage_service.dart';
import 'providers/settings_provider.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // جلب إعدادات الخادم والاتصال
  final relayConfig = await storage.getRelayConfig();
  WebSocketService().connect(
    myId,
    serverIp: relayConfig['host'] as String,
    serverPort: relayConfig['port'] as int,
    useWss: relayConfig['useWss'] as bool,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: WaslApp(currentUserId: myId),
    ),
  );
}

class WaslApp extends StatelessWidget {
  final String currentUserId;
  const WaslApp({super.key, required this.currentUserId});

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settings, child) {
        return MaterialApp(
          title: 'WASL E2EE',
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
          theme: ThemeData.light(useMaterial3: true).copyWith(
            primaryColor: Colors.teal,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
            primaryColor: Colors.teal,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.teal,
              brightness: Brightness.dark,
            ),
          ),
          themeMode: settings.themeMode,
          home: HomeScreen(currentUserId: currentUserId),
        );
      },
    );
  }
}
