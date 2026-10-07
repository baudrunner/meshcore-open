/// Wire format for reliable groups: a fixed member list on one private channel
/// whose apps confirm, and repair, every message of every member.
///
/// Everything travels as MeshCore `PAYLOAD_TYPE_GRP_DATA` blobs with data type
/// [dataTypeReliableGroup], so other clients and the image transport ignore
/// these packets. The protocol logic lives in `reliable_group_engine.dart`;
/// this file only packs and unpacks blobs and is pure Dart.
///
/// ## Wire format (little-endian)
///
/// ```
///   off   size  field
///   0     1     version << 4 | kind      kind 1 = message, 2 = status
///   1     4     group_id                 random per group, uint32
///   5     1     sender                   member index of the transmitter
///   6     1     member_count             n, 1..[kReliableGroupMaxMembers]
///   7     2n    frontier[n]              uint16 per member: the highest seq
///                                        the sender holds without a gap
///   7+2n  2     wait_mask                bit p set: sender asks member p to
///                                        report its frontier
///   9+2n  ..    message body (kind 1 only)
/// ```
///
/// Message body:
///
/// ```
///   0  1  author      member index that wrote the message
///   1  2  seq         uint16, 1-based, per author, never reused
///   3  4  timestamp   uint32 seconds since epoch, set by the author
///   7  .. text        UTF-8
/// ```
///
/// `sender` and `author` differ when a member repairs another member's
/// message. Every packet carries the sender's frontier, so each message also
/// acknowledges everything the sender holds.
library;

import 'dart:convert';
import 'dart:typed_data';

/// GRP_DATA data type of reliable group packets. `0x0000` is rejected by the
/// firmware; images use `0xAE1C`.
const int dataTypeReliableGroup = 0x52C7;

/// Largest blob we put in one GRP_DATA packet (same binding limit as images).
const int kReliableGroupBlobBytes = 163;

const int kReliableGroupVersion = 1;

/// Members are addressed by index, and `wait_mask` is 16 bits wide.
const int kReliableGroupMaxMembers = 16;

/// Sequence numbers are uint16 and start at 1, so 0 means "none yet".
const int kReliableGroupMaxSeq = 0xFFFF;

const int _kHeaderFixedBytes = 9;
const int _kMessageBodyFixedBytes = 7;

enum ReliableGroupPacketKind {
  message(1),
  status(2);

  const ReliableGroupPacketKind(this.code);
  final int code;

  static ReliableGroupPacketKind? fromCode(int code) {
    for (final kind in values) {
      if (kind.code == code) return kind;
    }
    return null;
  }
}

/// Maximum UTF-8 text bytes one message can carry in a group of
/// [memberCount] members.
int reliableGroupMaxTextBytes(int memberCount) =>
    kReliableGroupBlobBytes -
    _kHeaderFixedBytes -
    2 * memberCount -
    _kMessageBodyFixedBytes;

class ReliableGroupMessage {
  final int author;
  final int seq;
  final DateTime timestamp;
  final String text;

  ReliableGroupMessage({
    required this.author,
    required this.seq,
    required DateTime timestamp,
    required this.text,
  }) : timestamp = DateTime.fromMillisecondsSinceEpoch(
         timestamp.millisecondsSinceEpoch ~/ 1000 * 1000,
       );

  Map<String, dynamic> toJson() => {
    'author': author,
    'seq': seq,
    'ts': timestamp.millisecondsSinceEpoch ~/ 1000,
    'text': text,
  };

  factory ReliableGroupMessage.fromJson(Map<String, dynamic> json) =>
      ReliableGroupMessage(
        author: json['author'] as int,
        seq: json['seq'] as int,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (json['ts'] as int) * 1000,
        ),
        text: json['text'] as String,
      );

  @override
  bool operator ==(Object other) =>
      other is ReliableGroupMessage &&
      other.author == author &&
      other.seq == seq &&
      other.timestamp == timestamp &&
      other.text == text;

  @override
  int get hashCode => Object.hash(author, seq, timestamp, text);

  @override
  String toString() => 'ReliableGroupMessage($author:$seq "$text")';
}

class ReliableGroupPacket {
  final ReliableGroupPacketKind kind;
  final int groupId;
  final int sender;
  final List<int> frontier;
  final int waitMask;
  final ReliableGroupMessage? message;

  const ReliableGroupPacket.status({
    required this.groupId,
    required this.sender,
    required this.frontier,
    this.waitMask = 0,
  }) : kind = ReliableGroupPacketKind.status,
       message = null;

