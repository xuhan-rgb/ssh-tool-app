import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/conversation_sync.dart';

void main() {
  Map<String, dynamic> row(String id, String text) =>
      {'_syncId': id, 'kind': 'assistant', 'text': text};
  String snapshot(String version, List<Map<String, dynamic>> records) =>
      jsonEncode({
        'protocol': 1,
        'type': 'snapshot',
        'version': version,
        'records': records
      });
  List<dynamic> decode(String raw) => raw.split('\n').map(jsonDecode).toList();

  test('snapshot, updates, removals and unchanged preserve full local records',
      () async {
    final sync = ConversationSync();
    final first = await sync.read('host', 'chat', (version) async {
      expect(version, '');
      return snapshot('v1', [row('1', 'old'), row('2', 'running')]);
    });
    expect(decode(first), [row('1', 'old'), row('2', 'running')]);
    final next = await sync.read('host', 'chat', (version) async {
      expect(version, 'v1');
      return jsonEncode({
        'protocol': 1,
        'type': 'delta',
        'base': 'v1',
        'version': 'v2',
        'upserts': [row('2', 'done'), row('3', 'new')],
        'removed': ['1'],
        'order': ['2', '3']
      });
    });
    expect(decode(next), [row('2', 'done'), row('3', 'new')]);
    expect(
        await sync.read(
            'host',
            'chat',
            (version) async => jsonEncode({
                  'protocol': 1,
                  'type': 'unchanged',
                  'version': version,
                })),
        next);
  });

  test('failed request or invalid delta cannot advance the cursor', () async {
    final sync = ConversationSync();
    await sync.read('h', 'c', (_) async => snapshot('v1', [row('1', 'saved')]));
    await expectLater(
        sync.read('h', 'c', (_) async => throw StateError('offline')),
        throwsStateError);
    await expectLater(
        sync.read(
            'h',
            'c',
            (_) async => jsonEncode({
                  'protocol': 1,
                  'type': 'delta',
                  'base': 'v1',
                  'version': 'v2',
                  'upserts': [row('2', 'new')],
                  'removed': [],
                  'order': ['missing'],
                })),
        throwsFormatException);
    final result = await sync.read('h', 'c', (version) async {
      expect(version, 'v1');
      return jsonEncode(
          {'protocol': 1, 'type': 'unchanged', 'version': version});
    });
    expect(decode(result), [row('1', 'saved')]);
  });

  test('coalesces requests and clear rejects stale in-flight state', () async {
    final sync = ConversationSync();
    final pending = Completer<String>();
    var calls = 0;
    Future<String> request(String version) {
      calls++;
      return pending.future;
    }

    final first = sync.read('h', 'c', request);
    final second = sync.read('h', 'c', request);
    expect(calls, 1);
    sync.clear('h');
    pending.complete(snapshot('stale', [row('1', 'stale')]));
    await Future.wait([first, second]);
    await sync.read('h', 'c', (version) async {
      expect(version, '');
      return snapshot('fresh', []);
    });
  });

  test('isolates hosts and resets evicted snapshots with their cursors',
      () async {
    final sync = ConversationSync();
    for (var i = 0; i < 25; i++) {
      await sync.read('h', '$i', (_) async => snapshot('v$i', []));
    }
    await sync.read('h', '0', (version) async {
      expect(version, '');
      return snapshot('new', []);
    });
    await sync.read('other', '0', (version) async {
      expect(version, '');
      return snapshot('other', []);
    });
    sync.clear('other');
    await sync.read('h', '0', (version) async {
      expect(version, 'new');
      return snapshot('new', []);
    });
  });
}
