import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/reliable_group.dart';
import '../services/reliable_group_codec.dart';
import '../services/reliable_group_service.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/empty_state.dart';
import '../widgets/qr_code_display.dart';
import '../widgets/qr_scanner_widget.dart';
import 'reliable_group_chat_screen.dart';

class ReliableGroupsScreen extends StatefulWidget {
  const ReliableGroupsScreen({super.key});

  @override
  State<ReliableGroupsScreen> createState() => _ReliableGroupsScreenState();
}

class _ReliableGroupsScreenState extends State<ReliableGroupsScreen>
    with DisconnectNavigationMixin {
  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final service = context.watch<ReliableGroupService>();
    if (!checkConnectionAndNavigate(connector)) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.reliableGroup_title),
        centerTitle: true,
      ),
      floatingActionButton: service.isSupported
          ? FloatingActionButton(
              onPressed: () => _showAddMenu(context),
              tooltip: l10n.reliableGroup_create,
              child: const Icon(Icons.add),
            )
          : null,
      body: !service.isSupported
          ? EmptyState(
              icon: Icons.verified_user_outlined,
              title: l10n.reliableGroup_title,
              subtitle: l10n.reliableGroup_unsupported,
            )
          : service.groups.isEmpty
          ? EmptyState(
              icon: Icons.verified_user_outlined,
              title: l10n.reliableGroup_empty,
              subtitle: l10n.reliableGroup_emptyHint,
            )
          : ListView(
              children: [
                for (final group in service.groups)
                  _GroupTile(group: group, service: service),
              ],
            ),
    );
  }

  void _showAddMenu(BuildContext context) {
    final l10n = context.l10n;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.group_add),
              title: Text(l10n.reliableGroup_create),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ReliableGroupCreateScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.qr_code_scanner),
              title: Text(l10n.reliableGroup_joinScan),
              onTap: () {
                Navigator.pop(sheetContext);
                _scanInvite(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste),
              title: Text(l10n.reliableGroup_joinPaste),
              onTap: () {
                Navigator.pop(sheetContext);
                _pasteInvite(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _scanInvite(BuildContext context) async {
    final code = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _InviteScannerScreen()),
    );
    if (code != null && context.mounted) await _join(context, code);
  }

  Future<void> _pasteInvite(BuildContext context) async {
    final controller = TextEditingController();
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    // Prefill a copied invite, selected, so pasting it again replaces it.
    final copied = clipboard?.text ?? '';
    if (ReliableGroup.fromInviteCode(copied) != null) {
      controller.value = TextEditingValue(
        text: copied,
        selection: TextSelection(baseOffset: 0, extentOffset: copied.length),
      );
    }
    if (!context.mounted) return;
    final l10n = context.l10n;
    final code = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.reliableGroup_joinPaste),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: l10n.reliableGroup_invitePasteHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(l10n.common_add),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code != null && context.mounted) await _join(context, code);
  }

  Future<void> _join(BuildContext context, String code) async {
    final l10n = context.l10n;
    final group = ReliableGroup.fromInviteCode(code);
    if (group == null) {
      showDismissibleSnackBar(
        context,
        content: Text(l10n.reliableGroup_invalidInvite),
      );
      return;
    }
    final result = await context.read<ReliableGroupService>().addGroup(group);
    if (!context.mounted) return;
    showDismissibleSnackBar(
      context,
      content: Text(switch (result) {
        ReliableGroupAddResult.added => l10n.reliableGroup_joined(group.name),
        ReliableGroupAddResult.notAMember => l10n.reliableGroup_notAMember,
        ReliableGroupAddResult.noFreeChannelSlot =>
          l10n.reliableGroup_noFreeChannel,
      }),
    );
  }
}

class _GroupTile extends StatelessWidget {
  final ReliableGroup group;
  final ReliableGroupService service;

  const _GroupTile({required this.group, required this.service});

  @override
  Widget build(BuildContext context) {
    final engine = service.engineFor(group.groupId);
    final messages = engine?.messages ?? const [];
    final last = messages.isEmpty ? null : messages.last;
    final status = engine == null
        ? null
        : ReliableGroupStatus.of(context, group, engine);
    return ListTile(
      leading: CircleAvatar(
        child: Icon(status?.icon ?? Icons.verified_user_outlined),
      ),
      title: Text(group.name),
      subtitle: Text(
        last == null
            ? context.l10n.reliableGroup_noMessages
            : '${memberName(context, group, last.author, engine!)}: '
                  '${last.text}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: status == null
          ? null
          : Icon(Icons.circle, size: 12, color: status.color),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReliableGroupChatScreen(groupId: group.groupId),
        ),
      ),
    );
  }
}

