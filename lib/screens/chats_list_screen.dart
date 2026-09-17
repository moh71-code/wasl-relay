import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/database/database_helper.dart';
import '../core/network/websocket_service.dart';
import '../core/crypto/pairing_service.dart';
import '../core/storage/storage_service.dart';
import 'dart:convert';
import '../core/crypto/crypto_engine.dart';
import 'package:cryptography/cryptography.dart';
import '../providers/settings_provider.dart';
import 'chat_screen.dart';
import 'login_screen.dart';
import 'settings_screen.dart';
import 'qr_scanner_screen.dart';

class ChatsListScreen extends StatefulWidget {
  final String currentUserId;

  const ChatsListScreen({super.key, required this.currentUserId});

  @override
  State<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends State<ChatsListScreen> {
  final WebSocketService _wsService = WebSocketService();
  List<Map<String, dynamic>> _contacts = [];
  bool _isLoading = true;
  String _connectionStatus = 'connected';
  StreamSubscription? _statusSub;
  StreamSubscription? _msgSub;

  @override
  void initState() {
    super.initState();
    _connectionStatus = _wsService.connectionState;
    _statusSub = _wsService.statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });
    _initNetworkAndLoadContacts();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _msgSub?.cancel();
    super.dispose();
  }

  Future<void> _initNetworkAndLoadContacts() async {
    _msgSub = _wsService.messageStream.listen((data) async {
      final t = data['type'];
      if (t == 'message_received' ||
          t == 'new_message' ||
          t == 'chat_message' ||
          t == 'message' ||
          t == 'read_ack' ||
          t == 'delivery_ack' ||
          t == 'file_received') {
        await _loadContacts();
      } else if (t == 'pair_request') {
        final recipient = data['recipient_id'];
        if (recipient == widget.currentUserId) {
          await _handleIncomingPairingRequest(data);
        }
      } else if (t == 'pair_accept') {
        await _loadContacts();
      }
    });
    await _loadContacts();
  }

  String _getRecipientId(Map<String, dynamic> contact) {
    return (contact['id'] ??
            contact['recipient_id'] ??
            contact['contact_id'] ??
            contact['name'] ??
            '')
        .toString();
  }

  String _getDecryptedLastMessage(Map<String, dynamic> contact) {
    final display = contact['display_last_message'];
    if (display != null && display.toString().trim().isNotEmpty) {
      return display.toString();
    }

    final rawMessage = contact['last_message'];
    if (rawMessage == null || rawMessage.toString().trim().isEmpty) {
      return 'لا توجد رسائل بعد';
    }

    try {
      final parsed = jsonDecode(rawMessage.toString());
      final cipher = parsed['ciphertext'] as String?;
      final nonce = parsed['nonce'] as String?;
      final mac = parsed['mac'] as String?;
      if (cipher == null || nonce == null || mac == null) {
        return rawMessage.toString();
      }
      return 'رسالة مشفرة';
    } catch (_) {
      return rawMessage.toString();
    }
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);
    final contacts = await DatabaseHelper.instance
        .getContactsWithLatestMessages(widget.currentUserId);
    if (!mounted) return;

    // Attempt to decrypt last messages for each contact using stored session keys
    for (var c in contacts) {
      try {
        final raw = c['last_message'];
        if (raw != null && raw.toString().isNotEmpty) {
          final parsed = jsonDecode(raw.toString());
          final cipher = parsed['ciphertext'] as String?;
          final nonce = parsed['nonce'] as String?;
          final mac = parsed['mac'] as String?;
          if (cipher != null && nonce != null && mac != null) {
            final contactId = _getRecipientId(c);
            final sessionB64 = await StorageService()
                .getSessionKey(widget.currentUserId, contactId);
            if (sessionB64 != null) {
              final keyBytes = base64.decode(sessionB64);
              final secretKey = SecretKey(keyBytes);
              final engine = CryptoEngine();
              final clear = await engine.decryptMessage(
                cipherTextBase64: cipher,
                nonceBase64: nonce,
                macBase64: mac,
                sharedKey: secretKey,
              );
              c['display_last_message'] = clear;
            } else {
              c['display_last_message'] = 'رسالة مشفرة';
            }
          }
        }
      } catch (_) {
        // ignore and leave raw text
      }
    }

    setState(() {
      _contacts = contacts;
      _isLoading = false;
    });
  }

  Future<void> _handleIncomingPairingRequest(Map<String, dynamic> data) async {
    final senderId = data['sender_id'] as String;
    // attempt to store peer public keys and verify signature
    try {
      final peerEd = data['ed25519'] as String?;
      final peerX = data['x25519'] as String?;
      final sig = data['signature'] as String?;
      if (peerEd != null) StorageService().saveEdPublicKey(senderId, peerEd);
      if (peerX != null) StorageService().saveXPublicKey(senderId, peerX);
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
        // ignore verification failure silently
        await PairingService().verify(
            utf8.encode(payload), base64.decode(sig), base64.decode(peerEd));
      }
    } catch (_) {}

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('طلب ربط تشفيري وارد'),
        content: Text(
            'يرغب المستخدم ($senderId) بإنشاء قناة محادثة مشفرة مزدوجة معك.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('رفض'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () async {
              // store contact, ensure identity keys, derive session key if peer pubkey available
              await DatabaseHelper.instance
                  .saveContact(senderId, senderId, 'accepted');
              await PairingService().ensureIdentityKeys(widget.currentUserId);
              final peerX = await StorageService().getXPublicKey(senderId);
              if (peerX != null) {
                await PairingService().deriveAndStoreSessionKey(
                    myUserId: widget.currentUserId,
                    peerId: senderId,
                    peerXPublicBytes: base64Decode(peerX));
              }
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
              _wsService.sendData({...payload, 'signature': base64Encode(sig)});
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              _loadContacts();
            },
            child: const Text('موافقة وربط',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showAddContactDialog() {
    final TextEditingController idController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('إرسال طلب ربط جديد'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idController,
              decoration: const InputDecoration(
                labelText: 'المعرّف التشفيري للطرف الآخر',
                hintText: 'WASL-XXXX-XXXX',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('مسح الكود عبر الكاميرا'),
              onPressed: () async {
                await Navigator.push(
                  dialogContext,
                  MaterialPageRoute(
                      builder: (context) =>
                          QrScannerScreen(currentUserId: widget.currentUserId)),
                );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () async {
              final targetId = idController.text.trim();
              if (targetId.isNotEmpty) {
                await DatabaseHelper.instance
                    .saveContact(targetId, targetId, 'pending_approval');
                await PairingService().sendPairRequest(
                    myId: widget.currentUserId, targetId: targetId);
                if (!dialogContext.mounted) return;
                Navigator.pop(dialogContext);
                _loadContacts();
              }
            },
            child: const Text('إرسال الطلب',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr =
        Provider.of<SettingsProvider>(context).locale.languageCode == 'ar';

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(isAr ? 'تطبيق وصل (WASL)' : 'WASL Messenger',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _connectionStatus == 'connected'
                        ? Colors.greenAccent
                        : (_connectionStatus == 'connecting'
                            ? Colors.amberAccent
                            : Colors.redAccent),
                  ),
                ),
              ],
            ),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: widget.currentUserId));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Text(isAr
                          ? 'تم نسخ عنوانك التشفيري'
                          : 'Crypto ID copied')),
                );
              },
              child: Text(
                '${widget.currentUserId} (انقر للنسخ)',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ),
          ],
        ),
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: 'إظهار الـ QR الخاص بي',
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) =>
                    QrDisplayDialog(userId: widget.currentUserId),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const LoginScreen()),
              );
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _contacts.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.phonelink_lock,
                          size: 80, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        isAr
                            ? 'لا توجد اتصالات مشفرة حتى الآن'
                            : 'No encrypted connections yet',
                        style: TextStyle(fontSize: 18, color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      Text(isAr
                          ? 'اضغط على الزر بالأسفل وتبادل المعرّف للربط'
                          : 'Tap below to add contacts'),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _contacts.length,
                  separatorBuilder: (context, index) =>
                      const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final contact = _contacts[index];
                    final recipientId = _getRecipientId(contact);
                    final lastMessage = _getDecryptedLastMessage(contact);
                    final unreadCount = (contact['unread_count'] as int?) ?? 0;

                    return ListTile(
                      leading: const CircleAvatar(
                        backgroundColor: Colors.teal,
                        child: Icon(Icons.person, color: Colors.white),
                      ),
                      title: Text(
                        recipientId,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        lastMessage,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[700]),
                      ),
                      trailing: unreadCount > 0
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.teal,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '$unreadCount',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold),
                              ),
                            )
                          : const Icon(
                              Icons.chat_bubble_outline,
                              color: Colors.teal,
                            ),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => ChatScreen(
                              currentUserId: widget.currentUserId,
                              recipientId: recipientId,
                            ),
                          ),
                        ).then((_) => _loadContacts());
                      },
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.teal,
        onPressed: _showAddContactDialog,
        child: const Icon(Icons.person_add, color: Colors.white),
      ),
    );
  }
}
