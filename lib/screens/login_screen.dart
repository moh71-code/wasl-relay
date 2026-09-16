import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/crypto/pairing_service.dart';
import '../core/storage/storage_service.dart';
import 'chats_list_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final StorageService _storageService = StorageService();
  String? _myCryptoId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initAnonymousIdentity();
  }

  Future<void> _initAnonymousIdentity() async {
    String? savedId = await _storageService.getUserId();
    
    if (savedId == null || savedId.isEmpty) {
      savedId = PairingService.generateSecureUserId();
      await _storageService.saveUserId(savedId);
    }

    try {
      await PairingService().ensureIdentityKeys(savedId);
    } catch (_) {}

    setState(() {
      _myCryptoId = savedId;
      _isLoading = false;
    });
  }

  void _enterApp() {
    if (_myCryptoId != null) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => ChatsListScreen(currentUserId: _myCryptoId!),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Colors.teal),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('WASL - هوية مشفرة مجهولة'),
        centerTitle: true,
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.security, size: 90, color: Colors.teal),
            const SizedBox(height: 20),
            const Text(
              'هويتك التشفيرية الخاصة',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              'تم إنشاء عنوانك التشفيري المحلي بنجاح. لا يتطلب التطبيق أي رقم هاتف أو صلاحيات لجهات الاتصال.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.teal.shade200),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      _myCryptoId ?? '',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                        color: Colors.teal,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, color: Colors.teal),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _myCryptoId ?? ''));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('تم نسخ معرّفك المشفر')),
                      );
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                onPressed: _enterApp,
                child: const Text(
                  'الدخول إلى المحادثات',
                  style: TextStyle(fontSize: 18, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
