import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../crypto/crypto_engine.dart';
import '../database/database_helper.dart';
import '../media/media_kind.dart';
import '../storage/storage_service.dart';
import 'websocket_service.dart';

/// End-to-end encrypted group messaging.
///
/// Design: sender-side fan-out. Each group owns a random AES-256 group key.
/// The creator distributes the key to every member inside a `group_invite`
/// frame whose body is encrypted with the pairwise session key that already
/// exists between the two users, so the relay never sees the key or the
/// group roster. Group messages are encrypted once with the group key and a
/// copy is routed to each member via the stateless relay.
class GroupService {
  static final GroupService _instance = GroupService._internal();
  factory GroupService() => _instance;
  GroupService._internal();

  final CryptoEngine _engine = CryptoEngine();
  final StorageService _storage = StorageService();
  final Uuid _uuid = const Uuid();

  // Incoming group file assembly buffers (file_id -> chunks/expectations/meta)
  final Map<String, Map<int, Uint8List>> _fileBuffers = {};
  final Map<String, int> _fileExpected = {};
  final Map<String, Map<String, dynamic>> _fileMeta = {};

  static String generateGroupId() {
    final rand = Random.secure();
    final bytes = List<int>.generate(6, (_) => rand.nextInt(256));
    final hex = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('')
        .toUpperCase();
    return 'GRP-$hex';
  }

  /// Create a group locally and send an encrypted invite to every member.
  /// Returns the new group id, or null if no members were provided.
  Future<String?> createGroup({
    required String myId,
    required String name,
    required Map<String, String> members, // memberId -> display name
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty || members.isEmpty) return null;

    final myIdNorm = myId.trim().toUpperCase();
    final groupId = generateGroupId();
    final createdAt = DateTime.now().millisecondsSinceEpoch;

    // Generate the shared AES-256 group key and keep it in secure storage
    final keyPair = await AesGcm.with256bits().newSecretKey();
    final keyBytes = await keyPair.extractBytes();
    final groupKeyB64 = base64.encode(keyBytes);
    await _storage.saveGroupKey(groupId, groupKeyB64);

    await DatabaseHelper.instance.saveGroup(
      id: groupId,
      name: trimmedName,
      createdBy: myIdNorm,
      createdAt: createdAt,
    );

    final myName = (await _storage.getDisplayName()) ?? myIdNorm;
    await DatabaseHelper.instance.saveGroupMember(
      groupId: groupId,
      memberId: myIdNorm,
      memberName: myName,
      role: 'admin',
    );

    final memberIds = <String>[];
    for (final entry in members.entries) {
      final mid = entry.key.trim().toUpperCase();
      if (mid.isEmpty || mid == myIdNorm) continue;
      memberIds.add(mid);
      await DatabaseHelper.instance.saveGroupMember(
        groupId: groupId,
        memberId: mid,
        memberName: entry.value,
      );
    }

    // Encrypted invite blob — only pairwise session key can open it
    final inviteBody = jsonEncode({
      'group_id': groupId,
      'group_name': trimmedName,
      'created_by': myIdNorm,
      'creator_name': myName,
      'group_key': groupKeyB64,
      'members': {myIdNorm: myName, ...members},
      'created_at': createdAt,
    });

    for (final mid in memberIds) {
      await _sendEncryptedControl(
        myId: myIdNorm,
        peerId: mid,
        type: 'group_invite',
        body: inviteBody,
        extra: {'group_id': groupId},
      );
    }

    return groupId;
  }

