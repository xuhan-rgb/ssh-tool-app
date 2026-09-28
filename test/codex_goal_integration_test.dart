import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_chat_screen.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('goal-integration-');
    Hive.init(directory.path);
    await Hive.openBox('settings');
    await StorageService.addOpenedCodexConversation('goal-connection', 'goal-thread');
    await StorageService.markCodexConversationViewed('goal-connection', 'goal-thread',
        viewedAt: DateTime.now().add(const Duration(days: 1)));
  });
  tearDown(() {
    CodexSessionService.runPythonOverride = null;
    CodexSessionService.clearCache();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final viewer in [false, true]) {
    testWidgets('current goal appears in ${viewer ? 'viewer' : 'chat'}',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      const conversation = CodexConversation(
        id: 'goal-thread', cwd: '/project', updatedAt: null,
        title: 'Goal 对话', state: CodexConversationState.complete,
      );
      var goalReads = 0;
      CodexSessionService.runPythonOverride = (connection, script, args) async {
        if (script.contains("'method': 'thread/goal/get'")) {
          expect(connection, 'goal-connection');
          expect(args, ['goal-thread']);
          goalReads++;
          return jsonEncode({
            'objective': '优化渲染时间，同时保证效果',
            'status': 'active',
            'tokenBudget': null,
            'tokensUsed': 123,
          });
        }
        return jsonEncode({'kind': 'assistant', 'text': '已有回复'});
      };
      final Widget screen = viewer
          ? CodexConversationViewerDialog(
              connectionId: 'goal-connection',
              conversation: conversation,
              loadRecords: (_) async => const [],
            )
          : CodexChatScreen(
              connection: SshConnection(
                id: 'goal-connection', name: 'test', host: 'localhost',
                username: 'test', createdAt: DateTime(2026),
                updatedAt: DateTime(2026),
              ),
              workDir: '/project',
              conversation: conversation,
            );
      await tester.pumpWidget(MaterialApp(home: screen));
      await tester.pumpAndSettle();
      expect(goalReads, 1);
      expect(find.text('优化渲染时间，同时保证效果'), findsOneWidget);
      expect(find.byKey(ValueKey(viewer ? 'viewer-message-input' : 'chat-input')),
          findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
