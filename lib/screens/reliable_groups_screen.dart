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

/// Scans an invite QR code and joins its group.
Future<void> scanReliableGroupInvite(BuildContext context) async {
  final code = await Navigator.push<String>(
    context,
    MaterialPageRoute(builder: (_) => const _InviteScannerScreen()),
  );
  if (code != null && context.mounted) await _join(context, code);
}

/// Asks for a pasted invite text and joins its group.
Future<void> pasteReliableGroupInvite(BuildContext context) async {
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
  final service = context.read<ReliableGroupService>();
  if (!service.isSupported) {
    showDismissibleSnackBar(
      context,
      content: Text(l10n.reliableGroup_unsupported),
    );
    return;
  }
  final group = ReliableGroup.fromInviteCode(code);
  if (group == null) {
    showDismissibleSnackBar(
      context,
      content: Text(l10n.reliableGroup_invalidInvite),
    );
    return;
  }
  final result = await service.addGroup(group);
  if (!context.mounted) return;
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
  Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) => ReliableGroupChatScreen(groupId: group.groupId),
    ),
  );
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
