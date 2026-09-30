import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/claude_conversation_picker_screen.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/claude_runtime_service.dart';
import 'package:ssh_tool_app/services/claude_session_service.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('claude-layout-');
    Hive.init(directory.path);
    await Hive.openBox('settings');
    SshService.connectClientOverride = (_) async => TerminalSession('layout');
    ClaudeRuntimeService.requestOverride = (_, action, __) async =>
        action == 'list' ? [] : {'session': null, 'messages': []};
    ClaudeSessionService.runPythonOverride = (_, __, ___) async => jsonEncode({
          'id': 'layout-test',
          'cwd': '/work/project',
          'title': 'Shared layout',
          'updatedAt': '2026-09-29T01:00:00Z',
          'state': 'unknown',
          'preview': 'Visible preview',
        });
  });
  tearDown(() async {
    SshService.connectClientOverride = null;
    ClaudeRuntimeService.requestOverride = null;
    ClaudeSessionService.runPythonOverride = null;
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('Claude uses the same picker layout as Codex', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = SshConnection(
        id: 'layout',
        name: 'server',
        host: 'localhost',
        username: 'user',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026));
    await tester.pumpWidget(MaterialApp(
        home: ClaudeConversationPickerScreen(connection: connection)));
    await tester.pumpAndSettle();
    expect(find.byType(CodexSessionDialog), findsOneWidget);
    expect(find.text('对话'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorites-section-tab')), findsOneWidget);
    expect(find.text('时间筛选'), findsOneWidget);
    expect(find.text('Visible preview'), findsOneWidget);
    expect(find.text('状态未知'), findsOneWidget);
    expect(find.text('日志读取失败'), findsNothing);
    expect(find.byKey(const ValueKey('conversation-directory-/work/project')), findsOneWidget);
    expect(find.text('继续对话'), findsOneWidget);
    expect(find.byTooltip('恢复对话'), findsNothing);
    expect(find.byTooltip('打开终端'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
