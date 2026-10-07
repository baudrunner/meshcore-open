import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/reliable_group_codec.dart';
import 'package:meshcore_open/services/reliable_group_engine.dart';

const int groupId = 0xC0FFEE42;
final DateTime t0 = DateTime.utc(2026, 10, 7, 12);

class _InFlight {
  final DateTime deliverAt;
  final int to;
  final Uint8List blob;
  _InFlight(this.deliverAt, this.to, this.blob);
}

/// A mesh of [size] members in virtual time where every packet reaches every
/// online member after [airtime], unless [loss] or [drop] eats it.
class SimMesh {
  final List<ReliableGroupEngine> nodes;
  final List<bool> online;
  final math.Random _lossRandom;
  final double loss;
  final Duration airtime;

  /// Return true to drop the copy of a packet from `from` to `to`.
  bool Function(int from, int to, ReliableGroupPacket packet)? drop;

  DateTime now = t0;
  bool trace = false;
  int statusPackets = 0;
  int messagePackets = 0;
  final List<_InFlight> _inFlight = [];

  SimMesh(
    int size, {
    int seed = 1,
    this.loss = 0,
    this.airtime = const Duration(seconds: 1),
  }) : nodes = List.generate(
         size,
         (i) => ReliableGroupEngine(
           config: ReliableGroupConfig(
             groupId: groupId,
             memberCount: size,
             selfIndex: i,
           ),
           random: math.Random(seed * 100 + i),
         ),
       ),
       online = List.filled(size, true),
       _lossRandom = math.Random(seed);

  int get totalPackets => statusPackets + messagePackets;

  ReliableGroupMessage send(int from, String text) =>
      nodes[from].compose(text, now);

  void goOffline(int member) => online[member] = false;

  void goOnline(int member) {
    online[member] = true;
    nodes[member].announce(now);
  }

  void runFor(Duration duration) {
    final end = now.add(duration);
    for (var guard = 0; guard < 1000000; guard++) {
      DateTime? next;
      for (final f in _inFlight) {
        if (next == null || f.deliverAt.isBefore(next)) next = f.deliverAt;
      }
      for (var i = 0; i < nodes.length; i++) {
        if (!online[i]) continue;
        final wake = nodes[i].nextWakeAt;
        if (wake != null && (next == null || wake.isBefore(next))) next = wake;
      }
      if (next == null || next.isAfter(end)) break;
      if (next.isAfter(now)) now = next;

      final due = _inFlight.where((f) => !f.deliverAt.isAfter(now)).toList();
      _inFlight.removeWhere((f) => !f.deliverAt.isAfter(now));
      for (final f in due) {
        if (online[f.to]) nodes[f.to].receive(f.blob, now);
      }
      for (var i = 0; i < nodes.length; i++) {
        if (!online[i]) continue;
        final wake = nodes[i].nextWakeAt;
        if (wake == null || wake.isAfter(now)) continue;
        for (final blob in nodes[i].poll(now)) {
          _transmit(i, blob);
        }
      }
    }
    now = end;
  }

  void _transmit(int from, Uint8List blob) {
    final packet = ReliableGroupPacket.decode(blob)!;
    expect(blob.length, lessThanOrEqualTo(kReliableGroupBlobBytes));
    if (trace) {
      // ignore: avoid_print
      print(
        '${now.difference(t0).inSeconds}s  $from  ${packet.kind.name} '
        'f=${packet.frontier} mask=${packet.waitMask.toRadixString(2)} '
        '${packet.message ?? ''}',
      );
    }
    if (packet.kind == ReliableGroupPacketKind.status) {
      statusPackets++;
    } else {
      messagePackets++;
    }
    for (var to = 0; to < nodes.length; to++) {
      if (to == from || !online[to]) continue;
      if (drop?.call(from, to, packet) ?? false) continue;
      if (loss > 0 && _lossRandom.nextDouble() < loss) continue;
      _inFlight.add(_InFlight(now.add(airtime), to, blob));
    }
  }

  void expectAllHave(Iterable<ReliableGroupMessage> expected) {
    final want = expected.toSet();
    for (var i = 0; i < nodes.length; i++) {
      expect(nodes[i].messages.toSet(), want, reason: 'member $i');
      expect(nodes[i].missingCount, 0, reason: 'member $i');
    }
  }

  void expectAllSettled() {
    for (var i = 0; i < nodes.length; i++) {
      expect(nodes[i].isSettled, isTrue, reason: 'member $i');
    }
  }
}

