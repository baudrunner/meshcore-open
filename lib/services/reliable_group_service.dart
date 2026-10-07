import 'dart:async';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../models/channel.dart';
import '../models/reliable_group.dart';
import '../storage/reliable_group_store.dart';
import '../utils/app_logger.dart';
import 'image_chunk_transport.dart'
    show parseChannelDataFrame, respCodeChannelDataRecv;
import 'reliable_group_codec.dart';
import 'reliable_group_engine.dart';

enum ReliableGroupAddResult { added, notAMember, noFreeChannelSlot }

/// Runs every reliable group of the connected radio: routes GRP_DATA packets
/// to the protocol engines, transmits what they schedule, and persists their
/// state. It works regardless of which screen is open, so confirmations and
/// repairs continue while the app runs in the background (on Android the
/// foreground service keeps it alive).
class ReliableGroupService extends ChangeNotifier {
  static const Duration _saveDelay = Duration(seconds: 2);

  final MeshCoreConnector _connector;
  late final StreamSubscription<Uint8List> _frames;

  String _scopeKey = '';
  ReliableGroupStore? _store;
  List<ReliableGroup> _groups = const [];
  final Map<int, ReliableGroupEngine> _engines = {};
  final Set<int> _dirty = {};

  bool _wasConnected = false;
  Timer? _wakeTimer;
  Timer? _saveTimer;
  bool _pumping = false;

  ReliableGroupService(this._connector) {
    _connector.addListener(_onConnectorChanged);
    _frames = _connector.receivedFrames.listen(_onFrame);
    _onConnectorChanged();
  }

  List<ReliableGroup> get groups => _groups;

  /// False when the connected firmware cannot send GRP_DATA.
  bool get isSupported => _connector.supportsChannelData;

  ReliableGroup? groupById(int groupId) {
    for (final g in _groups) {
      if (g.groupId == groupId) return g;
    }
    return null;
  }

  ReliableGroupEngine? engineFor(int groupId) => _engines[groupId];

  /// The radio's channel slot holding [group]'s key, or null if none does.
  int? channelIndexFor(ReliableGroup group) {
    for (final channel in _connector.channels) {
      if (!channel.isEmpty && channel.pskHex == group.channelPskHex) {
        return channel.index;
      }
    }
    return null;
  }

  /// Adds [group] for the connected radio and makes sure its private channel
  /// exists on the radio.
  Future<ReliableGroupAddResult> addGroup(ReliableGroup group) async {
    final self = group.indexOf(_connector.selfPublicKeyHex);
    final store = _store;
    if (self == null || store == null) {
      return ReliableGroupAddResult.notAMember;
    }
    if (channelIndexFor(group) == null) {
      final free = _freeChannelSlot();
      if (free == null) return ReliableGroupAddResult.noFreeChannelSlot;
      await _connector.setChannel(
        free,
        group.channelName,
        Channel.parsePskHex(group.channelPskHex),
      );
    }
    _groups = [
      for (final g in _groups)
        if (g.groupId != group.groupId) g,
      group,
    ];
    await store.saveGroups(_groups);
    final engine = _engines[group.groupId] ??= _newEngine(group, self);
    await store.saveState(group.groupId, engine.toJson());
    engine.announce(DateTime.now());
    notifyListeners();
    _scheduleWake();
    return ReliableGroupAddResult.added;
  }

  /// Forgets [groupId] and its history on this phone. The radio channel is
  /// left in place.
  Future<void> removeGroup(int groupId) async {
    _groups = [
      for (final g in _groups)
        if (g.groupId != groupId) g,
    ];
    _engines.remove(groupId);
    _dirty.remove(groupId);
    await _store?.saveGroups(_groups);
    await _store?.deleteState(groupId);
    notifyListeners();
    _scheduleWake();
  }

  /// Stores and queues a new message. Throws [ArgumentError] when the text is
  /// too long (see [maxTextBytes]).
  Future<ReliableGroupMessage> sendMessage(int groupId, String text) async {
    final engine = _engines[groupId];
    if (engine == null) throw StateError('Unknown group $groupId');
    final message = engine.compose(text, DateTime.now());
    // Persist before transmitting, so a crash cannot reuse the seq.
    await _store?.saveState(groupId, engine.toJson());
    _dirty.remove(groupId);
    notifyListeners();
    _scheduleWake();
    return message;
  }

  int maxTextBytes(int groupId) {
    final group = groupById(groupId);
    return group == null ? 0 : reliableGroupMaxTextBytes(group.members.length);
  }

