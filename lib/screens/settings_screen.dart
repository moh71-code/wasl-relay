import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/storage/storage_service.dart';
import '../providers/settings_provider.dart';
import 'login_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String? _userId;

  @override
  void initState() {
    super.initState();
    StorageService().getUserId().then((id) {
      if (mounted) setState(() => _userId = id);
    });
  }

  void _showRelayConfigDialog(BuildContext context, SettingsProvider settings) {
    final hostController = TextEditingController(text: settings.relayHost);
    final portController = TextEditingController(text: settings.relayPort.toString());
    bool useWss = settings.useWss;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            final isAr = settings.isArabic;
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(Icons.dns, color: Colors.teal),
                  const SizedBox(width: 8),
                  Text(isAr ? 'إعدادات خادم الترحيل (Relay)' : 'Relay Server Settings'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: hostController,
                    decoration: InputDecoration(
                      labelText: isAr ? 'عنوان الخادم (IP أو النطاق)' : 'Server Host / IP',
                      hintText: '127.0.0.1',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: portController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: isAr ? 'منفذ الاتصال (Port)' : 'Port',
                      hintText: '8765',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(isAr ? 'استخدام اتصال مشفر (WSS)' : 'Use Secure WSS'),
                    value: useWss,
                    activeThumbColor: Colors.teal,
                    onChanged: (val) => setDlgState(() => useWss = val),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(isAr ? 'إلغاء' : 'Cancel'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                  onPressed: () async {
                    final host = hostController.text.trim();
                    final port = int.tryParse(portController.text.trim()) ?? 8765;
                    if (host.isNotEmpty) {
                      await settings.updateRelayConfig(
                        host: host,
                        port: port,
                        useWss: useWss,
                        currentUserId: _userId,
                      );
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(isAr
                                ? 'تم حفظ إعدادات الخادم وجارٍ إعادة الاتصال'
                                : 'Relay settings updated. Reconnecting...'),
                          ),
                        );
                      }
                    }
                  },
                  child: Text(isAr ? 'حفظ وتطبيق' : 'Save & Apply',
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showZeroizeDialog(BuildContext context, SettingsProvider settings) {
    final isAr = settings.isArabic;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red),
            const SizedBox(width: 8),
            Text(isAr ? 'تصفير ومسح شامل (Zeroize)' : 'Secure Zeroize Wipe'),
          ],
        ),
        content: Text(
          isAr
              ? 'سيتم تدمير ومسح كافة المفاتيح التشفيرية، قاعدة البيانات، وسجلات المحادثات، والملفات المؤقتة نهائياً وبشكل غير قابل للاسترجاع (Zeroize).\n\nهل أنت متأكد تماماً؟'
              : 'This will irreversibly erase all cryptographic keys, chat databases, and media from this device.\n\nAre you completely sure?',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(ctx);
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (_) => const Center(
                  child: CircularProgressIndicator(color: Colors.red),
                ),
              );

              await settings.performSecureZeroize();

              if (context.mounted) {
                Navigator.pop(context); // Close progress dialog
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              }
            },
            child: Text(isAr ? 'تأكيد التدمير النهائي' : 'Erase Everything',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final isAr = settings.isArabic;

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'إعدادات الخصوصية والنظام' : 'Privacy & Settings'),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Section 1: Anonymous Identity
          if (_userId != null) ...[
            Text(
              isAr ? 'الهوية التشفيرية المجهولة' : 'Anonymous Cryptographic Identity',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.teal,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.teal.shade200),
              ),
              child: Row(
                children: [
                  const Icon(Icons.fingerprint, color: Colors.teal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isAr ? 'معرّفك العام الخاص بهذا الجهاز' : 'Device Crypto ID',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        SelectableText(
                          _userId!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20, color: Colors.teal),
                    tooltip: isAr ? 'نسخ' : 'Copy',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _userId!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(isAr ? 'تم نسخ المعرف' : 'ID copied')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const Divider(height: 28),
          ],

          // Section 2: Relay Server
          Text(
            isAr ? 'خادم الترحيل (Relay Transport)' : 'Relay Transport Server',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.teal,
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.dns, color: Colors.teal),
            title: Text(isAr ? 'عنوان الخادم الوسيط' : 'Relay Server Host'),
            subtitle: Text('${settings.relayHost}:${settings.relayPort} (${settings.useWss ? "WSS" : "WS"})'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showRelayConfigDialog(context, settings),
          ),
          const Divider(height: 28),

          // Section 3: Privacy & Security Preferences
          Text(
            isAr ? 'الخصوصية وحماية البيانات' : 'Privacy & Data Protection',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.teal,
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            secondary: const Icon(Icons.done_all, color: Colors.teal),
            title: Text(isAr ? 'تأكيدات القراءة (Read Receipts)' : 'Read Receipts'),
            subtitle: Text(isAr
                ? 'إرسال واستقبال علامتي الصح الزرقاء/الخضراء عند قراءة الرسائل'
                : 'Send and receive read confirmations'),
            value: settings.sendReadReceipts,
            activeThumbColor: Colors.teal,
            onChanged: (val) => settings.setReadReceipts(val),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.download_for_offline, color: Colors.teal),
            title: Text(isAr ? 'التنزيل التلقائي للوسائط' : 'Auto-Download Media'),
            subtitle: Text(isAr
                ? 'تنزيل الصور والملفات الصوتية فور استلامها'
                : 'Automatically fetch and assemble incoming media files'),
            value: settings.autoDownloadMedia,
            activeThumbColor: Colors.teal,
            onChanged: (val) => settings.setAutoDownloadMedia(val),
          ),
          ListTile(
            leading: const Icon(Icons.security, color: Colors.teal),
            title: Text(isAr ? 'معايير التشفير' : 'Cryptographic Standards'),
            subtitle: const Text('Ed25519 / X25519 / AES-256-GCM / HKDF-SHA256'),
          ),
          const Divider(height: 28),

          // Section 4: Appearance & Language
          Text(
            isAr ? 'المظهر واللغة' : 'Appearance & Language',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: Colors.teal,
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.palette, color: Colors.teal),
            title: Text(isAr ? 'الوضع الليلي (Dark Mode)' : 'Dark Theme'),
            trailing: Switch(
              value: settings.themeMode == ThemeMode.dark,
              activeThumbColor: Colors.teal,
              onChanged: (val) => settings.toggleTheme(val),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.language, color: Colors.teal),
            title: Text(isAr ? 'لغة التطبيق' : 'App Language'),
            subtitle: Text(isAr ? 'العربية' : 'English'),
            trailing: DropdownButton<String>(
              value: settings.locale.languageCode,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'ar', child: Text('العربية')),
                DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: (lang) {
                if (lang != null) settings.changeLanguage(lang);
              },
            ),
          ),
          const Divider(height: 28),

          // Section 5: Secure Data Wipe (Zeroize)
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: Text(
              isAr ? 'تصفير ومسح كافة البيانات محلياً' : 'Zeroize & Wipe Local Data',
              style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              isAr
                  ? 'تدمير كامل وسريع للمفاتيح التشفيرية وقواعد البيانات'
                  : 'Permanently destroy cryptographic keys and local records',
            ),
            onTap: () => _showZeroizeDialog(context, settings),
          ),
        ],
      ),
    );
  }
}
