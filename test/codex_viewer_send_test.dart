import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/widgets/chat_markdown.dart';

void main() {
  setUp(() => CodexSessionService.clearCache());

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
          sendMessage: (message) async {
            sent.add(message);
            await pending.future;
            return CodexMessageRoute.queue;
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
      expect(find.byWidgetPredicate(
          (widget) => widget is ChatMarkdown && widget.data == message), findsOneWidget);
      expect(find.text('发送中…'), findsOneWidget);
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
      expect(find.byWidgetPredicate(
          (widget) => widget is ChatMarkdown && widget.data == message), findsOneWidget);
      expect(find.text('已发送到远程队列'), findsNothing);
      final completedReads = reads;
      await tester.pump(const Duration(seconds: 4));
      expect(reads, completedReads);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final finishAfterReopen in [false, true]) {
    testWidgets(
        'reopening restores queued status (send finishes after reopen: $finishAfterReopen)',
        (tester) async {
      var received = false;
      var reads = 0;
      final sendCompleted = Completer<void>();
      Widget viewer() => MaterialApp(
            home: CodexConversationViewerDialog(
              conversation: const CodexConversation(
                id: 'reopened-thread',
                cwd: '/p',
                title: '队列恢复',
                updatedAt: null,
                state: CodexConversationState.complete,
              ),
              sendMessage: (_) async {
                await sendCompleted.future;
                return CodexMessageRoute.queue;
              },
              loadRecords: (_) async {
                reads++;
                return [
                  if (received)
                    const CodexConversationRecord(
                        kind: 'user', timestamp: null, text: '继续处理'),
                  const CodexConversationRecord(
                      kind: 'task_complete', timestamp: null, text: '完成'),
                ];
              },
            ),
          );
      await tester.pumpWidget(viewer());
      await tester.pump();
      await tester.enterText(
          find.byKey(const ValueKey('viewer-message-input')), '继续处理');
      await tester.tap(find.byKey(const ValueKey('viewer-send-message')));
      await tester.pump();
      if (!finishAfterReopen) {
        sendCompleted.complete();
        await tester.pump();
        expect(find.text('已发送到远程队列'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(viewer());
      await tester.pump();
      if (finishAfterReopen) {
        sendCompleted.complete();
        await tester.pump();
      }
      expect(find.text('已发送到远程队列'), findsOneWidget);
      expect(find.textContaining('等待远程处理'), findsOneWidget);
      expect(find.byWidgetPredicate(
          (widget) => widget is ChatMarkdown && widget.data == '继续处理'), findsOneWidget);
      final beforePoll = reads;
      await tester.pump(const Duration(seconds: 2));
      expect(reads, greaterThan(beforePoll));
      received = true;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(find.text('已发送到远程队列'), findsNothing);
      expect(find.textContaining('等待远程处理'), findsNothing);
      final completedReads = reads;
      await tester.pump(const Duration(seconds: 4));
      expect(reads, completedReads);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('shows the message and service-selected steer receipt',
      (tester) async {
    final sent = <String>[];
    var received = false;
    final sending = Completer<void>();
    Widget viewer() => MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(id: 'steer-thread', cwd: '/p',
            title: '补充当前任务', updatedAt: null,
            state: CodexConversationState.running),
        sendMessage: (message) async {
          sent.add(message);
          await sending.future;
          return CodexMessageRoute.steer;
        },
        loadRecords: (_) async => [
          if (received)
            const CodexConversationRecord(kind: 'user', timestamp: null,
                text: '请检查边界情况'),
        ],
      ),
    );
    await tester.pumpWidget(viewer());
    await tester.pump();
    expect(find.byKey(const ValueKey('viewer-message-route')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('viewer-message-input')),
        '请检查边界情况');
    await tester.tap(find.byKey(const ValueKey('viewer-send-message')));
    await tester.pump();
    expect(sent, ['请检查边界情况']);
    expect(find.text('发送中…'), findsOneWidget);
    sending.complete();
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(viewer());
    await tester.pump();
    expect(find.text('已提交 Steer · 等待 Codex 接收'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is ChatMarkdown &&
        w.data == '请检查边界情况'), findsOneWidget);
    received = true;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('已提交 Steer · 等待 Codex 接收'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is ChatMarkdown &&
        w.data == '请检查边界情况'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle conversations use the service-selected queue route',
      (tester) async {
    CodexMessageRoute? sentRoute;
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(id: 'idle-thread', cwd: '/p',
            title: '空闲对话', updatedAt: null,
            state: CodexConversationState.notStarted),
        sendMessage: (_) async {
          sentRoute = CodexMessageRoute.queue;
          return sentRoute!;
        },
        loadRecords: (_) async => const [],
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('viewer-message-route')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('viewer-message-input')),
        '开始新一轮');
    await tester.tap(find.byKey(const ValueKey('viewer-send-message')));
    await tester.pump();
    expect(sentRoute, CodexMessageRoute.queue);
    expect(find.text('已发送到远程队列'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('send failure preserves the draft',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(id: 'steer-failed', cwd: '/p',
            title: '发送失败', updatedAt: null),
        sendMessage: (_) async => throw StateError('发送失败'),
        loadRecords: (_) async => const [],
      ),
    ));
    await tester.pump();
    final input = find.byKey(const ValueKey('viewer-message-input'));
    await tester.enterText(input, '保留补充信息');
    await tester.tap(find.byKey(const ValueKey('viewer-send-message')));
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '保留补充信息');
    expect(find.textContaining('Bad state: 发送失败'), findsOneWidget);
    expect(find.text('发送中…'), findsNothing);
    expect(find.text('已提交 Steer · 等待 Codex 接收'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is ChatMarkdown &&
        w.data == '保留补充信息'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('failed queue keeps the draft and exposes the remote error',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(id: 'failed-thread', cwd: '/p',
            title: '失败', updatedAt: null),
        sendMessage: (_) async => throw StateError('queue is unsupported'),
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

  testWidgets('shows refresh failure with cached records and recovers queued message',
      (tester) async {
    var failRefresh = false;
    var recovered = false;
    var sends = 0;
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(id: 'sync-thread', cwd: '/p',
            title: '同步诊断', updatedAt: null,
            state: CodexConversationState.complete),
        sendMessage: (_) async {
          sends++;
          return CodexMessageRoute.queue;
        },
        loadRecords: (_) async {
          reads++;
          if (failRefresh && !recovered) {
            throw StateError('connection reset');
          }
          return [
            const CodexConversationRecord(kind: 'user', timestamp: null,
                text: 'hello'),
            if (recovered)
              const CodexConversationRecord(kind: 'user', timestamp: null,
                  text: 'secondhello'),
            const CodexConversationRecord(kind: 'assistant', timestamp: null,
                text: 'answer'),
            const CodexConversationRecord(kind: 'task_complete',
                timestamp: null, text: '完成'),
          ];
        },
      ),
    ));
    await tester.pump();
    await tester.pump();
    failRefresh = true;
    await tester.enterText(
        find.byKey(const ValueKey('viewer-message-input')), 'secondhello');
    await tester.tap(find.byKey(const ValueKey('viewer-send-message')));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('同步记录失败，消息处理状态尚未确认'), findsOneWidget);
    expect(find.textContaining('connection reset'), findsOneWidget);
    expect(find.text('已发送到远程队列'), findsOneWidget);
    expect(find.text('hello'), findsOneWidget);
    expect(sends, 1);

    final readsBeforeResume = reads;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads, greaterThan(readsBeforeResume));
    expect(sends, 1);

    recovered = true;
    await tester.tap(find.text('重试'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('同步记录失败，消息处理状态尚未确认'), findsNothing);
    expect(find.text('已发送到远程队列'), findsNothing);
    expect(find.text('secondhello'), findsOneWidget);
    expect(find.text('answer'), findsOneWidget);
    expect(sends, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Codex picker keeps text chat selected when legacy terminal mode is stored',
      (tester) async {
    final settingsDirectory = await tester.runAsync(() async {
      final directory =
          await Directory.systemTemp.createTemp('ssh_tool_settings');
      Hive.init(directory.path);
      await Hive.openBox('settings');
      return directory;
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        await Hive.close();
        await settingsDirectory!.delete(recursive: true);
      });
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/p',
        initialOpenAsChat: false,
        loadConversations: (_) async => const [],
        loadRecords: (_) async => const [],
        loadDirectories: (path) async =>
            RemoteDirectoryListing(path: path, dirs: const []),
      ),
    ));
    await tester.pump();
    expect(find.text('聊天'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('codex-open-mode')));
    await tester.pump(const Duration(milliseconds: 300));
    final terminalItem = tester.widget<CheckedPopupMenuItem<bool>>(
        find.widgetWithText(CheckedPopupMenuItem<bool>, '终端'));
    expect(terminalItem.enabled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
