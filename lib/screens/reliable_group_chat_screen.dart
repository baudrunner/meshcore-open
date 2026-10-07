import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/snack_bar_builder.dart';
import '../l10n/l10n.dart';
import '../models/reliable_group.dart';
import '../services/reliable_group_codec.dart';
import '../services/reliable_group_engine.dart';
import '../services/reliable_group_service.dart';
import '../theme/mesh_theme.dart';
import '../utils/disconnect_navigation_mixin.dart';
import '../widgets/adaptive_app_bar_title.dart';
import '../widgets/mesh_ui.dart';
import 'reliable_groups_screen.dart';

String memberName(
  BuildContext context,
  ReliableGroup group,
  int index,
  ReliableGroupEngine engine,
) => index == engine.config.selfIndex
    ? context.l10n.reliableGroup_you
    : group.members[index].name;

/// The group-level completeness state shown in the list and chat header.
class ReliableGroupStatus {
  final String label;
  final Color color;
  final IconData icon;

  const ReliableGroupStatus(this.label, this.color, this.icon);

  factory ReliableGroupStatus.of(
    BuildContext context,
    ReliableGroup group,
    ReliableGroupEngine engine,
  ) {
    final l10n = context.l10n;
    final missing = engine.missingCount;
    if (missing > 0) {
      return ReliableGroupStatus(
        l10n.reliableGroup_statusMissing(missing),
        MeshPalette.alert,
        Icons.sync_problem,
      );
    }
    final waiting = [
      for (var p = 0; p < group.members.length; p++)
        if (!engine.isConfirmed(p)) group.members[p].name,
    ];
    if (waiting.isEmpty) {
      return ReliableGroupStatus(
        l10n.reliableGroup_statusComplete,
        MeshPalette.signal,
        Icons.verified,
      );
    }
    return ReliableGroupStatus(
      l10n.reliableGroup_statusWaiting(waiting.join(', ')),
      MeshPalette.warn,
      Icons.hourglass_top,
    );
  }
}

class ReliableGroupChatScreen extends StatefulWidget {
  final int groupId;

  const ReliableGroupChatScreen({super.key, required this.groupId});

  @override
  State<ReliableGroupChatScreen> createState() =>
      _ReliableGroupChatScreenState();
}

