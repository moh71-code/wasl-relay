import 'package:flutter/material.dart';
import '../core/l10n/s.dart';
import '../core/database/database_helper.dart';
import '../core/network/group_service.dart';
import '../core/theme/wasl_theme.dart';
import '../core/theme/wasl_widgets.dart';
import 'group_chat_screen.dart';

/// Group creation flow: name the group, then pick already-paired contacts
/// as members. Only verified (paired) contacts can be added so the shared
/// group key is always distributed over an existing E2E channel.
class CreateGroupScreen extends StatefulWidget {
  final String currentUserId;

  const CreateGroupScreen({super.key, required this.currentUserId});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final TextEditingController _nameController = TextEditingController();
  List<Map<String, dynamic>> _contacts = [];
  final Set<String> _selected = {};
  bool _isLoading = true;
  bool _isCreating = false;

  bool get _canCreate =>
      _nameController.text.trim().isNotEmpty && _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    final contacts = await DatabaseHelper.instance.getContacts();
    if (!mounted) return;
    setState(() {
      _contacts = contacts
          .where((c) =>
              (c['status'] ?? '').toString() == 'accepted' ||
              (c['status'] ?? '').toString() == 'connected')
          .toList();
      _isLoading = false;
    });
  }

  Future<void> _createGroup() async {
    if (!_canCreate || _isCreating) return;
    setState(() => _isCreating = true);

    final memberMap = <String, String>{};
    for (final c in _contacts) {
      final id = (c['id'] as String?) ?? '';
      if (_selected.contains(id)) {
        final cname = (c['name'] as String?)?.trim();
        memberMap[id] = (cname != null && cname.isNotEmpty) ? cname : id;
      }
    }

    final groupId = await GroupService().createGroup(
      myId: widget.currentUserId,
      name: _nameController.text.trim(),
      members: memberMap,
    );

    if (!mounted) return;
    setState(() => _isCreating = false);

    if (groupId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(S.groupCreateFailed)),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => GroupChatScreen(
          currentUserId: widget.currentUserId,
          groupId: groupId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title:       Text(S.createGroup,
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: ScreenIn(
        child: Column(
          children: [
            // Group name field
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _nameController,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: S.groupNameHint,
                  prefixIcon: const Icon(Icons.group_outlined),
                  filled: true,
                  fillColor: isDark
                      ? WaslColors.darkMuted
                      : WaslColors.muted,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),

            // Section label
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  _selected.isEmpty
                      ? S.pickMembers
                      : S.pickMembersCount(_selected.length),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: WaslColors.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Contact multi-select list
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: WaslColors.primary))
                  : _contacts.isEmpty
                      ?       Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text(
                              S.noContacts,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  color: WaslColors.mutedFg(context),
                                  fontSize: 15,
                                  height: 1.6),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _contacts.length,
                          itemBuilder: (context, i) {
                            final c = _contacts[i];
                            final id = (c['id'] as String?) ?? '';
                            final name =
                                (c['name'] as String?)?.trim();
                            final display =
                                (name != null && name.isNotEmpty)
                                    ? name
                                    : id;
                            final isSelected = _selected.contains(id);

                            return CheckboxListTile(
                              secondary: WaslAvatar(
                                color: WaslColors.avatarColorFor(id),
                                initials: display.isNotEmpty
                                    ? display[0].toUpperCase()
                                    : '?',
                                size: 44,
                              ),
                              title: Text(
                                display,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14),
                              ),
                              subtitle: Text(
                                id,
                                textDirection: TextDirection.ltr,
                                style: TextStyle(
                                    fontSize: 12,
                                    color:
                                        WaslColors.mutedFg(context)),
                              ),
                              value: isSelected,
                              activeColor: WaslColors.primary,
                              onChanged: (v) => setState(() {
                                v == true
                                    ? _selected.add(id)
                                    : _selected.remove(id);
                              }),
                            );
                          },
                        ),
            ),

            // Create button
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: WaslColors.primary,
                      disabledBackgroundColor: isDark
                          ? WaslColors.darkMuted
                          : WaslColors.muted,
                      padding: const EdgeInsets.symmetric(
                          vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed:
                        _canCreate && !_isCreating ? _createGroup : null,
                    icon: _isCreating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2))
                        : const Icon(Icons.check),
                    label: Text(
                      _selected.isEmpty
                          ? S.createGroupBtn
                          : S.createGroupBtnCount(_selected.length),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
