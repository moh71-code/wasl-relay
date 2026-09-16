import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'dart:async';
import '../core/network/websocket_service.dart';
import '../core/database/database_helper.dart';
import '../core/crypto/pairing_service.dart';
import 'chat_screen.dart';

class QrDisplayDialog extends StatelessWidget {
  final String userId;

  const QrDisplayDialog({super.key, required this.userId});

  @override
  Widget build(BuildContext context) {
    // التأكد من وجود قيمة للمعرف التشفيري، وفي حال عدم وجودها يتم وضع نص افتراضي للوقاية
    final displayData = userId.trim().isNotEmpty ? userId : 'WASL-UNKNOWN-ID';

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.qr_code_2, color: Colors.teal),
          SizedBox(width: 8),
          Text('معرّفك التشفيري (QR)'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'اسمح للطرف الآخر بمسح الكود أدناه لإنشاء قناة محادثة مشفرة E2EE مباشرة:',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: displayData,
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: Colors.white,
                errorCorrectionLevel: QrErrorCorrectLevel.M,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SelectableText(
            displayData,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}

class QrScannerScreen extends StatefulWidget {
  final String currentUserId;

  const QrScannerScreen({super.key, required this.currentUserId});

  @override
  State<QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<QrScannerScreen> {
  bool _scanned = false;
  StreamSubscription? _wsSub;

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }

  Future<void> _startPairing(String targetId) async {
    if (_scanned) return;
    _scanned = true;

    await PairingService()
        .sendPairRequest(myId: widget.currentUserId, targetId: targetId);

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('جارٍ إرسال طلب الاقتران'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('في انتظار قبول الطرف الآخر...'),
          ],
        ),
      ),
    );

    _wsSub = WebSocketService().messageStream.listen((data) async {
      final type = data['type'];
      final senderId = data['sender_id'];
      final recipientId = data['recipient_id'];

      // We only care about responses addressed to this device and related to the target we requested
      if (recipientId != widget.currentUserId) return;

      if (type == 'pair_accept' && senderId != null) {
        // save contact and navigate to chat
        await DatabaseHelper.instance
            .saveContact(senderId, 'طرف مقترن', 'connected');
        if (!mounted) return;
        Navigator.of(context).pop(); // close loading
        _wsSub?.cancel();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => ChatScreen(
              currentUserId: widget.currentUserId,
              recipientId: senderId,
            ),
          ),
        );
      } else if (type == 'pair_reject' && senderId == targetId) {
        if (mounted) {
          Navigator.of(context).pop(); // close loading
          _wsSub?.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم رفض طلب الاقتران من $senderId')),
          );
        }
      }
    });
  }

  Future<void> _askManualEntry() async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إدخال معرف الجهاز يدوياً'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'WASL-XXXXXX'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('إرسال طلب'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      _startPairing(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح كود التبادل المشفر'),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.keyboard),
            tooltip: 'إدخال يدوي',
            onPressed: _askManualEntry,
          ),
        ],
      ),
      body: MobileScanner(
        onDetect: (capture) {
          if (_scanned) return;
          final List<Barcode> barcodes = capture.barcodes;
          for (final barcode in barcodes) {
            if (barcode.rawValue != null) {
              final scanned = barcode.rawValue!.trim();
              _startPairing(scanned);
              break;
            }
          }
        },
      ),
    );
  }
}
