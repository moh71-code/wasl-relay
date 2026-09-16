import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../core/audio/audio_recorder_service.dart';
import '../core/crypto/crypto_engine.dart';
import '../core/crypto/pairing_service.dart';
import '../core/database/database_helper.dart';
import '../core/network/file_transfer_service.dart';
import '../core/network/websocket_service.dart';
import '../core/storage/storage_service.dart';

class ChatScreen extends StatefulWidget {
  final String currentUserId;
  final String recipientId;

  const ChatScreen({
    super.key,
    required this.currentUserId,
    required this.recipientId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];

  int? _selectedTtlMs;
  String _selectedExpireTrigger = 'send'; // 'send' or 'read'

  StreamSubscription? _wsSubscription;
  StreamSubscription? _ftProgressSub;
  StreamSubscription? _statusSubscription;

  final AudioPlayer _audioPlayer = AudioPlayer();
  final Uuid _uuid = const Uuid();

  String _connectionStatus = 'connected';
  bool _sendReadReceipts = true;

  @override
  void initState() {
    super.initState();
    _initChat();
  }

  Future<void> _initChat() async {
    final storage = StorageService();
    final priv = await storage.getPrivacySettings();
    _sendReadReceipts = priv['sendReadReceipts'] as bool;
    _selectedTtlMs = priv['defaultEphemeralTtl'] as int?;
    _selectedExpireTrigger = priv['defaultEphemeralTrigger'] as String? ?? 'send';

    _connectionStatus = WebSocketService().connectionState;

    _statusSubscription = WebSocketService().statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });

    await _loadLocalHistory();

    // Mark unread messages as read and send read_ack to peer
    final readUuids = await DatabaseHelper.instance
        .markMessagesAsRead(widget.currentUserId, widget.recipientId);
    if (readUuids.isNotEmpty && _sendReadReceipts) {
      WebSocketService().sendReadAck(
        messageUuids: readUuids,
        senderId: widget.currentUserId,
        recipientId: widget.recipientId,
      );
    }

    _ftProgressSub = FileTransferService().progressStream.listen((ev) async {
      final fid = ev['file_id'] as String?;
      final progress = (ev['progress'] as num?)?.toDouble() ?? 0.0;
      final direction = ev['direction'] as String? ?? 'upload';
      if (fid == null) return;

      var changed = false;
      for (var m in _messages) {
        if ((m['file_path'] ?? '') == fid || (m['message_uuid'] ?? '') == fid) {
          m['transfer_progress'] = progress;
          m['transfer_status'] =
              direction == 'upload' ? 'sending' : 'receiving';
          changed = true;
        }
      }
      if (changed && mounted) setState(() {});
    });