  /// Encrypt a control payload with the pairwise session key and send it,
  /// falling back to the offline outbox when the socket is down.
  Future<void> _sendEncryptedControl({
    required String myId,
    required String peerId,
    required String type,
    required String body,
    Map<String, dynamic>? extra,
  }) async {
    final sessionB64 = await _storage.getSessionKey(myId, peerId);
    if (sessionB64 == null) {
      debugPrint('GroupService: no session key for $peerId, cannot send $type');
      return;
    }
    final enc = await _engine.encryptMessage(
      plainText: body,
      sharedKey: SecretKey(base64.decode(sessionB64)),
    );
    final frame = {
      'type': type,
      'sender_id': myId,
      'recipient_id': peerId,
      'ciphertext': enc['ciphertext'],
      'nonce': enc['nonce'],
      'mac': enc['mac'],
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      ...?extra,
    };
    if (WebSocketService().isConnected) {
      WebSocketService().sendData(frame);
    } else {
      await DatabaseHelper.instance.enqueueOutbox(jsonEncode(frame));
    }
  }

  /// Encrypt once with the group key and fan out one copy per member.
  Future<int?> sendGroupTextMessage({
    required String myId,
    required String groupId,
    required String plaintext,
    int? ttlMs,
    String expireTrigger = 'send',
  }) async {
    final myIdNorm = myId.trim().toUpperCase();
    final groupKeyB64 = await _storage.getGroupKey(groupId);
    if (groupKeyB64 == null) return null;

    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final messageUuid = _uuid.v4();
    final enc = await _engine.encryptMessage(
      plainText: plaintext,
      sharedKey: SecretKey(base64.decode(groupKeyB64)),
    );

    int? expiresAt;
    if (ttlMs != null && expireTrigger == 'send') {
      expiresAt = timestamp + ttlMs;
    }

    final members = await DatabaseHelper.instance.getGroupMembers(groupId);
    final myName = (await _storage.getDisplayName()) ?? myIdNorm;
    final isOnline = WebSocketService().isConnected;

    for (final m in members) {
      final mid = (m['member_id'] as String).trim().toUpperCase();
      if (mid == myIdNorm) continue;
      final frame = {
        'type': 'group_message',
        'group_id': groupId,
        'message_uuid': messageUuid,
        'sender_id': myIdNorm,
        'recipient_id': mid,
        'sender_name': myName,
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
        'expires_duration_ms': ttlMs,
        'expire_trigger': expireTrigger,
        'timestamp': timestamp,
      };
      if (isOnline) {
        WebSocketService().sendData(frame);
      } else {
        await DatabaseHelper.instance
            .enqueueOutbox(jsonEncode(frame), messageUuid: messageUuid);
      }
    }

    // Persist the outgoing message locally (ciphertext at rest)
    final dbId = await DatabaseHelper.instance.saveMessageAndUpdateContacts({
      'message_uuid': messageUuid,
      'sender_id': myIdNorm,
      'recipient_id': groupId,
      'group_id': groupId,
      'sender_name': myName,
      'content': jsonEncode({
        'ciphertext': enc['ciphertext'],
        'nonce': enc['nonce'],
        'mac': enc['mac'],
      }),
      'type': 'text',
      'status': isOnline ? 'sent' : 'pending',
      'expires_at': expiresAt,
      'expires_duration_ms': ttlMs,
      'expire_trigger': expireTrigger,
      'timestamp': timestamp,
    });
    return dbId;
  }

  /// Encrypt a file once with the shared group key and fan out the chunks to
  /// every member. The local copy is kept encrypted on disk so the sender can
  /// replay it, exactly like 1:1 transfers.
  Future<String?> sendGroupFile({
    required String myId,
    required String groupId,
    required List<int> fileBytes,
    required String originalName,
    int? ttlMs,
    int chunkSize = 64 * 1024,
  }) async {
    final myIdNorm = myId.trim().toUpperCase();
    final groupKeyB64 = await _storage.getGroupKey(groupId);
    if (groupKeyB64 == null) return null;

    final enc = await _engine.encryptBytes(
      plainBytes: fileBytes,
      sharedKey: SecretKey(base64.decode(groupKeyB64)),
    );
    final ciphertext = base64.decode(enc['ciphertext']!);
    final nonceB64 = enc['nonce']!;
    final macB64 = enc['mac']!;

    final fileId = _uuid.v4();
    final name = originalName.isEmpty ? 'file' : originalName;
    final mediaType = WaslMedia.typeFromName(name);
    final totalChunks = (ciphertext.length / chunkSize).ceil();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final expiresAt = ttlMs != null ? timestamp + ttlMs : null;

    // Local encrypted copy for the sender (same <fileId>_<name> convention).
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final localPath = '${appDir.path}/${fileId}_${WaslMedia.safeFileName(name)}';
      await File(localPath).writeAsBytes(ciphertext, flush: true);
      await File('$localPath.meta.json').writeAsString(
        jsonEncode({
          'nonce': nonceB64,
          'mac': macB64,
          'sender_id': myIdNorm,
          'group_id': groupId,
          'original_name': name,
          'media_type': mediaType,
        }),
        flush: true,
      );
    } catch (e) {
      debugPrint('GroupService: failed to keep local group file copy: $e');
    }

