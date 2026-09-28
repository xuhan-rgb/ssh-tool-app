import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  setUp(() {
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = null;
  });

  tearDown(() {
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = null;
  });

  String conversation(String id, String title) => jsonEncode({
        'id': id,
        'cwd': '/workspace',
        'title': title,
      });

  test('listAll populates immutable per-connection snapshot and refreshes it',
      () async {
    var callCount = 0;
    CodexSessionService.runPythonOverride = (connectionId, script, args) async {
      expect(connectionId, 'one');
      expect(args, ['__all__', '0']);
      callCount++;
      return conversation('id-$callCount', 'title-$callCount');
    };

    expect(CodexSessionService.cachedConversations('one'), isNull);
    await CodexSessionService.listAll('one');
    final first = CodexSessionService.cachedConversations('one')!;
    expect(first.single.id, 'id-1');
    expect(() => first.add(first.single), throwsUnsupportedError);
    await CodexSessionService.listAllPage('one', 0);
    expect(CodexSessionService.cachedConversations('one')!.single.id, 'id-2');
    expect(callCount, 2);
  });

  test('conversation records refresh independently by connection and id',
      () async {
    var callCount = 0;
    CodexSessionService.runPythonOverride = (connectionId, script, args) async {
      callCount++;
      return jsonEncode({'kind': 'user', 'text': '$connectionId-$callCount'});
    };

    await CodexSessionService.readConversation('one', 'a');
    await CodexSessionService.readConversation('two', 'a');
    await CodexSessionService.readConversation('one', 'b');
    expect(CodexSessionService.cachedRecords('one', 'a')!.single.text, 'one-1');
    expect(CodexSessionService.cachedRecords('two', 'a')!.single.text, 'two-2');
    expect(CodexSessionService.cachedRecords('one', 'b')!.single.text, 'one-3');
    expect(() => CodexSessionService.cachedRecords('one', 'a')!.clear(),
        throwsUnsupportedError);
  });

  test('inflight requests coalesce, failures retain snapshots and retry',
      () async {
    final completer = Completer<String>();
    var listCalls = 0;
    CodexSessionService.runPythonOverride = (connectionId, script, args) {
      listCalls++;
      return completer.future;
    };
    final first = CodexSessionService.listAllPage('one', 0);
    final second = CodexSessionService.listAllPage('one', 0);
    await Future<void>.delayed(Duration.zero);
    expect(listCalls, 1);
    completer.complete(conversation('cached', 'cached'));
    await Future.wait([first, second]);

    CodexSessionService.runPythonOverride = (connectionId, script, args) async {
      throw StateError('offline');
    };
    await expectLater(CodexSessionService.listAll('one'), throwsStateError);
    expect(CodexSessionService.cachedConversations('one')!.single.id, 'cached');

    CodexSessionService.runPythonOverride =
        (connectionId, script, args) async => '';
    await CodexSessionService.listAll('one');
    expect(CodexSessionService.cachedConversations('one'), isEmpty);
  });

  test('clear prevents old inflight result from repopulating cache', () async {
    final completer = Completer<String>();
    CodexSessionService.runPythonOverride =
        (connectionId, script, args) => completer.future;
    final request = CodexSessionService.listAll('one');
    await Future<void>.delayed(Duration.zero);
    CodexSessionService.clearCache('one');
    completer.complete(conversation('stale', 'stale'));
    await request;
    expect(CodexSessionService.cachedConversations('one'), isNull);
  });
}
