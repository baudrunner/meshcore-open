/// Delivery confirmation and repair for one reliable group.
///
/// The engine is transport-agnostic and clock-free: the caller feeds received
/// blobs to [ReliableGroupEngine.receive], asks [ReliableGroupEngine.poll] for
/// blobs to transmit, and wakes it again at [ReliableGroupEngine.nextWakeAt].
/// That keeps it pure Dart and lets tests run whole lossy meshes in virtual
/// time.
///
/// ## How completeness is tracked
///
/// Every member numbers its own messages 1, 2, 3, ... Every packet carries the
/// transmitter's *frontier*: per member, the highest seq it holds without a
/// gap. From the frontiers it hears, each member knows
///
/// * which messages exist (the highest seq anyone reports), so a lost *last*
///   message is still detected once anyone who has it speaks,
/// * which of its own messages each other member has stored (acks), and
/// * which members are behind it, and on which messages.
///
/// ## When packets are sent
///
/// * A new message goes out at once. It doubles as a status.
/// * After storing new messages, a status (ack) follows after a random delay,
///   unless one of our own packets goes out first.
/// * A member that sees it is missing messages sends a status soon (nack),
///   which tells the others what to resend.
/// * A member that holds messages another member lacks resends them (repair).
///   The author goes first, everyone else waits longer and drops a repair
///   that someone else already sent.
/// * While a member cannot confirm that everyone has everything it has, it
///   probes with exponential backoff, naming the members it waits for in
///   `wait_mask`. Named members answer with a status. The first probe follows
///   after a minute, each further one after twice the previous wait; after
///   [ReliableGroupTiming.probeGiveUp] probing stops until something new
///   happens, and a settled group sends nothing at all.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'reliable_group_codec.dart';

class ReliableGroupTiming {
  /// Delay before acknowledging newly stored messages. Batches a burst of
  /// messages into one status and spreads the members' answers apart.
  final Duration ackDelayMin;
  final Duration ackDelayMax;

  /// Delay before reporting a detected gap.
  final Duration nackDelayMin;
  final Duration nackDelayMax;

  /// Minimum spacing between two of our own status-bearing packets that were
  /// triggered by others (acks, nacks, answers).
  final Duration statusHoldoff;

  /// Delay before the author resends its own message.
  final Duration repairAuthorDelayMin;
  final Duration repairAuthorDelayMax;

  /// Delay before any other member resends someone else's message.
  final Duration repairOtherDelayMin;
  final Duration repairOtherDelayMax;

  /// A message younger than this is not repaired yet: reports that lack it
  /// were probably sent before it arrived.
  final Duration repairGuard;

  /// Messages resent per member and author in reply to one report.
  final int repairBatch;

  final Duration probeInitial;
  final Duration probeMax;

  /// Probing stops this long after the last news. Own messages that are not
  /// confirmed by everyone after this long count as lost.
  final Duration probeGiveUp;

  /// Delay range of the hello status sent by [ReliableGroupEngine.announce].
  final Duration announceDelayMin;
  final Duration announceDelayMax;

  const ReliableGroupTiming({
    this.ackDelayMin = const Duration(seconds: 5),
    this.ackDelayMax = const Duration(seconds: 40),
    this.nackDelayMin = const Duration(seconds: 1),
    this.nackDelayMax = const Duration(seconds: 5),
    this.statusHoldoff = const Duration(seconds: 10),
    this.repairAuthorDelayMin = const Duration(seconds: 1),
    this.repairAuthorDelayMax = const Duration(seconds: 3),
    this.repairOtherDelayMin = const Duration(seconds: 4),
    this.repairOtherDelayMax = const Duration(seconds: 12),
    this.repairGuard = const Duration(seconds: 20),
    this.repairBatch = 4,
    this.probeInitial = const Duration(minutes: 1),
    this.probeMax = const Duration(hours: 4),
    this.probeGiveUp = const Duration(hours: 12),
    this.announceDelayMin = const Duration(seconds: 1),
    this.announceDelayMax = const Duration(seconds: 6),
  });
}

enum ReliableGroupDelivery {
  /// Composed, not handed to the radio yet.
  queued,

  /// On air; not every member has confirmed it yet.
  sent,

  /// Every other member has confirmed storing it.
  delivered,

  /// Not confirmed by everyone within [ReliableGroupTiming.probeGiveUp].
  lost,
}

class ReliableGroupConfig {
  final int groupId;
  final int memberCount;
  final int selfIndex;

