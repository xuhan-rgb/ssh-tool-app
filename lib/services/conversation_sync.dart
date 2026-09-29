import 'dart:convert';

import 'conversation_sync_script.dart';

/// Keeps the cursor and its records together; callers still receive JSON lines.
class ConversationSync {
  final _states = <String, _Snapshot>{};
  final _requests = <String, Future<String>>{};

  static String script(String reader, String provider) =>
      '$conversationSyncScript\nsync(${jsonEncode(reader)}, ${jsonEncode(provider)})\n';

  void clear([String? connectionId]) {
    bool matches(String key) =>
        connectionId == null || key.startsWith('$connectionId\u0000');
    _states.removeWhere((key, _) => matches(key));
    _requests.removeWhere((key, _) => matches(key));
  }

  Future<String> read(String connectionId, String conversationId,
      Future<String> Function(String version) request) {
    final key = '$connectionId\u0000$conversationId';
    final existing = _requests[key];
    if (existing != null) return existing;
    final previous = _states[key];
    late final Future<String> pending;
    pending =
        Future<String>.sync(() => request(previous?.version ?? '')).then((raw) {
      final next = _merge(raw, previous);
      if (next == null) return raw; // Legacy JSON-lines readers/test adapters.
      final result = next.records.map(jsonEncode).join('\n');
      if (identical(_requests[key], pending)) {
        _states.remove(key);
        _states[key] = next;
        while (_states.length > 24) {
          _states.remove(_states.keys.first);
        }
      }
      return result;
    }).whenComplete(() {
      if (identical(_requests[key], pending)) _requests.remove(key);
    });
    _requests[key] = pending;
    return pending;
  }

  _Snapshot? _merge(String raw, _Snapshot? previous) {
    dynamic value;
    try {
      value = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (value is! Map || !value.containsKey('protocol')) return null;
    if (value['protocol'] != 1 || value['version'] is! String) {
      throw const FormatException('Unsupported conversation sync response');
    }
    final version = value['version'] as String;
    List<Map<String, dynamic>> rows(dynamic input) {
      final result = (input as List)
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      final ids = result.map((row) => row['_syncId']).toSet();
      if (ids.length != result.length || ids.any((id) => id is! String)) {
        throw const FormatException('Invalid conversation record IDs');
      }
      return result;
    }

    switch (value['type']) {
      case 'snapshot':
        return _Snapshot(version, rows(value['records']));
      case 'unchanged':
        if (previous == null || previous.version != version) {
          throw const FormatException('Conversation cursor mismatch');
        }
        return previous;
      case 'delta':
        if (previous == null || previous.version != value['base']) {
          throw const FormatException('Conversation delta base mismatch');
        }
        final byId = {
          for (final row in previous.records) row['_syncId'] as String: row,
        };
        for (final id in value['removed'] as List) {
          byId.remove(id);
        }
        for (final row in rows(value['upserts'])) {
          byId[row['_syncId'] as String] = row;
        }
        final order = (value['order'] as List).cast<String>();
        if (order.toSet().length != order.length ||
            order.length != byId.length ||
            order.any((id) => !byId.containsKey(id))) {
          throw const FormatException('Invalid conversation delta order');
        }
        return _Snapshot(version, order.map((id) => byId[id]!).toList());
      default:
        throw const FormatException('Unknown conversation sync response');
    }
  }
}

class _Snapshot {
  final String version;
  final List<Map<String, dynamic>> records;
  _Snapshot(this.version, this.records);
}
