import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/reliable_group_engine.dart';
import 'package:meshcore_open/services/reliable_group_traffic.dart';

final DateTime t0 = DateTime.utc(2026, 10, 10, 12);

ReliableGroupTrafficEntry entry(
  ReliableGroupTrafficKind kind,
  Duration after, {
  Duration? airtime = const Duration(milliseconds: 500),
}) => ReliableGroupTrafficEntry(
  at: t0.add(after),
  kind: kind,
  bytes: 21,
  airtime: airtime,
);

void main() {
  group('ReliableGroupTrafficLog', () {
    test('summarizes sent and received packets per window', () {
      final log = ReliableGroupTrafficLog();
      log.record(entry(ReliableGroupTrafficKind.ownMessage, Duration.zero));
      log.record(
        entry(ReliableGroupTrafficKind.status, const Duration(minutes: 30)),
      );
      log.record(
        entry(ReliableGroupTrafficKind.repair, const Duration(minutes: 55)),
      );
      log.record(
        entry(ReliableGroupTrafficKind.received, const Duration(minutes: 56)),
      );
      final now = t0.add(const Duration(minutes: 58));

      final hour = log.summarize(const Duration(hours: 1), now);
      expect(hour.sentPackets, 3);
      expect(hour.automaticPackets, 2);
      expect(hour.count(ReliableGroupTrafficKind.received), 1);
      expect(hour.sentBytes, 63);
      expect(hour.sentAirtime, const Duration(milliseconds: 1500));

      final tenMinutes = log.summarize(const Duration(minutes: 10), now);
      expect(tenMinutes.sentPackets, 1);
      expect(tenMinutes.count(ReliableGroupTrafficKind.repair), 1);
    });

    test('unknown airtime makes the total unknown', () {
      final log = ReliableGroupTrafficLog()
        ..record(entry(ReliableGroupTrafficKind.status, Duration.zero))
        ..record(
          entry(ReliableGroupTrafficKind.status, Duration.zero, airtime: null),
        );
      expect(log.summarize(const Duration(hours: 1), t0).sentAirtime, isNull);
    });

    test('the automatic limit counts only acks, probes and repairs', () {
      final log = ReliableGroupTrafficLog(automaticLimit: 3);
      for (var i = 0; i < 5; i++) {
        log.record(
          entry(ReliableGroupTrafficKind.ownMessage, Duration(minutes: i)),
        );
      }
      expect(log.isOverLimit(t0.add(const Duration(minutes: 5))), isFalse);
      for (var i = 0; i < 3; i++) {
        log.record(
          entry(ReliableGroupTrafficKind.status, Duration(minutes: 10 + i)),
        );
      }
      final now = t0.add(const Duration(minutes: 20));
      expect(log.automaticInWindow(now), 3);
      expect(log.isOverLimit(now), isTrue);
      // The first automatic packet ages out of the hour at 1:10.
      expect(log.limitFreesAt(now), t0.add(const Duration(minutes: 70)));
      expect(log.isOverLimit(t0.add(const Duration(minutes: 71))), isFalse);
    });

    test('forgets entries older than 24 hours', () {
      final log = ReliableGroupTrafficLog()
        ..record(entry(ReliableGroupTrafficKind.status, Duration.zero))
        ..record(
          entry(ReliableGroupTrafficKind.status, const Duration(hours: 25)),
        );
      final now = t0.add(const Duration(hours: 25));
      expect(log.summarize(const Duration(days: 7), now).sentPackets, 1);
    });
  });

  test('takeOutbox hands out own messages and leaves acks scheduled', () {
    final a = ReliableGroupEngine(
      config: ReliableGroupConfig(groupId: 7, memberCount: 2, selfIndex: 0),
    );
    final b = ReliableGroupEngine(
      config: ReliableGroupConfig(groupId: 7, memberCount: 2, selfIndex: 1),
    );
    a.compose('hallo', t0);
    final own = a.takeOutbox();
    expect(own, hasLength(1));
    expect(a.hasOutbox, isFalse);

    b.receive(own.single, t0);
    b.compose('zurück', t0);
    expect(b.takeOutbox(), hasLength(1));
    // b's ack is still scheduled for poll, not handed out with the outbox.
    expect(b.nextWakeAt, isNotNull);
    expect(b.takeOutbox(), isEmpty);
  });
}