  // ---------------------------------------------------------------------------

  void _onConnectorChanged() {
    final connected = _connector.isConnected;
    final key = _connector.selfPublicKeyHex;
    if (key.isNotEmpty && key != _scopeKey) _load(key);
    if (connected && !_wasConnected && _store != null) {
      final now = DateTime.now();
      for (final engine in _engines.values) {
        engine.announce(now);
      }
      _scheduleWake();
    }
    if (!connected) _wakeTimer?.cancel();
    _wasConnected = connected;
  }

  void _load(String publicKeyHex) {
    _flushSaves();
    _scopeKey = publicKeyHex;
    final store = ReliableGroupStore(publicKeyHex);
    _store = store;
    _groups = store.loadGroups();
    _engines.clear();
    for (final group in _groups) {
      final self = group.indexOf(publicKeyHex);
      if (self == null) continue;
      final state = store.loadState(group.groupId);
      ReliableGroupEngine? engine;
      if (state != null) {
        try {
          engine = ReliableGroupEngine.fromJson(state);
        } on Object catch (e) {
          appLogger.warn('Reliable group ${group.groupId} state reset: $e');
        }
      }
      _engines[group.groupId] = engine ?? _newEngine(group, self);
    }
    notifyListeners();
  }

  ReliableGroupEngine _newEngine(ReliableGroup group, int self) =>
      ReliableGroupEngine(
        config: ReliableGroupConfig(
          groupId: group.groupId,
          memberCount: group.members.length,
          selfIndex: self,
        ),
      );

  int? _freeChannelSlot() {
    final used = {
      for (final c in _connector.channels)
        if (!c.isEmpty) c.index,
    };
    for (var i = 0; i < _connector.maxChannels; i++) {
      if (!used.contains(i)) return i;
    }
    return null;
  }

  void _onFrame(Uint8List frame) {
    if (frame.isEmpty || frame[0] != respCodeChannelDataRecv) return;
    final data = parseChannelDataFrame(frame);
    if (data == null || data.dataType != dataTypeReliableGroup) return;
    final now = DateTime.now();
    var changed = false;
    for (final group in _groups) {
      if (channelIndexFor(group) != data.channelIndex) continue;
      final engine = _engines[group.groupId];
      if (engine == null) continue;
      engine.receive(data.payload, now);
      _dirty.add(group.groupId);
      changed = true;
    }
    if (!changed) return;
    _saveTimer ??= Timer(_saveDelay, _flushSaves);
    notifyListeners();
    _scheduleWake();
  }

  void _flushSaves() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final store = _store;
    if (store == null) return;
    for (final groupId in _dirty) {
      final engine = _engines[groupId];
      if (engine != null) unawaited(store.saveState(groupId, engine.toJson()));
    }
    _dirty.clear();
  }

  void _scheduleWake() {
    _wakeTimer?.cancel();
    if (!_connector.isConnected || _pumping) return;
    DateTime? earliest;
    for (final engine in _engines.values) {
      final wake = engine.nextWakeAt;
      if (wake != null && (earliest == null || wake.isBefore(earliest))) {
        earliest = wake;
      }
    }
    if (earliest == null) return;
    final delay = earliest.difference(DateTime.now());
    _wakeTimer = Timer(delay.isNegative ? Duration.zero : delay, _pump);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      for (final group in List.of(_groups)) {
        final engine = _engines[group.groupId];
        if (engine == null) continue;
        final wake = engine.nextWakeAt;
        if (wake == null || wake.isAfter(DateTime.now())) continue;
        final blobs = engine.poll(DateTime.now());
        final channelIndex = channelIndexFor(group);
        // What cannot go out now is not lost for good: after reconnecting,
        // the hello status reveals our frontier and the others ask for it.
        if (channelIndex == null) continue;
        for (final blob in blobs) {
          if (!_connector.isConnected) break;
          try {
            await _connector.sendReliableGroupBlob(
              blob,
              channelIndex: channelIndex,
            );
          } on Object catch (e) {
            appLogger.warn('Reliable group send failed: $e');
          }
        }
      }
    } finally {
      _pumping = false;
    }
    notifyListeners();
    _scheduleWake();
  }

  @override
  void dispose() {
    _connector.removeListener(_onConnectorChanged);
    unawaited(_frames.cancel());
    _wakeTimer?.cancel();
    _flushSaves();
    super.dispose();
  }
}
