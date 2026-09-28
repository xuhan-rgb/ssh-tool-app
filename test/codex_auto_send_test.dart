import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in [
    (state: 'running', locked: true, route: CodexMessageRoute.steer),
    (state: 'pending', locked: true, route: CodexMessageRoute.steer),
    (state: 'complete', locked: true, route: CodexMessageRoute.queue),
    (state: 'complete', locked: false, route: CodexMessageRoute.queue),
    (state: 'aborted', locked: false, route: CodexMessageRoute.queue),
    (state: 'not_started', locked: false, route: CodexMessageRoute.queue),
    (state: 'pending', locked: false, route: CodexMessageRoute.queue),
  ]) {
    test('fresh ${scenario.state} / locked=${scenario.locked} uses ${scenario.route}',
        () async {
      final calls = <List<String>>[];
      final previous = CodexSessionService.runPythonOverride;
      CodexSessionService.runPythonOverride = (_, script, args) async {
        calls.add(args);
        if (args.first == 'id:thread') {
          return jsonEncode({'id': 'thread', 'cwd': '/project',
            'state': scenario.state, 'writerLocked': scenario.locked});
        }
        expect(script.contains("rpc.request('turn/steer'"),
            scenario.route == CodexMessageRoute.steer);
        expect(args, ['thread', '原样消息\n "引号" ']);
        return '';
      };
      addTearDown(() => CodexSessionService.runPythonOverride = previous);
      expect(await CodexSessionService.sendMessage(
          'connection', 'thread', '原样消息\n "引号" '), scenario.route);
      expect(calls.length, 2);
      expect(calls.first, ['id:thread']);
    });
  }

  test('every send rechecks state and steer failure never falls back to queue',
      () async {
    var state = 'running';
    var reads = 0;
    final sends = <CodexMessageRoute>[];
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      if (args.first == 'id:thread') {
        reads++;
        return jsonEncode({'id': 'thread', 'cwd': '/p',
          'state': state, 'writerLocked': true});
      }
      if (script.contains("rpc.request('turn/steer'")) {
        sends.add(CodexMessageRoute.steer);
        throw StateError('实时接口不可用');
      }
      sends.add(CodexMessageRoute.queue);
      return '';
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);
    await expectLater(CodexSessionService.sendMessage('c', 'thread', 'hello'),
        throwsStateError);
    expect(sends, [CodexMessageRoute.steer]);
    state = 'complete';
    expect(await CodexSessionService.sendMessage('c', 'thread', 'hello'),
        CodexMessageRoute.queue);
    expect(reads, 2);
    expect(sends, [CodexMessageRoute.steer, CodexMessageRoute.queue]);
  });

  for (final remote in [
    '',
    jsonEncode({'id': 'thread', 'cwd': '/p', 'state': 'unknown'}),
    jsonEncode({'id': 'thread', 'cwd': '/p', 'state': 'complete', 'isSubagent': true}),
  ]) {
    test('unavailable or unsupported conversation never sends: $remote', () async {
      var calls = 0;
      final previous = CodexSessionService.runPythonOverride;
      CodexSessionService.runPythonOverride = (_, __, args) async {
        calls++;
        expect(args, ['id:thread']);
        return remote;
      };
      addTearDown(() => CodexSessionService.runPythonOverride = previous);
      await expectLater(CodexSessionService.sendMessage('c', 'thread', 'hello'),
          throwsStateError);
      expect(calls, 1);
    });
  }
}
