import 'dart:async';
import '../l10n/s.dart';
import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:uuid/uuid.dart';
import '../media/media_kind.dart';
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
      // Separate guards — an outbox failure must never starve the
      // ephemeral cleanup, or expiring messages would silently persist.
      try {
        await processOutbox();
      } catch (_) {}
      try {
        await cleanupExpiredMessages();
      } catch (_) {}
    });
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 8,
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
        if (oldVersion < 5) {
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN group_id TEXT');
            await db.execute('ALTER TABLE messages ADD COLUMN sender_name TEXT');
          } catch (_) {}
          try {
            await db.execute('''
              CREATE TABLE groups (
                id TEXT PRIMARY KEY,
                name TEXT,
                created_by TEXT,
                created_at INTEGER,
                last_message TEXT,
                last_timestamp TEXT,
                unread_count INTEGER DEFAULT 0
              )
            ''');
            await db.execute('''
              CREATE TABLE group_members (
                group_id TEXT,
                member_id TEXT,
                member_name TEXT,
                role TEXT,
                added_at INTEGER,
                PRIMARY KEY (group_id, member_id)
              )
            ''');
          } catch (_) {}
        }
        if (oldVersion < 6) {
          try {
            await db.execute('ALTER TABLE contacts ADD COLUMN is_hidden INTEGER DEFAULT 0');
            await db.execute('ALTER TABLE groups ADD COLUMN is_hidden INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (oldVersion < 7) {
          try {
            await db.execute('ALTER TABLE messages ADD COLUMN reply_to_uuid TEXT');
            await db.execute('ALTER TABLE messages ADD COLUMN reply_to_text TEXT');
            await db.execute('ALTER TABLE messages ADD COLUMN reaction TEXT');
            await db.execute('ALTER TABLE messages ADD COLUMN is_edited INTEGER DEFAULT 0');
          } catch (_) {}
        }
        if (oldVersion < 8) {
          try {
            // Per-chat disappearing-timer override. A non-null
            // ephemeral_trigger marks an explicit per-chat choice — even
            // when ttl is NULL (chat opted out of the global default).
            await db.execute('ALTER TABLE contacts ADD COLUMN ephemeral_ttl_ms INTEGER');
            await db.execute('ALTER TABLE contacts ADD COLUMN ephemeral_trigger TEXT');
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
        unread_count INTEGER DEFAULT 0,
        is_hidden INTEGER DEFAULT 0,
        ephemeral_ttl_ms INTEGER,
        ephemeral_trigger TEXT
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
        group_id TEXT,
        sender_name TEXT,
        reply_to_uuid TEXT,
        reply_to_text TEXT,
        reaction TEXT,
        is_edited INTEGER DEFAULT 0,
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

    await db.execute('''
      CREATE TABLE groups (
        id TEXT PRIMARY KEY,
        name TEXT,
        created_by TEXT,
        created_at INTEGER,
        last_message TEXT,
        last_timestamp TEXT,
        unread_count INTEGER DEFAULT 0,
        is_hidden INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE group_members (
        group_id TEXT,
        member_id TEXT,
        member_name TEXT,
        role TEXT,
        added_at INTEGER,
        PRIMARY KEY (group_id, member_id)
      )
    ''');
  }

  Future<List<Map<String, dynamic>>> getContacts() async {
    final db = await instance.database;
    return await db.query('contacts');
  }

  /// Per-chat ephemeral-timer override. Returns null when the user has
  /// never configured this chat (caller falls back to the global default).
  /// A non-null `ephemeral_trigger` means an explicit choice — which may
  /// still be "off" (ttl_ms NULL).
  Future<Map<String, dynamic>?> getChatEphemeral(String peerId) async {
    final db = await instance.database;
    final rows = await db.query(
      'contacts',
      columns: ['ephemeral_ttl_ms', 'ephemeral_trigger'],
      where: 'id = ?',
      whereArgs: [peerId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['ephemeral_trigger'] == null) return null;
    return rows.first;
  }

  /// Persist the per-chat disappearing-timer choice. If the contact row
  /// does not exist yet (fresh pair), create it so the setting survives.
  Future<void> setChatEphemeral(
      String peerId, int? ttlMs, String trigger) async {
    final db = await instance.database;
    await db.insert(
      'contacts',
      {'id': peerId, 'name': peerId, 'status': 'connected'},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.update(
      'contacts',
      {'ephemeral_ttl_ms': ttlMs, 'ephemeral_trigger': trigger},
      where: 'id = ?',
      whereArgs: [peerId],
    );
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
      'group_id': msgData['group_id'],
      'sender_name': msgData['sender_name'],
      'reply_to_uuid': msgData['reply_to_uuid'],
      'reply_to_text': msgData['reply_to_text'],
      'reaction': msgData['reaction'],
      'is_edited': (msgData['is_edited'] == true || msgData['is_edited'] == 1) ? 1 : 0,
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

    // File transfers re-save the same message_uuid (placeholder -> received);
    // only a genuinely new message may bump the unread counter.
    final existingMessage = await db.query('messages',
        columns: ['id'], where: 'message_uuid = ?', whereArgs: [uuid]);
    final isNewMessage = existingMessage.isEmpty;

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
      'group_id': msgData['group_id'],
      'sender_name': msgData['sender_name'],
      'reply_to_uuid': msgData['reply_to_uuid'],
      'reply_to_text': msgData['reply_to_text'],
      'reaction': msgData['reaction'],
      'is_edited': (msgData['is_edited'] == true || msgData['is_edited'] == 1) ? 1 : 0,
      'timestamp': timestamp,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    final groupId = msgData['group_id'] as String?;
    if (groupId != null) {
      await _updateGroupAfterMessage(
          db, groupId, content?.toString() ?? '', timestamp, isIncoming, isNewMessage);
      return id;
    }

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
          'is_hidden': 0,
          if (isIncoming && isNewMessage) 'unread_count': currentUnread + 1,
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
        'unread_count': (isIncoming && isNewMessage) ? 1 : 0,
      });
    }

    return id;
  }

  /// Edit message content in place (peer edit or local edit) and flag it.
  Future<void> updateMessageContent(String uuid, String newContent) async {
    final db = await instance.database;
    await db.update(
      'messages',
      {'content': newContent, 'is_edited': 1},
      where: 'message_uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// Set or clear (emoji == null) an emoji reaction on a message.
  Future<void> updateMessageReaction(String uuid, String? emoji) async {
    final db = await instance.database;
    await db.update(
      'messages',
      {'reaction': emoji},
      where: 'message_uuid = ?',
      whereArgs: [uuid],
    );
  }

  /// Wipe every chat's messages + media + pending outbox, while keeping
  /// contacts, groups and pairings fully intact.
  Future<void> clearAllChatHistory() async {
    final db = await instance.database;
    await _deleteMessagesWithFiles(db, '1 = 1', []);
    await db.delete('outbox');
    await db.update(
      'contacts',
      {
        'last_message': null,
        'last_timestamp': null,
        'unread_count': 0,
        'is_hidden': 0,
      },
    );
    try {
      await db.update(
        'groups',
        {
          'last_message': null,
          'last_timestamp': null,
          'unread_count': 0,
          'is_hidden': 0,
        },
      );
    } catch (_) {}
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
        'content': S.deletedMessage,
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

  Future<List<String>> cleanupExpiredMessages() async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = await db.query('messages',
        where: 'expires_at IS NOT NULL AND expires_at <= ?', whereArgs: [now]);
    if (expired.isEmpty) return const [];
    final uuids = <String>[];
    for (final m in expired) {
      final uuid = m['message_uuid']?.toString();
      if (uuid != null) uuids.add(uuid);
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
    // Tell open screens to drop these rows from their in-memory lists —
    // DB deletion alone leaves stale bubbles until the next manual reload.
    WebSocketService()
        .emitLocal({'type': 'messages_expired', 'uuids': uuids});
    return uuids;
  }

  /// Arm read-triggered ephemeral timers on the SENDER's copy once the
  /// peer's read_ack arrives — expires_at = read time + duration.
  Future<void> activateReadExpiry(List<String> uuids) async {
    if (uuids.isEmpty) return;
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final placeholders = List.filled(uuids.length, '?').join(',');
    await db.rawUpdate(
      "UPDATE messages SET expires_at = ? + expires_duration_ms "
      "WHERE expire_trigger = 'read' AND expires_at IS NULL "
      "AND expires_duration_ms IS NOT NULL "
      "AND message_uuid IN ($placeholders)",
      [now, ...uuids],
    );
  }

  /// Permanently delete a 1:1 conversation: all its messages, media files and
  /// queued outbox frames — then hide the chat. The pairing stays intact so
  /// the chat reappears automatically when a new message arrives.
  Future<void> deleteChatHistory(String peerId) async {
    final db = await instance.database;
    await _deleteMessagesWithFiles(
      db,
      '((sender_id = ? OR recipient_id = ?) AND group_id IS NULL)',
      [peerId, peerId],
    );

    // Drop queued frames addressed to this peer (skip group fan-out frames —
    // those carry a group_id and belong to group conversations).
    final pending = await db.query('outbox');
    for (final r in pending) {
      try {
        final payload = jsonDecode(r['payload'] as String);
        if (payload is Map &&
            payload['recipient_id'] == peerId &&
            payload['group_id'] == null) {
          await db.delete('outbox', where: 'id = ?', whereArgs: [r['id']]);
        }
      } catch (_) {}
    }

    await db.update(
      'contacts',
      {
        'is_hidden': 1,
        'last_message': null,
        'last_timestamp': null,
        'unread_count': 0,
      },
      where: 'id = ?',
      whereArgs: [peerId],
    );
  }

  /// Same as [deleteChatHistory] but for a group conversation.
  Future<void> deleteGroupChatHistory(String groupId) async {
    final db = await instance.database;
    await _deleteMessagesWithFiles(db, 'group_id = ?', [groupId]);

    final pending = await db.query('outbox');
    for (final r in pending) {
      try {
        final payload = jsonDecode(r['payload'] as String);
        if (payload is Map && payload['group_id'] == groupId) {
          await db.delete('outbox', where: 'id = ?', whereArgs: [r['id']]);
        }
      } catch (_) {}
    }

    await db.update(
      'groups',
      {
        'is_hidden': 1,
        'last_message': null,
        'last_timestamp': null,
        'unread_count': 0,
      },
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  Future<void> _deleteMessagesWithFiles(
      Database db, String where, List<Object?> whereArgs) async {
    final rows = await db.query('messages',
        columns: ['file_path'], where: where, whereArgs: whereArgs);
    for (final m in rows) {
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
    await db.delete('messages', where: where, whereArgs: whereArgs);
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

  /// Drop queued frame(s) for a message whose delivery_ack just arrived.
  Future<void> deleteOutboxByMessageUuid(String messageUuid) async {
    final db = await instance.database;
    await db.delete('outbox', where: 'message_uuid = ?', whereArgs: [messageUuid]);
  }

  // chat_message rows live in the outbox until the peer's delivery_ack
  // arrives — at-least-once delivery that survives relay restarts and
  // silent socket drops. The map throttles re-sends; clearing it (on every
  // fresh 'registered' connection) forces one immediate re-drive.
  static final Map<int, int> _lastRelayAttempt = {};
  static const _resendIntervalMs = 5 * 60 * 1000;
  static const _outboxMaxAgeMs = 24 * 60 * 60 * 1000;

  static void resetOutboxRetry() => _lastRelayAttempt.clear();

  static bool _outboxBusy = false;

  /// Process Outbox prioritized: Text/Control first, then media chunks
  Future<void> processOutbox() async {
    if (_outboxBusy) return;
    _outboxBusy = true;
    try {
      await _processOutboxInner();
    } finally {
      _outboxBusy = false;
    }
  }

  Future<void> _processOutboxInner() async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await db.query(
      'outbox',
      where: 'status != ?',
      whereArgs: ['failed'],
      orderBy: 'priority ASC, created_at ASC',
    );

    for (final r in rows) {
      final id = r['id'] as int;
      final payload = r['payload'] as String;
      final attempts = (r['attempts'] as int?) ?? 0;
      final rowStatus = r['status'] as String? ?? 'pending';
      final createdAt = (r['created_at'] as int?) ?? now;

      // Give up on frames older than the relay's own queue TTL.
      if (now - createdAt > _outboxMaxAgeMs) {
        await db.update('outbox', {'status': 'failed'},
            where: 'id = ?', whereArgs: [id]);
        continue;
      }

      try {
        if (!WebSocketService().isConnected) {
          continue;
        }
        final Map<String, dynamic> data = jsonDecode(payload);
        final isChatMessage = data['type'] == 'chat_message';
        if (data['type'] == 'offline_file') {
          final ciphertext = base64.decode(data['ciphertext_b64'] as String);
          final nonce = data['nonce'] as String;
          final mac = data['mac'] as String;
          final fileId = data['file_id'] as String;
          final sender = data['sender_id'] as String;
          final recipient = data['recipient_id'] as String;
          final origName = data['original_name'] as String? ?? '';
          final mediaType =
              (data['media_type'] as String?) ?? WaslMedia.typeFromName(origName);
          final chunkSize = (data['chunk_size'] as int?) ?? 64 * 1024;
          final totalChunks = (ciphertext.length / chunkSize).ceil();

          WebSocketService().sendData({
            'type': 'file_offer',
            'file_id': fileId,
            'sender_id': sender,
            'recipient_id': recipient,
            'original_name': origName,
            'media_type': mediaType,
            'total_chunks': totalChunks,
            'expires_at': data['expires_at'],
          });

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
              'media_type': mediaType,
            };
            WebSocketService().sendData(payloadChunk);
            await Future.delayed(const Duration(milliseconds: 15));
          }
          await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
        } else if (isChatMessage && rowStatus == 'sent') {
          // Already relayed once — awaiting the peer's delivery_ack. Re-send
          // sparingly (every reconnect clears the backoff map, then every
          // 5 min) so a relay restart that wiped its queue gets re-queued.
          final last = _lastRelayAttempt[id] ?? 0;
          if (now - last < _resendIntervalMs) continue;
          WebSocketService().sendData(data);
          _lastRelayAttempt[id] = now;
        } else {
          WebSocketService().sendData(data);
          _lastRelayAttempt[id] = now;
          if (isChatMessage) {
            // Keep the row until delivery_ack retires it by message_uuid.
            await db.update('outbox', {'status': 'sent', 'attempts': attempts + 1},
                where: 'id = ?', whereArgs: [id]);
          } else {
            await db.delete('outbox', where: 'id = ?', whereArgs: [id]);
          }
        }
      } catch (e) {
        await db.update('outbox', {'attempts': attempts + 1},
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
      if ((c['is_hidden'] as int?) == 1) continue;
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

  // ==================== Groups ====================

  Future<void> _updateGroupAfterMessage(Database db, String groupId,
      String content, String timestamp, bool isIncoming, bool isNew) async {
    final rows =
        await db.query('groups', where: 'id = ?', whereArgs: [groupId]);
    if (rows.isEmpty) return;
    final currentUnread = (rows.first['unread_count'] as int?) ?? 0;
    await db.update(
      'groups',
      {
        'last_message': content,
        'last_timestamp': timestamp,
        'is_hidden': 0,
        if (isIncoming && isNew) 'unread_count': currentUnread + 1,
      },
      where: 'id = ?',
      whereArgs: [groupId],
    );
  }

  Future<void> saveGroup({
    required String id,
    required String name,
    required String createdBy,
    required int createdAt,
  }) async {
    final db = await instance.database;
    await db.insert(
      'groups',
      {
        'id': id,
        'name': name,
        'created_by': createdBy,
        'created_at': createdAt,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getGroups() async {
    final db = await instance.database;
    final groups = await db
        .query('groups', where: 'is_hidden = 0 OR is_hidden IS NULL');
    final List<Map<String, dynamic>> results = [];
    for (final g in groups) {
      final merged = Map<String, dynamic>.from(g);
      merged['members'] = await getGroupMembers(g['id'].toString());
      results.add(merged);
    }
    results.sort((a, b) {
      final ta = a['last_timestamp']?.toString() ?? '';
      final tb = b['last_timestamp']?.toString() ?? '';
      return tb.compareTo(ta);
    });
    return results;
  }

  Future<Map<String, dynamic>?> getGroup(String groupId) async {
    final db = await instance.database;
    final rows =
        await db.query('groups', where: 'id = ?', whereArgs: [groupId]);
    if (rows.isEmpty) return null;
    final merged = Map<String, dynamic>.from(rows.first);
    merged['members'] = await getGroupMembers(groupId);
    return merged;
  }

  Future<void> saveGroupMember({
    required String groupId,
    required String memberId,
    String memberName = '',
    String role = 'member',
  }) async {
    final db = await instance.database;
    await db.insert(
      'group_members',
      {
        'group_id': groupId,
        'member_id': memberId,
        'member_name': memberName,
        'role': role,
        'added_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, dynamic>>> getGroupMembers(String groupId) async {
    final db = await instance.database;
    return await db.query('group_members',
        where: 'group_id = ?', whereArgs: [groupId]);
  }

  Future<void> removeGroupMember(String groupId, String memberId) async {
    final db = await instance.database;
    await db.delete('group_members',
        where: 'group_id = ? AND member_id = ?',
        whereArgs: [groupId, memberId]);
  }

  Future<void> deleteGroup(String groupId) async {
    final db = await instance.database;
    await db.delete('groups', where: 'id = ?', whereArgs: [groupId]);
    await db.delete('group_members',
        where: 'group_id = ?', whereArgs: [groupId]);
    await db.delete('messages',
        where: 'group_id = ?', whereArgs: [groupId]);
  }

  Future<List<Map<String, dynamic>>> getGroupMessages(String groupId) async {
    final db = await instance.database;
    return await db.query(
      'messages',
      where: 'group_id = ? AND is_deleted_for_everyone = 0',
      whereArgs: [groupId],
      orderBy: 'timestamp ASC',
    );
  }

  /// Mark unread incoming group messages as read and reset unread counter
  Future<List<String>> markGroupMessagesAsRead(
      String currentUserId, String groupId) async {
    final db = await instance.database;
    final now = DateTime.now().millisecondsSinceEpoch;

    final unread = await db.query(
      'messages',
      where: 'group_id = ? AND sender_id != ? AND is_read = 0',
      whereArgs: [groupId, currentUserId],
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

    await db.update('groups', {'unread_count': 0},
        where: 'id = ?', whereArgs: [groupId]);
    return readUuids;
  }

  /// Zeroize Database: wipe all contents permanently
  Future<void> secureZeroizeDatabase() async {
    final db = await instance.database;
    await db.delete('messages');
    await db.delete('contacts');
    await db.delete('outbox');
    try {
      await db.delete('groups');
      await db.delete('group_members');
    } catch (_) {}
    try {
      await db.execute('VACUUM');
    } catch (_) {}
  }
}