    final members = await DatabaseHelper.instance.getGroupMembers(groupId);
    final myName = (await _storage.getDisplayName()) ?? myIdNorm;
    final isOnline = WebSocketService().isConnected;

    for (final m in members) {
      final mid = (m['member_id'] as String).trim().toUpperCase();
      if (mid == myIdNorm) continue;

      if (!isOnline) {
        // Offline: a single envelope per member (like offline_file in 1:1).
        await DatabaseHelper.instance.enqueueOutbox(
          jsonEncode({
            'type': 'offline_group_file',
            'group_id': groupId,
            'file_id': fileId,
            'sender_id': myIdNorm,
            'recipient_id': mid,
            'sender_name': myName,
            'ciphertext_b64': base64.encode(ciphertext),
            'nonce': nonceB64,
            'mac': macB64,
            'original_name': name,
            'media_type': mediaType,
            'expires_at': expiresAt,
          }),
          messageUuid: fileId,
          priority: 2,
        );
        continue;
      }

      WebSocketService().sendData({
        'type': 'group_file_offer',
        'group_id': groupId,
        'file_id': fileId,
        'sender_id': myIdNorm,
        'recipient_id': mid,
        'sender_name': myName,
        'original_name': name,
        'media_type': mediaType,
        'expires_at': expiresAt,
        'total_chunks': totalChunks,
      });

      for (var i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = ((i + 1) * chunkSize).clamp(0, ciphertext.length);
        WebSocketService().sendData({
          'type': 'group_file_chunk',
          'group_id': groupId,
          'file_id': fileId,
          'sender_id': myIdNorm,
          'recipient_id': mid,
          'sender_name': myName,
          'chunk_index': i,
          'total_chunks': totalChunks,
          'encrypted_payload': base64.encode(ciphertext.sublist(start, end)),
          'nonce': nonceB64,
          'mac': macB64,
          'original_name': name,
          'media_type': mediaType,
          'expires_at': expiresAt,
        });
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }

    // Persist the outgoing media message locally
    await DatabaseHelper.instance.saveMessageAndUpdateContacts({
      'message_uuid': fileId,
      'sender_id': myIdNorm,
      'recipient_id': groupId,
      'group_id': groupId,
      'sender_name': myName,
      'content': '[$mediaType:$name]',
      'type': mediaType,
      'file_path': fileId,
      'status': isOnline ? 'sent' : 'pending',
      'transfer_status': isOnline ? 'sent' : 'pending',
      'transfer_progress': 1.0,
      'expires_at': expiresAt,
      'expires_duration_ms': ttlMs,
      'expire_trigger': 'send',
      'timestamp': timestamp,
    });
    return fileId;
  }

