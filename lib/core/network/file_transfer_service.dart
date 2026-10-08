import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/network/websocket_service.dart';
import '../../core/notifications/notification_service.dart';
import '../../core/storage/storage_service.dart';
import '../../core/crypto/crypto_engine.dart';
import '../../core/database/database_helper.dart';
import '../../core/media/media_kind.dart';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

class FileTransferService {
  static final FileTransferService _instance = FileTransferService._internal();
  factory FileTransferService() => _instance;
  FileTransferService._internal() {
    WebSocketService().messageStream.listen(_onMessage);
    // A dropped chunk would leave a partial buffer forever; discard it on
    // disconnect so a later retry of the same file starts clean.
    WebSocketService().statusStream.listen((status) {
      if (status == 'disconnected') {
        _buffers.clear();
        _expected.clear();
      }
    });
  }

  final Map<String, Map<int, Uint8List>> _buffers = {};
  final Map<String, int> _expected = {};
  final Uuid _uuid = const Uuid();
  final CryptoEngine _engine = CryptoEngine();
  final StreamController<Map<String, dynamic>> _progressController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  /// Encrypt the whole file with AES-GCM then chunk the ciphertext and send via WebSocket
  Future<String> sendFile({
    required String myId,
    required String recipientId,
    required List<int> fileBytes,
    String? originalName,
    int chunkSize = 64 * 1024,
    int? expiresAt,
    int? expiresDurationMs,
    String? expireTrigger,
  }) async {
    final cleanMy = myId.trim().toUpperCase();
    final cleanPeer = recipientId.trim().toUpperCase();
    final sessionB64 = await StorageService().getSessionKey(cleanMy, cleanPeer);
    if (sessionB64 == null) throw Exception('No session key');
    final keyBytes = base64.decode(sessionB64);
    final secretKey = SecretKey(keyBytes);

    final enc =
        await _engine.encryptBytes(plainBytes: fileBytes, sharedKey: secretKey);
    final ciphertext = base64.decode(enc['ciphertext']!);
    final nonceB64 = enc['nonce']!;
    final macB64 = enc['mac']!;

    final fileId = _uuid.v4();
    final name = originalName ?? 'file';
    final mediaType = WaslMedia.typeFromName(name);
    final totalChunks = (ciphertext.length / chunkSize).ceil();

    // Keep a local encrypted copy so the sender can replay/download their own
    // media (same on-disk format the receiver uses: <fileId>_<name> + meta).
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final localPath = '${appDir.path}/${fileId}_${WaslMedia.safeFileName(name)}';
      await File(localPath).writeAsBytes(ciphertext, flush: true);
      await File('$localPath.meta.json').writeAsString(
        jsonEncode({
          'nonce': nonceB64,
          'mac': macB64,
          'sender_id': cleanMy,
          'original_name': name,
          'media_type': mediaType,
        }),
        flush: true,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to keep local copy of outgoing file: $e');
      }
    }

    if (!WebSocketService().isConnected) {
      final envelope = {
        'type': 'offline_file',
        'file_id': fileId,
        'sender_id': cleanMy,
        'recipient_id': cleanPeer,
        'ciphertext_b64': base64.encode(ciphertext),
        'nonce': nonceB64,
        'mac': macB64,
        'original_name': name,
        'media_type': mediaType,
        'expires_at': expiresAt,
        'expires_duration_ms': expiresDurationMs,
        'expire_trigger': expireTrigger,
        'chunk_size': chunkSize,
      };
      await DatabaseHelper.instance.enqueueOutbox(
        jsonEncode(envelope),
        messageUuid: fileId,
        priority: 2,
      );
      return fileId;
    }

    // Announce typed media so the receiver renders a player/file bubble even
    // before every chunk arrives (and never as a raw filename string).
    WebSocketService().sendData({
      'type': 'file_offer',
      'file_id': fileId,
      'sender_id': cleanMy,
      'recipient_id': cleanPeer,
      'original_name': name,
      'media_type': mediaType,
      'expires_at': expiresAt,
      'expires_duration_ms': expiresDurationMs,
      'expire_trigger': expireTrigger,
      'total_chunks': totalChunks,
    });

    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = ((i + 1) * chunkSize).clamp(0, ciphertext.length);
      final chunk = ciphertext.sublist(start, end);

