import 'dart:async';
import 'dart:convert';
// Uint8List provided by flutter/foundation.dart
import 'dart:io';
import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';
import '../../core/network/websocket_service.dart';
import '../../core/storage/storage_service.dart';
import '../../core/crypto/crypto_engine.dart';
import '../../core/database/database_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

class FileTransferService {
  static final FileTransferService _instance = FileTransferService._internal();
  factory FileTransferService() => _instance;
  FileTransferService._internal() {
    WebSocketService().messageStream.listen(_onMessage);
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
  }) async {
    final sessionB64 = await StorageService().getSessionKey(myId, recipientId);
    if (sessionB64 == null) throw Exception('No session key');
    final keyBytes = base64.decode(sessionB64);
    final secretKey = SecretKey(keyBytes);

    final enc =
        await _engine.encryptBytes(plainBytes: fileBytes, sharedKey: secretKey);
    final ciphertext = base64.decode(enc['ciphertext']!);
    final nonceB64 = enc['nonce']!;
    final macB64 = enc['mac']!;

    final fileId = _uuid.v4();
    final totalChunks = (ciphertext.length / chunkSize).ceil();
    // If not connected, enqueue the whole ciphertext as an offline envelope
    if (!WebSocketService().isConnected) {
      final envelope = {
        'type': 'offline_file',
        'file_id': fileId,
        'sender_id': myId,
        'recipient_id': recipientId,
        'ciphertext_b64': base64.encode(ciphertext),
        'nonce': nonceB64,
        'mac': macB64,
        'original_name': originalName ?? '',
        'expires_at': expiresAt,
        'chunk_size': chunkSize,
      };
      await DatabaseHelper.instance.enqueueOutbox(
        jsonEncode(envelope),
        messageUuid: fileId,
        priority: 2,
      );
      return fileId;
    }

    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = ((i + 1) * chunkSize).clamp(0, ciphertext.length);
      final chunk = ciphertext.sublist(start, end);

      final payload = {
        'type': 'file_chunk',
        'file_id': fileId,
        'sender_id': myId,
        'recipient_id': recipientId,
        'chunk_index': i,
        'total_chunks': totalChunks,
        'encrypted_payload': base64.encode(chunk),
        'nonce': nonceB64,
        'mac': macB64,
        'original_name': originalName ?? '',
        'expires_at': expiresAt,
      };

      WebSocketService().sendData(payload);
      // emit upload progress
      _progressController.add({
        'file_id': fileId,
        'progress': (i + 1) / totalChunks,
        'direction': 'upload'
      });
      // optional small delay to avoid flooding
      await Future.delayed(const Duration(milliseconds: 20));
    }

    return fileId;
  }

  Future<void> _onMessage(Map<String, dynamic> data) async {
    if (data['type'] != 'file_chunk') {
      return;
    }

    final fileId = data['file_id'] as String;
    final idx = data['chunk_index'] as int;
    final total = data['total_chunks'] as int;
    final encoded = data['encrypted_payload'] as String;
    final nonce = data['nonce'] as String;
    final mac = data['mac'] as String;
    final sender = data['sender_id'] as String;
    final origName = data['original_name'] as String? ?? '';

    final chunkBytes = base64.decode(encoded);
    _buffers.putIfAbsent(fileId, () => {});
    _buffers[fileId]![idx] = Uint8List.fromList(chunkBytes);
    _expected[fileId] = total;

    // emit receive progress
    _progressController.add({
      'file_id': fileId,
      'progress': _buffers[fileId]!.length / total,
      'direction': 'download'
    });

    // check completion
    if (_buffers[fileId]!.length == total) {
      // assemble
      final List<int> all = [];
      for (var i = 0; i < total; i++) {
        all.addAll(_buffers[fileId]![i]!);
      }

      // Save assembled ciphertext to disk (keep encrypted on disk), plus metadata
      try {
        final appDir = await getApplicationDocumentsDirectory();
        final outPath = '${appDir.path}/${fileId}_${origName.isNotEmpty ? origName : 'file'}';
        final metaPath = '$outPath.meta.json';
        final f = File(outPath);
        await f.writeAsBytes(all, flush: true);

        final meta = {
          'nonce': nonce,
          'mac': mac,
          'sender_id': sender,
          'original_name': origName,
        };
        final mf = File(metaPath);
        await mf.writeAsString(jsonEncode(meta), flush: true);

        // update DB: register received message pointing to encrypted file path
        final msgType = (origName.toLowerCase().endsWith('.m4a') ||
                origName.toLowerCase().endsWith('.aac') ||
                origName.toLowerCase().contains('voice_'))
            ? 'audio'
            : 'file';
        try {
          await DatabaseHelper.instance.saveMessageAndUpdateContacts({
            'message_uuid': fileId,
            'sender_id': sender,
            'recipient_id': data['recipient_id'],
            'content': '[$msgType:$origName]',
            'type': msgType,
            'file_path': outPath,
            'transfer_status': 'received',
            'transfer_progress': 1.0,
            'status': 'delivered',
            'expires_at': data['expires_at'],
            'is_incoming': true,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          });

          // Send delivery acknowledgment to sender
          WebSocketService().sendDeliveryAck(
            messageUuid: fileId,
            senderId: data['recipient_id'],
            recipientId: sender,
          );

          // notify UI locally
          WebSocketService().emitLocal({
            'type': 'file_received',
            'file_id': fileId,
            'sender_id': sender,
            'recipient_id': data['recipient_id'],
            'file_path': outPath,
            'message_type': msgType,
          });
        } catch (e) {
          if (kDebugMode) {
            debugPrint('Failed to save received file message: $e');
          }
        }
      } catch (e) {
        // ignore for now
      } finally {
        _buffers.remove(fileId);
        _expected.remove(fileId);
      }
    }
  }
}
