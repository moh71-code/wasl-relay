import 'dart:async';
import '../core/l10n/s.dart';
import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import '../core/crypto/crypto_engine.dart';
import '../core/crypto/pairing_service.dart';
import '../core/database/database_helper.dart';
import '../core/media/media_kind.dart';
import '../core/network/group_service.dart';
import '../core/network/websocket_service.dart';
import '../core/storage/storage_service.dart';
import '../core/theme/wasl_theme.dart';
import '../core/theme/wasl_widgets.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'settings_screen.dart';
import 'qr_scanner_screen.dart';

/// Main screen — conversations list with the official WASL identity:
/// logo + "وَصْل" + encrypted badge, search, add-member / create-group
/// actions, and conversation tiles (1:1 + groups).
class ChatsListScreen extends StatefulWidget {
  final String currentUserId;

  const ChatsListScreen({super.key, required this.currentUserId});

  @override
  State<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends State<ChatsListScreen> {
  final WebSocketService _wsService = WebSocketService();
  List<Map<String, dynamic>> _contacts = [];
  List<Map<String, dynamic>> _groups = [];
  bool _isLoading = true;
  String _connectionStatus = 'connected';
  String _query = '';
  StreamSubscription? _statusSub;
  StreamSubscription? _msgSub;
  StreamSubscription? _pairSubscription;

  @override
  void initState() {
    super.initState();
    _connectionStatus = _wsService.connectionState;
    _statusSub = _wsService.statusStream.listen((status) {
      if (mounted) setState(() => _connectionStatus = status);
    });
    _initNetworkAndLoadContacts();
    _listenForPairingRequests();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _msgSub?.cancel();
    _pairSubscription?.cancel();
    super.dispose();
  }

  void _listenForPairingRequests() {
    _pairSubscription = WebSocketService().messageStream.listen((data) async {
      if (!mounted) return;
      final msgType = data['type'];
      final myId = widget.currentUserId.trim().toUpperCase();
      final recipient = (data['recipient_id'] as String?)?.trim().toUpperCase();
      if (recipient != null && recipient != myId) return;

      if (msgType == 'pair_request') {
        _showPairingDialogWithData(data);
      } else if (msgType == 'pair_accept') {
        final senderId = (data['sender_id'] as String?)?.trim().toUpperCase();
        final ok = await PairingService()
            .handlePairAccept(data, expectedRecipientId: myId);
        if (ok && senderId != null) {
          final peerName = (data['display_name'] as String?)?.trim();
          DatabaseHelper.instance.saveContact(
            senderId,
            peerName != null && peerName.isNotEmpty ? peerName : senderId,
            'connected',
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(S.pairingAcceptedFrom(peerName ?? senderId)),
              backgroundColor: WaslColors.primary,
            ),
          );
          final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
          if (isCurrent) _openChat(senderId);
        }
      }
    });
  }