      final payload = {
        'type': 'file_chunk',
        'file_id': fileId,
        'sender_id': cleanMy,
        'recipient_id': cleanPeer,
        'chunk_index': i,
        'total_chunks': totalChunks,
        'encrypted_payload': base64.encode(chunk),
        'nonce': nonceB64,
        'mac': macB64,
        'original_name': name,
        'media_type': mediaType,
        'expires_at': expiresAt,
        'expires_duration_ms': expiresDurationMs,
        'expire_trigger': expireTrigger,
      };

      WebSocketService().sendData(payload);
      _progressController.add({
        'file_id': fileId,
        'progress': (i + 1) / totalChunks,
        'direction': 'upload'
      });
      await Future.delayed(const Duration(milliseconds: 20));
    }

    return fileId;
  }

  Future<void> _onMessage(Map<String, dynamic> data) async {
    final type = data['type'];
    if (type != 'file_chunk' && type != 'file_offer' && type != 'offline_file') {
      return;
    }

    final myId = (await StorageService().getUserId())?.trim().toUpperCase();
    final recipient =
        (data['recipient_id'] as String?)?.trim().toUpperCase();
    if (myId == null || recipient != myId) return;

    if (type == 'file_offer') {
      await _savePlaceholder(data);
      return;
    }

    if (type == 'offline_file') {
      await _saveOfflineFile(data);
      return;
    }

    final fileId = WaslMedia.safeFileId(data['file_id'] as String);
    final idx = data['chunk_index'] as int;
    final total = data['total_chunks'] as int;
    final encoded = data['encrypted_payload'] as String;
    final nonce = data['nonce'] as String;
    final mac = data['mac'] as String;
    final sender = (data['sender_id'] as String).trim().toUpperCase();
    final origName = data['original_name'] as String? ?? '';
    final mediaType = (data['media_type'] as String?) ??
        WaslMedia.typeFromName(origName);

    final chunkBytes = base64.decode(encoded);
    _buffers.putIfAbsent(fileId, () => {});
    _buffers[fileId]![idx] = Uint8List.fromList(chunkBytes);
    _expected[fileId] = total;

    _progressController.add({
      'file_id': fileId,
      'progress': _buffers[fileId]!.length / total,
      'direction': 'download'
    });

    if (_buffers[fileId]!.length == total) {
      bool complete = true;
      for (var i = 0; i < total; i++) {
        if (!_buffers[fileId]!.containsKey(i)) {
          complete = false;
          break;
        }
      }
      if (complete) {
        final List<int> all = [];
        for (var i = 0; i < total; i++) {
          all.addAll(_buffers[fileId]![i]!);
        }

        try {
          final appDir = await getApplicationDocumentsDirectory();
          final outPath =
              '${appDir.path}/${fileId}_${WaslMedia.safeFileName(origName)}';
          final metaPath = '$outPath.meta.json';
          await File(outPath).writeAsBytes(all, flush: true);
          await File(metaPath).writeAsString(
            jsonEncode({
              'nonce': nonce,
              'mac': mac,
              'sender_id': sender,
              'original_name': origName,
              'media_type': mediaType,
            }),
            flush: true,
          );

          await DatabaseHelper.instance.saveMessageAndUpdateContacts({
            'message_uuid': fileId,
            'sender_id': sender,
            'recipient_id': myId,
            'content': '[$mediaType:$origName]',
            'type': mediaType,
            'file_path': outPath,
            'transfer_status': 'received',
            'transfer_progress': 1.0,
            'status': 'delivered',
            'expires_at': data['expires_at'],
            'expires_duration_ms': data['expires_duration_ms'],
            'expire_trigger': data['expire_trigger'],
            'is_incoming': true,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });

          WebSocketService().sendDeliveryAck(
            messageUuid: fileId,
            senderId: myId,
            recipientId: sender,
          );

          WebSocketService().emitLocal({
            'type': 'file_received',
            'file_id': fileId,
            'message_uuid': fileId,
            'sender_id': sender,
            'recipient_id': myId,
            'file_path': outPath,
            'message_type': mediaType,
            'content': '[$mediaType:$origName]',
          });
          await NotificationService().notifyNewMessage();
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Failed to save received file message: $e');
          }
        } finally {
          _buffers.remove(fileId);
          _expected.remove(fileId);
        }
      }
    }
  }

  /// A sender that was offline enqueues an offline_file envelope; if one reaches
  /// us verbatim, persist the payload directly instead of dropping it.
  Future<void> _saveOfflineFile(Map<String, dynamic> data) async {
    try {
      final fileId = data['file_id'] == null
          ? null
          : WaslMedia.safeFileId(data['file_id'] as String);
      final sender = (data['sender_id'] as String?)?.trim().toUpperCase();
      final ciphertextB64 = data['ciphertext_b64'] as String?;
      if (fileId == null || sender == null || ciphertextB64 == null) return;
      final myId = (await StorageService().getUserId())?.trim().toUpperCase();
      if (myId == null) return;

      final origName = data['original_name'] as String? ?? '';
      final mediaType =
          (data['media_type'] as String?) ?? WaslMedia.typeFromName(origName);
      final ciphertext = base64.decode(ciphertextB64);

      final appDir = await getApplicationDocumentsDirectory();
      final outPath =
          '${appDir.path}/${fileId}_${WaslMedia.safeFileName(origName)}';
      await File(outPath).writeAsBytes(ciphertext, flush: true);
      await File('$outPath.meta.json').writeAsString(
        jsonEncode({
          'nonce': data['nonce'],
          'mac': data['mac'],
          'sender_id': sender,
          'original_name': origName,
          'media_type': mediaType,
        }),
        flush: true,
      );

      await DatabaseHelper.instance.saveMessageAndUpdateContacts({
        'message_uuid': fileId,
        'sender_id': sender,
        'recipient_id': myId,
        'content': '[$mediaType:$origName]',
        'type': mediaType,
        'file_path': outPath,
        'transfer_status': 'received',
        'transfer_progress': 1.0,
        'status': 'delivered',
        'expires_at': data['expires_at'],
        'expires_duration_ms': data['expires_duration_ms'],
        'expire_trigger': data['expire_trigger'],
        'is_incoming': true,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      });

      WebSocketService().sendDeliveryAck(
        messageUuid: fileId,
        senderId: myId,
        recipientId: sender,
      );

      WebSocketService().emitLocal({
        'type': 'file_received',
        'file_id': fileId,
        'message_uuid': fileId,
        'sender_id': sender,
        'recipient_id': myId,
        'file_path': outPath,
        'message_type': mediaType,
        'content': '[$mediaType:$origName]',
      });
      await NotificationService().notifyNewMessage();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to save offline file: $e');
      }
    }
  }

  Future<void> _savePlaceholder(Map<String, dynamic> data) async {
    final fileId = data['file_id'] as String?;
    final sender = (data['sender_id'] as String?)?.trim().toUpperCase();
    final recipient = (data['recipient_id'] as String?)?.trim().toUpperCase();
    if (fileId == null || sender == null || recipient == null) return;
    final origName = data['original_name'] as String? ?? '';
    final mediaType =
        (data['media_type'] as String?) ?? WaslMedia.typeFromName(origName);

    await DatabaseHelper.instance.saveMessageAndUpdateContacts({
      'message_uuid': fileId,
      'sender_id': sender,
      'recipient_id': recipient,
      'content': '[$mediaType:$origName]',
      'type': mediaType,
      'transfer_status': 'receiving',
      'transfer_progress': 0.0,
      'status': 'delivered',
      'expires_at': data['expires_at'],
      'expires_duration_ms': data['expires_duration_ms'],
      'expire_trigger': data['expire_trigger'],
      'is_incoming': true,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    WebSocketService().emitLocal({
      'type': 'file_received',
      'file_id': fileId,
      'message_uuid': fileId,
      'sender_id': sender,
      'recipient_id': recipient,
      'message_type': mediaType,
      'content': '[$mediaType:$origName]',
    });
  }
}
