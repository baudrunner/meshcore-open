import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/reliable_group.dart';
import 'package:meshcore_open/services/reliable_group_engine.dart';
import 'package:meshcore_open/storage/prefs_manager.dart';
import 'package:meshcore_open/storage/reliable_group_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

String keyOf(int i) =>
    List.filled(32, i.toRadixString(16).padLeft(2, '0')).join();

ReliableGroup sampleGroup() => ReliableGroup.create(
  name: 'Wanderrunde',
  members: [
    for (var i = 0; i < 6; i++)
      ReliableGroupMember(name: 'Person $i', publicKeyHex: keyOf(i)),
  ],
  random: math.Random(7),
);

void main() {
  group('ReliableGroup', () {
    test('invite code round-trips the whole definition', () {
      final group = sampleGroup();
      final parsed = ReliableGroup.fromInviteCode('  ${group.inviteCode}\n')!;
      expect(parsed.toJson(), group.toJson());
      expect(parsed.channelPskHex, hasLength(32));
      expect(parsed.indexOf(keyOf(3).toUpperCase()), 3);
      expect(parsed.indexOf(keyOf(9)), isNull);
    });

    test('finds the invite in messenger-mangled text', () {
      final group = sampleGroup();
      final code = group.inviteCode;
      final wrapped = [
        for (var i = 0; i < code.length; i += 40)
          code.substring(i, math.min(i + 40, code.length)),
      ].join('\n');
      for (final text in [
        'Hier die Einladung: $code Bis gleich!',
        '$code$code',
        '$code\n$code',
        wrapped,
      ]) {
        expect(
          ReliableGroup.fromInviteCode(text)?.toJson(),
          group.toJson(),
          reason: text,
        );
      }
    });

    test('rejects codes that are not reliable group invites', () {
      expect(ReliableGroup.fromInviteCode('hello'), isNull);
      expect(ReliableGroup.fromInviteCode('mcrg1:'), isNull);
      expect(ReliableGroup.fromInviteCode('mcrg1:!!!'), isNull);
      final code = sampleGroup().inviteCode;
      expect(
        ReliableGroup.fromInviteCode(code.substring(0, code.length - 8)),
        isNull,
      );
    });

    test('requires 2 to 16 distinct members', () {
      final one = [ReliableGroupMember(name: 'a', publicKeyHex: keyOf(1))];
      expect(
        () => ReliableGroup.create(name: 'x', members: one),
        throwsArgumentError,
      );
      expect(
        () => ReliableGroup.create(name: 'x', members: [...one, ...one]),
        throwsArgumentError,
      );
    });
  });

  group('ReliableGroupStore', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      PrefsManager.reset();
      await PrefsManager.initialize();
    });

    test('keeps groups and state per radio identity', () async {
      final group = sampleGroup();
      final store = ReliableGroupStore(keyOf(1));
      await store.saveGroups([group]);
      final engine = ReliableGroupEngine(
        config: ReliableGroupConfig(
          groupId: group.groupId,
          memberCount: 6,
          selfIndex: 1,
        ),
      );
      engine.compose('Hallo', DateTime.utc(2026));
      await store.saveState(group.groupId, engine.toJson());

      final reloaded = ReliableGroupStore(keyOf(1));
      expect(reloaded.loadGroups().single.toJson(), group.toJson());
      final restored = ReliableGroupEngine.fromJson(
        reloaded.loadState(group.groupId)!,
      );
      expect(restored.messages, engine.messages);

      final otherRadio = ReliableGroupStore(keyOf(2));
      expect(otherRadio.loadGroups(), isEmpty);
      expect(otherRadio.loadState(group.groupId), isNull);

      await reloaded.deleteState(group.groupId);
      expect(reloaded.loadState(group.groupId), isNull);
    });
  });
}
