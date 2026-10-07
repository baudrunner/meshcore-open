import 'dart:convert';

import '../models/reliable_group.dart';
import '../utils/app_logger.dart';
import 'prefs_manager.dart';

/// Reliable group definitions and protocol state, scoped to the connected
/// radio's identity (first 10 hex chars of its public key), because member
/// indices and sequence numbers belong to that identity.
class ReliableGroupStore {
  static const String _groupsPrefix = 'reliable_groups_';
  static const String _statePrefix = 'reliable_group_state_';

  final String _scope;

  ReliableGroupStore(String publicKeyHex)
    : _scope = publicKeyHex.length >= 10
          ? publicKeyHex.substring(0, 10).toLowerCase()
          : '';

  bool get isScoped => _scope.isNotEmpty;

  List<ReliableGroup> loadGroups() {
    if (!isScoped) return [];
    final raw = PrefsManager.instance.getString('$_groupsPrefix$_scope');
    if (raw == null || raw.isEmpty) return [];
    try {
      return [
        for (final json in jsonDecode(raw) as List)
          ReliableGroup.fromJson((json as Map).cast<String, dynamic>()),
      ];
    } on Object catch (e) {
      appLogger.warn('Stored reliable groups are unreadable: $e');
      return [];
    }
  }

  Future<void> saveGroups(List<ReliableGroup> groups) async {
    if (!isScoped) return;
    await PrefsManager.instance.setString(
      '$_groupsPrefix$_scope',
      jsonEncode([for (final g in groups) g.toJson()]),
    );
  }

  Map<String, dynamic>? loadState(int groupId) {
    if (!isScoped) return null;
    final raw = PrefsManager.instance.getString(_stateKey(groupId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } on Object catch (e) {
      appLogger.warn(
        'Stored state of reliable group $groupId is unreadable: $e',
      );
      return null;
    }
  }

  Future<void> saveState(int groupId, Map<String, dynamic> state) async {
    if (!isScoped) return;
    await PrefsManager.instance.setString(
      _stateKey(groupId),
      jsonEncode(state),
    );
  }

  Future<void> deleteState(int groupId) async {
    if (!isScoped) return;
    await PrefsManager.instance.remove(_stateKey(groupId));
  }

  String _stateKey(int groupId) => '$_statePrefix${_scope}_$groupId';
}
