import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/theme/app_theme.dart';
import 'package:ssh_tool_app/widgets/chat_markdown.dart';

void main() {
  testWidgets('running conversation refreshes until its task completes',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: CodexConversationViewerDialog(
        conversation: CodexConversation(
          id: 'running-thread',
          cwd: '/project',
          updatedAt: DateTime(2026, 9, 24),
          title: '正在执行的任务',
          state: CodexConversationState.running,
        ),
        loadRecords: (_) async {
          reads++;
          return [
            const CodexConversationRecord(
                kind: 'user', timestamp: null, text: '开始测试'),
            if (reads >= 2)
              const CodexConversationRecord(
                  kind: 'assistant', timestamp: null, text: '正在更新的答复'),
            if (reads >= 3)
              const CodexConversationRecord(
                  kind: 'task_complete', timestamp: null, text: '任务完成'),
          ];
        },
      ),
    ));
    await tester.pump();
    expect(reads, 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('正在更新的答复'), findsOneWidget);
    Rect bubbleRect(String text) => tester.getRect(find
        .ancestor(
          of: find.byWidgetPredicate(
              (widget) => widget is ChatMarkdown && widget.data == text),
          matching: find.byType(FractionallySizedBox),
        )
        .first);
    final userBubble = bubbleRect('开始测试');
    final assistantBubble = bubbleRect('正在更新的答复');
    expect(userBubble.left, greaterThan(assistantBubble.left));
    expect(userBubble.right, greaterThan(assistantBubble.right));
    expect(userBubble.width, closeTo(assistantBubble.width, 1));
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(reads, 3);
    await tester.pump(const Duration(seconds: 4));
    expect(reads, 3);
  });
  testWidgets(
      'failed refresh reports unknown status then shows the completed reply',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(
            id: 'stalled-thread',
            cwd: '/project',
            updatedAt: null,
            title: 'stalled',
            state: CodexConversationState.running),
        loadRecords: (_) async {
          reads++;
          if (reads == 2) throw TimeoutException('读取超时');
          return [
            const CodexConversationRecord(
                kind: 'task_started',
                timestamp: null,
                text: '任务开始',
                terminalSummary: '任务开始'),
            if (reads >= 3) ...[
              const CodexConversationRecord(
                  kind: 'assistant', timestamp: null, text: '远端已经完成的回复'),
              const CodexConversationRecord(
                  kind: 'task_complete',
                  timestamp: null,
                  text: '任务完成',
                  terminalSummary: '任务完成'),
            ],
          ];
        },
      ),
    ));
    await tester.pump();
    expect(find.textContaining('Working'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('同步中断，状态待确认'), findsOneWidget);
    expect(find.textContaining('Working'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('远端已经完成的回复'), findsOneWidget);
    expect(find.textContaining('同步中断，状态待确认'), findsNothing);
    expect(find.textContaining('Working'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
