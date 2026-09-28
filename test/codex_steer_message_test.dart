import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('steer sends the bundled script and exact message once', () async {
    final calls = <List<String>>[];
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (connection, script, args) async {
      expect(connection, 'connection');
      expect(script, contains("rpc.request('turn/steer'"));
      expect(script, isNot(contains("'turn/interrupt'")));
      calls.add(args);
      throw StateError('expected active turn mismatch');
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);
    await expectLater(
      CodexSessionService.steerMessage('connection', 'thread', '中文\n "引号" '),
      throwsStateError,
    );
    expect(calls, [['thread', '中文\n "引号" ']]);
  });

  test('steer rejects empty inputs before any remote call', () async {
    var called = false;
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, __, ___) async {
      called = true;
      return '';
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);
    await expectLater(CodexSessionService.steerMessage('c', '', 'hello'),
        throwsArgumentError);
    await expectLater(CodexSessionService.steerMessage('c', 't', ' '),
        throwsArgumentError);
    expect(called, false);
  });
}