  const ReliableGroupPacket.message({
    required this.groupId,
    required this.sender,
    required this.frontier,
    required ReliableGroupMessage this.message,
    this.waitMask = 0,
  }) : kind = ReliableGroupPacketKind.message;

  int get memberCount => frontier.length;

  /// Packs this packet into one GRP_DATA blob. Throws [ArgumentError] when a
  /// field is out of range or the text does not fit.
  Uint8List encode() {
    final n = frontier.length;
    if (n < 1 || n > kReliableGroupMaxMembers) {
      throw ArgumentError.value(n, 'memberCount');
    }
    if (sender < 0 || sender >= n) throw ArgumentError.value(sender, 'sender');
    final textBytes = message == null ? null : utf8.encode(message!.text);
    if (textBytes != null && textBytes.length > reliableGroupMaxTextBytes(n)) {
      throw ArgumentError(
        'text is ${textBytes.length} bytes, '
        'limit is ${reliableGroupMaxTextBytes(n)}',
      );
    }
    final builder = BytesBuilder(copy: false);
    final header = ByteData(_kHeaderFixedBytes + 2 * n);
    header.setUint8(0, kReliableGroupVersion << 4 | kind.code);
    header.setUint32(1, groupId, Endian.little);
    header.setUint8(5, sender);
    header.setUint8(6, n);
    for (var i = 0; i < n; i++) {
      header.setUint16(7 + 2 * i, frontier[i], Endian.little);
    }
    header.setUint16(7 + 2 * n, waitMask, Endian.little);
    builder.add(header.buffer.asUint8List());
    final msg = message;
    if (msg != null) {
      if (msg.author < 0 || msg.author >= n) {
        throw ArgumentError.value(msg.author, 'author');
      }
      if (msg.seq < 1 || msg.seq > kReliableGroupMaxSeq) {
        throw ArgumentError.value(msg.seq, 'seq');
      }
      final body = ByteData(_kMessageBodyFixedBytes);
      body.setUint8(0, msg.author);
      body.setUint16(1, msg.seq, Endian.little);
      body.setUint32(
        3,
        msg.timestamp.millisecondsSinceEpoch ~/ 1000,
        Endian.little,
      );
      builder.add(body.buffer.asUint8List());
      builder.add(textBytes!);
    }
    return builder.toBytes();
  }

  /// Unpacks a GRP_DATA blob, or returns null when it is not a well-formed
  /// packet of a version this build understands.
  static ReliableGroupPacket? decode(Uint8List blob) {
    if (blob.length < _kHeaderFixedBytes + 2) return null;
    final data = ByteData.sublistView(blob);
    final versionKind = data.getUint8(0);
    if (versionKind >> 4 != kReliableGroupVersion) return null;
    final kind = ReliableGroupPacketKind.fromCode(versionKind & 0x0F);
    if (kind == null) return null;
    final groupId = data.getUint32(1, Endian.little);
    final sender = data.getUint8(5);
    final n = data.getUint8(6);
    if (n < 1 || n > kReliableGroupMaxMembers || sender >= n) return null;
    final headerBytes = _kHeaderFixedBytes + 2 * n;
    if (blob.length < headerBytes) return null;
    final frontier = List<int>.generate(
      n,
      (i) => data.getUint16(7 + 2 * i, Endian.little),
    );
    final waitMask = data.getUint16(7 + 2 * n, Endian.little);
    if (kind == ReliableGroupPacketKind.status) {
      if (blob.length != headerBytes) return null;
      return ReliableGroupPacket.status(
        groupId: groupId,
        sender: sender,
        frontier: frontier,
        waitMask: waitMask,
      );
    }
    if (blob.length < headerBytes + _kMessageBodyFixedBytes) return null;
    final author = data.getUint8(headerBytes);
    final seq = data.getUint16(headerBytes + 1, Endian.little);
    final seconds = data.getUint32(headerBytes + 3, Endian.little);
    if (author >= n || seq < 1) return null;
    final String text;
    try {
      text = utf8.decode(blob.sublist(headerBytes + _kMessageBodyFixedBytes));
    } on FormatException {
      return null;
    }
    return ReliableGroupPacket.message(
      groupId: groupId,
      sender: sender,
      frontier: frontier,
      waitMask: waitMask,
      message: ReliableGroupMessage(
        author: author,
        seq: seq,
        timestamp: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
        text: text,
      ),
    );
  }
}
