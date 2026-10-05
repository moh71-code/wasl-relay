import 'dart:async';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../crypto/crypto_engine.dart';
import '../crypto/pairing_service.dart';
import '../database/database_helper.dart';
import '../media/media_kind.dart';
import '../notifications/notification_service.dart';
import '../storage/storage_service.dart';
import 'file_transfer_service.dart';
import 'group_service.dart';
import 'websocket_service.dart';

/// Central background message ingestion service.
/// Listens to all incoming WebSocket frames, decrypts incoming chat messages,
/// writes them to local SQLite storage, updates contacts, and sends acks.
class MessageIngestionService {
  static final MessageIngestionService _instance = MessageIngestionService._internal();
  factory MessageIngestionService() => _instance;
  MessageIngestionService._internal();

  StreamSubscription? _sub;
  StreamSubscription? _statusSub;
  String? _currentUserId;
  final CryptoEngine _engine = CryptoEngine();
  final Uuid _uuid = const Uuid();
  final StorageService _storage = StorageService();

  void init(String userId) {
    _currentUserId = userId.trim().toUpperCase();
    _sub?.cancel();
    _sub = WebSocketService().messageStream.listen(_handleIncomingFrame);
    // Ensure FileTransferService is also active for media chunks
    FileTransferService();
    // Every fresh authenticated connection re-drives the outbox: messages
    // still awaiting a delivery_ack are re-sent immediately so a relay
    // restart that wiped its in-memory queue gets them re-queued.
    _statusSub?.cancel();
    _statusSub = WebSocketService().statusStream.listen((state) {
      if (state == 'connected') {
        DatabaseHelper.resetOutboxRetry();
        unawaited(DatabaseHelper.instance.processOutbox());
      }
    });
  }

  void dispose() {
    _sub?.cancel();
    _statusSub?.cancel();
  }

