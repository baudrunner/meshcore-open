import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../services/reliable_group_codec.dart';

class ReliableGroupMember {
  final String name;

  /// Full public key, lowercase hex.
  final String publicKeyHex;

  const ReliableGroupMember({required this.name, required this.publicKeyHex});

  Map<String, dynamic> toJson() => {'n': name, 'k': publicKeyHex};

  factory ReliableGroupMember.fromJson(Map<String, dynamic> json) =>
      ReliableGroupMember(
        name: json['n'] as String,
        publicKeyHex: (json['k'] as String).toLowerCase(),
      );
}

/// A reliable group: a fixed, ordered member list bound to one private
/// channel. The member order is the index used on air, so every member must
/// hold the same definition; it is distributed as an [inviteCode].
class ReliableGroup {
  static const String invitePrefix = 'mcrg1:';

  final int groupId;
  final String name;
  final String channelName;

  /// 16-byte channel PSK as 32 hex chars. Binds the group to its channel by
  /// key, because channel slot indices differ from radio to radio.
  final String channelPskHex;
  final List<ReliableGroupMember> members;

  ReliableGroup({
    required this.groupId,
    required this.name,
    required this.channelName,
    required String channelPskHex,
    required List<ReliableGroupMember> members,
  }) : channelPskHex = channelPskHex.toLowerCase(),
       members = List.unmodifiable(members) {
    if (members.length < 2 || members.length > kReliableGroupMaxMembers) {
      throw ArgumentError.value(members.length, 'members.length');
    }
    final keys = members.map((m) => m.publicKeyHex).toSet();
    if (keys.length != members.length) {
      throw ArgumentError('members contain a duplicate public key');
    }
  }

  /// A new group with a random id and channel key. [members] must include the
  /// creator.
  factory ReliableGroup.create({
    required String name,
    required List<ReliableGroupMember> members,
    math.Random? random,
  }) {
    final rng = random ?? math.Random.secure();
    final psk = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
    return ReliableGroup(
      groupId: rng.nextInt(1 << 16) << 16 | rng.nextInt(1 << 16),
      name: name,
      channelName: name,
      channelPskHex: [
        for (final b in psk) b.toRadixString(16).padLeft(2, '0'),
      ].join(),
      members: members,
    );
  }

  /// This radio's member index, or null when [selfPublicKeyHex] is not a
  /// member.
  int? indexOf(String selfPublicKeyHex) {
    final key = selfPublicKeyHex.toLowerCase();
    for (var i = 0; i < members.length; i++) {
      if (members[i].publicKeyHex == key) return i;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': groupId,
    'name': name,
    'ch': channelName,
    'psk': channelPskHex,
    'm': [for (final m in members) m.toJson()],
  };

  factory ReliableGroup.fromJson(Map<String, dynamic> json) => ReliableGroup(
    groupId: json['id'] as int,
    name: json['name'] as String,
    channelName: json['ch'] as String,
    channelPskHex: json['psk'] as String,
    members: [
      for (final m in json['m'] as List)
        ReliableGroupMember.fromJson((m as Map).cast<String, dynamic>()),
    ],
  );

  /// Text to share with the members (as text or QR code). It contains the
  /// channel key: share it only with them.
  String get inviteCode =>
      invitePrefix + base64Url.encode(utf8.encode(jsonEncode(toJson())));

  /// Parses an [inviteCode], or returns null when it is not a valid one.
  static ReliableGroup? fromInviteCode(String code) {
    final trimmed = code.trim();
    if (!trimmed.startsWith(invitePrefix)) return null;
    try {
      final payload = base64Url.normalize(
        trimmed.substring(invitePrefix.length),
      );
      final json = jsonDecode(utf8.decode(base64Url.decode(payload)));
      final group = ReliableGroup.fromJson(
        (json as Map).cast<String, dynamic>(),
      );
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(group.channelPskHex)) {
        return null;
      }
      if (group.groupId < 0 || group.groupId > 0xFFFFFFFF) return null;
      return group;
    } on Object {
      return null;
    }
  }
}
