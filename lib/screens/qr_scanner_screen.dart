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
  MobileScannerController? _scannerController;
  bool _cameraReady = false;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _scannerController = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
        torchEnabled: false,
      );
      await _scannerController!.start();
      if (mounted) {
        setState(() {
          _cameraReady = true;
          _cameraError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cameraError = 'تعذّر تشغيل الكاميرا.\nتأكد من منح صلاحية الكاميرا للتطبيق من إعدادات الهاتف.';
          _cameraReady = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _scannerController?.dispose();
    super.dispose();
  }

  Future<void> _startPairing(String targetId) async {
    if (_scanned || targetId.isEmpty) return;
    _scanned = true;

    // Stop camera to save battery
    await _scannerController?.stop();

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
            CircularProgressIndicator(color: Colors.teal),
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

      if (recipientId != widget.currentUserId) return;

      if (type == 'pair_accept' && senderId != null) {
        await DatabaseHelper.instance
            .saveContact(senderId, 'طرف مقترن', 'connected');
        if (!mounted) return;
        Navigator.of(context).pop();
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
          Navigator.of(context).pop();
          _wsSub?.cancel();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم رفض طلب الاقتران من $senderId')),
          );
          // Restart camera on rejection
          setState(() => _scanned = false);
          await _scannerController?.start();
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
          decoration: const InputDecoration(
            hintText: 'WASL-XXXXXX',
            prefixIcon: Icon(Icons.security, color: Colors.teal),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('إرسال طلب', style: TextStyle(color: Colors.white)),
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
      backgroundColor: Colors.black,
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
          if (_scannerController != null)
            IconButton(
              icon: const Icon(Icons.flash_on),
              tooltip: 'فلاش',
              onPressed: () => _scannerController?.toggleTorch(),
            ),
        ],
      ),
      body: _cameraError != null
          ? _buildCameraError()
          : !_cameraReady
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Colors.teal),
                      SizedBox(height: 16),
                      Text('جارٍ تشغيل الكاميرا...',
                          style: TextStyle(color: Colors.white)),
                    ],
                  ),
                )
              : Stack(
                  children: [
                    MobileScanner(
                      controller: _scannerController,
                      onDetect: (capture) {
                        if (_scanned) return;
                        for (final barcode in capture.barcodes) {
                          if (barcode.rawValue != null) {
                            final scanned = barcode.rawValue!.trim();
                            if (scanned.isNotEmpty) {
                              _startPairing(scanned);
                              break;
                            }
                          }
                        }
                      },
                    ),
                    // Scanning frame overlay
                    Center(
                      child: Container(
                        width: 250,
                        height: 250,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.teal, width: 3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Center(
                          child: Text(
                            'وجّه الكاميرا نحو الكود',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                        ),
                      ),
                    ),
                    // Manual entry hint at bottom
                    Positioned(
                      bottom: 40,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: TextButton.icon(
                          icon: const Icon(Icons.keyboard, color: Colors.white70),
                          label: const Text(
                            'أو أدخل المعرف يدوياً',
                            style: TextStyle(color: Colors.white70),
                          ),
                          onPressed: _askManualEntry,
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildCameraError() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.camera_alt_outlined, size: 80, color: Colors.red),
            const SizedBox(height: 20),
            Text(
              _cameraError ?? 'خطأ في الكاميرا',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
              onPressed: () {
                setState(() {
                  _cameraError = null;
                  _cameraReady = false;
                });
                _initCamera();
              },
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              icon: const Icon(Icons.keyboard, color: Colors.white70),
              label: const Text(
                'إدخال المعرف يدوياً',
                style: TextStyle(color: Colors.white70),
              ),
              onPressed: _askManualEntry,
            ),
          ],
        ),
      ),
    );
  }
}
