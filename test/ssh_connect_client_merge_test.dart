import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final config = SshConnection(
    id: 'merge-test',
    name: 'test',
    host: 'localhost',
    username: 'user',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  tearDown(() => SshService.connectClientOverride = null);

  test('merges same-id client connection attempts', () async {
    final gate = Completer<TerminalSession>();
    var calls = 0;
    SshService.connectClientOverride = (_) {
      calls++;
      return gate.future;
    };
    final first = SshService.connectClient(config);
    final second = SshService.connectClient(config);
    expect(calls, 1);
    final session = TerminalSession(config.id);
    gate.complete(session);
    expect(await first, same(session));
    expect(await second, same(session));
  });

  test('clears failed in-flight connection so it can retry', () async {
    var calls = 0;
    SshService.connectClientOverride = (_) async {
      calls++;
      if (calls == 1) throw StateError('offline');
      return TerminalSession(config.id);
    };
    await expectLater(SshService.connectClient(config), throwsStateError);
    final result = await SshService.connectClient(config);
    expect(result.connectionId, config.id);
    expect(calls, 2);
  });
}
