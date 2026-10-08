import 'dart:async';
import '../core/l10n/s.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../core/audio/audio_recorder_service.dart';
import '../core/crypto/crypto_engine.dart';
import '../core/database/database_helper.dart';
import '../core/media/media_kind.dart';
import '../core/network/group_service.dart';
import '../core/network/websocket_service.dart';
import '../core/storage/storage_service.dart';
import '../core/theme/wasl_theme.dart';
import '../core/theme/wasl_widgets.dart';

/// Group conversation screen. Messages are encrypted once with the shared
/// AES-256 group key and fanned out to every member by [GroupService].
/// Incoming bubbles show the sender's display name above the text.
class GroupChatScreen extends StatefulWidget {
  final String currentUserId;
  final String groupId;

  const GroupChatScreen({
    super.key,
    required this.currentUserId,
    required this.groupId,
  });

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];

  String _groupName = '';
  List<Map<String, dynamic>> _members = [];
  String _connectionStatus = 'connecting';
  StreamSubscription? _statusSub;
  StreamSubscription? _msgSub;
  bool _isLoading = true;
  bool _isRecording = false;
  final AudioPlayer _audioPlayer = AudioPlayer();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _msgSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    _connectionStatus = WebSocketService().connectionState;
    _statusSub = WebSocketService().statusStream.listen((s) {
      if (mounted) setState(() => _connectionStatus = s);
    });

    final group = await DatabaseHelper.instance.getGroup(widget.groupId);
    if (group != null && mounted) {
      setState(() {
        _groupName = (group['name'] as String?) ?? S.group;
        _members =
            (group['members'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      });
    }

    await _loadHistory();

    _msgSub = WebSocketService().messageStream.listen((data) async {
      if (!mounted) return;
      if (data['type'] == 'group_message_local' &&
          data['group_id'] == widget.groupId) {
        await _loadHistory();
      }
      if (data['type'] == 'group_file_received_local' &&
          data['group_id'] == widget.groupId) {
        await _loadHistory();
      }
      if (data['type'] == 'group_leave_local' &&
          data['group_id'] == widget.groupId) {
        await _reloadMembers();
      }
      if (data['type'] == 'messages_expired') {
        await _loadHistory();
      }
    });
  }

  Future<void> _reloadMembers() async {
    _members = await DatabaseHelper.instance.getGroupMembers(widget.groupId);
    if (mounted) setState(() {});
  }

  Future<void> _loadHistory() async {
    final rows = await DatabaseHelper.instance.getGroupMessages(widget.groupId);
    final myId = widget.currentUserId.trim().toUpperCase();
    final List<Map<String, dynamic>> loaded = [];
    for (final m in rows) {
      final stored = m['content']?.toString() ?? '';
      final msgType = m['type']?.toString() ?? 'text';
      // Media rows store a plain '[type:name]' marker — only text carries the
      // ciphertext JSON blob that needs the group key.
      var clear = stored;
      if (msgType == 'text') {
        clear = await GroupService()
                .decryptGroupMessageBody(widget.groupId, stored) ??
            S.encryptedMessage;
      }
      loaded.add({
        ...m,
        'content': clear,
        'isMe': (m['sender_id'] as String?)?.trim().toUpperCase() == myId,
      });
    }
    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(loaded);
      _isLoading = false;
    });
    await DatabaseHelper.instance
        .markGroupMessagesAsRead(widget.currentUserId, widget.groupId);
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

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    await GroupService().sendGroupTextMessage(
      myId: widget.currentUserId,
      groupId: widget.groupId,
      plaintext: text,
    );
    await _loadHistory();
  }

  Future<void> _sendAttachment() async {
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    final file = result.single;
    final bytes = await file.readAsBytes();
    if (bytes.length > 100 * 1024 * 1024) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(S.fileTooLarge)),
      );
      return;
    }
    try {
      await GroupService().sendGroupFile(
        myId: widget.currentUserId,
        groupId: widget.groupId,
        fileBytes: bytes,
        originalName: file.name,
      );
      await _loadHistory();
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
    if (bytes.length > 10 * 1024 * 1024) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(      SnackBar(
          content: Text(S.audioTooLarge)));
      return;
    }
    try {
      await GroupService().sendGroupFile(
        myId: widget.currentUserId,
        groupId: widget.groupId,
        fileBytes: bytes,
        originalName: 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a',
      );
      await _loadHistory();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(S.audioSendFailed(e))));
    }
  }

  /// Resolves a stored file reference to an on-disk path (bare fileId or full
  /// `<dir>/<fileId>_<name>` path).
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

  /// Decrypts group media with the shared AES-256 group key.
  Future<Uint8List?> _decryptGroupMedia(String fileRef) async {
    try {
      final path = await _resolveMediaPath(fileRef);
      if (path == null) return null;
      final meta = jsonDecode(await File('$path.meta.json').readAsString());
      final cipher = await File(path).readAsBytes();
      final groupKeyB64 =
          await StorageService().getGroupKey(widget.groupId);
      if (groupKeyB64 == null) return null;
      final plain = await CryptoEngine().decryptBytes(
        cipherTextBase64: base64.encode(cipher),
        nonceBase64: meta['nonce'] as String,
        macBase64: meta['mac'] as String,
        sharedKey: SecretKey(base64.decode(groupKeyB64)),
      );
      return Uint8List.fromList(plain);
    } catch (_) {
      return null;
    }
  }

  Future<void> _playAudio(String fileRef) async {
    final plain = await _decryptGroupMedia(fileRef);
    if (!mounted) return;
    if (plain == null) {
      ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(S.audioPlayFailed)));
      return;
    }
    try {
      await _audioPlayer.play(BytesSource(plain));
    } catch (_) {}
  }

  /// Decrypts group media in memory then streams it to ANY destination the
  /// user picks via SAF — USB OTG flash, SD card, Downloads, cloud providers —
  /// without leaving a plaintext copy in app storage. No permission needed.
  Future<void> _exportGroupFile(String fileRef, String fileName) async {
    final plain = await _decryptGroupMedia(fileRef);
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

  String _formatTime(dynamic ts) {
    final ms = _tsMs(ts);
    if (ms == 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
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

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            const CircleAvatar(
              radius: 19,
              backgroundColor: WaslColors.foreground,
              child:
                  Icon(Icons.groups_rounded, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _groupName.isEmpty ? S.group : _groupName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      const Icon(Icons.lock,
                          size: 11, color: WaslColors.primary),
                      const SizedBox(width: 3),
                      Text(
                        S.membersCountEncrypted(_members.length),
                        style: const TextStyle(
                            fontSize: 11, color: WaslColors.primary),
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
            icon: const Icon(Icons.more_vert),
            onPressed: _showGroupMenu,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_connectionStatus != 'connected')
            Container(
              width: double.infinity,
              color: Colors.amber[800],
              padding:
                  const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              child:       Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  SizedBox(width: 8),
                  Text(
                    S.offlineQueueGroup,
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child:
                        CircularProgressIndicator(color: WaslColors.primary))
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.groups_rounded,
                                size: 64,
                                color: isDark
                                    ? WaslColors.darkMutedForeground
                                    : Colors.grey[400]),
                            const SizedBox(height: 12),
                                  Text(
                              S.firstGroupMessage,
                              style: TextStyle(
                                  color: WaslColors.mutedFg(context)),
                            ),
                          ],
                        ),
                      )
                    : SelectionArea(
                        child: ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          padding: const EdgeInsets.all(16),
                          itemCount: _messages.length,
                          itemBuilder: (context, i) {
                            // reverse:true → visual 0 is the newest message;
                            // the day pill sits above the first message of
                            // each new day (realIndex 0 = oldest).
                            final realIndex = _messages.length - 1 - i;
                            final m = _messages[realIndex];
                            final showDayHeader = realIndex == 0 ||
                                !_isSameDay(
                                    _tsMs(_messages[realIndex - 1]
                                        ['timestamp']),
                                    _tsMs(m['timestamp']));
                            return Column(
                              children: [
                                if (showDayHeader)
                                  _dayHeader(
                                      _dayLabel(_tsMs(m['timestamp'])),
                                      isDark),
                                _buildBubble(m, isDark),
                              ],
                            );
                          },
                        ),
                      ),
          ),
          _buildComposer(isDark),
        ],
      ),
    );
  }

  Widget _buildBubble(Map<String, dynamic> m, bool isDark) {
    final isMe = m['isMe'] == true;
    final senderName = (m['sender_name'] as String?)?.trim();
    final senderId = (m['sender_id'] as String?) ?? '';
    final shownSender =
        (senderName != null && senderName.isNotEmpty) ? senderName : senderId;

    return MessageIn(
      child: Align(
        // In RTL the parent's directionality flips these correctly
        alignment:
            isMe ? Alignment.centerLeft : Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          decoration: BoxDecoration(
            color: isMe
                ? WaslColors.primary
                : (isDark ? WaslColors.darkCard : Colors.white),
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
            children: [
              if (!isMe)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    shownSender,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: WaslColors.avatarColorFor(senderId),
                    ),
                  ),
                ),
              _buildMessageBody(m, isMe, isDark),
              const SizedBox(height: 3),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTime(m['timestamp']),
                    style: TextStyle(
                      fontSize: 10,
                      color: isMe
                          ? Colors.white70
                          : WaslColors.mutedFg(context),
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      _statusIcon(m['status']),
                      size: 13,
                      color: Colors.white70,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Bubble body by message type: playable voice note, image preview,
  /// openable file card, or plain text.
  Widget _buildMessageBody(Map<String, dynamic> m, bool isMe, bool isDark) {
    final type = m['type']?.toString() ?? 'text';
    final content = m['content']?.toString() ?? '';
    final textColor = isMe
        ? Colors.white
        : (isDark ? WaslColors.darkForeground : WaslColors.foreground);
    final fileRef = m['file_path']?.toString();

    if (type == 'audio') {
      final canPlay = fileRef != null && fileRef.isNotEmpty;
      return GestureDetector(
        onTap: canPlay ? () => _playAudio(fileRef) : null,
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
            Text(S.voiceMessage,
                style: TextStyle(fontSize: 13, color: textColor)),
          ],
        ),
      );
    }

    if (type == 'image') {
      return _GroupImageBubble(
        fileRef: fileRef,
        loader: _decryptGroupMedia,
        fallbackName: WaslMedia.displayName(content),
      );
    }

    if (type == 'file') {
      final rawName = WaslMedia.displayName(content);
      final canOpen = fileRef != null && fileRef.isNotEmpty;
      return GestureDetector(
        onTap: canOpen ? () => _exportGroupFile(fileRef, rawName) : null,
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

    return Text(content, style: TextStyle(fontSize: 14, color: textColor));
  }

  IconData _statusIcon(String? status) {
    switch (status) {
      case 'read':
      case 'delivered':
        return Icons.done_all;
      case 'pending':
        return Icons.schedule;
      default:
        return Icons.check;
    }
  }

  Widget _buildComposer(bool isDark) {
    return SafeArea(
      top: false,
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Row(
          children: [
            WaslRoundIconButton(
                icon: Icons.attach_file, onTap: _sendAttachment),
            const SizedBox(width: 8),
            Expanded(
              child: _isRecording
                  ? Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color:
                            isDark ? WaslColors.darkMuted : WaslColors.muted,
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
                      onSubmitted: (_) => _send(),
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
              child: const WaslRoundIconButton(icon: Icons.mic_none),
            ),
            const SizedBox(width: 8),
            WaslRoundIconButton(
                icon: Icons.send, filled: true, onTap: _send),
          ],
        ),
      ),
    );
  }

  void _showGroupMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.people_outline,
                  color: WaslColors.primary),
              title:       Text(S.groupMembers),
              onTap: () {
                Navigator.pop(ctx);
                _showMembersSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.exit_to_app,
                  color: WaslColors.destructive),
              title:       Text(S.leaveGroup),
              onTap: () async {
                Navigator.pop(ctx);
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (dctx) => AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18)),
                    title:       Text(S.leaveGroupConfirm),
                    content:       Text(
                        S.leaveGroupWarning),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, false),
                        child:       Text(S.cancel),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, true),
                        child:       Text(S.leave,
                            style:
                                TextStyle(color: WaslColors.destructive)),
                      ),
                    ],
                  ),
                );
                if (confirm == true && mounted) {
                  await GroupService().leaveGroup(
                    myId: widget.currentUserId,
                    groupId: widget.groupId,
                  );
                  if (mounted) Navigator.pop(context);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showMembersSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: _members.map((m) {
            final name = (m['member_name'] as String?)?.trim();
            final id = (m['member_id'] as String?) ?? '';
            final isAdmin = (m['role'] as String?) == 'admin';
            final display =
                (name != null && name.isNotEmpty) ? name : id;
            return ListTile(
              leading: WaslAvatar(
                color: WaslColors.avatarColorFor(id),
                initials: display.substring(0, 1).toUpperCase(),
                size: 40,
              ),
              title: Text(display),
              subtitle: Text(
                id,
                textDirection: TextDirection.ltr,
                style: TextStyle(
                    fontSize: 11,
                    color: WaslColors.mutedFg(context)),
              ),
              trailing: isAdmin
                  ?       Chip(
                      label: Text(S.admin,
                          style: TextStyle(fontSize: 11)),
                      backgroundColor: WaslColors.accent,
                    )
                  : null,
            );
          }).toList(),
        ),
      ),
    );
  }
}

/// Group image preview decrypted once with the shared group key.
class _GroupImageBubble extends StatefulWidget {
  final String? fileRef;
  final Future<Uint8List?> Function(String fileRef) loader;
  final String fallbackName;

  const _GroupImageBubble({
    required this.fileRef,
    required this.loader,
    required this.fallbackName,
  });

  @override
  State<_GroupImageBubble> createState() => _GroupImageBubbleState();
}

class _GroupImageBubbleState extends State<_GroupImageBubble> {
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
            errorBuilder: (_, __, ___) => _fallback(),
          ),
        ),
      );
    }
    if (_failed) return _fallback();
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

  Widget _fallback() {
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