void main() {
  group('ReliableGroupPacket', () {
    test('round-trips a message with UTF-8 text', () {
      final packet = ReliableGroupPacket.message(
        groupId: groupId,
        sender: 2,
        frontier: const [3, 0, 7, 1, 0, 65535],
        waitMask: 0x21,
        message: ReliableGroupMessage(
          author: 5,
          seq: 65535,
          timestamp: t0,
          text: 'Grüße vom Berg 🏔',
        ),
      );
      final decoded = ReliableGroupPacket.decode(packet.encode())!;
      expect(decoded.kind, ReliableGroupPacketKind.message);
      expect(decoded.groupId, groupId);
      expect(decoded.sender, 2);
      expect(decoded.frontier, packet.frontier);
      expect(decoded.waitMask, 0x21);
      expect(decoded.message, packet.message);
    });

    test('a status of six members is 21 bytes', () {
      final blob = const ReliableGroupPacket.status(
        groupId: groupId,
        sender: 0,
        frontier: [1, 2, 3, 4, 5, 6],
      ).encode();
      expect(blob.length, 21);
      expect(ReliableGroupPacket.decode(blob)!.frontier, [1, 2, 3, 4, 5, 6]);
    });

    test('text fills the blob exactly at the limit and no further', () {
      final limit = reliableGroupMaxTextBytes(6);
      expect(limit, 135);
      ReliableGroupPacket withText(String text) => ReliableGroupPacket.message(
        groupId: groupId,
        sender: 0,
        frontier: List.filled(6, 0),
        message: ReliableGroupMessage(
          author: 0,
          seq: 1,
          timestamp: t0,
          text: text,
        ),
      );
      expect(withText('x' * limit).encode().length, kReliableGroupBlobBytes);
      expect(() => withText('x' * (limit + 1)).encode(), throwsArgumentError);
    });

    test('rejects truncated, foreign-version and malformed blobs', () {
      final good = ReliableGroupPacket.message(
        groupId: groupId,
        sender: 1,
        frontier: const [0, 1],
        message: ReliableGroupMessage(
          author: 1,
          seq: 1,
          timestamp: t0,
          text: 'hi',
        ),
      ).encode();
      expect(ReliableGroupPacket.decode(good), isNotNull);
      expect(ReliableGroupPacket.decode(good.sublist(0, 10)), isNull);
      expect(ReliableGroupPacket.decode(Uint8List(0)), isNull);
      expect(
        ReliableGroupPacket.decode(Uint8List.fromList([0x21, ...good.skip(1)])),
        isNull,
      );
      final badUtf8 = Uint8List.fromList([
        ...good.sublist(0, good.length - 2),
        0xC3,
      ]);
      expect(ReliableGroupPacket.decode(badUtf8), isNull);
      final senderOutOfRange = Uint8List.fromList(good)..[5] = 2;
      expect(ReliableGroupPacket.decode(senderOutOfRange), isNull);
    });
  });

  group('ReliableGroupEngine', () {
    test('one message on a lossless mesh: delivered, acked, then silence', () {
      final mesh = SimMesh(6);
      final message = mesh.send(1, 'Treffpunkt 18 Uhr');
      mesh.runFor(const Duration(minutes: 2));

      mesh.expectAllHave([message]);
      expect(mesh.nodes[1].ackedBy(1), [0, 2, 3, 4, 5]);
      mesh.expectAllSettled();
      expect(mesh.messagePackets, 1);
      expect(mesh.statusPackets, 5);

      final before = mesh.totalPackets;
      mesh.runFor(const Duration(hours: 6));
      expect(mesh.totalPackets, before, reason: 'a settled group is silent');
    });

    test('a burst of messages is acknowledged in one status per member', () {
      final mesh = SimMesh(6);
      final sent = [for (var i = 0; i < 5; i++) mesh.send(0, 'Teil $i')];
      mesh.runFor(const Duration(minutes: 2));

      mesh.expectAllHave(sent);
      mesh.expectAllSettled();
      expect(mesh.nodes[0].ackedBy(5), [1, 2, 3, 4, 5]);
      expect(mesh.statusPackets, 5);
    });

    test('a lost last message is detected and repaired', () {
      final mesh = SimMesh(6);
      final first = mesh.send(1, 'erste');
      mesh.runFor(const Duration(minutes: 1));

      // Member 0 misses the original transmission of Ben's last message.
      var dropped = false;
      mesh.drop = (from, to, packet) {
        if (dropped || to != 0 || packet.message?.seq != 2) return false;
        return dropped = true;
      };
      final last = mesh.send(1, 'letzte');
      mesh.runFor(const Duration(minutes: 5));

      expect(dropped, isTrue);
      mesh.expectAllHave([first, last]);
      mesh.expectAllSettled();
    });

    test('the last message is repaired by others while its author is away', () {
      final mesh = SimMesh(6);
      mesh.drop = (from, to, packet) => to == 0 && packet.message != null;
      final message = mesh.send(1, 'nur einmal gesendet');
      // Ben switches off right after sending, before any repair.
      mesh.runFor(const Duration(milliseconds: 1500));
      mesh.goOffline(1);
      mesh.drop = null;
      mesh.runFor(const Duration(minutes: 10));

      expect(mesh.nodes[0].messages, [message]);
      expect(mesh.nodes[0].missingCount, 0);
    });

    test('a member that was offline catches up after announcing', () {
      final mesh = SimMesh(6, seed: 3);
      mesh.goOffline(4);
      final sent = <ReliableGroupMessage>[];
      for (var i = 0; i < 10; i++) {
        sent.add(mesh.send(i % 4, 'Nachricht $i'));
        mesh.runFor(const Duration(minutes: 1));
      }
      mesh.runFor(const Duration(minutes: 30));
      expect(mesh.nodes[0].isSettled, isFalse, reason: 'member 4 unconfirmed');
      expect(mesh.nodes[0].isConfirmed(4), isFalse);

      mesh.goOnline(4);
      mesh.runFor(const Duration(minutes: 30));

      mesh.expectAllHave(sent);
      mesh.expectAllSettled();
    });

    test('probing an absent member stops after maxProbes', () {
      final mesh = SimMesh(6);
      mesh.goOffline(5);
      mesh.send(0, 'Hallo?');
      mesh.runFor(const Duration(hours: 3));
      final afterBackoff = mesh.totalPackets;
      // 1 message, 4 acks, then one probe per round for the whole group:
      // members that hear someone else probe count it as their own.
      expect(afterBackoff, lessThanOrEqualTo(1 + 4 + 8));

      mesh.runFor(const Duration(hours: 12));
      expect(mesh.totalPackets, afterBackoff, reason: 'probing gave up');
    });

    for (final seed in [1, 2, 3, 4, 5, 6, 7, 8]) {
      test('30 messages over a mesh with 30 % loss converge (seed $seed)', () {
        final mesh = SimMesh(6, seed: seed, loss: 0.3);
        final random = math.Random(seed);
        final sent = <ReliableGroupMessage>[];
        for (var i = 0; i < 30; i++) {
          sent.add(mesh.send(random.nextInt(6), 'msg $i'));
          mesh.runFor(Duration(seconds: 5 + random.nextInt(60)));
        }
        mesh.runFor(const Duration(hours: 1));

        mesh.expectAllHave(sent);
        mesh.expectAllSettled();
        // 30 originals plus acks, nacks, repairs and probes. 40 seeds peaked
        // at 244 packets.
        expect(mesh.totalPackets, lessThan(30 * 10));
      });
    }

    test('restoring from JSON keeps messages and never reuses a seq', () {
      final mesh = SimMesh(3);
      mesh.send(0, 'eins');
      mesh.send(0, 'zwei');
      mesh.runFor(const Duration(minutes: 1));

      final json = jsonDecode(jsonEncode(mesh.nodes[0].toJson()));
      final restored = ReliableGroupEngine.fromJson(
        (json as Map).cast<String, dynamic>(),
      );
      expect(restored.messages, mesh.nodes[0].messages);
      expect(restored.ackedBy(2), [1, 2]);
      expect(restored.isSettled, isTrue);
      expect(restored.compose('drei', mesh.now).seq, 3);
    });

    test('after losing its data a member does not reuse reported seqs', () {
      final engine = SimMesh(3).nodes[0];
      engine.receive(
        const ReliableGroupPacket.status(
          groupId: groupId,
          sender: 1,
          frontier: [5, 0, 0],
        ).encode(),
        t0,
      );
      expect(engine.compose('neu', t0).seq, 6);
    });

    test('an over-long text is rejected without consuming a seq', () {
      final engine = SimMesh(6).nodes[0];
      expect(() => engine.compose('x' * 136, t0), throwsArgumentError);
      expect(engine.compose('ok', t0).seq, 1);
    });

    test('ignores packets of other groups and its own echoes', () {
      final engine = SimMesh(3).nodes[0];
      ReliableGroupPacket from(int sender, int group) =>
          ReliableGroupPacket.message(
            groupId: group,
            sender: sender,
            frontier: const [0, 1, 0],
            message: ReliableGroupMessage(
              author: 1,
              seq: 1,
              timestamp: t0,
              text: 'x',
            ),
          );
      expect(engine.receive(from(1, groupId + 1).encode(), t0), isNull);
      expect(engine.receive(from(0, groupId).encode(), t0), isNull);
      expect(engine.messages, isEmpty);
      expect(engine.receive(from(1, groupId).encode(), t0), isNotNull);
    });
  });
}
