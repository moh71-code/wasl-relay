import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import '../network/websocket_service.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  Timer? _bgTimer;
  final Uuid _uuid = const Uuid();

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('wasl_database.db');
    _startBackgroundProcessing();
    return _database!;
  }

  void _startBackgroundProcessing() {
    _bgTimer ??= Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        await processOutbox();
        await cleanupExpiredMessages();
      } catch (_) {}
    });
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 4,
      onCreate: _createDB,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE messages ADD COLUMN type TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN file_path TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN transfer_status TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN transfer_progress REAL');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE messages ADD COLUMN expires_at INTEGER');
          await db.execute('''
            CREATE TABLE outbox (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              payload TEXT,
              status TEXT,
              attempts INTEGER,
              created_at INTEGER
            )
          ''');
        }
        if (oldVersion < 4) {
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN message_uuid TEXT');
            await db.execute("ALTER TABLE messages ADD COLUMN status TEXT DEFAULT 'sent'");
            await db.execute("ALTER TABLE messages ADD COLUMN expire_trigger TEXT DEFAULT 'send'");
            await db.execute('ALTER TABLE messages ADD COLUMN expires_duration_ms INTEGER');
            await db.execute('ALTER TABLE messages ADD COLUMN is_read INTEGER DEFAULT 0');
            await db.execute('ALTER TABLE messages ADD COLUMN read_at INTEGER');
            await db.execute('ALTER TABLE messages ADD COLUMN is_deleted_for_everyone INTEGER DEFAULT 0');
          } catch (_) {}

          try {
            await db.execute('ALTER TABLE outbox ADD COLUMN message_uuid TEXT');
            await db.execute('ALTER TABLE outbox ADD COLUMN priority INTEGER DEFAULT 1');
          } catch (_) {}

          try {
            await db.execute('ALTER TABLE contacts ADD COLUMN unread_count INTEGER DEFAULT 0');
            await db.execute('ALTER TABLE contacts ADD COLUMN last_timestamp TEXT');
          } catch (_) {}
        }
      },
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE contacts (
        id TEXT PRIMARY KEY,
        name TEXT,
        status TEXT,
        last_message TEXT,
        last_timestamp TEXT,
        unread_count INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_uuid TEXT UNIQUE,
        sender_id TEXT,
        recipient_id TEXT,
        content TEXT,
        type TEXT,
        file_path TEXT,
        transfer_status TEXT,
        transfer_progress REAL,
        status TEXT DEFAULT 'sent',
        expires_at INTEGER,
        expires_duration_ms INTEGER,
        expire_trigger TEXT DEFAULT 'send',
        is_read INTEGER DEFAULT 0,
        read_at INTEGER,
        is_deleted_for_everyone INTEGER DEFAULT 0,
        timestamp TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        message_uuid TEXT,
        priority INTEGER DEFAULT 1,
        payload TEXT,
        status TEXT,
        attempts INTEGER,
        created_at INTEGER
      )
    ''');
  }

  Future<List<Map<String, dynamic>>> getContacts() async {
    final db = await instance.database;
    return await db.query('contacts');
  }

  Future<void> saveContact(String id, String name, String status) async {
    final db = await instance.database;
    await db.insert(
      'contacts',
      {'id': id, 'name': name, 'status': status},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> updateContactStatus(String id, String status) async {
    final db = await instance.database;
    await db.update(
      'contacts',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Map<String, dynamic>>> getMessagesBetween(
      String userId, String recipientId) async {
    final db = await instance.database;
    return await db.query(
      'messages',
      where:
          '((sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)) AND is_deleted_for_everyone = 0',
      whereArgs: [userId, recipientId, recipientId, userId],
      orderBy: 'timestamp ASC',
    );
  }

  Future<int> saveMessage(Map<String, dynamic> msgData) async {
    final db = await instance.database;
    final uuid = msgData['message_uuid'] ?? _uuid.v4();
    return await db.insert('messages', {
      'message_uuid': uuid,
      'sender_id': msgData['sender_id'],
      'recipient_id': msgData['recipient_id'],
      'content': msgData['content'] ?? msgData['message'],
      'type': msgData['type'] ?? 'text',
      'file_path': msgData['file_path'],
      'transfer_status': msgData['transfer_status'],
      'transfer_progress': msgData['transfer_progress'] ?? 0.0,
      'status': msgData['status'] ?? 'sent',
      'expires_at': msgData['expires_at'],
      'expires_duration_ms': msgData['expires_duration_ms'],
      'expire_trigger': msgData['expire_trigger'] ?? 'send',
      'is_read': (msgData['is_read'] == true || msgData['is_read'] == 1) ? 1 : 0,
      'read_at': msgData['read_at'],
      'is_deleted_for_everyone': (msgData['is_deleted_for_everyone'] == true || msgData['is_deleted_for_everyone'] == 1) ? 1 : 0,
      'timestamp': msgData['timestamp'].toString(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Save a message and update contacts' last_message for both participants.
  Future<int> saveMessageAndUpdateContacts(Map<String, dynamic> msgData) async {
    final db = await instance.database;
    final content = msgData['content'] ?? msgData['message'];
    final timestamp = msgData['timestamp'].toString();
    final uuid = msgData['message_uuid'] ?? _uuid.v4();
    final senderId = msgData['sender_id'];
    final recipientId = msgData['recipient_id'];
    final isIncoming = msgData['is_incoming'] == true;

    final id = await db.insert('messages', {
      'message_uuid': uuid,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'content': content,
      'type': msgData['type'] ?? 'text',
      'file_path': msgData['file_path'],
      'transfer_status': msgData['transfer_status'],
      'transfer_progress': msgData['transfer_progress'] ?? 0.0,
      'status': msgData['status'] ?? 'sent',
      'expires_at': msgData['expires_at'],
      'expires_duration_ms': msgData['expires_duration_ms'],
      'expire_trigger': msgData['expire_trigger'] ?? 'send',
      'is_read': (msgData['is_read'] == true || msgData['is_read'] == 1) ? 1 : 0,
      'read_at': msgData['read_at'],
      'is_deleted_for_everyone': 0,
      'timestamp': timestamp,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Update contacts
    final partnerId = isIncoming ? senderId : recipientId;
    final existingContact = await db.query('contacts', where: 'id = ?', whereArgs: [partnerId]);
    if (existingContact.isNotEmpty) {
      final currentUnread = (existingContact.first['unread_count'] as int?) ?? 0;
      await db.update(
        'contacts',
        {
          'last_message': content,
          'last_timestamp': timestamp,
          if (isIncoming) 'unread_count': currentUnread + 1,
        },
        where: 'id = ?',
        whereArgs: [partnerId],
      );
    } else {
      await db.insert('contacts', {
        'id': partnerId,
        'name': partnerId,
        'status': 'connected',
        'last_message': content,
        'last_timestamp': timestamp,
        'unread_count': isIncoming ? 1 : 0,
      });
    }

    return id;
  }

  /// Update message delivery/read status by UUID
  Future<void> updateMessageStatusByUuid(String uuid, String newStatus) async {
    final db = await instance.database;
    await db.update(
      'messages',
      {
        'status': newStatus,
        if (newStatus == 'read') 'is_read': 1,
        if (newStatus == 'read') 'read_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'message_uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// Mark all unread incoming messages from peer as read and activate read-triggered ephemerals
  Future<List<String>> markMessagesAsRead(String currentUserId, String peerId) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final unread = await db.query(
      'messages',
      where: 'sender_id = ? AND recipient_id = ? AND is_read = 0',
      whereArgs: [peerId, currentUserId],
    );

    final readUuids = <String>[];
    for (var m in unread) {
      final uuid = m['message_uuid'] as String?;
      if (uuid != null) readUuids.add(uuid);

      final trigger = m['expire_trigger'] as String?;
      final duration = m['expires_duration_ms'] as int?;
      int? calculatedExpiresAt = m['expires_at'] as int?;

      if (trigger == 'read' && duration != null && duration > 0) {
        calculatedExpiresAt = now + duration;
      }

      await db.update(
        'messages',
        {
          'is_read': 1,
          'status': 'read',
          'read_at': now,
          if (calculatedExpiresAt != null) 'expires_at': calculatedExpiresAt,
        },
        where: 'id = ?',
        whereArgs: [m['id']],
      );
    }

    // Reset unread count for peer
    await db.update('contacts', {'unread_count': 0}, where: 'id = ?', whereArgs: [peerId]);

    return readUuids;
  }

  /// Delete message for everyone: Mark deleted, erase content, remove physical files
  Future<void> deleteMessageForEveryone(String messageUuid) async {
    final db = await instance.database;
    final rows = await db.query('messages', where: 'message_uuid = ?', whereArgs: [messageUuid]);
    for (var r in rows) {
      final fp = r['file_path'] as String?;
      if (fp != null && fp.isNotEmpty) {
        try {
          final f = File(fp);
          final mf = File('$fp.meta.json');
          if (await f.exists()) await f.delete();
          if (await mf.exists()) await mf.delete();
        } catch (_) {}
      }
    }

    await db.update(
      'messages',
      {
        'is_deleted_for_everyone': 1,
        'content': '[تم حذف هذه الرسالة]',
        'file_path': null,
      },
      where: 'message_uuid = ?',
      whereArgs: [messageUuid],
    );

    await db.delete('outbox', where: 'message_uuid = ?', whereArgs: [messageUuid]);
  }

  /// Delete message locally (for me)
  Future<void> deleteMessageLocally(int id) async {
    final db = await instance.database;
    final rows = await db.query('messages', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final fp = rows.first['file_path'] as String?;
      if (fp != null && fp.isNotEmpty) {
        try {
          final f = File(fp);
          final mf = File('$fp.meta.json');
          if (await f.exists()) await f.delete();
          if (await mf.exists()) await mf.delete();
        } catch (_) {}
      }
    }
    await db.delete('messages', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> cleanupExpiredMessages() async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = await db.query('messages',
        where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
    for (final m in expired) {
      final fp = m['file_path'] as String?;
      if (fp != null && fp.isNotEmpty) {
        try {
          final f = File(fp);
          final mf = File('$fp.meta.json');
          if (await f.exists()) await f.delete();
          if (await mf.exists()) await mf.delete();
        } catch (_) {}
      }
    }
    await db.delete('messages',
        where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
  }

  Future<void> deleteMessageByFilePath(String filePath) async {
    final db = await instance.database;
    await db.delete('messages', where: 'file_path = ?', whereArgs: [filePath]);
  }

  Future<void> deleteOutboxByFileId(String fileId) async {
    final db = await instance.database;
    final rows = await db.query('outbox');
    for (final r in rows) {
      try {
        final payload = jsonDecode(r['payload'] as String);
        if (payload['file_id'] == fileId) {
          await db.delete('outbox', where: 'id = ?', whereArgs: [r['id']]);
        }
      } catch (_) {}
    }
  }

  /// Enqueue payload into outbox with priority (1: Text/Control, 2: Media chunks)
  Future<int> enqueueOutbox(String payload, {String? messageUuid, int priority = 1}) async {
    final db = await instance.database;
    return await db.insert('outbox', {
      'message_uuid': messageUuid,
      'priority': priority,
      'payload': payload,
      'status': 'pending',
      'attempts': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Process Outbox prioritized: Text/Control first, then media chunks
  Future<void> processOutbox() async {
    final db = await instance.database;
    final rows = await db.query(
      'outbox',
      where: 'status != ?',
      whereArgs: ['sent'],
      orderBy: 'priority ASC, created_at ASC',
    );

    for (final r in rows) {
      final id = r['id'] as int;
      final payload = r['payload'] as String;
      final attempts = (r['attempts'] as int?) ?? 0;

      try {
        if (!WebSocketService().isConnected) {
          continue;
        }
        final Map<String, dynamic> data = jsonDecode(payload);
        if (data['type'] == 'offline_file') {
          final ciphertext = base64.decode(data['ciphertext_b64'] as String);
          final nonce = data['nonce'] as String;
          final mac = data['mac'] as String;
          final fileId = data['file_id'] as String;
          final sender = data['sender_id'] as String;
          final recipient = data['recipient_id'] as String;
          final origName = data['original_name'] as String? ?? '';
          final chunkSize = (data['chunk_size'] as int?) ?? 64 * 1024;
          final totalChunks = (ciphertext.length / chunkSize).ceil();

          for (var i = 0; i < totalChunks; i++) {
            final start = i * chunkSize;
            final end = ((i + 1) * chunkSize).clamp(0, ciphertext.length);
            final chunk = ciphertext.sublist(start, end);
            final payloadChunk = {
              'type': 'file_chunk',
              'file_id': fileId,
              'sender_id': sender,
              'recipient_id': recipient,
              'chunk_index': i,
              'total_chunks': totalChunks,
              'encrypted_payload': base64.encode(chunk),
              'nonce': nonce,
              'mac': mac,
              'original_name': origName,
            };
            WebSocketService().sendData(payloadChunk);
            await Future.delayed(const Duration(milliseconds: 15));
          }
          await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
        } else {
          WebSocketService().sendData(data);
          await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
        }
      } catch (e) {
        final newAttempts = attempts + 1;
        final status = newAttempts >= 5 ? 'failed' : 'pending';
        await db.update('outbox', {'attempts': newAttempts, 'status': status},
            where: 'id = ?', whereArgs: [id]);
      }
    }
  }

  /// Get contacts with their latest message and unread count for a given userId
  Future<List<Map<String, dynamic>>> getContactsWithLatestMessages(
      String userId) async {
    final db = await instance.database;
    final contacts = await db.query('contacts');
    final List<Map<String, dynamic>> results = [];

    for (final c in contacts) {
      if ((c['status'] ?? '').toString() != 'accepted' &&
          (c['status'] ?? '').toString() != 'connected') {
        continue;
      }
      final contactId = c['id'].toString();
      final msgs = await db.query(
        'messages',
        where:
            '((sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)) AND is_deleted_for_everyone = 0',
        whereArgs: [userId, contactId, contactId, userId],
        orderBy: 'timestamp DESC',
        limit: 1,
      );
      final merged = Map<String, dynamic>.from(c);
      if (msgs.isNotEmpty) {
        merged['last_message'] = msgs.first['content'];
        merged['last_timestamp'] = msgs.first['timestamp'];
      }
      results.add(merged);
    }

    results.sort((a, b) {
      final ta = a['last_timestamp']?.toString() ?? '';
      final tb = b['last_timestamp']?.toString() ?? '';
      return tb.compareTo(ta);
    });

    return results;
  }

  Future<void> updateMessageTransfer(
      String filePath, String status, double progress) async {
    final db = await instance.database;
    await db.update(
      'messages',
      {'transfer_status': status, 'transfer_progress': progress},
      where: 'file_path = ?',
      whereArgs: [filePath],
    );
  }

  /// Zeroize Database: wipe all contents permanently
  Future<void> secureZeroizeDatabase() async {
    final db = await instance.database;
    await db.delete('messages');
    await db.delete('contacts');
    await db.delete('outbox');
    try {
      await db.execute('VACUUM');
    } catch (_) {}
  }
}
