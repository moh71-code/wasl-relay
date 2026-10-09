import 'dart:async';
import '../core/l10n/s.dart';
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
import '../core/media/media_kind.dart';
import '../core/theme/wasl_theme.dart';
import '../core/theme/wasl_widgets.dart';

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
  bool _peerOnline = false;
  bool _sendReadReceipts = true;
  String _peerDisplayName = '';
  bool _isRecording = false;

  // Typing indicator state
  bool _peerTyping = false;
  Timer? _peerTypingTimer;
  DateTime _lastTypingSentAt =
      DateTime.fromMillisecondsSinceEpoch(0);
  bool _typingSent = false;

  // Real peer presence — polled from the relay, never inferred locally.
  Timer? _presenceTimer;

  // Reply / edit / multi-select state
  Map<String, dynamic>? _replyTo;
  Map<String, dynamic>? _editingMsg;
  bool _selectionMode = false;
  final Set<String> _selectedUuids = {};

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

    // Per-chat override wins over the global default — a non-null trigger
    // means the user explicitly configured THIS chat (even as "off").
    final chatEph =
        await DatabaseHelper.instance.getChatEphemeral(widget.recipientId);
    if (chatEph != null) {
      _selectedTtlMs = (chatEph['ephemeral_ttl_ms'] as num?)?.toInt();
      _selectedExpireTrigger =
          chatEph['ephemeral_trigger']?.toString() ?? 'send';
    }

    _connectionStatus = WebSocketService().connectionState;

    _statusSubscription = WebSocketService().statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
      if (status == 'connected') {
        _queryPeerPresence();
      } else {
        _presenceTimer?.cancel();
        _presenceTimer = null;
      }
    });

    // If already authenticated, ask the relay once immediately.
    if (_connectionStatus == 'connected') {
      _queryPeerPresence();
    }

    await _loadLocalHistory();

    // Resolve the peer's saved display name for the app bar
    try {
      final contacts = await DatabaseHelper.instance.getContacts();
      final peerUpper = widget.recipientId.trim().toUpperCase();
      for (final c in contacts) {
        if ((c['id'] as String?)?.trim().toUpperCase() == peerUpper) {
          final n = (c['name'] as String?)?.trim();
          if (n != null && n.isNotEmpty && n.toUpperCase() != peerUpper) {
            if (mounted) setState(() => _peerDisplayName = n);
          }
          break;
        }
      }
    } catch (_) {}

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
          var clear = await engine.decryptMessage(
            cipherTextBase64: cipher,
            nonceBase64: nonce,
            macBase64: mac,
            sharedKey: secretKey,
          );

          // v2 envelope: carries reply/edit/reaction metadata inside the
          // ciphertext so the relay never sees plaintext metadata.
          String? replyUuid;
          String? replyText;
          try {
            final env = jsonDecode(clear);
            if (env is Map) {
            if (env['edit'] != null) {
              final targetUuid = env['edit']?.toString();
              final newText = env['t']?.toString() ?? '';
              if (targetUuid != null) {
                await DatabaseHelper.instance.updateMessageContent(
                  targetUuid,
                  jsonEncode(
                      {'ciphertext': cipher, 'nonce': nonce, 'mac': mac}),
                );
                setState(() {
                  for (var m in _messages) {
                    if (m['message_uuid'] == targetUuid) {
                      m['content'] = newText;
                      m['is_edited'] = 1;
                    }
                  }
                });
              }
              return;
            }
            if (env['react'] != null) {
              final targetUuid = env['react']?.toString();
              final emoji = env['e']?.toString();
              if (targetUuid != null) {
                await DatabaseHelper.instance
                    .updateMessageReaction(targetUuid, emoji);
                setState(() {
                  for (var m in _messages) {
                    if (m['message_uuid'] == targetUuid) {
                      m['reaction'] = emoji;
                    }
                  }
                });
              }
              return;
            }
            replyUuid = env['ru']?.toString();
            replyText = env['rt']?.toString();
            clear = env['t']?.toString() ?? clear;
            }
          } catch (_) {
            // Not a v2 envelope — treat decrypted payload as plain text.
          }

          final ttl = (data['expires_duration_ms'] as num?)?.toInt();
          final trigger = data['expire_trigger'] as String? ?? 'send';
          // This handler only runs while the chat is OPEN — the message is
          // being read right now, so both triggers arm immediately.
          final calculatedExp = ttl != null
              ? DateTime.now().millisecondsSinceEpoch + ttl
              : null;

          final newMsg = {
            'message_uuid': uuid,
            'sender_id': widget.recipientId,
            'recipient_id': widget.currentUserId,
            'content': clear,
            'type': WaslMedia.typeFromContent('text', clear),
            'status': 'read',
            'is_read': 1,
            'expires_at': calculatedExp,
            'expires_duration_ms': ttl,
            'expire_trigger': trigger,
            'reply_to_uuid': replyUuid,
            'reply_to_text': replyText,
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
              'content': S.decryptFailed,
              'type': 'text',
              'status': 'failed',
              'timestamp': data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
              'isMe': false,
            });
          });
        }
      }

      // 1b. Local edit/reaction events emitted by the ingestion service
      else if (type == 'edit_local' &&
          data['sender_id'] == widget.recipientId) {
        final uuid = data['message_uuid']?.toString();
        setState(() {
          for (var m in _messages) {
            if (m['message_uuid'] == uuid) m['is_edited'] = 1;
          }
        });
      } else if (type == 'reaction_local' &&
          data['sender_id'] == widget.recipientId) {
        final uuid = data['message_uuid']?.toString();
        setState(() {
          for (var m in _messages) {
            if (m['message_uuid'] == uuid) m['reaction'] = data['emoji'];
          }
        });
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
        // Arm read-triggered ephemeral timers on our sent copies now that
        // the peer has actually read them.
        await DatabaseHelper.instance.activateReadExpiry(uuids);
        setState(() {
          for (var m in _messages) {
            if (uuids.contains(m['message_uuid'])) {
              m['status'] = 'read';
            }
          }
        });
      }

      // 4. Incoming completed file/audio transfer
      else if (type == 'file_received' &&
          data['sender_id'] == widget.recipientId) {
        final uuid = data['message_uuid'] as String?;
        if (uuid != null &&
            !_messages.any((m) => m['message_uuid'] == uuid)) {
          setState(() {
            _messages.add({
              'message_uuid': uuid,
              'sender_id': widget.recipientId,
              'recipient_id': widget.currentUserId,
              'content': data['content']?.toString() ?? '',
              'type': data['message_type']?.toString() ?? 'file',
              'file_path': data['file_path'],
              'transfer_status': 'received',
              'transfer_progress': 1.0,
              'status': 'read',
              'is_read': 1,
              'timestamp': DateTime.now().millisecondsSinceEpoch,
              'isMe': false,
            });
          });
          _scrollToBottom();
        } else if (uuid != null) {
          setState(() {
            for (var m in _messages) {
              if (m['message_uuid'] == uuid) {
                m['file_path'] = data['file_path'];
                m['transfer_status'] = 'received';
                m['transfer_progress'] = 1.0;
              }
            }
          });
        }
      }

      // 4b. Ephemeral cleanup deleted rows — drop them from the open view.
      else if (type == 'messages_expired') {
        final uuids =
            (data['uuids'] as List?)?.map((e) => e.toString()).toSet() ??
                const <String>{};
        if (uuids.isNotEmpty) {
          setState(() {
            _messages.removeWhere(
                (m) => uuids.contains(m['message_uuid']?.toString()));
          });
        }
      }

      // 5. Authenticated relay presence result for this peer
      else if (type == 'presence_info' &&
          data['recipient_id']?.toString().trim().toUpperCase() ==
              widget.recipientId.trim().toUpperCase()) {
        final online = data['online'] == true;
        setState(() => _peerOnline = online);
      }

      // 5. Typing indicator from peer
      else if (type == 'typing' && data['sender_id'] == widget.recipientId) {
        final isTyping = data['is_typing'] == true;
        _peerTypingTimer?.cancel();
        if (isTyping) {
          setState(() => _peerTyping = true);
          // Safety auto-hide if the peer's "stopped typing" frame is lost
          _peerTypingTimer = Timer(const Duration(seconds: 6), () {
            if (mounted) setState(() => _peerTyping = false);
          });
        } else if (_peerTyping) {
          setState(() => _peerTyping = false);
        }
      }

      // 6. Incoming delete_message (Delete for everyone)
      else if (type == 'delete_message' && data['sender_id'] == widget.recipientId) {
        final uuid = data['message_uuid'] as String?;
        if (uuid != null) {
          await DatabaseHelper.instance.deleteMessageForEveryone(uuid);
          setState(() {
            for (var m in _messages) {
              if (m['message_uuid'] == uuid) {
                m['is_deleted_for_everyone'] = 1;
                m['content'] = S.deletedMessage;
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
            // Unwrap v2 envelopes (edit/reply metadata) for display.
            try {
              final env = jsonDecode(clear);
              if (env is Map && env['t'] != null) {
                displayed = env['t'].toString();
              } else {
                displayed = clear;
              }
            } catch (_) {
              displayed = clear;
            }
          } else {
            displayed = S.encryptedMessage;
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
        'reaction': item['reaction'],
        'reply_to_uuid': item['reply_to_uuid'],
        'reply_to_text': item['reply_to_text'],
        'is_edited': item['is_edited'] ?? 0,
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
        // reverse:true → offset 0 is the newest message (visual bottom).
        _scrollController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    // Clear the unread badge for this chat when leaving, since messages that
    // arrived while the screen was open were already seen by the user.
    DatabaseHelper.instance
        .markMessagesAsRead(widget.currentUserId, widget.recipientId)
        .catchError((_) => <String>[]);
    _wsSubscription?.cancel();
    _ftProgressSub?.cancel();
    _statusSubscription?.cancel();
    _peerTypingTimer?.cancel();
    _presenceTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  void _queryPeerPresence() {
    if (!WebSocketService().isConnected) return;
    WebSocketService().sendPresenceQuery(
      recipientId: widget.recipientId,
      requestId: DateTime.now().millisecondsSinceEpoch.toString(),
    );
    _presenceTimer?.cancel();
    _presenceTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && WebSocketService().isConnected) {
        _queryPeerPresence();
      }
    });
  }

  /// Typing indicator: tiny unencrypted control frame (metadata only — no
  /// content), throttled so it never floods the relay.
  void _handleTypingChanged(String text) {
    final typing = text.trim().isNotEmpty;
    final now = DateTime.now();
    if (typing) {
      if (!_typingSent ||
          now.difference(_lastTypingSentAt).inSeconds >= 3) {
        _sendTypingFrame(true);
        _typingSent = true;
        _lastTypingSentAt = now;
      }
    } else if (_typingSent) {
      _sendTypingFrame(false);
      _typingSent = false;
    }
  }

  void _sendTypingFrame(bool isTyping) {
    if (!WebSocketService().isConnected) return;
    WebSocketService().sendData({
      'type': 'typing',
      'sender_id': widget.currentUserId,
      'recipient_id': widget.recipientId,
      'is_typing': isTyping,
    });
  }

  /// Short text used inside the reply quote block (and stored as
  /// reply_to_text). Never leaks — it travels inside the encrypted envelope.
  String _previewOf(Map<String, dynamic> msg) {
    final type = msg['type']?.toString() ?? 'text';
    if (type == 'audio') return S.voiceMessage;
    if (type == 'image') return S.image;
    if (type == 'file') return S.attachedFile;
    final c = msg['content']?.toString() ?? '';
    return c.length > 80 ? '${c.substring(0, 80)}…' : c;
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    if (_editingMsg != null) {
      await _sendEdit(text);
      return;
    }
    if (_typingSent) {
      _sendTypingFrame(false);
      _typingSent = false;
    }

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
          content:       Text(S.sessionKeyMissing),
          action: SnackBarAction(
            label: S.pairing,
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

      // v2 envelope carries reply metadata inside the ciphertext
      final replying = _replyTo;
      final plain = replying != null
          ? jsonEncode({
              'v': 2,
              't': text,
              'ru': replying['message_uuid']?.toString(),
              'rt': _previewOf(replying),
            })
          : text;

      final engine = CryptoEngine();
      final enc =
          await engine.encryptMessage(plainText: plain, sharedKey: secretKey);

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

      // Always enqueue first — the outbox keeps the frame until the peer's
      // delivery_ack retires it (at-least-once delivery). When connected,
      // processOutbox relays it immediately.
      await DatabaseHelper.instance.enqueueOutbox(
        jsonEncode(messageData),
        messageUuid: messageUuid,
        priority: 1,
      );
      if (isOnline) {
        unawaited(DatabaseHelper.instance.processOutbox());
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
        'reply_to_uuid': replying?['message_uuid']?.toString(),
        'reply_to_text': replying != null ? _previewOf(replying) : null,
        'timestamp': timestamp,
      });

      setState(() {
        _replyTo = null;
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
          'reply_to_uuid': replying?['message_uuid']?.toString(),
          'reply_to_text': replying != null ? _previewOf(replying) : null,
          'isMe': true,
        });
        _messageController.clear();
      });
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.messageSendFailed(e))));
    }
  }

  /// Send a v2 edit envelope (encrypted) and update the local copy.
  Future<void> _sendEdit(String newText) async {
    final msg = _editingMsg!;
    final uuid = msg['message_uuid'] as String?;
    setState(() => _editingMsg = null);
    _messageController.clear();
    if (uuid == null) return;
    try {
      final sessionB64 = await StorageService()
          .getSessionKey(widget.currentUserId, widget.recipientId);
      if (sessionB64 == null) return;
      final secretKey = SecretKey(base64.decode(sessionB64));
      final enc = await CryptoEngine().encryptMessage(
        plainText: jsonEncode({'v': 2, 'edit': uuid, 't': newText}),
        sharedKey: secretKey,
      );
      final frame = {
        'type': 'chat_message',
        'message_uuid': _uuid.v4(),
        'sender_id': widget.currentUserId,
        'recipient_id': widget.recipientId,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await DatabaseHelper.instance.enqueueOutbox(
        jsonEncode(frame),
        messageUuid: frame['message_uuid'] as String,
        priority: 1,
      );
      if (WebSocketService().isConnected) {
        unawaited(DatabaseHelper.instance.processOutbox());
      }
      // Store the ciphertext envelope so history reload re-decrypts to the
      // edited text, matching how outgoing messages are persisted.
      await DatabaseHelper.instance.updateMessageContent(
        uuid,
        jsonEncode({
          'ciphertext': enc['ciphertext'],
          'nonce': enc['nonce'],
          'mac': enc['mac'],
        }),
      );
      setState(() {
        for (var m in _messages) {
          if (m['message_uuid'] == uuid) {
            m['content'] = newText;
            m['is_edited'] = 1;
          }
        }
      });
    } catch (_) {}
  }

  /// Send a v2 reaction envelope (encrypted) and update the local bubble.
  Future<void> _sendReaction(Map<String, dynamic> msg, String emoji) async {
    final uuid = msg['message_uuid'] as String?;
    if (uuid == null) return;
    final newEmoji = msg['reaction'] == emoji ? null : emoji;
    try {
      final sessionB64 = await StorageService()
          .getSessionKey(widget.currentUserId, widget.recipientId);
      if (sessionB64 == null) return;
      final secretKey = SecretKey(base64.decode(sessionB64));
      final enc = await CryptoEngine().encryptMessage(
        plainText: jsonEncode({'v': 2, 'react': uuid, 'e': newEmoji}),
        sharedKey: secretKey,
      );
      final frame = {
        'type': 'chat_message',
        'message_uuid': _uuid.v4(),
        'sender_id': widget.currentUserId,
        'recipient_id': widget.recipientId,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      await DatabaseHelper.instance.enqueueOutbox(
        jsonEncode(frame),
        messageUuid: frame['message_uuid'] as String,
        priority: 1,
      );
      if (WebSocketService().isConnected) {
        unawaited(DatabaseHelper.instance.processOutbox());
      }
      await DatabaseHelper.instance.updateMessageReaction(uuid, newEmoji);
      setState(() => msg['reaction'] = newEmoji);
    } catch (_) {}
  }

  /// Re-send a message whose delivery stalled (pending/failed). Rebuilds the
  /// frame with the SAME message_uuid (dedup-safe) and a fresh ciphertext.
  Future<void> _resendMessage(Map<String, dynamic> msg) async {
    final uuid = msg['message_uuid'] as String?;
    if (uuid == null) return;
    try {
      final sessionB64 = await StorageService()
          .getSessionKey(widget.currentUserId, widget.recipientId);
      if (sessionB64 == null) return;
      final secretKey = SecretKey(base64.decode(sessionB64));

      // Re-wrap in the v2 envelope when the message was a reply.
      final replyUuid = msg['reply_to_uuid']?.toString();
      final replyText = msg['reply_to_text']?.toString();
      final text = msg['content']?.toString() ?? '';
      final plain = replyUuid != null
          ? jsonEncode({
              'v': 2,
              't': text,
              'ru': replyUuid,
              'rt': replyText,
            })
          : text;

      final enc = await CryptoEngine()
          .encryptMessage(plainText: plain, sharedKey: secretKey);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final frame = {
        'type': 'chat_message',
        'message_uuid': uuid,
        'sender_id': widget.currentUserId,
        'recipient_id': widget.recipientId,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
        'expires_duration_ms': msg['expires_duration_ms'],
        'expire_trigger': msg['expire_trigger'],
        'expires_at': msg['expires_at'],
        'timestamp': timestamp,
      };
      final isOnline = WebSocketService().isConnected;
      final newStatus = isOnline ? 'sent' : 'pending';
      await DatabaseHelper.instance.enqueueOutbox(
        jsonEncode(frame),
        messageUuid: uuid,
        priority: 1,
      );
      if (isOnline) {
        unawaited(DatabaseHelper.instance.processOutbox());
      }
      await DatabaseHelper.instance.updateMessageStatusByUuid(uuid, newStatus);
      setState(() {
        msg['status'] = newStatus;
        msg['timestamp'] = timestamp;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.resendDone)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.resendFailed)));
    }
  }

  Future<void> _sendAttachment() async {
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    final file = result.single;
    final bytes = await file.readAsBytes();

    const maxFileBytes = 100 * 1024 * 1024;
    if (bytes.length > maxFileBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(S.fileTooLarge)),
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
        expiresDurationMs: _selectedTtlMs,
        expireTrigger: _selectedExpireTrigger,
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
          .showSnackBar(SnackBar(content: Text(S.fileSendFailed(e))));
    }
  }

  Future<void> _startRecording() async {
    final ok = await AudioRecorderService().hasPermission();
    if (!ok) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(S.noMicPermission)));
      return;
    }
    await AudioRecorderService().startRecording();
    if (mounted) setState(() => _isRecording = true);
  }

  Future<void> _stopRecordingAndSend() async {
    if (mounted) setState(() => _isRecording = false);
    final bytes = await AudioRecorderService().stopRecording();
    if (bytes == null || bytes.isEmpty) return;

    const maxAudioBytes = 10 * 1024 * 1024;
    if (bytes.length > maxAudioBytes) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(      SnackBar(
          content: Text(S.audioTooLarge)));
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
        expiresDurationMs: _selectedTtlMs,
        expireTrigger: _selectedExpireTrigger,
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
          SnackBar(content: Text(S.audioSendFailed(e))));
    }
  }

  /// Resolves a stored file reference to an on-disk path. Older rows store the
  /// bare fileId while newer ones store the full `<dir>/<fileId>_<name>` path.
  Future<String?> _resolveMediaPath(String fileRef) async {
    final direct = File(fileRef);
    if (await direct.exists()) return fileRef;
    final appDir = await getApplicationDocumentsDirectory();
    final byId = File('${appDir.path}/$fileRef');
    if (await byId.exists()) return byId.path;
    try {
      final sep = Platform.pathSeparator;
      for (final e in appDir.listSync()) {
        final base = e.path.split(sep).last;
        if (base.startsWith('${fileRef}_') &&
            !base.endsWith('.meta.json')) {
          return e.path;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Decrypts a stored media file (audio/image/file) to plaintext bytes using
  /// the peer session key. Returns null on any failure.
  Future<Uint8List?> _decryptMediaBytes(String fileRef) async {
    try {
      final path = await _resolveMediaPath(fileRef);
      if (path == null) return null;
      final metaStr = await File('$path.meta.json').readAsString();
      final meta = jsonDecode(metaStr);
      final cipher = await File(path).readAsBytes();

      // In a 1:1 chat the session key is always keyed by the peer id.
      final sessionB64 = await StorageService()
          .getSessionKey(widget.currentUserId, widget.recipientId);
      if (sessionB64 == null) return null;
      final secretKey = SecretKey(base64.decode(sessionB64));

      final plain = await CryptoEngine().decryptBytes(
        cipherTextBase64: base64.encode(cipher),
        nonceBase64: meta['nonce'] as String,
        macBase64: meta['mac'] as String,
        sharedKey: secretKey,
      );
      return Uint8List.fromList(plain);
    } catch (_) {
      return null;
    }
  }

  Future<void> _playEncryptedAudio(String fileRef) async {
    final plain = await _decryptMediaBytes(fileRef);
    if (!mounted) return;
    if (plain == null) {
      ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(S.audioPlayMissing)));
      return;
    }
    try {
      await _audioPlayer.play(BytesSource(plain));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(S.audioPlayError(e))));
    }
  }

  /// Decrypts media in memory then streams it to ANY destination the user
  /// picks via SAF — USB OTG flash, SD card, Downloads, cloud providers —
  /// without leaving a plaintext copy in app storage. No permission needed.
  Future<void> _exportMediaFile(String fileRef, String fileName) async {
    final plain = await _decryptMediaBytes(fileRef);
    if (!mounted) return;
    if (plain == null) {
      ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(S.decryptFileFailed)));
      return;
    }
    try {
      final saved = await FilePicker.saveFile(
        dialogTitle: S.saveToExternal,
        fileName: fileName.isEmpty ? 'wasl_file' : fileName,
        bytes: plain,
      );
      if (!mounted || saved == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(S.fileSaved)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(S.fileExportFailed)));
    }
  }

  static const List<String> _reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  void _toggleSelect(Map<String, dynamic> msg) {
    final uuid = msg['message_uuid']?.toString();
    if (uuid == null) return;
    setState(() {
      if (_selectedUuids.contains(uuid)) {
        _selectedUuids.remove(uuid);
        if (_selectedUuids.isEmpty) _selectionMode = false;
      } else {
        _selectedUuids.add(uuid);
      }
    });
  }

  void _enterSelection(Map<String, dynamic> msg) {
    setState(() {
      _selectionMode = true;
      final uuid = msg['message_uuid']?.toString();
      if (uuid != null) _selectedUuids.add(uuid);
    });
  }

  Future<void> _deleteSelected() async {
    final selected = _messages
        .where((m) => _selectedUuids.contains(m['message_uuid']?.toString()))
        .toList();
    for (final m in selected) {
      final id = m['id'] as int?;
      if (id != null) {
        await DatabaseHelper.instance.deleteMessageLocally(id);
      }
    }
    setState(() {
      _messages.removeWhere(
          (m) => _selectedUuids.contains(m['message_uuid']?.toString()));
      _selectedUuids.clear();
      _selectionMode = false;
    });
  }

  void _showMessageInfo(Map<String, dynamic> msg) {
    final status = msg['status']?.toString() ?? 'sent';
    final statusText = status == 'read'
        ? S.statusRead
        : status == 'delivered'
            ? S.statusDelivered
            : status == 'sent'
                ? S.statusSent
                : S.statusPending;
    final type = msg['type']?.toString() ?? 'text';
    final typeText = type == 'audio'
        ? S.voiceMessage
        : type == 'image'
            ? S.image
            : type == 'file'
                ? S.attachedFile
                : S.textLabel;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(S.info),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _infoRow(S.typeLabel, typeText),
            _infoRow(S.statusLabel, statusText),
            _infoRow(S.timeLabel, _formatMessageTime(msg['timestamp'])),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(S.close),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text('$label: ',
              style: const TextStyle(fontWeight: FontWeight.bold)),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  void _showMessageOptions(Map<String, dynamic> msg, int index) {
    final isMe = msg['isMe'] == true;
    final isDeleted = (msg['is_deleted_for_everyone'] ?? 0) == 1;
    final isText = (msg['type']?.toString() ?? 'text') == 'text';
    final status = msg['status']?.toString() ?? '';
    final canResend = isMe && !isDeleted &&
        (status == 'pending' || status == 'failed');
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
              // Emoji reaction row
              if (!isDeleted && messageUuid != null)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (final e in _reactionEmojis)
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(ctx);
                            _sendReaction(msg, e);
                          },
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: msg['reaction'] == e
                                  ? WaslColors.primary.withValues(alpha: 0.18)
                                  : Colors.transparent,
                            ),
                            child: Text(e, style: const TextStyle(fontSize: 24)),
                          ),
                        ),
                    ],
                  ),
                ),
              if (!isDeleted && messageUuid != null) const Divider(height: 1),
              if (canResend)
                ListTile(
                  leading: const Icon(Icons.refresh_rounded,
                      color: Colors.orange),
                  title: Text(S.resend),
                  onTap: () {
                    Navigator.pop(ctx);
                    _resendMessage(msg);
                  },
                ),
              if (!isDeleted)
                ListTile(
                  leading: const Icon(Icons.reply_rounded,
                      color: WaslColors.primary),
                  title: Text(S.reply),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _editingMsg = null;
                      _replyTo = msg;
                    });
                  },
                ),
              if (isMe && !isDeleted && isText && messageUuid != null)
                ListTile(
                  leading: const Icon(Icons.edit_outlined,
                      color: WaslColors.primary),
                  title: Text(S.edit),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _replyTo = null;
                      _editingMsg = msg;
                      _messageController.text =
                          msg['content']?.toString() ?? '';
                    });
                  },
                ),
              if (!isDeleted)
                ListTile(
                  leading: const Icon(Icons.copy, color: Colors.teal),
                  title:       Text(S.copyContent),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: msg['content'] ?? ''));
                    ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(S.copied)),
                    );
                  },
                ),
              if (!isDeleted && !isText &&
                  (msg['file_path']?.toString().isNotEmpty ?? false))
                ListTile(
                  leading: const Icon(Icons.save_alt_rounded,
                      color: WaslColors.primary),
                  title: Text(S.saveToExternal),
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportMediaFile(
                      msg['file_path'].toString(),
                      WaslMedia.displayName(
                          msg['content']?.toString() ?? ''),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline,
                    color: WaslColors.primary),
                title: Text(S.info),
                onTap: () {
                  Navigator.pop(ctx);
                  _showMessageInfo(msg);
                },
              ),
              ListTile(
                leading: const Icon(Icons.check_circle_outline,
                    color: WaslColors.primary),
                title: Text(S.select),
                onTap: () {
                  Navigator.pop(ctx);
                  _enterSelection(msg);
                },
              ),
              if (isMe && !isDeleted && messageUuid != null)
                ListTile(
                  leading: const Icon(Icons.delete_sweep, color: Colors.red),
                  title:       Text(S.deleteForEveryone),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title:       Text(S.confirmDeleteAll),
                        content:       Text(
                            S.deleteAllWarning),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child:       Text(S.cancel),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                            onPressed: () => Navigator.pop(c, true),
                            child:       Text(S.deleteForEveryone,
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
                        msg['content'] = S.deletedMessage;
                      });
                    }
                  },
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title:       Text(S.deleteForMe),
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
              title:       Row(
                children: [
                  Icon(Icons.timer_outlined, color: Colors.teal),
                  SizedBox(width: 8),
                  Text(S.disappearing),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                        Text(S.ttlDuration,
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label:       Text(S.ttlOff),
                        selected: tempTtl == null,
                        onSelected: (_) => setDlgState(() => tempTtl = null),
                      ),
                      ChoiceChip(
                        label:       Text(S.ttl1h),
                        selected: tempTtl == 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 60 * 60 * 1000),
                      ),
                      ChoiceChip(
                        label:       Text(S.ttl12h),
                        selected: tempTtl == 12 * 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 12 * 60 * 60 * 1000),
                      ),
                      ChoiceChip(
                        label:       Text(S.ttl24h),
                        selected: tempTtl == 24 * 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 24 * 60 * 60 * 1000),
                      ),
                      ChoiceChip(
                        label:       Text(S.ttl7d),
                        selected: tempTtl == 7 * 24 * 60 * 60 * 1000,
                        onSelected: (_) =>
                            setDlgState(() => tempTtl = 7 * 24 * 60 * 60 * 1000),
                      ),
                    ],
                  ),
                  if (tempTtl != null) ...[
                    const Divider(height: 24),
                          Text(S.ttlStartFrom,
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    RadioGroup<String>(
                      groupValue: tempTrigger,
                      onChanged: (val) =>
                          setDlgState(() => tempTrigger = val ?? 'send'),
                      child:       Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RadioListTile<String>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(S.ttlFromSend),
                            value: 'send',
                          ),
                          RadioListTile<String>(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(S.ttlFromRead),
                            value: 'read',
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child:       Text(S.cancel),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
                  onPressed: () {
                    setState(() {
                      _selectedTtlMs = tempTtl;
                      _selectedExpireTrigger = tempTrigger;
                    });
                    // Persist per-chat so the choice survives reopening —
                    // the previous in-memory-only setState silently
                    // reverted to the global default.
                    unawaited(DatabaseHelper.instance.setChatEphemeral(
                      widget.recipientId, tempTtl, tempTrigger));
                    Navigator.pop(ctx);
                  },
                  child:       Text(S.save, style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatMessageTime(dynamic timestamp) {
    final ms = _tsMs(timestamp);
    if (ms == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  int _tsMs(dynamic ts) =>
      ts is int ? ts : int.tryParse(ts?.toString() ?? '') ?? 0;

  bool _isSameDay(int aMs, int bMs) {
    final a = DateTime.fromMillisecondsSinceEpoch(aMs);
    final b = DateTime.fromMillisecondsSinceEpoch(bMs);
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  /// WhatsApp-style day pill: "اليوم" / "أمس" / numeric date.
  String _dayLabel(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    if (diff <= 0) return S.today;
    if (diff == 1) return S.yesterday;
    return '${d.day}/${d.month}/${d.year}';
  }

  Widget _dayHeader(String label, bool isDark) => Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: isDark ? WaslColors.darkMuted : WaslColors.muted,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: WaslColors.mutedFg(context),
            ),
          ),
        ),
      );

  /// True only while a media transfer is genuinely in flight. Plain text rows
  /// store transfer_progress = 0.0, so checking progress alone would paint a
  /// stray progress line under every history message.
  bool _isTransferActive(Map<String, dynamic> msg) {
    final status = msg['transfer_status']?.toString();
    if (status != 'sending' && status != 'receiving') return false;
    final progress = (msg['transfer_progress'] as num?)?.toDouble() ?? 0.0;
    return progress < 1.0;
  }

  /// Renders the bubble body according to the message type:
  /// playable voice note, file card, or plain text.
  Widget _buildMessageBody(
      Map<String, dynamic> msg, bool isMe, bool isDeleted, bool isDark) {
    final type = msg['type']?.toString() ?? 'text';
    final content = msg['content']?.toString() ?? '';
    final textColor = isDeleted
        ? WaslColors.mutedFg(context)
        : (isMe
            ? Colors.white
            : (isDark ? WaslColors.darkForeground : WaslColors.foreground));

    if (!isDeleted && type == 'audio') {
      final filePath = msg['file_path']?.toString();
      final canPlay = filePath != null && filePath.isNotEmpty;
      return GestureDetector(
        onTap: canPlay ? () => _playEncryptedAudio(filePath) : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: isMe
                    ? Colors.white.withValues(alpha: 0.22)
                    : WaslColors.accent,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.play_arrow_rounded,
                color: isMe ? Colors.white : WaslColors.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.graphic_eq,
                size: 18,
                color: isMe ? Colors.white70 : WaslColors.primary),
            const SizedBox(width: 6),
            Text(
              S.voiceMessage,
              style: TextStyle(fontSize: 13, color: textColor),
            ),
          ],
        ),
      );
    }

    if (!isDeleted && type == 'image') {
      final filePath = msg['file_path']?.toString();
      return _DecryptedImageBubble(
        fileRef: filePath,
        loader: _decryptMediaBytes,
        fallbackName: WaslMedia.displayName(content),
      );
    }

    if (!isDeleted && type == 'file') {
      final rawName = WaslMedia.displayName(content);
      final filePath = msg['file_path']?.toString();
      final canOpen = filePath != null && filePath.isNotEmpty;
      return GestureDetector(
        onTap: canOpen ? () => _exportMediaFile(filePath, rawName) : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isMe
                    ? Colors.white.withValues(alpha: 0.22)
                    : WaslColors.accent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.insert_drive_file_outlined,
                color: isMe ? Colors.white : WaslColors.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                rawName.isEmpty ? S.attachedFile : rawName,
                style: TextStyle(fontSize: 13, color: textColor),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (canOpen) ...[
              const SizedBox(width: 6),
              Icon(Icons.download_rounded,
                  size: 16,
                  color: isMe ? Colors.white70 : WaslColors.primary),
            ],
          ],
        ),
      );
    }

    return Text(
      content,
      style: TextStyle(
        color: textColor,
        fontSize: 14,
        fontStyle: isDeleted ? FontStyle.italic : FontStyle.normal,
      ),
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
    final localConnected = _connectionStatus == 'connected';
    final peerOnline = _peerOnline;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final peerName = _peerDisplayName.isNotEmpty
        ? _peerDisplayName
        : widget.recipientId;

    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              titleSpacing: 0,
              title: Text(
                S.selectedCount(_selectedUuids.length),
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selectionMode = false;
                  _selectedUuids.clear();
                }),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.redAccent),
                  tooltip: S.delete,
                  onPressed: _deleteSelected,
                ),
              ],
            )
          : AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            WaslAvatar(
              color: WaslColors.avatarColorFor(widget.recipientId),
              initials: peerName.isNotEmpty ? peerName[0].toUpperCase() : '?',
              size: 38,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    peerName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.lock,
                          size: 11, color: WaslColors.primary),
                      const SizedBox(width: 3),
                      Flexible(
                        child: Text(
                          _peerTyping
                              ? S.typing
                              : (peerOnline
                                  ? S.onlineE2e
                                  : S.e2e),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: WaslColors.primary,
                              fontWeight: _peerTyping
                                  ? FontWeight.w600
                                  : FontWeight.normal),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              Icons.timer_outlined,
              color: _selectedTtlMs != null
                  ? WaslColors.primary
                  : WaslColors.mutedFg(context),
            ),
            tooltip: S.ttlSettings,
            onPressed: _showEphemeralSettingsDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          // Ephemeral hint banner (visible when a TTL is configured)
          if (_selectedTtlMs != null)
            Container(
              width: double.infinity,
              color: isDark ? WaslColors.darkMuted : WaslColors.accent,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.timer_outlined,
                      size: 14, color: WaslColors.primary),
                  const SizedBox(width: 6),
                  Text(
                    S.disappearingHint +
                        (_selectedTtlMs! >= 86400000
                            ? S.ttlDays(_selectedTtlMs! ~/ 86400000)
                            : S.ttlHours(_selectedTtlMs! ~/ 3600000)),
                    style: const TextStyle(
                        fontSize: 12, color: WaslColors.primary),
                  ),
                ],
              ),
            ),
          if (!localConnected)
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
                        ? S.connecting
                        : S.offlineQueue,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          Expanded(
            child: SelectionArea(
              child: ListView.builder(
              controller: _scrollController,
              reverse: true,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                // reverse:true puts the newest message (end of _messages)
                // at visual index 0 — the chat opens at the latest message
                // instantly, with no scroll animation.
                final realIndex = _messages.length - 1 - index;
                final msg = _messages[realIndex];
                // Day pill above the first message of each new day —
                // realIndex == 0 is the oldest message of the chat.
                final showDayHeader = realIndex == 0 ||
                    !_isSameDay(
                        _tsMs(_messages[realIndex - 1]['timestamp']),
                        _tsMs(msg['timestamp']));
                final isMe = msg['isMe'] == true;
                final isDeleted = (msg['is_deleted_for_everyone'] ?? 0) == 1;
                final msgUuid = msg['message_uuid']?.toString();
                final isSelected =
                    msgUuid != null && _selectedUuids.contains(msgUuid);
                final reaction = msg['reaction']?.toString();
                final replyText = msg['reply_to_text']?.toString();

                return Column(
                  children: [
                    if (showDayHeader)
                      _dayHeader(
                          _dayLabel(_tsMs(msg['timestamp'])), isDark),
                    MessageIn(
                  child: Container(
                    color: isSelected
                        ? WaslColors.primary.withValues(alpha: 0.12)
                        : Colors.transparent,
                    child: Align(
                    alignment:
                        isMe ? Alignment.centerLeft : Alignment.centerRight,
                    child: GestureDetector(
                      onTap: _selectionMode ? () => _toggleSelect(msg) : null,
                      onLongPress: () => _selectionMode
                          ? _toggleSelect(msg)
                          : _showMessageOptions(msg, realIndex),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        constraints: BoxConstraints(
                          maxWidth:
                              MediaQuery.of(context).size.width * 0.75,
                        ),
                        decoration: BoxDecoration(
                          color: isDeleted
                              ? (isDark
                                  ? WaslColors.darkMuted
                                  : WaslColors.muted)
                              : (isMe
                                  ? WaslColors.primary
                                  : (isDark
                                      ? WaslColors.darkCard
                                      : Colors.white)),
                          borderRadius: BorderRadius.only(
                            topRight: const Radius.circular(18),
                            topLeft: const Radius.circular(18),
                            bottomRight: Radius.circular(isMe ? 18 : 4),
                            bottomLeft: Radius.circular(isMe ? 4 : 18),
                          ),
                          border: isMe
                              ? null
                              : Border.all(
                                  color: isDark
                                      ? WaslColors.darkBorder
                                      : WaslColors.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (replyText != null &&
                                replyText.isNotEmpty &&
                                !isDeleted)
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isMe
                                      ? Colors.white.withValues(alpha: 0.15)
                                      : WaslColors.primary
                                          .withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border(
                                    right: BorderSide(
                                      color: isMe
                                          ? Colors.white70
                                          : WaslColors.primary,
                                      width: 3,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  replyText,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isMe
                                        ? Colors.white70
                                        : WaslColors.mutedFg(context),
                                  ),
                                ),
                              ),
                            _buildMessageBody(msg, isMe, isDeleted, isDark),
                            if (_isTransferActive(msg))
                              Padding(
                                padding: const EdgeInsets.only(top: 6.0),
                                child: LinearProgressIndicator(
                                  value: (msg['transfer_progress']
                                              as num?)
                                          ?.toDouble() ??
                                      0.0,
                                  backgroundColor: isMe
                                      ? Colors.white24
                                      : (isDark
                                          ? WaslColors.darkMuted
                                          : WaslColors.muted),
                                  color: isMe
                                      ? Colors.white
                                      : WaslColors.primary,
                                  minHeight: 3,
                                ),
                              ),
                            const SizedBox(height: 3),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (msg['expires_at'] != null) ...[
                                  const Icon(Icons.timer,
                                      size: 11,
                                      color: WaslColors.primary),
                                  const SizedBox(width: 4),
                                ],
                                Text(
                                  _formatMessageTime(msg['timestamp']),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: isMe
                                        ? Colors.white70
                                        : WaslColors.mutedFg(context),
                                  ),
                                ),
                                if ((msg['is_edited'] ?? 0) == 1) ...[
                                  const SizedBox(width: 4),
                                  Text(
                                    '(${S.edited})',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontStyle: FontStyle.italic,
                                      color: isMe
                                          ? Colors.white70
                                          : WaslColors.mutedFg(context),
                                    ),
                                  ),
                                ],
                                if (isMe) ...[
                                  const SizedBox(width: 4),
                                  _buildStatusTicks(msg),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (reaction != null && reaction.isNotEmpty)
                        Positioned(
                          bottom: -8,
                          right: isMe ? null : -4,
                          left: isMe ? -4 : null,
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? WaslColors.darkCard
                                  : Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: WaslColors.border, width: 0.5),
                              boxShadow: const [
                                BoxShadow(
                                    blurRadius: 4, color: Colors.black26)
                              ],
                            ),
                            child: Text(reaction,
                                style: const TextStyle(fontSize: 13)),
                          ),
                        ),
                        ],
                      ),
                    ),
                  ),
                  ),
                    ),
                  ],
                );
              },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              color: Theme.of(context).colorScheme.surface,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_replyTo != null)
                    _composerBar(
                      icon: Icons.reply_rounded,
                      title: S.reply,
                      preview: _previewOf(_replyTo!),
                      onClose: () => setState(() => _replyTo = null),
                    ),
                  if (_editingMsg != null)
                    _composerBar(
                      icon: Icons.edit_outlined,
                      title: S.editMessage,
                      preview: _previewOf(_editingMsg!),
                      onClose: () => setState(() {
                        _editingMsg = null;
                        _messageController.clear();
                      }),
                    ),
              Row(
                children: [
                  WaslRoundIconButton(
                    icon: Icons.attach_file,
                    onTap: _sendAttachment,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _isRecording
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? WaslColors.darkMuted
                                  : WaslColors.muted,
                              borderRadius: BorderRadius.circular(24),
                            ),
                            child:       Row(
                              children: [
                                Icon(Icons.fiber_manual_record,
                                    color: Colors.red, size: 14),
                                SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    S.recording,
                                    style: TextStyle(fontSize: 13),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : TextField(
                            controller: _messageController,
                            onChanged: _handleTypingChanged,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            minLines: 1,
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: S.typeMessage,
                              filled: true,
                              fillColor: isDark
                                  ? WaslColors.darkMuted
                                  : WaslColors.muted,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onLongPressStart: (_) => _startRecording(),
                    onLongPressEnd: (_) => _stopRecordingAndSend(),
                    child: const WaslRoundIconButton(
                        icon: Icons.mic_none),
                  ),
                  const SizedBox(width: 8),
                  WaslRoundIconButton(
                    icon: _editingMsg != null ? Icons.check : Icons.send,
                    filled: true,
                    onTap: _sendMessage,
                  ),
                ],
              ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Preview strip shown above the composer while replying or editing.
  Widget _composerBar({
    required IconData icon,
    required String title,
    required String preview,
    required VoidCallback onClose,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: WaslColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: const Border(
          right: BorderSide(color: WaslColors.primary, width: 3),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: WaslColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: WaslColors.primary)),
                Text(preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ],
            ),
          ),
          GestureDetector(
            onTap: onClose,
            child: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

/// Inline image preview that decrypts the stored ciphertext once and caches
/// the result, instead of showing the raw filename.
class _DecryptedImageBubble extends StatefulWidget {
  final String? fileRef;
  final Future<Uint8List?> Function(String fileRef) loader;
  final String fallbackName;

  const _DecryptedImageBubble({
    required this.fileRef,
    required this.loader,
    required this.fallbackName,
  });

  @override
  State<_DecryptedImageBubble> createState() => _DecryptedImageBubbleState();
}

class _DecryptedImageBubbleState extends State<_DecryptedImageBubble> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final ref = widget.fileRef;
    if (ref == null || ref.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    final bytes = await widget.loader(ref);
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _failed = bytes == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 230, maxHeight: 280),
          child: Image.memory(
            _bytes!,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallbackCard(),
          ),
        ),
      );
    }
    if (_failed) return _fallbackCard();
    return const SizedBox(
      width: 200,
      height: 120,
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }

  Widget _fallbackCard() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            widget.fallbackName.isEmpty ? S.image : widget.fallbackName,
            style: const TextStyle(fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
