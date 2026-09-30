import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_chat_screen.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_chat_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('codex-context-model-');
    Hive.init(directory.path);
    Hive.registerAdapter(SshConnectionAdapter());
    await Hive.openBox('settings');
    await Hive.openBox<SshConnection>('connections');
    final now = DateTime.now();
    await Hive.box<SshConnection>('connections').put(
        'test',
        SshConnection(
            id: 'test',
            name: 'test',
            host: 'localhost',
            username: 'test',
            createdAt: now,
            updatedAt: now));
    await StorageService.setCodexConversationModel(
        'test', 'confirmed-model', ('new-model', 'low'));
  });
  tearDownAll(() async {
    await directory.delete(recursive: true);
  });
  setUp(() {
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = (_, __, ___) async => 'null';
  });
  tearDown(() => CodexSessionService.runPythonOverride = null);

  const records = [
    CodexConversationRecord(kind: 'user', timestamp: null, text: '旧问题'),
    CodexConversationRecord(kind: 'assistant', timestamp: null, text: '旧答复'),
  ];
  CodexConversationViewerDialog viewer({String id = 'old-thread'}) =>
      CodexConversationViewerDialog(
        connectionId: 'test',
        conversation: CodexConversation(
            id: id,
            cwd: '/project',
            title: '旧对话',
            updatedAt: null,
            state: CodexConversationState.complete),
        loadRecords: (_) async => records,
        loadModels: () async => const [
          CodexModel(
              id: 'new-model',
              name: '新模型',
              defaultEffort: 'low',
              efforts: [CodexReasoningEffort('low', '')])
        ],
      );

  testWidgets(
      'remote viewer clears context into a fresh chat and preserves history',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: viewer()));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('viewer-conversation-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空上下文'));
    await tester.pumpAndSettle();
    final chat = tester.widget<CodexChatScreen>(find.byType(CodexChatScreen));
    expect(chat.conversation, isNull);
    expect(chat.workDir, '/project');
    expect(chat.clearedContextRecords, records);
    expect(find.textContaining('上下文已清空'), findsOneWidget);
    expect(find.text('旧答复'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'remote model option persists selection and sends it with the next message',
      (tester) async {
    final previous = CodexSessionService.runPythonOverride;
    final calls = <List<String>>[];
    CodexSessionService.runPythonOverride = (_, script, args) async {
      if (script.contains('thread_id, message, model, effort, work_dir =')) {
        calls.add(args);
        return '';
      }
      return 'null';
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);
    await tester.pumpWidget(MaterialApp(home: viewer(id: 'model-thread')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('viewer-conversation-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更改模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('low'));
    await tester.pumpAndSettle();
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    expect(find.textContaining('最近一轮'), findsNothing);
    expect(find.textContaining('下一轮模型'), findsNothing);
    expect(StorageService.getCodexConversationModel('test', 'model-thread'),
        ('new-model', 'low'));
    expect(find.text('模型：new-model · 思考强度：低（low） · 下次发送生效'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('viewer-message-input')), '继续');
    await tester.tap(find.byKey(const ValueKey('viewer-send-message')));
    await tester.pump();
    expect(calls, [
      ['model-thread', '继续', 'new-model', 'low', '/project']
    ]);
    expect(find.text('已提交远程执行'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MaterialApp(home: viewer(id: 'model-thread')));
    await tester.pump();
    expect(find.text('模型：new-model · 思考强度：低（low） · 下次发送生效'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-conversation-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空上下文'));
    await tester.pumpAndSettle();
    expect(tester.widget<CodexChatScreen>(find.byType(CodexChatScreen)).initialModel,
        ('new-model', 'low'));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('model summary removes the pending hint after remote configuration matches', (tester) async {
    var current = const [CodexConversationRecord(kind: 'assistant', timestamp: null,
        text: 'old', model: 'old-model', reasoningEffort: 'high')];
    await tester.pumpWidget(MaterialApp(home: CodexConversationViewerDialog(
      connectionId: 'test', conversation: const CodexConversation(id: 'confirmed-model',
        cwd: '/project', title: 'test', updatedAt: null, state: CodexConversationState.complete),
      loadRecords: (_) async => current,
    )));
    await tester.pump();
    expect(find.text('模型：new-model · 思考强度：低（low） · 下次发送生效'), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-reasoning-effort')), findsOneWidget);
    expect(find.textContaining('最近一轮'), findsNothing);
    expect(find.textContaining('下一轮模型'), findsNothing);
    current = const [CodexConversationRecord(kind: 'assistant', timestamp: null,
        text: 'new', model: 'new-model', reasoningEffort: 'low')];
    await tester.tap(find.byTooltip('刷新记录'));
    await tester.pump();
    expect(find.text('模型：new-model · 思考强度：低（low）'), findsOneWidget);
    expect(find.textContaining('下次发送生效'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

}