  void _showPairingDialogWithData(Map<String, dynamic> data) async {
    final senderId = (data['sender_id'] as String?)?.trim();
    if (senderId == null || senderId.isEmpty) return;

    final expiresAt = (data['expires_at'] as num?)?.toInt();
    if (expiresAt != null &&
        DateTime.now().millisecondsSinceEpoch > expiresAt) {
      return;
    }

    final peerEd = data['ed25519'] as String?;
    final peerX = data['x25519'] as String?;
    try {
      final sig = data['signature'] as String?;
      if (peerEd == null || peerX == null || sig == null) return;

      // Verify the signature BEFORE trusting anything — and never write keys
      // to storage until the user explicitly accepts below.
      final payload = jsonEncode(PairingService.canonicalPayload(
        type: 'pair_request',
        senderId: senderId,
        recipientId: data['recipient_id'] as String,
        x25519: peerX,
        ed25519: peerEd,
        requestId: data['request_id'] as String?,
        challenge: data['challenge'] as String?,
        expiresAt: (data['expires_at'] as num?)?.toInt(),
        displayName: data['display_name'] as String?,
      ));
      final ok = await PairingService().verify(
          utf8.encode(payload), base64.decode(sig), base64.decode(peerEd));
      if (!ok) return;

      // Reject key rotation on an already-paired contact — a MITM attempt
      // looks exactly like this; re-pairing must start from the user's side.
      final existingEd = await StorageService().getEdPublicKey(senderId);
      if (existingEd != null && existingEd != peerEd) return;
    } catch (_) {
      return;
    }

    if (!mounted) return;

    final peerDisplayName = (data['display_name'] as String?)?.trim();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title:       Text(S.newPairRequest),
        content: Text(
          peerDisplayName != null && peerDisplayName.isNotEmpty
              ? S.pairRequestNamed(peerDisplayName, senderId)
              : S.pairRequestDevice(senderId),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              WebSocketService().sendData({
                'type': 'pair_reject',
                'sender_id': widget.currentUserId,
                'recipient_id': senderId,
              });
            },
            child:       Text(S.reject,
                style: TextStyle(color: WaslColors.destructive)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: WaslColors.primary),
            onPressed: () async {
              Navigator.pop(context);
              await PairingService()
                  .ensureIdentityKeys(widget.currentUserId);
              // Persist the verified keys only now — the user consented.
              await StorageService().saveEdPublicKey(senderId, peerEd);
              await StorageService().saveXPublicKey(senderId, peerX);
              await PairingService().deriveAndStoreSessionKey(
                  myUserId: widget.currentUserId,
                  peerId: senderId,
                  peerXPublicBytes: base64Decode(peerX));

              await DatabaseHelper.instance.saveContact(
                senderId,
                peerDisplayName != null && peerDisplayName.isNotEmpty
                    ? peerDisplayName
                    : senderId,
                'connected',
              );

              final pubs = await PairingService()
                  .getLocalPublicKeys(widget.currentUserId);
              final myDisplayName =
                  await StorageService().getDisplayName();
              final freshExpiry = DateTime.now()
                  .add(const Duration(minutes: 5))
                  .millisecondsSinceEpoch;
              final payload = PairingService.canonicalPayload(
                type: 'pair_accept',
                senderId: widget.currentUserId,
                recipientId: senderId,
                x25519: pubs['x25519']!,
                ed25519: pubs['ed25519']!,
                requestId: data['request_id'] as String?,
                challenge: data['challenge'] as String?,
                expiresAt: freshExpiry,
                displayName: myDisplayName,
              );
              final sig = await PairingService().sign(
                  widget.currentUserId, utf8.encode(jsonEncode(payload)));
              WebSocketService()
                  .sendData({...payload, 'signature': base64Encode(sig)});

              _openChat(senderId);
            },
            child:       Text(S.acceptConnect),
          ),
        ],
      ),
    );
  }

  Future<void> _initNetworkAndLoadContacts() async {
    _msgSub = _wsService.messageStream.listen((data) async {
      final t = data['type'];
      if (t == 'message_received' ||
          t == 'new_message' ||
          t == 'chat_message' ||
          t == 'message_ingested' ||
          t == 'message' ||
          t == 'read_ack' ||
          t == 'delivery_ack' ||
          t == 'file_received' ||
          t == 'file_offer' ||
          t == 'group_message' ||
          t == 'group_message_local' ||
          t == 'group_invite_local' ||
          t == 'group_leave_local' ||
          t == 'messages_expired' ||
          t == 'pair_accept') {
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

  String _getDisplayName(Map<String, dynamic> contact) {
    final id = _getRecipientId(contact);
    final name = (contact['name'] as String?)?.trim();
    if (name != null &&
        name.isNotEmpty &&
        name.toUpperCase() != id.toUpperCase()) {
      return name;
    }
    return id;
  }

  String _getDecryptedLastMessage(Map<String, dynamic> contact) {
    final display = contact['display_last_message'];
    if (display != null && display.toString().trim().isNotEmpty) {
      return display.toString();
    }

    final rawMessage = contact['last_message'];
    if (rawMessage == null || rawMessage.toString().trim().isEmpty) {
      return S.noMessages;
    }

    try {
      final parsed = jsonDecode(rawMessage.toString());
      final cipher = parsed['ciphertext'] as String?;
      if (cipher == null) return rawMessage.toString();
      return S.encryptedMessage;
    } catch (_) {
      final kind =
          WaslMedia.typeFromContent('text', rawMessage.toString());
      if (kind == 'audio') return S.voiceMessageEnc;
      if (kind == 'image') return S.imageEnc;
      if (kind == 'file') return S.fileEnc;
      return rawMessage.toString();
    }
  }

  Future<void> _loadContacts() async {
    final contacts = await DatabaseHelper.instance
        .getContactsWithLatestMessages(widget.currentUserId);
    if (!mounted) return;

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
              final secretKey = SecretKey(base64.decode(sessionB64));
              final clear = await CryptoEngine().decryptMessage(
                cipherTextBase64: cipher,
                nonceBase64: nonce,
                macBase64: mac,
                sharedKey: secretKey,
              );
              c['display_last_message'] = clear;
            } else {
              c['display_last_message'] = S.encryptedMessage;
            }
          }
        }
      } catch (_) {}
    }

    // Load groups and decrypt their last-message previews
    final groups = await DatabaseHelper.instance.getGroups();
    for (var g in groups) {
      try {
        final raw = g['last_message'];
        if (raw != null && raw.toString().isNotEmpty) {
          final clear = await GroupService()
              .decryptGroupMessageBody(g['id'].toString(), raw.toString());
          g['display_last_message'] = clear ?? S.encryptedMessage;
        }
      } catch (_) {
        g['display_last_message'] = S.encryptedMessage;
      }
    }
    if (!mounted) return;
    setState(() {
      _contacts = contacts;
      _groups = groups;
      _isLoading = false;
    });
  }

  /// Unified, time-sorted list of 1:1 chats and groups.
  List<Map<String, dynamic>> get _mergedChats {
    final items = <Map<String, dynamic>>[];
    for (final c in _contacts) {
      items.add({...c, 'is_group': false});
    }
    for (final g in _groups) {
      items.add({...g, 'is_group': true});
    }
    items.sort((a, b) {
      final ta = a['last_timestamp'] is int
          ? a['last_timestamp'] as int
          : int.tryParse(a['last_timestamp']?.toString() ?? '') ?? 0;
      final tb = b['last_timestamp'] is int
          ? b['last_timestamp'] as int
          : int.tryParse(b['last_timestamp']?.toString() ?? '') ?? 0;
      return tb.compareTo(ta);
    });
    if (_query.isEmpty) return items;
    final q = _query.trim();
    return items.where((i) {
      final name = (i['name'] as String?) ?? '';
      final id = (i['id'] as String?) ?? '';
      return name.contains(q) || id.toUpperCase().contains(q.toUpperCase());
    }).toList();
  }

  /// Long-press on a chat: bottom sheet with a "Delete chat" action.
  /// Deletes all local messages + media for that peer/group and hides the
  /// chat; the pairing itself stays intact.
  void _showChatOptions(String id, String displayName, bool isGroup) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: WaslColors.mutedFg(context).withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: Colors.red),
              title: Text(S.deleteChat,
                  style: const TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w600)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDeleteChat(id, isGroup);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteChat(String id, bool isGroup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(S.deleteChatConfirm),
        content: Text(S.deleteChatWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.cancel),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(S.delete,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (isGroup) {
      await DatabaseHelper.instance.deleteGroupChatHistory(id);
    } else {
      await DatabaseHelper.instance.deleteChatHistory(id);
    }
    await _loadContacts();
  }

  void _openChat(String recipientId) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          currentUserId: widget.currentUserId,
          recipientId: recipientId,
        ),
      ),
    ).then((_) => _loadContacts());
  }

  /// Bottom sheet for entering a member code (validated) + QR scan option.
  void _showInviteSheet() {
    final controller = TextEditingController();
    final codeReg = RegExp(r'^[A-Z0-9-]{6,20}$');
    String? error;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surface,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(24)),
                ),
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: WaslColors.border,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                          Text(
                      S.addMemberByCode,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                          Text(
                      S.addMemberHint,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13,
                          color: WaslColors.mutedFg(context)),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: controller,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        hintText: 'WASL-XXXX',
                        errorText: error,
                        filled: true,
                        fillColor: WaslColors.muted,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextButton.icon(
                      onPressed: () async {
                        Navigator.pop(sheetCtx);
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => QrScannerScreen(
                                currentUserId: widget.currentUserId),
                          ),
                        );
                        _loadContacts();
                      },
                      icon: const Icon(Icons.qr_code_scanner,
                          color: WaslColors.primary, size: 20),
                      label:       Text(S.scanQr,
                          style: TextStyle(color: WaslColors.primary)),
                    ),
                    const SizedBox(height: 6),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: WaslColors.primary,
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () async {
                        final code =
                            controller.text.trim().toUpperCase();
                        if (!codeReg.hasMatch(code)) {
                          setSheetState(
                              () => error = S.invalidCode);
                          return;
                        }
                        Navigator.pop(sheetCtx);
                        await DatabaseHelper.instance.saveContact(
                            code, code, 'pending_approval');
                        await PairingService().sendPairRequest(
                            myId: widget.currentUserId,
                            targetId: code);
                        _loadContacts();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content:
                                    Text(S.requestSentTo(code))),
                          );
                        }
                      },
                      child:       Text(S.sendRequest),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatTime(dynamic timestamp) {
    final ms = timestamp is int
        ? timestamp
        : int.tryParse(timestamp?.toString() ?? '') ?? 0;
    if (ms == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inDays == 0 &&
        date.day == now.day &&
        date.month == now.month) {
      return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays < 2 &&
        now.day - date.day == 1 &&
        date.month == now.month) {
      return S.yesterday;
    } else if (diff.inDays < 7) {
      return S.weekdays[date.weekday - 1];
    } else {
      return '${date.day}/${date.month}/${date.year}';
    }
  }

  // ==================== UI ====================

  @override
  Widget build(BuildContext context) {
    final items = _mergedChats;

    return Scaffold(
      body: SafeArea(
        child: ScreenIn(
          child: Column(
            children: [
              _buildHeader(context),
              _buildSearch(),
              _buildActionsRow(context),
              const Divider(),
              Expanded(
                child: _isLoading
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: WaslColors.primary))
                    : items.isEmpty
                        ? _buildEmptyState()
                        : ListView.separated(
                            itemCount: items.length,
                            separatorBuilder: (_, __) =>
                                const Divider(indent: 84),
                            itemBuilder: (context, i) {
                              final item = items[i];
                              return item['is_group'] == true
                                  ? _buildGroupTile(item)
                                  : _buildContactTile(item);
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const WaslLogo(size: 40),
          const SizedBox(width: 10),
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'وَصْل',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              EncryptedBadge(),
            ],
          ),
          const Spacer(),
          // Connection indicator
          if (_connectionStatus != 'connected')
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(Icons.cloud_off,
                  size: 18, color: WaslColors.destructive),
            ),
          IconButton(
            tooltip: S.myIdentity,
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) =>
                    QrDisplayDialog(userId: widget.currentUserId),
              );
            },
            icon: const Icon(Icons.qr_code_2),
          ),
          IconButton(
            tooltip: S.settings,
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const SettingsScreen()),
              );
            },
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildSearch() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          hintText: S.searchChats,
          prefixIcon: const Icon(Icons.search, size: 20),
          filled: true,
          fillColor:
              isDark ? WaslColors.darkMuted : WaslColors.muted,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _buildActionsRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: WaslColors.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: _showInviteSheet,
              icon: const Icon(Icons.person_add_alt_1, size: 18),
              label:       Text(S.addMemberByCode),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: WaslColors.primary,
                side: const BorderSide(color: WaslColors.primary),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CreateGroupScreen(
                        currentUserId: widget.currentUserId),
                  ),
                ).then((_) => _loadContacts());
              },
              icon: const Icon(Icons.group_add_outlined, size: 18),
              label:       Text(S.createGroup),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 110,
            height: 110,
            decoration: const BoxDecoration(
              color: WaslColors.accent,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.phonelink_lock,
                size: 52, color: WaslColors.primary),
          ),
          const SizedBox(height: 24),
                Text(
            S.noConnections,
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: WaslColors.fg(context)),
          ),
          const SizedBox(height: 8),
                Text(
            S.noConnectionsHint,
            style: TextStyle(
                fontSize: 14, color: WaslColors.mutedFg(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildContactTile(Map<String, dynamic> contact) {
    final recipientId = _getRecipientId(contact);
    final displayName = _getDisplayName(contact);
    final lastMessage = _getDecryptedLastMessage(contact);
    final unreadCount = (contact['unread_count'] as int?) ?? 0;
    final ts = contact['last_timestamp'];
    final timeStr = _formatTime(ts);
    final avatarColor = WaslColors.avatarColorFor(recipientId);
    final initial =
        displayName.isNotEmpty ? displayName[0].toUpperCase() : '?';

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: () => _openChat(recipientId),
      onLongPress: () => _showChatOptions(recipientId, displayName, false),
      leading: Stack(
        children: [
          WaslAvatar(
              color: avatarColor, initials: initial, size: 52),
          if (_connectionStatus == 'connected')
            Positioned(
              bottom: 0,
              left: 0,
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: const Color(0xFF2FBF9B),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: Colors.white, width: 2),
                ),
              ),
            ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            timeStr,
            style: TextStyle(
                fontSize: 12, color: WaslColors.mutedFg(context)),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          const Icon(Icons.lock,
              size: 13, color: WaslColors.primary),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              lastMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  color: WaslColors.mutedFg(context)),
            ),
          ),
          if (unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: WaslColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$unreadCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGroupTile(Map<String, dynamic> group) {
    final groupId = (group['id'] as String?) ?? '';
    final name = (group['name'] as String?)?.trim();
    final displayName =
        (name != null && name.isNotEmpty) ? name : S.group;
    final unreadCount = (group['unread_count'] as int?) ?? 0;
    final lastMessage = (group['display_last_message'] as String?) ??
        (group['last_message']?.toString() ?? '');
    final preview =
        lastMessage.isEmpty ? S.noMessages : lastMessage;
    final timeStr = _formatTime(group['last_timestamp']);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupChatScreen(
              currentUserId: widget.currentUserId,
              groupId: groupId,
            ),
          ),
        ).then((_) => _loadContacts());
      },
      onLongPress: () => _showChatOptions(groupId, displayName, true),
      leading: const CircleAvatar(
        radius: 26,
        backgroundColor: WaslColors.foreground,
        child: Icon(Icons.groups_rounded,
            color: Colors.white, size: 26),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              displayName,
              style: const TextStyle(
                  fontWeight: FontWeight.w700, fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            timeStr,
            style: TextStyle(
                fontSize: 12, color: WaslColors.mutedFg(context)),
          ),
        ],
      ),
      subtitle: Row(
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4),
            child: Icon(Icons.group,
                size: 14, color: WaslColors.primary),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 13,
                  color: WaslColors.mutedFg(context)),
            ),
          ),
          if (unreadCount > 0)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(
                  horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: WaslColors.primary,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$unreadCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
