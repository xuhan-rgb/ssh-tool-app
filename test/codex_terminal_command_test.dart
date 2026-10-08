import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/connection_form_screen.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('codex_terminal_command');
    Hive.init(directory.path);
    Hive.registerAdapter(SshConnectionAdapter());
    await Hive.openBox('settings');
    await Hive.openBox<SshConnection>('connections');
  });
  setUp(() async {
    await Hive.box('settings').clear();
    await Hive.box<SshConnection>('connections').clear();
  });
  tearDown(() => CodexSessionService.runPythonOverride = null);
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('command persists per connection and blank restores the default',
      () async {
    expect(StorageService.getCodexTerminalCommand('first'),
        StorageService.defaultCodexTerminalCommand);
    await StorageService.setCodexTerminalCommand('first', '  codex-yolo  ');
    await Hive.box('settings').close();
    await Hive.openBox('settings');
    expect(StorageService.getCodexTerminalCommand('first'), 'codex-yolo');
    expect(StorageService.getCodexTerminalCommand('second'),
        StorageService.defaultCodexTerminalCommand);
    await StorageService.setCodexTerminalCommand('first', '   ');
    expect(StorageService.getCodexTerminalCommand('first'),
        StorageService.defaultCodexTerminalCommand);
  });

  test('new Codex terminal uses the configured command', () async {
    await StorageService.setCodexTerminalCommand('first', 'codex-yolo');
    expect(SessionType.codex.autoCommandForConnection('first'), 'codex-yolo');
    expect(SessionType.claude.autoCommandForConnection('first'), 'claude');
    expect(SessionType.shell.autoCommandForConnection('first'), isNull);
  });

  test('resume and fork append arguments and quote the conversation id', () {
    expect(
      CodexSessionService.commandForConversation("session'quoted",
          startupCommand: 'codex-yolo'),
      "codex-yolo resume 'session'\"'\"'quoted'",
    );
    expect(
      CodexSessionService.commandForConversation('session-id',
          startupCommand: '/opt/codex/bin/codex --model example',
          launch: CodexConversationLaunch.fork),
      "/opt/codex/bin/codex --model example fork 'session-id'",
    );
  });

  test('resume in existing tmux passes the configured command to the script',
      () async {
    await StorageService.setCodexTerminalCommand('first', 'codex-yolo');
    CodexSessionService.runPythonOverride = (connectionId, script, args) async {
      expect(connectionId, 'first');
      expect(args,
          ['terminal', 'resume', 'thread-id', "codex-yolo resume 'thread-id'"]);
      expect(script, contains('command = sys.argv[4]'));
      return 'ready';
    };
    await CodexSessionService.resumeInTmux('first', 'terminal', 'thread-id');
  });

  testWidgets('connection editor loads and saves the terminal command',
      (tester) async {
    final connection = SshConnection.create(
        name: 'test',
        host: 'localhost',
        username: 'user',
        password: 'password');
    await tester.runAsync(() async {
      await StorageService.saveConnection(connection);
      await StorageService.setCodexTerminalCommand(connection.id, 'codex-yolo');
    });
    await tester.pumpWidget(
        MaterialApp(home: ConnectionFormScreen(connection: connection)));
    final field = find.widgetWithText(TextFormField, 'Codex 终端启动命令');
    await tester.ensureVisible(field);
    expect(find.descendant(of: field, matching: find.text('codex-yolo')),
        findsOneWidget);
    await tester.enterText(field, '/opt/codex/bin/codex');
    final save = find.text('保存修改');
    await tester.ensureVisible(save);
    await tester.runAsync(() async {
      await tester.tap(save);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(StorageService.getCodexTerminalCommand(connection.id),
        '/opt/codex/bin/codex');
    expect(tester.takeException(), isNull);
  });
}
