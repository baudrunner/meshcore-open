/// Per-group record of the reliable group packets this phone sent and heard,
/// for the traffic overview and the automatic-traffic limit. Kept in memory
/// for [ReliableGroupTrafficLog.retention]; it starts empty with the app.
library;

enum ReliableGroupTrafficKind {
  /// An own message, transmitted for the first time.
  ownMessage,

  /// A status packet: acknowledgement, gap report or probe.
  status,

  /// A message resent for a member that lacks it.
  repair,

  /// Any group packet received from another member.
  received,
}

class ReliableGroupTrafficEntry {
  final DateTime at;
  final ReliableGroupTrafficKind kind;
  final int bytes;

  /// Estimated time on air, or null when the radio settings are unknown.
  final Duration? airtime;

  const ReliableGroupTrafficEntry({
    required this.at,
    required this.kind,
    required this.bytes,
    this.airtime,
  });

  /// Sent by the protocol on its own, as opposed to typed by the user.
  bool get isAutomatic =>
      kind == ReliableGroupTrafficKind.status ||
      kind == ReliableGroupTrafficKind.repair;
}

class ReliableGroupTrafficSummary {
  final Map<ReliableGroupTrafficKind, int> packets;
  final int sentBytes;

  /// Total estimated airtime of sent packets; null when any is unknown.
  final Duration? sentAirtime;

  const ReliableGroupTrafficSummary({
    required this.packets,
    required this.sentBytes,
    required this.sentAirtime,
  });

  int count(ReliableGroupTrafficKind kind) => packets[kind] ?? 0;

  int get sentPackets =>
      count(ReliableGroupTrafficKind.ownMessage) +
      count(ReliableGroupTrafficKind.status) +
      count(ReliableGroupTrafficKind.repair);

  int get automaticPackets =>
      count(ReliableGroupTrafficKind.status) +
      count(ReliableGroupTrafficKind.repair);
}

class ReliableGroupTrafficLog {
  static const Duration retention = Duration(hours: 24);
  static const Duration limitWindow = Duration(hours: 1);

  /// Automatic packets this phone may send per group within [limitWindow].
  final int automaticLimit;

  final List<ReliableGroupTrafficEntry> _entries = [];

  ReliableGroupTrafficLog({this.automaticLimit = 30});

  void record(ReliableGroupTrafficEntry entry) {
    _entries.add(entry);
    _prune(entry.at);
  }

  ReliableGroupTrafficSummary summarize(Duration window, DateTime now) {
    final since = now.subtract(window);
    final packets = <ReliableGroupTrafficKind, int>{};
    var bytes = 0;
    Duration? airtime = Duration.zero;
    for (final e in _entries) {
      if (e.at.isBefore(since)) continue;
      packets[e.kind] = (packets[e.kind] ?? 0) + 1;
      if (e.kind == ReliableGroupTrafficKind.received) continue;
      bytes += e.bytes;
      final a = e.airtime;
      airtime = (airtime == null || a == null) ? null : airtime + a;
    }
    return ReliableGroupTrafficSummary(
      packets: packets,
      sentBytes: bytes,
      sentAirtime: airtime,
    );
  }

  /// Automatic packets sent within the last [limitWindow].
  int automaticInWindow(DateTime now) {
    final since = now.subtract(limitWindow);
    return _entries.where((e) => e.isAutomatic && !e.at.isBefore(since)).length;
  }

  bool isOverLimit(DateTime now) => automaticInWindow(now) >= automaticLimit;

  /// When the limit frees up again, or null when it is not reached.
  DateTime? limitFreesAt(DateTime now) {
    if (!isOverLimit(now)) return null;
    final since = now.subtract(limitWindow);
    final automatic = _entries
        .where((e) => e.isAutomatic && !e.at.isBefore(since))
        .toList();
    // Once the oldest counted packets age out, one slot is free again.
    final excess = automatic.length - automaticLimit;
    return automatic[excess].at.add(limitWindow);
  }

  void _prune(DateTime now) {
    final cutoff = now.subtract(retention);
    _entries.removeWhere((e) => e.at.isBefore(cutoff));
  }
}