  ReliableGroupConfig({
    required this.groupId,
    required this.memberCount,
    required this.selfIndex,
  }) {
    if (groupId < 0 || groupId > 0xFFFFFFFF) {
      throw ArgumentError.value(groupId, 'groupId');
    }
    if (memberCount < 2 || memberCount > kReliableGroupMaxMembers) {
      throw ArgumentError.value(memberCount, 'memberCount');
    }
    if (selfIndex < 0 || selfIndex >= memberCount) {
      throw ArgumentError.value(selfIndex, 'selfIndex');
    }
  }
}

class _Repair {
  DateTime dueAt;
  final Set<int> requesters;
  _Repair(this.dueAt, this.requesters);
}

class ReliableGroupEngine {
  final ReliableGroupConfig config;
  final ReliableGroupTiming timing;
  final math.Random _random;

  /// Stored messages per author, keyed by seq.
  final List<Map<int, ReliableGroupMessage>> _messages;

  /// Our own frontier: per author, the highest seq stored without a gap.
  final List<int> _frontier;

  /// Highest seq known to exist per author, from any report or message.
  final List<int> _maxSeen;

  /// Last frontier heard from each member; zeros until first heard.
  final List<List<int>> _known;
  final List<DateTime?> _lastHeard;

  /// When a message was first stored in this run, for [ReliableGroupTiming
  /// .repairGuard]. Not persisted: after a restart nothing counts as fresh.
  final Map<int, DateTime> _storedAt = {};

  final List<Uint8List> _outbox = [];

  /// Own messages composed but not yet handed to [poll].
  final Set<int> _unsentOwn = {};
  final Map<int, _Repair> _repairs = {};
  DateTime? _statusDueAt;
  bool _statusIsHello = false;
  DateTime? _lastSentAt;

  DateTime? _probeDueAt;
  late Duration _probeInterval = timing.probeInitial;
  DateTime? _probeSeriesStart;

  ReliableGroupEngine({
    required this.config,
    this.timing = const ReliableGroupTiming(),
    math.Random? random,
  }) : _random = random ?? math.Random(),
       _messages = List.generate(config.memberCount, (_) => {}),
       _frontier = List.filled(config.memberCount, 0),
       _maxSeen = List.filled(config.memberCount, 0),
       _known = List.generate(
         config.memberCount,
         (_) => List.filled(config.memberCount, 0),
       ),
       _lastHeard = List.filled(config.memberCount, null);

  int get _n => config.memberCount;
  int get _self => config.selfIndex;

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// All stored messages, oldest first.
  List<ReliableGroupMessage> get messages {
    final all = [for (final byAuthor in _messages) ...byAuthor.values];
    all.sort((a, b) {
      final byTime = a.timestamp.compareTo(b.timestamp);
      if (byTime != 0) return byTime;
      final byAuthor = a.author.compareTo(b.author);
      return byAuthor != 0 ? byAuthor : a.seq.compareTo(b.seq);
    });
    return all;
  }

  /// Our frontier per author (see the library comment).
  List<int> get frontier => List.unmodifiable(_frontier);

  /// Number of messages known to exist that we have not stored.
  int get missingCount {
    var missing = 0;
    for (var a = 0; a < _n; a++) {
      for (var s = _frontier[a] + 1; s <= _maxSeen[a]; s++) {
        if (!_messages[a].containsKey(s)) missing++;
      }
    }
    return missing;
  }

  /// Other members that have reported storing our own message [seq].
  List<int> ackedBy(int seq) => [
    for (var p = 0; p < _n; p++)
      if (p != _self && _known[p][_self] >= seq) p,
  ];

  /// Delivery state of our own message [seq] at [now].
  ReliableGroupDelivery deliveryOf(int seq, DateTime now) {
    if (_unsentOwn.contains(seq)) return ReliableGroupDelivery.queued;
    if (ackedBy(seq).length == _n - 1) return ReliableGroupDelivery.delivered;
    final message = _messages[_self][seq];
    if (message != null &&
        now.difference(message.timestamp) >= timing.probeGiveUp) {
      return ReliableGroupDelivery.lost;
    }
    return ReliableGroupDelivery.sent;
  }

  /// When we last heard any packet from [member].
  DateTime? lastHeard(int member) => _lastHeard[member];

  /// Whether [member] has reported holding everything we hold.
  bool isConfirmed(int member) {
    if (member == _self) return missingCount == 0;
    for (var a = 0; a < _n; a++) {
      if (_known[member][a] < _frontier[a]) return false;
    }
    return true;
  }

  /// True when we hold every message known to exist and every member has
  /// confirmed holding all of them. This is relative to the last reports we
  /// heard: a member out of range may have written something since.
  bool get isSettled => missingCount == 0 && _waitMask() == 0;