  /// Write a completed group file to disk and persist its message row.
  Future<void> _persistGroupFile({
    required String groupId,
    required String fileId,
    required String senderId,
    required String? senderName,
    required List<int> ciphertext,
    required String nonce,
    required String mac,
    required String origName,
    required String mediaType,
    required dynamic expiresAt,
    required String myId,
  }) async {
    final appDir = await getApplicationDocumentsDirectory();
    final outPath =
        '${appDir.path}/${fileId}_${WaslMedia.safeFileName(origName)}';
    await File(outPath).writeAsBytes(ciphertext, flush: true);
    await File('$outPath.meta.json').writeAsString(
      jsonEncode({
        'nonce': nonce,
        'mac': mac,
        'sender_id': senderId,
        'group_id': groupId,
        'original_name': origName,
        'media_type': mediaType,
      }),
      flush: true,
    );

    await DatabaseHelper.instance.saveMessageAndUpdateContacts({
      'message_uuid': fileId,
      'sender_id': senderId,
      'recipient_id': groupId,
      'group_id': groupId,
      'sender_name': senderName,
      'content': '[$mediaType:$origName]',
      'type': mediaType,
      'file_path': outPath,
      'transfer_status': 'received',
      'transfer_progress': 1.0,
      'status': 'delivered',
      'is_read': 0,
      'expires_at': expiresAt,
      'is_incoming': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    WebSocketService().emitLocal({
      'type': 'group_file_received_local',
      'group_id': groupId,
      'file_id': fileId,
      'sender_id': senderId,
    });
  }

  /// Decrypt a stored group message (content holds the ciphertext JSON blob).
  Future<String?> decryptGroupMessageBody(
      String groupId, String storedContent) async {
    try {
      final groupKeyB64 = await _storage.getGroupKey(groupId);
      if (groupKeyB64 == null) return null;
      final parsed = jsonDecode(storedContent);
      if (parsed is! Map || parsed['ciphertext'] == null) {
        return storedContent; // already plaintext (e.g. system messages)
      }
      return await _engine.decryptMessage(
        cipherTextBase64: parsed['ciphertext'],
        nonceBase64: parsed['nonce'],
        macBase64: parsed['mac'],
        sharedKey: SecretKey(base64.decode(groupKeyB64)),
      );
    } catch (_) {
      return null;
    }
  }

  /// Handle inbound group frames. Returns true when the frame was consumed.
  Future<bool> handleFrame(Map<String, dynamic> data, String myId) async {
    final type = data['type'];
    final myIdNorm = myId.trim().toUpperCase();

    if (type == 'group_invite') {
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      if (senderId == null) return true;
      try {
        final sessionB64 = await _storage.getSessionKey(myIdNorm, senderId);
        if (sessionB64 == null) return true;
        final clear = await _engine.decryptMessage(
          cipherTextBase64: data['ciphertext'],
          nonceBase64: data['nonce'],
          macBase64: data['mac'],
          sharedKey: SecretKey(base64.decode(sessionB64)),
        );
        final invite = jsonDecode(clear) as Map<String, dynamic>;
        final groupId = (invite['group_id'] as String).trim().toUpperCase();
        await _storage.saveGroupKey(groupId, invite['group_key']);
        await DatabaseHelper.instance.saveGroup(
          id: groupId,
          name: invite['group_name'] ?? 'Group',
          createdBy:
              (invite['created_by'] as String?)?.trim().toUpperCase() ?? senderId,
          createdAt: (invite['created_at'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        );
        final members = (invite['members'] as Map?) ?? {};
        for (final entry in members.entries) {
          final mid = entry.key.toString().trim().toUpperCase();
          await DatabaseHelper.instance.saveGroupMember(
            groupId: groupId,
            memberId: mid,
            memberName: entry.value?.toString() ?? mid,
            role: mid == senderId ? 'admin' : 'member',
          );
        }
        WebSocketService().emitLocal({
          'type': 'group_invite_local',
          'group_id': groupId,
          'group_name': invite['group_name'],
          'sender_id': senderId,
        });
      } catch (e) {
        debugPrint('GroupService: failed to process invite: $e');
      }
      return true;
    }

    if (type == 'group_message') {
      final groupId = (data['group_id'] as String?)?.trim().toUpperCase();
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      final recipientId =
          (data['recipient_id'] as String?)?.trim().toUpperCase();
      if (groupId == null || senderId == null || recipientId != myIdNorm) {
        return true;
      }
      final uuid = data['message_uuid'] as String? ?? _uuid.v4();
      try {
        final groupKeyB64 = await _storage.getGroupKey(groupId);
        String storedContent;
        if (groupKeyB64 != null) {
          // Store ciphertext at rest (same as 1:1 messages)
          storedContent = jsonEncode({
            'ciphertext': data['ciphertext'],
            'nonce': data['nonce'],
            'mac': data['mac'],
          });
        } else {
          storedContent = jsonEncode({
            'ciphertext': data['ciphertext'],
            'nonce': data['nonce'],
            'mac': data['mac'],
            'undecryptable': true,
          });
        }
        final ttl = (data['expires_duration_ms'] as num?)?.toInt();
        final trigger = (data['expire_trigger'] as String?) ?? 'send';
        final now = DateTime.now().millisecondsSinceEpoch;
        final timestamp = (data['timestamp'] as num?)?.toInt() ?? now;
        await DatabaseHelper.instance.saveMessageAndUpdateContacts({
          'message_uuid': uuid,
          'sender_id': senderId,
          'recipient_id': groupId,
          'group_id': groupId,
          'sender_name': data['sender_name'],
          'content': storedContent,
          'type': 'text',
          'status': 'delivered',
          'is_read': 0,
          // 'read'-triggered timers arm when the member actually reads the
          // message (markGroupMessagesAsRead), not at arrival. Sender's
          // timestamp is clamped to local now so it cannot extend expiry.
          'expires_at': (ttl != null && trigger == 'send')
              ? (timestamp < now ? timestamp : now) + ttl
              : null,
          'expires_duration_ms': ttl,
          'expire_trigger': trigger,
          'timestamp': timestamp,
          'is_incoming': true,
        });
        WebSocketService().emitLocal({
          'type': 'group_message_local',
          'group_id': groupId,
          'message_uuid': uuid,
          'sender_id': senderId,
          'sender_name': data['sender_name'],
          'timestamp': timestamp,
        });
      } catch (e) {
        debugPrint('GroupService: failed to ingest group message: $e');
      }
      return true;
    }

    if (type == 'group_leave') {
      final groupId = (data['group_id'] as String?)?.trim().toUpperCase();
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      if (groupId != null && senderId != null) {
        await DatabaseHelper.instance.removeGroupMember(groupId, senderId);
        WebSocketService().emitLocal({
          'type': 'group_leave_local',
          'group_id': groupId,
          'sender_id': senderId,
        });
      }
      return true;
    }

    if (type == 'group_file_offer') {
      final groupId = (data['group_id'] as String?)?.trim().toUpperCase();
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      final recipientId =
          (data['recipient_id'] as String?)?.trim().toUpperCase();
      final fileId = data['file_id'] == null
          ? null
          : WaslMedia.safeFileId(data['file_id'] as String);
      if (groupId == null || senderId == null || recipientId != myIdNorm ||
          fileId == null) {
        return true;
      }
      final origName = data['original_name'] as String? ?? '';
      final mediaType =
          (data['media_type'] as String?) ?? WaslMedia.typeFromName(origName);
      _fileMeta[fileId] = {
        'group_id': groupId,
        'sender_id': senderId,
        'sender_name': data['sender_name'],
        'original_name': origName,
        'media_type': mediaType,
        'expires_at': data['expires_at'],
      };
      await DatabaseHelper.instance.saveMessageAndUpdateContacts({
        'message_uuid': fileId,
        'sender_id': senderId,
        'recipient_id': groupId,
        'group_id': groupId,
        'sender_name': data['sender_name'],
        'content': '[$mediaType:$origName]',
        'type': mediaType,
        'transfer_status': 'receiving',
        'transfer_progress': 0.0,
        'status': 'delivered',
        'expires_at': data['expires_at'],
        'is_incoming': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    }

    if (type == 'group_file_chunk') {
      final recipientId =
          (data['recipient_id'] as String?)?.trim().toUpperCase();
      final fileId = data['file_id'] == null
          ? null
          : WaslMedia.safeFileId(data['file_id'] as String);
      final groupId = (data['group_id'] as String?)?.trim().toUpperCase();
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      final idx = data['chunk_index'] as int?;
      final total = data['total_chunks'] as int?;
      final encoded = data['encrypted_payload'] as String?;
      if (recipientId != myIdNorm || fileId == null || groupId == null ||
          senderId == null || idx == null || total == null || encoded == null) {
        return true;
      }

      _fileBuffers.putIfAbsent(fileId, () => {});
      _fileBuffers[fileId]![idx] =
          Uint8List.fromList(base64.decode(encoded));
      _fileExpected[fileId] = total;
      _fileMeta[fileId] ??= {
        'group_id': groupId,
        'sender_id': senderId,
        'sender_name': data['sender_name'],
        'original_name': data['original_name'] as String? ?? '',
        'media_type': data['media_type'],
        'expires_at': data['expires_at'],
      };

      final buf = _fileBuffers[fileId]!;
      if (buf.length == total) {
        var complete = true;
        for (var i = 0; i < total; i++) {
          if (!buf.containsKey(i)) {
            complete = false;
            break;
          }
        }
        if (complete) {
          final all = <int>[];
          for (var i = 0; i < total; i++) {
            all.addAll(buf[i]!);
          }
          final meta = _fileMeta[fileId]!;
          try {
            await _persistGroupFile(
              groupId: groupId,
              fileId: fileId,
              senderId: senderId,
              senderName: meta['sender_name'] as String?,
              ciphertext: all,
              nonce: data['nonce'] as String? ?? '',
              mac: data['mac'] as String? ?? '',
              origName: meta['original_name'] as String? ?? '',
              mediaType: (meta['media_type'] as String?) ??
                  WaslMedia.typeFromName(
                      meta['original_name'] as String? ?? ''),
              expiresAt: meta['expires_at'],
              myId: myIdNorm,
            );
          } catch (e) {
            debugPrint('GroupService: failed to persist group file: $e');
          } finally {
            _fileBuffers.remove(fileId);
            _fileExpected.remove(fileId);
            _fileMeta.remove(fileId);
          }
        }
      }
      return true;
    }

    if (type == 'offline_group_file') {
      final recipientId =
          (data['recipient_id'] as String?)?.trim().toUpperCase();
      final fileId = data['file_id'] == null
          ? null
          : WaslMedia.safeFileId(data['file_id'] as String);
      final groupId = (data['group_id'] as String?)?.trim().toUpperCase();
      final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
      final cipherB64 = data['ciphertext_b64'] as String?;
      if (recipientId != myIdNorm || fileId == null || groupId == null ||
          senderId == null || cipherB64 == null) {
        return true;
      }
      try {
        await _persistGroupFile(
          groupId: groupId,
          fileId: fileId,
          senderId: senderId,
          senderName: data['sender_name'] as String?,
          ciphertext: base64.decode(cipherB64),
          nonce: data['nonce'] as String? ?? '',
          mac: data['mac'] as String? ?? '',
          origName: data['original_name'] as String? ?? '',
          mediaType: (data['media_type'] as String?) ??
              WaslMedia.typeFromName(
                  data['original_name'] as String? ?? ''),
          expiresAt: data['expires_at'],
          myId: myIdNorm,
        );
      } catch (e) {
        debugPrint('GroupService: failed to persist offline group file: $e');
      }
      return true;
    }

    return false;
  }

  /// Leave a group: notify remaining members, then wipe local group data.
  Future<void> leaveGroup({required String myId, required String groupId}) async {
    final myIdNorm = myId.trim().toUpperCase();
    final members = await DatabaseHelper.instance.getGroupMembers(groupId);
    for (final m in members) {
      final mid = (m['member_id'] as String).trim().toUpperCase();
      if (mid == myIdNorm) continue;
      await _sendEncryptedControl(
        myId: myIdNorm,
        peerId: mid,
        type: 'group_leave',
        body: groupId,
        extra: {'group_id': groupId},
      );
    }
    await _storage.deleteGroupKey(groupId);
    await DatabaseHelper.instance.deleteGroup(groupId);
  }
}