    _wsSubscription = WebSocketService().messageStream.listen((data) async {
      if (!mounted) return;
      final type = data['type'];

      // 1. Incoming chat message
      if (type == 'chat_message' && data['sender_id'] == widget.recipientId) {
        final uuid = data['message_uuid'] as String? ?? _uuid.v4();
        try {
          final sessionB64 = await StorageService()
              .getSessionKey(widget.currentUserId, widget.recipientId);
          if (sessionB64 == null) throw Exception('No session key');
          final keyBytes = base64.decode(sessionB64);
          final secretKey = SecretKey(keyBytes);

          final cipher = data['ciphertext'] as String?;
          final nonce = data['nonce'] as String?;
          final mac = data['mac'] as String?;
          if (cipher == null || nonce == null || mac == null) {
            throw Exception('Malformed payload');
          }

          final engine = CryptoEngine();
          final clear = await engine.decryptMessage(
            cipherTextBase64: cipher,
            nonceBase64: nonce,
            macBase64: mac,
            sharedKey: secretKey,
          );

          final ttl = data['expires_duration_ms'] as int?;
          final trigger = data['expire_trigger'] as String? ?? 'send';
          final calculatedExp = trigger == 'send' && ttl != null
              ? DateTime.now().millisecondsSinceEpoch + ttl
              : (trigger == 'read' && ttl != null
                  ? DateTime.now().millisecondsSinceEpoch + ttl
                  : null);

          final newMsg = {
            'message_uuid': uuid,
            'sender_id': widget.recipientId,
            'recipient_id': widget.currentUserId,
            'content': clear,
            'type': 'text',
            'status': 'read',
            'is_read': 1,
            'expires_at': calculatedExp,
            'expires_duration_ms': ttl,
            'expire_trigger': trigger,
            'timestamp': data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
            'isMe': false,
          };

          await DatabaseHelper.instance.saveMessageAndUpdateContacts({
            ...newMsg,
            'content': jsonEncode({'ciphertext': cipher, 'nonce': nonce, 'mac': mac}),
            'is_incoming': true,
          });

          // Send delivery_ack
          WebSocketService().sendDeliveryAck(
            messageUuid: uuid,
            senderId: widget.currentUserId,
            recipientId: widget.recipientId,
          );

          // Send read_ack if receipts enabled
          if (_sendReadReceipts) {
            WebSocketService().sendReadAck(
              messageUuids: [uuid],
              senderId: widget.currentUserId,
              recipientId: widget.recipientId,
            );
          }

          setState(() {
            _messages.add(newMsg);
          });
          _scrollToBottom();
        } catch (e) {
          setState(() {
            _messages.add({
              'message_uuid': uuid,
              'sender_id': widget.recipientId,
              'recipient_id': widget.currentUserId,
              'content': 'تعذر فك تشفير هذه الرسالة',
              'type': 'text',
              'status': 'failed',
              'timestamp': data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
              'isMe': false,
            });
          });
        }
      }

      // 2. Incoming delivery_ack
      else if (type == 'delivery_ack' && data['sender_id'] == widget.recipientId) {
        final uuid = data['message_uuid'] as String?;
        if (uuid != null) {
          await DatabaseHelper.instance.updateMessageStatusByUuid(uuid, 'delivered');
          setState(() {
            for (var m in _messages) {
              if (m['message_uuid'] == uuid && m['status'] != 'read') {
                m['status'] = 'delivered';
              }
            }
          });
        }
      }

      // 3. Incoming read_ack
      else if (type == 'read_ack' && data['sender_id'] == widget.recipientId) {
        final uuids = (data['message_uuids'] as List?)?.cast<String>() ?? [];
        for (var u in uuids) {
          await DatabaseHelper.instance.updateMessageStatusByUuid(u, 'read');
        }
        setState(() {
          for (var m in _messages) {
            if (uuids.contains(m['message_uuid'])) {
              m['status'] = 'read';
            }
          }
        });
      }

      // 4. Incoming delete_message (Delete for everyone)
      else if (type == 'delete_message' && data['sender_id'] == widget.recipientId) {
        final uuid = data['message_uuid'] as String?;
        if (uuid != null) {
          await DatabaseHelper.instance.deleteMessageForEveryone(uuid);
          setState(() {
            for (var m in _messages) {
              if (m['message_uuid'] == uuid) {
                m['is_deleted_for_everyone'] = 1;
                m['content'] = '[تم حذف هذه الرسالة]';
              }
            }
          });
        }
      }
    });
  }

  Future<void> _loadLocalHistory() async {
    final history = await DatabaseHelper.instance.getMessagesBetween(
      widget.currentUserId,
      widget.recipientId,
    );

    final List<Map<String, dynamic>> msgs = [];
    for (var item in history) {
      final rawContent = item['content'] ?? '';
      String displayed = rawContent.toString();
      try {
        final parsed = jsonDecode(rawContent.toString());
        final cipher = parsed['ciphertext'] as String?;
        final nonce = parsed['nonce'] as String?;
        final mac = parsed['mac'] as String?;
        if (cipher != null && nonce != null && mac != null) {
          final sessionB64 = await StorageService()
              .getSessionKey(widget.currentUserId, widget.recipientId);
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
            displayed = clear;
          } else {
            displayed = 'رسالة مشفرة';
          }
        }
      } catch (_) {}

      msgs.add({
        'id': item['id'],
        'message_uuid': item['message_uuid'],
        'sender_id': item['sender_id'],
        'recipient_id': item['recipient_id'],
        'content': displayed,
        'type': item['type'] ?? 'text',
        'file_path': item['file_path'],
        'transfer_status': item['transfer_status'],
        'transfer_progress': item['transfer_progress'],
        'status': item['status'] ?? 'sent',
        'timestamp': item['timestamp'],
        'expires_at': item['expires_at'],
        'expires_duration_ms': item['expires_duration_ms'],
        'expire_trigger': item['expire_trigger'],
        'is_deleted_for_everyone': item['is_deleted_for_everyone'] ?? 0,
        'isMe': item['sender_id'] == widget.currentUserId,
      });
    }

    if (!mounted) return;
    setState(() {
      _messages.clear();
      _messages.addAll(msgs);
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    _ftProgressSub?.cancel();
    _statusSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageUuid = _uuid.v4();

    try {
      final storage = StorageService();
      var sessionB64 =
          await storage.getSessionKey(widget.currentUserId, widget.recipientId);

      if (sessionB64 == null) {
        final peerXb64 = await storage.getXPublicKey(widget.recipientId);
        if (peerXb64 != null) {
          try {
            final peerPub = base64.decode(peerXb64);
            await PairingService().deriveAndStoreSessionKey(
              myUserId: widget.currentUserId,
              peerId: widget.recipientId,
              peerXPublicBytes: peerPub,
            );
            sessionB64 = await storage.getSessionKey(
                widget.currentUserId, widget.recipientId);
          } catch (_) {}
        }
      }

      if (sessionB64 == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('مفتاح الجلسة المشفر مفقود. أرسل طلب اقتران أولاً.'),
          action: SnackBarAction(
            label: 'اقتران',
            onPressed: () {
              PairingService().sendPairRequest(
                myId: widget.currentUserId,
                targetId: widget.recipientId,
              );
            },
          ),
        ));
        return;
      }

      final keyBytes = base64.decode(sessionB64);
      final secretKey = SecretKey(keyBytes);

      final engine = CryptoEngine();
      final enc = await engine.encryptMessage(plainText: text, sharedKey: secretKey);

      int? expiresAt;
      if (_selectedTtlMs != null && _selectedExpireTrigger == 'send') {
        expiresAt = timestamp + _selectedTtlMs!;
      }

      final isOnline = WebSocketService().isConnected;
      final initialStatus = isOnline ? 'sent' : 'pending';

      final messageData = {
        'type': 'chat_message',
        'message_uuid': messageUuid,
        'sender_id': widget.currentUserId,
        'recipient_id': widget.recipientId,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
        'expires_duration_ms': _selectedTtlMs,
        'expire_trigger': _selectedExpireTrigger,
        'expires_at': expiresAt,
        'timestamp': timestamp,
      };

      if (isOnline) {
        WebSocketService().sendData(messageData);
      } else {
        // Enqueue with priority 1 (Text has highest priority)
        await DatabaseHelper.instance.enqueueOutbox(
          jsonEncode(messageData),
          messageUuid: messageUuid,
          priority: 1,
        );
      }

      final dbId = await DatabaseHelper.instance.saveMessageAndUpdateContacts({
        'message_uuid': messageUuid,
        'sender_id': widget.currentUserId,
        'recipient_id': widget.recipientId,
        'content': jsonEncode({
          'ciphertext': enc['ciphertext'],
          'nonce': enc['nonce'],
          'mac': enc['mac']
        }),
        'status': initialStatus,
        'expires_at': expiresAt,
        'expires_duration_ms': _selectedTtlMs,
        'expire_trigger': _selectedExpireTrigger,
        'timestamp': timestamp,
      });

      setState(() {
        _messages.add({
          'id': dbId,
          'message_uuid': messageUuid,
          'sender_id': widget.currentUserId,
          'recipient_id': widget.recipientId,
          'content': text,
          'type': 'text',
          'status': initialStatus,
          'timestamp': timestamp,
          'expires_at': expiresAt,
          'expires_duration_ms': _selectedTtlMs,
          'expire_trigger': _selectedExpireTrigger,
          'isMe': true,
        });
        _messageController.clear();
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر إرسال الرسالة: $e')));
    }
  }

  Future<void> _sendAttachment() async {
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    final file = result.single;
    final bytes = await file.readAsBytes();

    const maxFileBytes = 25 * 1024 * 1024;
    if (bytes.length > maxFileBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('حجم الملف أكبر من 25 ميجابايت')),
      );
      return;
    }

    try {
      final expiresAt = _selectedTtlMs != null && _selectedExpireTrigger == 'send'
          ? DateTime.now().millisecondsSinceEpoch + _selectedTtlMs!
          : null;

      final connected = WebSocketService().isConnected;
      final fileId = await FileTransferService().sendFile(
        myId: widget.currentUserId,
        recipientId: widget.recipientId,
        fileBytes: bytes,
        originalName: file.name,
        expiresAt: expiresAt,
      );

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dbId = await DatabaseHelper.instance.saveMessageAndUpdateContacts({
        'message_uuid': fileId,
        'sender_id': widget.currentUserId,
        'recipient_id': widget.recipientId,
        'content': '[file:${file.name}]',
        'type': 'file',
        'file_path': fileId,
        'status': connected ? 'sent' : 'pending',
        'transfer_status': connected ? 'sending' : 'pending',
        'transfer_progress': 0.0,
        'expires_at': expiresAt,
        'expires_duration_ms': _selectedTtlMs,
        'expire_trigger': _selectedExpireTrigger,
        'timestamp': timestamp,
      });

      setState(() {
        _messages.add({
          'id': dbId,
          'message_uuid': fileId,
          'sender_id': widget.currentUserId,
          'recipient_id': widget.recipientId,
          'content': '[file:${file.name}]',
          'type': 'file',
          'file_path': fileId,
          'status': connected ? 'sent' : 'pending',
          'timestamp': timestamp,
          'transfer_status': connected ? 'sending' : 'pending',
          'transfer_progress': 0.0,
          'expires_at': expiresAt,
          'isMe': true,
        });
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر إرسال الملف: $e')));
    }
  }

  Future<void> _startRecording() async {
    final ok = await AudioRecorderService().hasPermission();
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا يوجد إذن لتسجيل الصوت')));
      return;
    }
    await AudioRecorderService().startRecording();
  }

  Future<void> _stopRecordingAndSend() async {
    final bytes = await AudioRecorderService().stopRecording();
    if (bytes == null) return;

    const maxAudioBytes = 10 * 1024 * 1024;
    if (bytes.length > maxAudioBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('حجم المقطع الصوتي أكبر من 10 ميجابايت')));
      return;
    }

    try {
      final expiresAt = _selectedTtlMs != null && _selectedExpireTrigger == 'send'
          ? DateTime.now().millisecondsSinceEpoch + _selectedTtlMs!
          : null;
      final connected = WebSocketService().isConnected;
      final fileId = await FileTransferService().sendFile(
        myId: widget.currentUserId,
        recipientId: widget.recipientId,
        fileBytes: bytes,
        originalName: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
        expiresAt: expiresAt,
      );

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final dbId = await DatabaseHelper.instance.saveMessageAndUpdateContacts({
        'message_uuid': fileId,
        'sender_id': widget.currentUserId,
        'recipient_id': widget.recipientId,
        'content': '[audio]',
        'type': 'audio',
        'file_path': fileId,
        'status': connected ? 'sent' : 'pending',
        'transfer_status': connected ? 'sending' : 'pending',
        'transfer_progress': connected ? 1.0 : 0.0,
        'expires_at': expiresAt,
        'expires_duration_ms': _selectedTtlMs,
        'expire_trigger': _selectedExpireTrigger,
        'timestamp': timestamp,
      });

      setState(() {
        _messages.add({
          'id': dbId,
          'message_uuid': fileId,
          'sender_id': widget.currentUserId,
          'recipient_id': widget.recipientId,
          'content': '[audio]',
          'type': 'audio',
          'file_path': fileId,
          'status': connected ? 'sent' : 'pending',
          'timestamp': timestamp,
          'transfer_status': connected ? 'sent' : 'pending',
          'transfer_progress': connected ? 1.0 : 0.0,
          'expires_at': expiresAt,
          'isMe': true,
        });
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر إرسال المقطع الصوتي: $e')));
    }
  }

  Future<void> _playEncryptedAudio(String fileId, String senderId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final path = '${appDir.path}/$fileId';
      final metaPath = '$path.meta.json';
      final f = File(path);
      if (!await f.exists()) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('الملف غير موجود')));
        return;
      }
      final cipher = await f.readAsBytes();
      final metaStr = await File(metaPath).readAsString();
      final meta = jsonDecode(metaStr);
      final nonce = meta['nonce'] as String;
      final mac = meta['mac'] as String;

      final sessionB64 =
          await StorageService().getSessionKey(widget.currentUserId, senderId);
      if (sessionB64 == null) throw Exception('No session key');
      final keyBytes = base64.decode(sessionB64);
      final secretKey = SecretKey(keyBytes);

      final plain = await CryptoEngine().decryptBytes(
        cipherTextBase64: base64.encode(cipher),
        nonceBase64: nonce,
        macBase64: mac,
        sharedKey: secretKey,
      );

      await _audioPlayer.play(BytesSource(Uint8List.fromList(plain)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('تعذر تشغيل الصوت: $e')));
    }
  }

  void _showMessageOptions(Map<String, dynamic> msg, int index) {
    final isMe = msg['isMe'] == true;
    final isDeleted = (msg['is_deleted_for_everyone'] ?? 0) == 1;
    final messageUuid = msg['message_uuid'] as String?;
    final msgId = msg['id'] as int?;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!isDeleted)
                ListTile(
                  leading: const Icon(Icons.copy, color: Colors.teal),
                  title: const Text('نسخ محتوى الرسالة'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: msg['content'] ?? ''));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('تم نسخ النص')),
                    );
                  },
                ),
              if (isMe && !isDeleted && messageUuid != null)
                ListTile(
                  leading: const Icon(Icons.delete_sweep, color: Colors.red),
                  title: const Text('حذف للجميع (Delete for Everyone)'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('تأكيد الحذف للجميع'),
                        content: const Text(
                            'سيتم حذف هذه الرسالة ومرفقاتها نهائياً من جهازك وجهاز الطرف الآخر.'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('إلغاء'),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('حذف للجميع',
                                style: TextStyle(color: Colors.white)),
                          ),
                        ],
                      ),
                    );

                    if (confirm == true) {
                      await DatabaseHelper.instance
                          .deleteMessageForEveryone(messageUuid);
                      WebSocketService().sendDeleteMessage(
                        messageUuid: messageUuid,
                        senderId: widget.currentUserId,
                        recipientId: widget.recipientId,
                      );
                      setState(() {
                        msg['is_deleted_for_everyone'] = 1;
                        msg['content'] = '[تم حذف هذه الرسالة]';
                      });
                    }
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('حذف لدي فقط (Delete for Me)'),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (msgId != null) {
                    await DatabaseHelper.instance.deleteMessageLocally(msgId);
                  }
                  setState(() {
                    _messages.removeAt(index);
                  });
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showEphemeralSettingsDialog() {
    int? tempTtl = _selectedTtlMs;
    String tempTrigger = _selectedExpireTrigger;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            return AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.timer_outlined, color: Colors.teal),
                  SizedBox(width: 8),
                  Text('الرسائل ذاتية الاختفاء'),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('مدة بقاء الرسالة:',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('إيقاف'),
                        selected: tempTtl == null,
                        onSelected: (_) => setDlgState(() => tempTtl = null),
                      ),
                      ChoiceChip(
                        label: const Text('1 ساعة'),
                        selected: tempTtl == 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 60 * 60 * 1000),
                      ),
                      ChoiceChip(
                        label: const Text('12 ساعة'),
                        selected: tempTtl == 12 * 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 12 * 60 * 60 * 1000),
                      ),
                      ChoiceChip(
                        label: const Text('24 ساعة'),
                        selected: tempTtl == 24 * 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 24 * 60 * 60 * 1000),
                      ),
                      ChoiceChip(
                        label: const Text('7 أيام'),
                        selected: tempTtl == 7 * 24 * 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 7 * 24 * 60 * 60 * 1000),
                      ),
                    ],
                  ),
                  if (tempTtl != null) ...[
                    const Divider(height: 24),
                    const Text('بدء احتساب المدة من:',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('وقت إرسال الرسالة'),
                      value: 'send',
                      groupValue: tempTrigger,
                      onChanged: (val) =>
                          setDlgState(() => tempTrigger = val ?? 'send'),
                    ),
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('وقت قراءة الطرف الآخر لها'),
                      value: 'read',
                      groupValue: tempTrigger,
                      onChanged: (val) =>
                          setDlgState(() => tempTrigger = val ?? 'read'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                  onPressed: () {
                    setState(() {
                      _selectedTtlMs = tempTtl;
                      _selectedExpireTrigger = tempTrigger;
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('حفظ', style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildStatusTicks(Map<String, dynamic> msg) {
    final status = msg['status']?.toString() ?? 'sent';
    if (status == 'pending' || status == 'sending') {
      return const Icon(Icons.access_time, size: 12, color: Colors.white70);
    } else if (status == 'sent') {
      return const Icon(Icons.check, size: 14, color: Colors.white70);
    } else if (status == 'delivered') {
      return const Icon(Icons.done_all, size: 14, color: Colors.white70);
    } else if (status == 'read') {
      return const Icon(Icons.done_all, size: 14, color: Colors.cyanAccent);
    } else {
      return const Icon(Icons.error_outline, size: 12, color: Colors.redAccent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = _connectionStatus == 'connected';

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.lock, size: 18, color: Colors.greenAccent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'محادثة مشفرة: ${widget.recipientId}',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.timer_outlined,
              color: _selectedTtlMs != null ? Colors.amberAccent : Colors.white,
            ),
            tooltip: 'إعدادات الرسائل ذاتية الاختفاء',
            onPressed: _showEphemeralSettingsDialog,
          ),
        ],
        backgroundColor: Colors.teal,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          if (!isOnline)
            Container(
              width: double.infinity,
              color: Colors.amber[800],
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _connectionStatus == 'connecting'
                        ? 'جارٍ الاتصال بالخادم الترحيلي...'
                        : 'غير متصل (الرسائل ستُحفظ في Outbox للإرسال لاحقاً)',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(12),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final msg = _messages[index];
                final isMe = msg['isMe'] == true;
                final isDeleted = (msg['is_deleted_for_everyone'] ?? 0) == 1;

                return Align(
                  alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                  child: GestureDetector(
                    onLongPress: () => _showMessageOptions(msg, index),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.78,
                      ),
                      decoration: BoxDecoration(
                        color: isDeleted
                            ? Colors.grey[800]
                            : (isMe ? Colors.teal[700] : Colors.grey[850]),
                        borderRadius: BorderRadius.circular(12),
                        border: isDeleted
                            ? Border.all(color: Colors.white24, style: BorderStyle.solid)
                            : null,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: () {
                              final type = msg['type']?.toString() ?? 'text';
                              if ((type == 'audio' || type == 'file') &&
                                  msg['file_path'] != null) {
                                _playEncryptedAudio(
                                  msg['file_path'].toString(),
                                  msg['sender_id'].toString(),
                                );
                              }
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    msg['content'] ?? '',
                                    style: TextStyle(
                                      color: isDeleted ? Colors.white54 : Colors.white,
                                      fontSize: 15,
                                      fontStyle: isDeleted
                                          ? FontStyle.italic
                                          : FontStyle.normal,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if ((msg['transfer_progress'] ?? 1.0) < 1.0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6.0),
                              child: LinearProgressIndicator(
                                value: (msg['transfer_progress'] as double?) ?? 0.0,
                                backgroundColor: Colors.grey[700],
                                color: Colors.cyanAccent,
                                minHeight: 3,
                              ),
                            ),
                          const SizedBox(height: 4),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (msg['expires_at'] != null) ...[
                                const Icon(Icons.timer, size: 11, color: Colors.amberAccent),
                                const SizedBox(width: 4),
                              ],
                              if (isMe) ...[
                                _buildStatusTicks(msg),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
            color: Theme.of(context).scaffoldBackgroundColor,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    onSubmitted: (_) => _sendMessage(),
                    decoration: InputDecoration(
                      hintText: 'اكتب رسالتك المشفرة E2EE...',
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.attach_file, color: Colors.teal),
                  onPressed: _sendAttachment,
                  tooltip: 'إرفاق ملف',
                ),
                GestureDetector(
                  onLongPressStart: (_) => _startRecording(),
                  onLongPressEnd: (_) => _stopRecordingAndSend(),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6.0),
                    child: Icon(Icons.mic, color: Colors.teal, size: 28),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Colors.teal),
                  onPressed: _sendMessage,
                  tooltip: 'إرسال',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