  /// Earliest time [poll] has something to send, or null when idle.
  DateTime? get nextWakeAt {
    if (_outbox.isNotEmpty) return DateTime.fromMillisecondsSinceEpoch(0);
    DateTime? earliest;
    void consider(DateTime? t) {
      if (t != null && (earliest == null || t.isBefore(earliest!))) {
        earliest = t;
      }
    }

    consider(_statusDueAt);
    consider(_probeDueAt);
    for (final repair in _repairs.values) {
      consider(repair.dueAt);
    }
    return earliest;
  }

  // ---------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------

  /// Stores a new message of our own and queues it for transmission. Persist
  /// the engine ([toJson]) before transmitting so a seq is never reused.
  ReliableGroupMessage compose(String text, DateTime now) {
    // Others may report seqs we no longer hold, e.g. after a reinstall.
    final seq = math.max(_frontier[_self], _maxSeen[_self]) + 1;
    if (seq > kReliableGroupMaxSeq) {
      throw StateError('Sequence numbers of this group are exhausted');
    }
    final message = ReliableGroupMessage(
      author: _self,
      seq: seq,
      timestamp: now,
      text: text,
    );
    // An over-long text must not consume a seq.
    final textBytes = utf8.encode(text).length;
    if (textBytes > reliableGroupMaxTextBytes(_n)) {
      throw ArgumentError(
        'text is $textBytes bytes, limit is ${reliableGroupMaxTextBytes(_n)}',
      );
    }
    _store(message, now);
    _outbox.add(_encodeMessage(message));
    _unsentOwn.add(seq);
    _markSent(now);
    _resetProbe(now);
    return message;
  }

  /// Sends a hello status soon, asking every member to report. Call it when
  /// the radio (re)connects or the app starts.
  void announce(DateTime now) {
    _statusIsHello = true;
    _scheduleStatus(
      now.add(_jitter(timing.announceDelayMin, timing.announceDelayMax)),
    );
    _resetProbe(now);
  }

  /// Processes one received GRP_DATA blob of type [dataTypeReliableGroup].
  /// Returns the newly stored message, if the blob carried one we lacked.
  ReliableGroupMessage? receive(Uint8List blob, DateTime now) {
    final packet = ReliableGroupPacket.decode(blob);
    if (packet == null ||
        packet.groupId != config.groupId ||
        packet.memberCount != _n ||
        packet.sender == _self) {
      return null;
    }
    final sender = packet.sender;
    _lastHeard[sender] = now;

    var newInfo = false;
    var newGap = false;
    var senderCanRepair = false;
    for (var a = 0; a < _n; a++) {
      final reported = packet.frontier[a];
      if (reported > _known[sender][a]) {
        _known[sender][a] = reported;
        newInfo = true;
      }
      if (reported > _maxSeen[a]) {
        _maxSeen[a] = reported;
        newGap = true;
      }
      if (reported > _frontier[a]) senderCanRepair = true;
    }

    ReliableGroupMessage? stored;
    final message = packet.message;
    if (message != null) {
      _repairs.remove(_key(message.author, message.seq));
      if (!_messages[message.author].containsKey(message.seq)) {
        _store(message, now);
        stored = message;
      }
    }

    if (stored != null) {
      _scheduleStatus(
        _respectHoldoff(
          now.add(_jitter(timing.ackDelayMin, timing.ackDelayMax)),
        ),
      );
    }
    // Only report a gap that is new, or to a member that can fill it. Members
    // that lack the same message would otherwise keep answering each other.
    if ((newGap || senderCanRepair) && missingCount > 0) {
      _scheduleStatus(
        _respectHoldoff(
          now.add(_jitter(timing.nackDelayMin, timing.nackDelayMax)),
        ),
      );
    }
    // A packet sent before ours arrived still names us; our recent packet
    // already answers it.
    final answeredRecently =
        _lastSentAt != null &&
        now.difference(_lastSentAt!) < timing.statusHoldoff;
    if (packet.waitMask & (1 << _self) != 0 && !answeredRecently) {
      _scheduleStatus(
        _respectHoldoff(
          now.add(_jitter(timing.ackDelayMin, timing.ackDelayMax)),
        ),
      );
    }
    _scheduleRepairs(sender, now);

    if (stored != null || newInfo) {
      _resetProbe(now);
    } else {
      _maybeSuppressProbe(packet, now);
    }
    _updateProbe(now);
    return stored;
  }

  /// True while own messages wait to be handed out by [takeOutbox] or [poll].
  bool get hasOutbox => _outbox.isNotEmpty;

