import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  for (final state in [
    CodexConversationState.running,
    CodexConversationState.complete,
  ]) {
    testWidgets('viewer queues a message for a $state conversation',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final sent = <String>[];
      final pending = Completer<void>();
      var reads = 0;
      var newResult = false;
      const message = '继续这条对话。\n保留 "引号" 和 **格式**';
      await tester.pumpWidget(MaterialApp(
        home: CodexConversationViewerDialog(
          conversation: CodexConversation(
            id: 'same-thread', cwd: '/project', title: '远程任务',
            updatedAt: null, state: state,
          ),
          queueMessage: (message) {
            sent.add(message);
            return pending.future;
          },
          loadRecords: (_) async {
            reads++;
            return [
              if (newResult)
                const CodexConversationRecord(kind: 'user', timestamp: null,
                    text: message),
              CodexConversationRecord(kind: 'assistant', timestamp: null,
                  text: newResult ? '新的结果' : '原有结果'),
              const CodexConversationRecord(kind: 'task_complete',
                  timestamp: null, text: '完成'),
              if (newResult)
                const CodexConversationRecord(kind: 'task_complete',
                    timestamp: null, text: '新一轮完成'),
            ];
          },
        ),
      ));
      await tester.pump();
      final input = find.byKey(const ValueKey('viewer-message-input'));
      final send = find.byKey(const ValueKey('viewer-send-message'));
      await tester.tap(send);
      expect(sent, isEmpty);
      await tester.enterText(input, message);
      await tester.tap(send);
      await tester.pump();
      expect(sent, [message]);
      expect(tester.widget<IconButton>(send).onPressed, isNull);
      pending.complete();
      await tester.pump();
      expect(find.text('已发送到远程队列'), findsOneWidget);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      final beforePoll = reads;
      await tester.pump(const Duration(seconds: 2));
      expect(reads, greaterThan(beforePoll));
      newResult = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('新的结果'), findsOneWidget);
      final completedReads = reads;
      await tester.pump(const Duration(seconds: 4));
      expect(reads, completedReads);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('failed queue keeps the draft and exposes the remote error',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(id: 'failed-thread', cwd: '/p',
            title: '失败', updatedAt: null),
        queueMessage: (_) async => throw StateError('queue is unsupported'),
        loadRecords: (_) async => const [],
      ),
    ));
    await tester.pump();
    final input = find.byKey(const ValueKey('viewer-message-input'));
    await tester.enterText(input, '保留这条消息');
    await tester.tap(find.byKey(const ValueKey('viewer-send-message')));
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '保留这条消息');
    expect(find.textContaining('queue is unsupported'), findsOneWidget);
    expect(find.text('已发送到远程队列'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