class ReliableGroupCreateScreen extends StatefulWidget {
  const ReliableGroupCreateScreen({super.key});

  @override
  State<ReliableGroupCreateScreen> createState() =>
      _ReliableGroupCreateScreenState();
}

class _ReliableGroupCreateScreenState extends State<ReliableGroupCreateScreen>
    with DisconnectNavigationMixin {
  final TextEditingController _name = TextEditingController();
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    if (!checkConnectionAndNavigate(connector)) {
      return const SizedBox.shrink();
    }
    final l10n = context.l10n;
    final contacts =
        connector.contacts.where((c) => c.type == advTypeChat).toList()..sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
    const maxOthers = kReliableGroupMaxMembers - 1;
    final canCreate =
        !_busy && _name.text.trim().isNotEmpty && _selected.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.reliableGroup_create),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: canCreate ? () => _create(context, connector) : null,
            child: Text(l10n.common_create),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _name,
              maxLength: 31,
              decoration: InputDecoration(labelText: l10n.reliableGroup_name),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l10n.reliableGroup_selectedMembers(_selected.length),
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
          ),
          Expanded(
            child: contacts.isEmpty
                ? EmptyState(
                    icon: Icons.person_search,
                    title: l10n.reliableGroup_noContacts,
                  )
                : ListView(
                    children: [
                      for (final contact in contacts)
                        CheckboxListTile(
                          value: _selected.contains(contact.publicKeyHex),
                          title: Text(contact.name),
                          onChanged: (checked) {
                            if (checked == true &&
                                _selected.length >= maxOthers) {
                              showDismissibleSnackBar(
                                context,
                                content: Text(
                                  l10n.reliableGroup_tooManyMembers(
                                    kReliableGroupMaxMembers,
                                  ),
                                ),
                              );
                              return;
                            }
                            setState(() {
                              if (checked == true) {
                                _selected.add(contact.publicKeyHex);
                              } else {
                                _selected.remove(contact.publicKeyHex);
                              }
                            });
                          },
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _create(
    BuildContext context,
    MeshCoreConnector connector,
  ) async {
    setState(() => _busy = true);
    final l10n = context.l10n;
    final service = context.read<ReliableGroupService>();
    final group = ReliableGroup.create(
      name: _name.text.trim(),
      members: [
        ReliableGroupMember(
          name: connector.selfName ?? l10n.reliableGroup_you,
          publicKeyHex: connector.selfPublicKeyHex,
        ),
        for (final contact in connector.contacts)
          if (_selected.contains(contact.publicKeyHex))
            ReliableGroupMember(
              name: contact.name,
              publicKeyHex: contact.publicKeyHex,
            ),
      ],
    );
    final result = await service.addGroup(group);
    if (!context.mounted) return;
    setState(() => _busy = false);
    if (result != ReliableGroupAddResult.added) {
      showDismissibleSnackBar(
        context,
        content: Text(
          result == ReliableGroupAddResult.noFreeChannelSlot
              ? l10n.reliableGroup_noFreeChannel
              : l10n.reliableGroup_notAMember,
        ),
      );
      return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ReliableGroupChatScreen(groupId: group.groupId),
      ),
    );
    await showReliableGroupInvite(context, group);
  }
}

/// Shows [group]'s invite as QR code with a copy button.
Future<void> showReliableGroupInvite(
  BuildContext context,
  ReliableGroup group,
) {
  final l10n = context.l10n;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrCodeDisplay(
              data: group.inviteCode,
              size: 260,
              title: '${l10n.reliableGroup_invite}: ${group.name}',
              instructions: l10n.reliableGroup_inviteHint,
            ),
            FilledButton.icon(
              icon: const Icon(Icons.copy),
              label: Text(l10n.common_copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: group.inviteCode));
                if (sheetContext.mounted) {
                  showDismissibleSnackBar(
                    sheetContext,
                    content: Text(l10n.reliableGroup_inviteCopied),
                  );
                }
              },
            ),
          ],
        ),
      ),
    ),
  );
}

class _InviteScannerScreen extends StatelessWidget {
  const _InviteScannerScreen();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(l10n.reliableGroup_joinScan),
        centerTitle: true,
      ),
      body: QrScannerWidget(
        onScanned: (data) => Navigator.pop(context, data),
        validator: (data) => ReliableGroup.fromInviteCode(data) != null,
        onValidationFailed: (_) => showDismissibleSnackBar(
          context,
          content: Text(l10n.reliableGroup_invalidInvite),
        ),
      ),
    );
  }
}
