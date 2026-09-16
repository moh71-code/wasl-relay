import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../core/database/database_helper.dart';
import '../core/network/websocket_service.dart';
import '../core/crypto/pairing_service.dart';
import '../core/storage/storage_service.dart';
import 'chat_screen.dart';
import 'chats_list_screen.dart';
import 'qr_scanner_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final String currentUserId;
  const HomeScreen({super.key, required this.currentUserId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _peerIdController = TextEditingController();
  StreamSubscription? _pairSubscription;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    _listenForPairingRequests();
  }

  @override
  void dispose() {
    _pairSubscription?.cancel();
    _peerIdController.dispose();
    super.dispose();
  }

  void _listenForPairingRequests() {
    _pairSubscription = WebSocketService().messageStream.listen((data) async {
      if (!mounted) return;
      final msgType = data['type'];

      if (msgType == 'pair_request') {
        _showPairingDialogWithData(data);
      } else if (msgType == 'pair_accept') {
        final senderId = data['sender_id'];
        // verify + derive session key
        final ok = await PairingService().handlePairAccept(data, expectedRecipientId: widget.currentUserId);
        if (ok) {
          DatabaseHelper.instance
              .saveContact(senderId, 'طرف مقترن', 'connected');
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('تم قبول طلب الاقتران بواسطة: $senderId')),
          );
          final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
          if (isCurrent) {
            _openChat(senderId);
          }
        }
      }
    });
  }

  void _showPairingDialogWithData(Map<String, dynamic> data) async {
    final senderId = data['sender_id'] as String;
    // verify signature and save peer public keys to secure storage
    try {
      final peerEd = data['ed25519'] as String?;
      final peerX = data['x25519'] as String?;
      final sig = data['signature'] as String?;
      if (peerEd != null) {
        await StorageService().saveEdPublicKey(senderId, peerEd);
      }
      if (peerX != null) {
        await StorageService().saveXPublicKey(senderId, peerX);
      }

      // verify signature if present
      if (sig != null && peerEd != null) {
        final payload = jsonEncode(PairingService.canonicalPayload(
          type: 'pair_request',
          senderId: senderId,
          recipientId: data['recipient_id'] as String,
          x25519: peerX ?? '',
          ed25519: peerEd,
          requestId: data['request_id'] as String?,
          challenge: data['challenge'] as String?,
          expiresAt: data['expires_at'] as int?,
        ));
        final ok = await PairingService().verify(
            utf8.encode(payload), base64.decode(sig), base64.decode(peerEd));
        if (!ok) {
          // signature failed - ignore pairing
          return;
        }
      }
    } catch (_) {}

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('طلب اقتران جديد'),
        content: Text('يرغب الجهاز ($senderId) بإنشاء قناة محادثة مشفرة معك.'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              WebSocketService().sendData({
                'type': 'pair_reject',
                'sender_id': widget.currentUserId,
                'recipient_id': senderId,
              });
            },
            child: const Text('رفض', style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () async {
              Navigator.pop(context);
              // Ensure local identity keys exist, derive session key, and reply with our public keys + signature
              await PairingService().ensureIdentityKeys(widget.currentUserId);
              final peerX = await StorageService().getXPublicKey(senderId);
              if (peerX != null) {
                await PairingService().deriveAndStoreSessionKey(
                    myUserId: widget.currentUserId,
                    peerId: senderId,
                    peerXPublicBytes: base64Decode(peerX));
              }

              await DatabaseHelper.instance
                  .saveContact(senderId, 'طرف مقترن', 'connected');

              // Send pair_accept including our public keys and signature
              final pubs = await PairingService()
                  .getLocalPublicKeys(widget.currentUserId);
              final payload = PairingService.canonicalPayload(
                type: 'pair_accept',
                senderId: widget.currentUserId,
                recipientId: senderId,
                x25519: pubs['x25519']!,
                ed25519: pubs['ed25519']!,
                requestId: data['request_id'] as String?,
                challenge: data['challenge'] as String?,
                expiresAt: data['expires_at'] as int?,
              );
              final sig = await PairingService()
                  .sign(widget.currentUserId, utf8.encode(jsonEncode(payload)));
              WebSocketService().sendData({...payload, 'signature': base64Encode(sig)});

              _openChat(senderId);
            },
            child: const Text('قبول وتواصل',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _sendPairingRequest(String targetId) {
    final cleanId = targetId.trim();
    if (cleanId.isEmpty || cleanId == widget.currentUserId) return;

    // Use PairingService to include public keys and signature
    PairingService()
        .sendPairRequest(myId: widget.currentUserId, targetId: cleanId);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تم إرسال طلب الاتصال إلى $cleanId...')),
    );
  }

  void _openChat(String recipientId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          currentUserId: widget.currentUserId,
          recipientId: recipientId,
        ),
      ),
    );
  }

  void _showMyQrCode() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('معرف الجهاز الخاص بك'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 200,
              height: 200,
              child: QrImageView(
                data: widget.currentUserId,
                version: QrVersions.auto,
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              widget.currentUserId,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إغلاق'),
          ),
        ],
      ),
    );
  }

  Widget _buildHomeTab() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          TextField(
            controller: _peerIdController,
            decoration: InputDecoration(
              labelText: 'أدخل معرّف الجهاز الآخر (WASL-XXXXXX)',
              suffixIcon: IconButton(
                icon: const Icon(Icons.send),
                onPressed: () => _sendPairingRequest(_peerIdController.text),
              ),
              border: const OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = [
      _buildHomeTab(),
      ChatsListScreen(currentUserId: widget.currentUserId),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_currentIndex == 0 ? 'WASL E2EE' : 'المحادثات'),
        actions: _currentIndex == 0
            ? [
                IconButton(
                  icon: const Icon(Icons.qr_code),
                  onPressed: _showMyQrCode,
                  tooltip: 'عرض كود QR الخاص بي',
                ),
                IconButton(
                  icon: const Icon(Icons.settings),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const SettingsScreen(),
                      ),
                    );
                  },
                  tooltip: 'الإعدادات',
                ),
              ]
            : null,
      ),
      body: pages[_currentIndex],
      floatingActionButton: _currentIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        QrScannerScreen(currentUserId: widget.currentUserId),
                  ),
                );
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('مسح كود QR'),
            )
          : null,
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home),
            label: 'الرئيسية',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'المحادثات',
          ),
        ],
      ),
    );
  }
}