  Future<void> _handleIncomingFrame(Map<String, dynamic> data) async {
    final type = data['type'];
    if (type == null) return;

    final myId = _currentUserId ?? (await _storage.getUserId())?.trim().toUpperCase();
    if (myId == null) return;

    // Group protocol frames (invites, group messages, member events)
    if (type == 'group_invite' || type == 'group_message' || type == 'group_leave' ||
        type == 'group_file_offer' || type == 'group_file_chunk' ||
        type == 'offline_group_file') {
      await GroupService().handleFrame(data, myId);
      if (type == 'group_message' || type == 'group_file_chunk' ||
          type == 'offline_group_file') {
        await NotificationService().notifyNewMessage();
      }
      return;
    }

    // 1. Incoming chat message
    if (type == 'chat_message') {
      final recipientId = (data['recipient_id'] as String?)?.trim().toUpperCase();
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      final uuid = (data['message_uuid'] as String?) ?? _uuid.v4();

      if (recipientId != myId || senderId == null) return;

      // Acknowledge transport-level receipt immediately — covers edits,
      // reactions and frames that would return early below, so the
      // sender's outbox can always retire the message_uuid.
      WebSocketService().sendDeliveryAck(
        messageUuid: uuid,
        senderId: myId,
        recipientId: senderId,
      );

      try {
        var sessionB64 = await _storage.getSessionKey(myId, senderId);

        // Auto-derive session key if not yet cached
        if (sessionB64 == null) {
          final peerXb64 = await _storage.getXPublicKey(senderId);
          if (peerXb64 != null) {
            try {
              final peerPubBytes = base64.decode(peerXb64);
              await PairingService().deriveAndStoreSessionKey(
                myUserId: myId,
                peerId: senderId,
                peerXPublicBytes: peerPubBytes,
              );
              sessionB64 = await _storage.getSessionKey(myId, senderId);
            } catch (e) {
              debugPrint('Error deriving session key in ingestion: $e');
            }
          }
        }

        final cipher = data['ciphertext'] as String?;
        final nonce = data['nonce'] as String?;
        final mac = data['mac'] as String?;

        String clearText;
        if (sessionB64 != null && cipher != null && nonce != null && mac != null) {
          try {
            final keyBytes = base64.decode(sessionB64);
            final secretKey = SecretKey(keyBytes);
            clearText = await _engine.decryptMessage(
              cipherTextBase64: cipher,
              nonceBase64: nonce,
              macBase64: mac,
              sharedKey: secretKey,
            );
          } catch (e) {
            debugPrint('Decrypt failed for $uuid, storing ciphertext for retry: $e');
            clearText = jsonEncode({'ciphertext': cipher, 'nonce': nonce, 'mac': mac});
          }
        } else {
          // If session key is missing, store JSON payload so it can be decrypted later
          clearText = jsonEncode({'ciphertext': cipher, 'nonce': nonce, 'mac': mac});
        }

        // v2 envelope: reply / edit / reaction metadata lives INSIDE the
        // encrypted payload so the relay sees nothing but ciphertext.
        String? replyUuid;
        String? replyText;
        try {
          final parsed = jsonDecode(clearText);
          if (parsed is Map && parsed['v'] == 2) {
            if (parsed['react'] != null) {
              await DatabaseHelper.instance.updateMessageReaction(
                  parsed['react'].toString(), parsed['e'] as String?);
              WebSocketService().emitLocal({
                'type': 'reaction_local',
                'message_uuid': parsed['react'].toString(),
                'emoji': parsed['e'],
                'sender_id': senderId,
              });
              return;
            }
            if (parsed['edit'] != null) {
              await DatabaseHelper.instance.updateMessageContent(
                  parsed['edit'].toString(), parsed['t']?.toString() ?? '');
              WebSocketService().emitLocal({
                'type': 'edit_local',
                'message_uuid': parsed['edit'].toString(),
                'sender_id': senderId,
              });
              return;
            }
            clearText = parsed['t']?.toString() ?? '';
            replyUuid = parsed['ru']?.toString();
            replyText = parsed['rt']?.toString();
          }
        } catch (_) {
          // Not a v2 envelope — plain text message
        }

        final msgType = WaslMedia.typeFromContent('text', clearText);

        final ttl = (data['expires_duration_ms'] as num?)?.toInt();
        final trigger = (data['expire_trigger'] as String?) ?? 'send';
        final now = DateTime.now().millisecondsSinceEpoch;
        final timestamp = (data['timestamp'] as num?)?.toInt() ?? now;

        int? calculatedExp;
        // 'read'-triggered timers stay unarmed until markMessagesAsRead fires;
        // 'send'-triggered ones start counting at the sender's timestamp —
        // clamped to local now so a forged future timestamp cannot make a
        // message never expire.
        if (ttl != null && trigger == 'send') {
          calculatedExp = (timestamp < now ? timestamp : now) + ttl;
        }

        // Save to SQLite
        await DatabaseHelper.instance.saveMessageAndUpdateContacts({
          'message_uuid': uuid,
          'sender_id': senderId,
          'recipient_id': myId,
          'content': clearText,
          'type': msgType,
          'status': 'delivered',
          'is_read': 0,
          'expires_at': calculatedExp,
          'expires_duration_ms': ttl,
          'expire_trigger': trigger,
          'timestamp': timestamp,
          'reply_to_uuid': replyUuid,
          'reply_to_text': replyText,
          'is_incoming': true,
        });

        // Privacy-safe local notification (no content or sender shown)
        await NotificationService().notifyNewMessage();

        // Notify active UI listeners
        WebSocketService().emitLocal({
          'type': 'message_ingested',
          'message_uuid': uuid,
          'sender_id': senderId,
          'recipient_id': myId,
          'content': clearText,
          'msg_type': msgType,
          'timestamp': timestamp,
        });
      } catch (e) {
        debugPrint('MessageIngestionService failed for $uuid: $e');
      }
    }

    // 2. Incoming delivery ack
    else if (type == 'delivery_ack') {
      final uuid = data['message_uuid'] as String?;
      if (uuid != null) {
        await DatabaseHelper.instance.updateMessageStatusByUuid(uuid, 'delivered');
        // The peer confirmed receipt — retire any outbox copy of this frame.
        await DatabaseHelper.instance.deleteOutboxByMessageUuid(uuid);
        WebSocketService().emitLocal({
          'type': 'delivery_ack_local',
          'message_uuid': uuid,
          'sender_id': data['sender_id'],
        });
      }
    }

    // 3. Incoming read ack
    else if (type == 'read_ack') {
      final uuids = (data['message_uuids'] as List?)?.cast<String>() ?? [];
      for (var u in uuids) {
        await DatabaseHelper.instance.updateMessageStatusByUuid(u, 'read');
      }
      // Arm read-triggered ephemeral timers on our sent copies now that
      // the peer has actually read them.
      await DatabaseHelper.instance.activateReadExpiry(uuids);
      WebSocketService().emitLocal({
        'type': 'read_ack_local',
        'message_uuids': uuids,
        'sender_id': data['sender_id'],
      });
    }

    // 4. Delete message for everyone (must carry a valid Ed25519 signature)
    else if (type == 'delete_message') {
      final uuid = data['message_uuid'] as String?;
      final senderId = data['sender_id'] as String?;
      final recipientId = data['recipient_id'] as String?;
      final signature = data['signature'] as String?;
      final ts = (data['timestamp'] as num?)?.toInt();
      if (uuid == null || senderId == null || recipientId == null) return;

      bool verified = false;
      if (signature != null) {
        try {
          // Rebuild the exact bytes that were signed from the raw wire values.
          final canonical = PairingService.canonicalControlPayload(
            type: 'delete_message',
            senderId: senderId,
            recipientId: recipientId,
            messageUuid: uuid,
            timestamp: ts,
          );
          verified = await PairingService().verifyControlPayload(
              canonical, signature, senderId.trim().toUpperCase());
        } catch (_) {
          verified = false;
        }
      }
      if (!verified) {
        debugPrint('Rejected unsigned/unverifiable delete_message for $uuid');
        return;
      }

      await DatabaseHelper.instance.deleteMessageForEveryone(uuid);
      WebSocketService().emitLocal({
        'type': 'delete_message_local',
        'message_uuid': uuid,
        'sender_id': senderId,
      });
    }
  }
}
