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
    // disconnect so a later retry of the same file starts clean — mark the
    // placeholder row 'failed' AND ask the sender for one automatic resend,
    // so a lost chunk self-heals instead of dying silently.
    WebSocketService().statusStream.listen((status) {
      if (status == 'disconnected') {
        _failInFlight();
        _buffers.clear();
        _fileMeta.clear();
        _lastChunkAt.clear();
      }
    });
    // Stale-transfer sweep: a mid-transfer stall (lost chunk, silent socket
    // death) must surface as 'failed', not an endless progress bar.
    Timer.periodic(const Duration(seconds: 30), (_) {
      final cutoff =
          DateTime.now().millisecondsSinceEpoch - _staleTransferMs;
      for (final fileId in _buffers.keys.toList()) {
        final last = _lastChunkAt[fileId] ?? 0;
        if (last != 0 && last < cutoff) {
          _buffers.remove(fileId);
          _lastChunkAt.remove(fileId);
          unawaited(_failTransfer(fileId));
        }
      }
    });
  }

  static const int _staleTransferMs = 90 * 1000;
  static const int _maxResends = 3;
  final Map<String, int> _lastChunkAt = {};
  final Map<String, int> _resentCount = {};
  final Set<String> _resendRequested = {};

  void _failInFlight() {
    for (final fileId in _buffers.keys) {
      unawaited(_failTransfer(fileId));
    }
  }

  /// Mark a stalled transfer failed and fire a one-shot resend request at
  /// the original sender — bounded by _resendRequested so a permanently
  /// dead file doesn't loop forever.
  Future<void> _failTransfer(String fileId) async {
    await DatabaseHelper.instance.markTransferFailedByUuid(fileId);
    final meta = _fileMeta[fileId];
    final sender = meta?['sender'];
    final myId = (await StorageService().getUserId())?.trim().toUpperCase();
    if (sender != null && myId != null && _resendRequested.add(fileId)) {
      WebSocketService().sendData({
        'type': 'file_resend_request',
        'file_id': fileId,
        'sender_id': myId,
        'recipient_id': sender,
      });
    }
  }

  final Map<String, Map<int, Uint8List>> _buffers = {};
  // fileId -> {sender, name, mediaType} — decrypted once per file so every
  // chunk doesn't re-open the sealed name.
  final Map<String, Map<String, String>> _fileMeta = {};
  final Uuid _uuid = const Uuid();
  final CryptoEngine _engine = CryptoEngine();
  final StreamController<Map<String, dynamic>> _progressController =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get progressStream => _progressController.stream;

  /// Seal the filename + media type INSIDE the pairwise session — the relay
  /// then sees only opaque frames: no filename, no media type, no metadata.
  Future<Map<String, String>> _sealMeta(
      String name, String mediaType, SecretKey key) async {
    final enc = await _engine.encryptMessage(
      plainText: jsonEncode({'n': name, 't': mediaType}),
      sharedKey: key,
    );
    return {'nct': enc['ciphertext']!, 'nn': enc['nonce']!, 'nm': enc['mac']!};
  }

  /// Open a sealed name/type; falls back to legacy cleartext fields so
  /// pre-v10 senders still work during the rollout window.
  Future<Map<String, String>?> _openMeta(
      Map<String, dynamic> frame, String senderId, String myId) async {
    final nct = frame['nct'] as String?;
    final nn = frame['nn'] as String?;
    final nm = frame['nm'] as String?;
    if (nct == null || nn == null || nm == null) {
      final legacy = frame['original_name'] as String?;
      if (legacy == null) return null;
      return {
        'name': legacy,
        'mediaType': (frame['media_type'] as String?) ??
            WaslMedia.typeFromName(legacy),
      };
    }
    try {
      final sessionB64 = await StorageService().getSessionKey(myId, senderId);
      if (sessionB64 == null) return null;
      final clear = await _engine.decryptMessage(
        cipherTextBase64: nct,
        nonceBase64: nn,
        macBase64: nm,
        sharedKey: SecretKey(base64.decode(sessionB64)),
      );
      final parsed = jsonDecode(clear);
      if (parsed is! Map) return null;
      final name = parsed['n']?.toString() ?? 'file';
      return {
        'name': name,
        'mediaType':
            parsed['t']?.toString() ?? WaslMedia.typeFromName(name),
      };
    } catch (_) {
      return null;
    }
  }

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
    // Defense-in-depth: the UI caps picks at 100MB, but a service-level
    // guard catches any future caller that forgets. Larger files would
    // OOM the encrypt-in-RAM pipeline anyway.
    const maxMediaBytes = 100 * 1024 * 1024;
    if (fileBytes.length > maxMediaBytes) {
      throw Exception('file exceeds 100MB media cap');
    }
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
    final sealed = await _sealMeta(name, mediaType, secretKey);
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
        ...sealed,
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
      ...sealed,
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
        ...sealed,
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
      // Yield to the UI every 8th chunk instead of every chunk — ~4x
      // faster throughput while still keeping the isolate responsive.
      if (i % 8 == 7) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }

    return fileId;
  }

  Future<void> _onMessage(Map<String, dynamic> data) async {
    final type = data['type'];
    if (type != 'file_chunk' &&
        type != 'file_offer' &&
        type != 'offline_file' &&
        type != 'file_resend_request') {
      return;
    }

    final myId = (await StorageService().getUserId())?.trim().toUpperCase();
    final recipient =
        (data['recipient_id'] as String?)?.trim().toUpperCase();
    if (myId == null || recipient != myId) return;

    if (type == 'file_resend_request') {
      await _handleResendRequest(data, myId);
      return;
    }

    final sender = (data['sender_id'] as String?)?.trim().toUpperCase();
    if (sender == null) return;

    if (type == 'file_offer') {
      final offerId = data['file_id'] as String?;
      if (offerId == null) return;
      final fileId = WaslMedia.safeFileId(offerId);
      // Track from the offer too — if no chunk ever arrives the sweep
      // still fails the row instead of an eternal "receiving" bubble.
      _buffers.putIfAbsent(fileId, () => {});
      _lastChunkAt[fileId] = DateTime.now().millisecondsSinceEpoch;
      final meta = await _openMeta(data, sender, myId);
      _fileMeta[fileId] = {
        'sender': sender,
        'name': meta?['name'] ?? 'file',
        'mediaType': meta?['mediaType'] ?? 'file',
      };
      await _savePlaceholder(data, fileId,
          _fileMeta[fileId]!['name']!, _fileMeta[fileId]!['mediaType']!);
      return;
    }

    if (type == 'offline_file') {
      await _saveOfflineFile(data, myId);
      return;
    }

    final fileId = WaslMedia.safeFileId(data['file_id'] as String);
    final idx = data['chunk_index'] as int;
    final total = data['total_chunks'] as int;
    final encoded = data['encrypted_payload'] as String;
    final nonce = data['nonce'] as String;
    final mac = data['mac'] as String;

    // Resolve the sealed name once — subsequent chunks hit the cache.
    var meta = _fileMeta[fileId];
    if (meta == null) {
      final opened = await _openMeta(data, sender, myId);
      meta = {
        'sender': sender,
        'name': opened?['name'] ?? 'file',
        'mediaType': opened?['mediaType'] ?? 'file',
      };
      _fileMeta[fileId] = meta;
    }
    final origName = meta['name']!;
    final mediaType = meta['mediaType']!;

    final chunkBytes = base64.decode(encoded);
    _buffers.putIfAbsent(fileId, () => {});
    _buffers[fileId]![idx] = Uint8List.fromList(chunkBytes);
    _lastChunkAt[fileId] = DateTime.now().millisecondsSinceEpoch;

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
          _fileMeta.remove(fileId);
          _lastChunkAt.remove(fileId);
          _resendRequested.remove(fileId);
        }
      }
    }
  }

  /// The receiver asked us to re-send a file we still hold encrypted on
  /// disk (`<fileId>_<name>` + `.meta.json`). Bounded per fileId so a hostile or
  /// buggy peer can't force an endless resend loop. Re-sealing the name for
  /// the requester is harmless — the ciphertext stays keyed to the original
  /// pairwise session the requester belongs to.
  Future<void> _handleResendRequest(
      Map<String, dynamic> data, String myId) async {
    final requester = (data['sender_id'] as String?)?.trim().toUpperCase();
    final rawId = data['file_id'] as String?;
    if (requester == null || rawId == null) return;
    final fileId = WaslMedia.safeFileId(rawId);
    final sent = (_resentCount[fileId] ?? 0);
    if (sent >= _maxResends) return;

    try {
      final appDir = await getApplicationDocumentsDirectory();
      String? cipherPath;
      String? metaPath;
      for (final e in appDir.listSync()) {
        final base = e.path.split(Platform.pathSeparator).last;
        if (base.startsWith('${fileId}_') && base.endsWith('.meta.json')) {
          metaPath = e.path;
        } else if (base.startsWith('${fileId}_')) {
          cipherPath = e.path;
        }
      }
      if (cipherPath == null || metaPath == null) return;

      final meta = jsonDecode(await File(metaPath).readAsString());
      final ciphertext = await File(cipherPath).readAsBytes();
      final nonceB64 = meta['nonce'] as String;
      final macB64 = meta['mac'] as String;
      final name = meta['original_name'] as String? ?? 'file';
      final mediaType = meta['media_type'] as String? ??
          WaslMedia.typeFromName(name);

      // Only resend if we can re-seal the name for the requester's session —
      // otherwise they'd see an undecryptable placeholder.
      final sessionB64 =
          await StorageService().getSessionKey(myId, requester);
      if (sessionB64 == null) return;
      final sealed =
          await _sealMeta(name, mediaType, SecretKey(base64.decode(sessionB64)));

      const chunkSize = 64 * 1024;
      final totalChunks = (ciphertext.length / chunkSize).ceil();
      _resentCount[fileId] = sent + 1;

      WebSocketService().sendData({
        'type': 'file_offer',
        'file_id': fileId,
        'sender_id': myId,
        'recipient_id': requester,
        ...sealed,
        'total_chunks': totalChunks,
      });
      for (var i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = ((i + 1) * chunkSize).clamp(0, ciphertext.length);
        WebSocketService().sendData({
          'type': 'file_chunk',
          'file_id': fileId,
          'sender_id': myId,
          'recipient_id': requester,
          'chunk_index': i,
          'total_chunks': totalChunks,
          'encrypted_payload':
              base64.encode(ciphertext.sublist(start, end)),
          'nonce': nonceB64,
          'mac': macB64,
          ...sealed,
        });
        if (i % 8 == 7) {
          await Future.delayed(const Duration(milliseconds: 15));
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Resend for $fileId failed: $e');
      }
    }
  }

  /// A sender that was offline enqueues an offline_file envelope; if one reaches
  /// us verbatim, persist the payload directly instead of dropping it.
  Future<void> _saveOfflineFile(Map<String, dynamic> data, String myId) async {
    try {
      final fileId = data['file_id'] == null
          ? null
          : WaslMedia.safeFileId(data['file_id'] as String);
      final sender = (data['sender_id'] as String?)?.trim().toUpperCase();
      final ciphertextB64 = data['ciphertext_b64'] as String?;
      if (fileId == null || sender == null || ciphertextB64 == null) return;

      final meta = await _openMeta(data, sender, myId);
      final origName = meta?['name'] ?? 'file';
      final mediaType = meta?['mediaType'] ?? 'file';
      final ciphertext = base64.decode(ciphertextB64);

      final appDir = await getApplicationDocumentsDirectory();
      final outPath =
          '${appDir.path}/${fileId}_${WaslMedia.safeFileName(origName)}';
      await File(outPath).writeAsBytes(ciphertext, flush: true);
      await File('$outPath.meta.json').writeAsString(
        jsonEncode({
          'nonce': data['nonce'],
          'mac': data['mac'],
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

  Future<void> _savePlaceholder(Map<String, dynamic> data, String fileId,
      String origName, String mediaType) async {
    final sender = (data['sender_id'] as String?)?.trim().toUpperCase();
    final recipient = (data['recipient_id'] as String?)?.trim().toUpperCase();
    if (sender == null || recipient == null) return;

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