  /// Hands out only the own messages composed since the last call, leaving
  /// automatic traffic (acks, repairs, probes) scheduled. Lets the caller
  /// keep sending what the user typed while automatic traffic is paused.
  List<Uint8List> takeOutbox() {
    final out = List<Uint8List>.of(_outbox);
    _outbox.clear();
    _unsentOwn.clear();
    return out;
  }

  /// Returns every blob that is due at [now]; transmit them in order.
  List<Uint8List> poll(DateTime now) {
    final out = <Uint8List>[..._outbox];
    _outbox.clear();
    _unsentOwn.clear();

    final dueRepairs =
        _repairs.entries.where((e) => !e.value.dueAt.isAfter(now)).toList()
          ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in dueRepairs) {
      _repairs.remove(entry.key);
      final author = entry.key >> 16;
      final seq = entry.key & 0xFFFF;
      final stillNeeded = entry.value.requesters.any(
        (p) => _known[p][author] < seq,
      );
      final message = _messages[author][seq];
      if (!stillNeeded || message == null) continue;
      out.add(_encodeMessage(message));
      _markSent(now);
    }

    final statusDue = _statusDueAt != null && !_statusDueAt!.isAfter(now);
    final probeDue = _probeDueAt != null && !_probeDueAt!.isAfter(now);
    if (probeDue) _advanceProbe(now);
    if ((statusDue || probeDue) && out.isEmpty) {
      out.add(_encodeStatus());
      _markSent(now);
    } else if (statusDue) {
      _statusDueAt = null;
    }
    _updateProbe(now);
    return out;
  }

  // ---------------------------------------------------------------------------
  // Persistence
  // ---------------------------------------------------------------------------

  Map<String, dynamic> toJson() => {
    'groupId': config.groupId,
    'memberCount': _n,
    'selfIndex': _self,
    'messages': [for (final m in messages) m.toJson()],
    'known': [for (final row in _known) List<int>.of(row)],
    'maxSeen': List<int>.of(_maxSeen),
    'lastHeard': [for (final t in _lastHeard) t?.millisecondsSinceEpoch],
  };

  factory ReliableGroupEngine.fromJson(
    Map<String, dynamic> json, {
    ReliableGroupTiming timing = const ReliableGroupTiming(),
    math.Random? random,
  }) {
    final engine = ReliableGroupEngine(
      config: ReliableGroupConfig(
        groupId: json['groupId'] as int,
        memberCount: json['memberCount'] as int,
        selfIndex: json['selfIndex'] as int,
      ),
      timing: timing,
      random: random,
    );
    final n = engine._n;
    for (final raw in json['messages'] as List) {
      final message = ReliableGroupMessage.fromJson(
        (raw as Map).cast<String, dynamic>(),
      );
      if (message.author >= n) continue;
      engine._messages[message.author][message.seq] = message;
      if (message.seq > engine._maxSeen[message.author]) {
        engine._maxSeen[message.author] = message.seq;
      }
    }
    for (var a = 0; a < n; a++) {
      engine._advanceFrontier(a);
    }
    final known = json['known'] as List;
    for (var p = 0; p < n && p < known.length; p++) {
      final row = known[p] as List;
      for (var a = 0; a < n && a < row.length; a++) {
        engine._known[p][a] = row[a] as int;
      }
    }
    final maxSeen = json['maxSeen'] as List;
    for (var a = 0; a < n && a < maxSeen.length; a++) {
      engine._maxSeen[a] = math.max(engine._maxSeen[a], maxSeen[a] as int);
    }
    final lastHeard = json['lastHeard'] as List;
    for (var p = 0; p < n && p < lastHeard.length; p++) {
      final ms = lastHeard[p] as int?;
      if (ms != null) {
        engine._lastHeard[p] = DateTime.fromMillisecondsSinceEpoch(ms);
      }
    }
    return engine;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  static int _key(int author, int seq) => author << 16 | seq;

  void _store(ReliableGroupMessage message, DateTime now) {
    final a = message.author;
    _messages[a][message.seq] = message;
    _storedAt[_key(a, message.seq)] = now;
    if (message.seq > _maxSeen[a]) _maxSeen[a] = message.seq;
    _advanceFrontier(a);
  }

  void _advanceFrontier(int author) {
    while (_messages[author].containsKey(_frontier[author] + 1)) {
      _frontier[author]++;
    }
  }

  /// Members that have not confirmed holding everything we hold.
  int _waitMask() {
    var mask = 0;
    for (var p = 0; p < _n; p++) {
      if (p != _self && !isConfirmed(p)) mask |= 1 << p;
    }
    return mask;
  }

  Uint8List _encodeStatus() => ReliableGroupPacket.status(
    groupId: config.groupId,
    sender: _self,
    frontier: List.of(_frontier),
    waitMask: _outgoingWaitMask(),
  ).encode();

  Uint8List _encodeMessage(ReliableGroupMessage message) =>
      ReliableGroupPacket.message(
        groupId: config.groupId,
        sender: _self,
        frontier: List.of(_frontier),
        waitMask: _outgoingWaitMask(),
        message: message,
      ).encode();

  /// A hello asks everyone; otherwise ask the members we wait for.
  int _outgoingWaitMask() =>
      _statusIsHello ? ((1 << _n) - 1) & ~(1 << _self) : _waitMask();

  /// Every packet we send carries our frontier, so it satisfies a pending
  /// ack, nack or answer.
  void _markSent(DateTime now) {
    _statusDueAt = null;
    _statusIsHello = false;
    _lastSentAt = now;
  }

  void _scheduleStatus(DateTime at) {
    if (_statusDueAt == null || at.isBefore(_statusDueAt!)) _statusDueAt = at;
  }

  DateTime _respectHoldoff(DateTime at) {
    final last = _lastSentAt;
    if (last == null) return at;
    final earliest = last.add(timing.statusHoldoff);
    return at.isBefore(earliest) ? earliest : at;
  }

  /// [requester] just reported its frontier; queue what it lacks that we have.
  void _scheduleRepairs(int requester, DateTime now) {
    for (var a = 0; a < _n; a++) {
      final has = _known[requester][a];
      final last = math.min(_frontier[a], has + timing.repairBatch);
      for (var seq = has + 1; seq <= last; seq++) {
        final key = _key(a, seq);
        final existing = _repairs[key];
        if (existing != null) {
          existing.requesters.add(requester);
          continue;
        }
        final isAuthor = a == _self;
        var due = now.add(
          isAuthor
              ? _jitter(
                  timing.repairAuthorDelayMin,
                  timing.repairAuthorDelayMax,
                )
              : _jitter(timing.repairOtherDelayMin, timing.repairOtherDelayMax),
        );
        final storedAt = _storedAt[key];
        if (storedAt != null) {
          final fresh = storedAt.add(timing.repairGuard);
          if (due.isBefore(fresh)) due = fresh.add(due.difference(now));
        }
        _repairs[key] = _Repair(due, {requester});
      }
    }
  }

  void _resetProbe(DateTime now) {
    _probeInterval = timing.probeInitial;
    _probeSeriesStart = now;
    _probeDueAt = null;
    _updateProbe(now);
  }

  void _updateProbe(DateTime now) {
    if (isSettled) {
      _probeDueAt = null;
      _probeInterval = timing.probeInitial;
      _probeSeriesStart = null;
      return;
    }
    if (_probeDueAt != null) return;
    final deadline = (_probeSeriesStart ??= now).add(timing.probeGiveUp);
    if (!now.isBefore(deadline)) return;
    final due = now.add(_spread(_probeInterval));
    // One last try at the deadline rather than none past it.
    _probeDueAt = due.isBefore(deadline) ? due : deadline;
  }

  void _advanceProbe(DateTime now) {
    final doubled = _probeInterval * 2;
    _probeInterval = doubled > timing.probeMax ? timing.probeMax : doubled;
    _probeDueAt = null;
  }

  /// Another member just asked the same members we wait for, and knows at
  /// least what we know: our own probe would add nothing this round.
  void _maybeSuppressProbe(ReliableGroupPacket packet, DateTime now) {
    final due = _probeDueAt;
    if (due == null) return;
    final ours = _waitMask() & ~(1 << packet.sender);
    if (ours == 0 || packet.waitMask & ours != ours) return;
    for (var a = 0; a < _n; a++) {
      if (packet.frontier[a] < _frontier[a]) return;
    }
    // Count it as our own probe, so the whole group backs off together.
    _advanceProbe(now);
    _updateProbe(now);
  }

  Duration _jitter(Duration min, Duration max) {
    final span = max.inMilliseconds - min.inMilliseconds;
    if (span <= 0) return min;
    return min + Duration(milliseconds: _random.nextInt(span + 1));
  }

  /// [base] ±20 %, so members probing on the same schedule drift apart.
  Duration _spread(Duration base) {
    final ms = base.inMilliseconds;
    return Duration(
      milliseconds: (ms * 0.8 + _random.nextDouble() * ms * 0.4).round(),
    );
  }
}