class _ReliableGroupChatScreenState extends State<ReliableGroupChatScreen>
    with DisconnectNavigationMixin {
  final TextEditingController _text = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connector = context.watch<MeshCoreConnector>();
    final service = context.watch<ReliableGroupService>();
    if (!checkConnectionAndNavigate(connector)) {
      return const SizedBox.shrink();
    }
    final group = service.groupById(widget.groupId);
    final engine = service.engineFor(widget.groupId);
    if (group == null || engine == null) {
      return Scaffold(appBar: AppBar());
    }
    final l10n = context.l10n;
    final status = ReliableGroupStatus.of(context, group, engine);
    final channelMissing = service.channelIndexFor(group) == null;
    final messages = engine.messages.reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: AdaptiveAppBarTitle(group.name),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.people_outline),
            tooltip: l10n.reliableGroup_members,
            onPressed: () => _showMembers(context, group),
          ),
          PopupMenuButton<void>(
            itemBuilder: (menuContext) => [
              PopupMenuItem(
                child: Text(menuContext.l10n.reliableGroup_invite),
                onTap: () => showReliableGroupInvite(context, group),
              ),
              PopupMenuItem(
                child: Text(menuContext.l10n.reliableGroup_leave),
                onTap: () => _confirmLeave(context, group),
              ),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 16, right: 16),
            child: StatusChip(
              label: status.label,
              color: status.color,
              icon: status.icon,
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          if (channelMissing)
            MaterialBanner(
              content: Text(l10n.reliableGroup_channelMissing),
              actions: const [SizedBox.shrink()],
            ),
          Expanded(
            child: messages.isEmpty
                ? Center(child: Text(l10n.reliableGroup_noMessages))
                : ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.all(8),
                    itemCount: messages.length,
                    itemBuilder: (context, i) => _MessageBubble(
                      group: group,
                      engine: engine,
                      message: messages[i],
                    ),
                  ),
          ),
          _buildComposer(context, group, enabled: !channelMissing),
        ],
      ),
    );
  }

  Widget _buildComposer(
    BuildContext context,
    ReliableGroup group, {
    required bool enabled,
  }) {
    final l10n = context.l10n;
    final limit = reliableGroupMaxTextBytes(group.members.length);
    final used = utf8.encode(_text.text).length;
    final tooLong = used > limit;
    final canSend =
        enabled && !_sending && !tooLong && _text.text.trim().isNotEmpty;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _text,
                enabled: enabled,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: l10n.reliableGroup_composeHint,
                  counterText: '$used/$limit',
                  errorText: tooLong ? l10n.reliableGroup_textTooLong : null,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: canSend ? () => _send(context, group) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send(BuildContext context, ReliableGroup group) async {
    setState(() => _sending = true);
    try {
      await context.read<ReliableGroupService>().sendMessage(
        group.groupId,
        _text.text.trim(),
      );
      _text.clear();
    } on ArgumentError {
      if (context.mounted) {
        showDismissibleSnackBar(
          context,
          content: Text(context.l10n.reliableGroup_textTooLong),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _showMembers(BuildContext context, ReliableGroup group) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => Consumer<ReliableGroupService>(
        builder: (context, service, _) {
          final engine = service.engineFor(group.groupId);
          if (engine == null) return const SizedBox.shrink();
          final l10n = context.l10n;
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(title: Text(l10n.reliableGroup_members)),
                for (var p = 0; p < group.members.length; p++)
                  if (p != engine.config.selfIndex)
                    ListTile(
                      leading: Icon(
                        engine.isConfirmed(p)
                            ? Icons.check_circle
                            : Icons.help_outline,
                        color: engine.isConfirmed(p)
                            ? MeshPalette.signal
                            : MeshPalette.warn,
                      ),
                      title: Text(group.members[p].name),
                      subtitle: Text(
                        '${engine.isConfirmed(p) ? l10n.reliableGroup_memberConfirmed : l10n.reliableGroup_memberNotConfirmed}'
                        ' · ${_lastHeard(context, engine.lastHeard(p))}',
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmLeave(BuildContext context, ReliableGroup group) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.reliableGroup_leave),
        content: Text(l10n.reliableGroup_leaveConfirm(group.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.common_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.common_remove),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<ReliableGroupService>().removeGroup(group.groupId);
    if (context.mounted) Navigator.pop(context);
  }
}

String _lastHeard(BuildContext context, DateTime? time) {
  final l10n = context.l10n;
  if (time == null) return l10n.reliableGroup_neverHeard;
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return l10n.time_justNow;
  if (diff.inMinutes < 60) return l10n.time_minutesAgo(diff.inMinutes);
  if (diff.inHours < 24) return l10n.time_hoursAgo(diff.inHours);
  return l10n.time_daysAgo(diff.inDays);
}

class _MessageBubble extends StatelessWidget {
  final ReliableGroup group;
  final ReliableGroupEngine engine;
  final ReliableGroupMessage message;

  const _MessageBubble({
    required this.group,
    required this.engine,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final own = message.author == engine.config.selfIndex;
    final others = group.members.length - 1;
    final acked = own ? engine.ackedBy(message.seq) : const <int>[];
    final time = TimeOfDay.fromDateTime(message.timestamp).format(context);
    return Align(
      alignment: own ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: own ? () => _showAcks(context, acked) : null,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.8,
          ),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: own
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!own)
                Text(
                  group.members[message.author].name,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              Text(message.text),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(time, style: theme.textTheme.labelSmall),
                  if (own) ...[
                    const SizedBox(width: 6),
                    Icon(
                      acked.length == others ? Icons.done_all : Icons.done,
                      size: 14,
                      color: acked.length == others
                          ? MeshPalette.signal
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${acked.length}/$others',
                      style: theme.textTheme.labelSmall,
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

  void _showAcks(BuildContext context, List<int> acked) {
    final l10n = context.l10n;
    final pending = [
      for (var p = 0; p < group.members.length; p++)
        if (p != engine.config.selfIndex && !acked.contains(p)) p,
    ];
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(title: Text(l10n.reliableGroup_storedBy)),
            for (final p in acked)
              ListTile(
                leading: const Icon(Icons.check, color: MeshPalette.signal),
                title: Text(group.members[p].name),
              ),
            if (pending.isNotEmpty)
              ListTile(title: Text(l10n.reliableGroup_notConfirmedBy)),
            for (final p in pending)
              ListTile(
                leading: const Icon(Icons.schedule, color: MeshPalette.warn),
                title: Text(group.members[p].name),
              ),
          ],
        ),
      ),
    );
  }
}
