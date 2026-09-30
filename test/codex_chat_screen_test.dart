import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_chat_screen.dart';
import 'package:ssh_tool_app/services/codex_chat_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';
import 'package:ssh_tool_app/services/notification_service.dart';

void main() {
  late Directory settingsDirectory;
  setUpAll(() async {
    settingsDirectory = await Directory.systemTemp.createTemp('codex-chat-ui-');
    Hive.init(settingsDirectory.path);
    await Hive.openBox('settings');
  });
  tearDownAll(() async => settingsDirectory.delete(recursive: true));

  testWidgets('completion in background stays unread until the conversation resumes', (tester) async {
    final result = Completer<CodexChatResult>();
    var started = false;
    final now = DateTime.now();
    addTearDown(() {
      if (tester.binding.lifecycleState == AppLifecycleState.paused) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      }
      if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      }
      if (tester.binding.lifecycleState != AppLifecycleState.resumed) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      }
      NotificationService.isAppInForeground = true;
    });
    await tester.pumpWidget(MaterialApp(home: CodexChatScreen(
      connection: SshConnection(id: 'background-read', name: 'test', host: 'localhost',
        username: 'test', createdAt: now, updatedAt: now),
      workDir: '/project', sendMessage: (_) { started = true; return result.future; },
    )));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '隔离测试');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    expect(started, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    NotificationService.isAppInForeground = false;
    await tester.runAsync(() => NotificationService.recordCodexFinished(
        'background-read', 'background-thread', 'background-job'));
    result.complete(const CodexChatResult(threadId: 'background-thread', answer: '完成'));
    await tester.pump();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    bool isRead() => StorageService.getCodexCompletionNotices()
        .firstWhere((notice) => notice.id == 'background-read:background-job').read;
    expect(isRead(), isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    NotificationService.isAppInForeground = true;
    await tester.pump();
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    expect(isRead(), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'draft and completed chat show remote session state and can close',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    var closes = 0;
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'persistent-session',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        sendMessage: (_) async =>
            const CodexChatResult(threadId: 'thread', answer: '答复'),
        closeRemoteSession: (_) async {
          closes++;
        },
      ),
    ));
    expect(find.text('尚未启动·发送首条消息后启动远程会话'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '问题');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('等待消息·远程已打开'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    expect(find.text('关闭远程会话'), findsOneWidget);
    await tester.tap(find.text('关闭远程会话'));
    await tester.pump();
    expect(closes, 1);
    expect(find.text('等待消息·远程已关闭'), findsOneWidget);
  });

  testWidgets('/clear starts a new context without erasing visible messages',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'clear-chat',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/workspace/project',
        sendMessage: (_) async => CodexChatResult(
            threadId: 'thread-${++sends}', answer: '旧答复'),
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '旧问题');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    expect(find.text('旧答复'), findsOneWidget);
    expect(StorageService.getOpenedCodexConversations('clear-chat'),
        contains('thread-1'));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '未发送的草稿');
    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空上下文'));
    await tester.pump();
    expect(find.text('旧问题'), findsWidgets);
    expect(find.text('旧答复'), findsOneWidget);
    expect(find.textContaining('上下文已清空'), findsOneWidget);
    expect(find.textContaining('/workspace/project'), findsOneWidget);
    expect(
        tester.widget<TextField>(find.byKey(const ValueKey('chat-input')))
            .controller!
            .text,
        '未发送的草稿');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    expect(find.text('旧答复'), findsWidgets);
    expect(find.text('未发送的草稿'), findsWidgets);
    expect(StorageService.getOpenedCodexConversations('clear-chat'),
        contains('thread-2'));
  });

  testWidgets('opening the more menu keeps the current reading position',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 9, 24);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'menu-scroll',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        sendMessage: (_) async => CodexChatResult(
            threadId: 'same-thread',
            answer: List.filled(30, '较长的回复内容。').join()),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.enterText(find.byKey(const ValueKey('chat-input')), '问题 $i');
      await tester.tap(find.byKey(const ValueKey('chat-send')));
      await tester.pump();
    }
    final messages = find.byKey(const ValueKey('chat-messages'));
    await tester.drag(messages, const Offset(0, 300));
    await tester.pump();
    final scroll = tester.widget<ListView>(messages).controller!;
    final position = scroll.position.pixels;
    expect(position, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, position);
  });

  testWidgets('opening a top menu preserves an IME draft', (tester) async {
    final now = DateTime(2026, 9, 24);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'ime-draft',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
      ),
    ));
    final input = find.byKey(const ValueKey('chat-input'));
    await tester.enterText(input, '尚未发送');
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
    tester.widget<TextField>(input).controller!.clear();
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '尚未发送');
  });

  testWidgets('/clear waits for the active reply', (tester) async {
    final now = DateTime(2026, 9, 24);
    final reply = Completer<CodexChatResult>();
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'clear-pending',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        sendMessage: (_) => reply.future,
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '问题');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空上下文'));
    await tester.pump();
    expect(find.text('问题'), findsWidgets);
    reply.complete(const CodexChatResult(threadId: 'old', answer: '答复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('问题'), findsWidgets);
    expect(find.text('答复'), findsOneWidget);
    expect(find.textContaining('上下文已清空'), findsOneWidget);
  });

  testWidgets('/clear waits for messages already queued in the old chat',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    final replies = [Completer<CodexChatResult>(), Completer<CodexChatResult>()];
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'clear-queue',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        sendMessage: (_) => replies[sends++].future,
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '第一条');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '第二条');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空上下文'));
    await tester.pump();
    replies[0].complete(
        const CodexChatResult(threadId: 'old', answer: '第一条答复'));
    await tester.pump();
    expect(sends, 2);
    expect(find.text('第一条答复'), findsOneWidget);
    replies[1].complete(
        const CodexChatResult(threadId: 'old', answer: '第二条答复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('第一条答复'), findsOneWidget);
    expect(find.text('第二条答复'), findsOneWidget);
    expect(find.textContaining('上下文已清空'), findsOneWidget);
  });

  testWidgets('chat title keeps the last directory visible on a narrow phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 9, 24);
    const path = '/mnt/data/projects/very_long_parent_name/last_folder';
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'path-title',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: path,
      ),
    ));
    expect(find.textContaining('last_folder'), findsOneWidget);
    expect(find.byTooltip(path), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('chat-input'))).width,
        greaterThan(270));
    expect(find.text('清空上下文'), findsNothing);
  });

  testWidgets('token display choice survives opening another conversation',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    final connection = SshConnection(
      id: 'token-preference',
      name: 'test',
      host: 'localhost',
      username: 'test',
      createdAt: now,
      updatedAt: now,
    );
    Widget chat(String path) => MaterialApp(
          home: CodexChatScreen(
            key: ValueKey(path),
            connection: connection,
            workDir: path,
            sendMessage: (_) async =>
                const CodexChatResult(threadId: 'thread', answer: '完成'),
          ),
        );
    await tester.pumpWidget(chat('/first'));
    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(
        CheckedPopupMenuItem<String>, '显示 Token 用量'));
    await tester.pump();
    expect(StorageService.getCodexShowTokenUsage(), isTrue);
    await tester.pumpWidget(chat('/second'));
    await tester.tap(find.byKey(const ValueKey('chat-display-options')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckedPopupMenuItem<String>>(find.widgetWithText(
                CheckedPopupMenuItem<String>, '显示 Token 用量'))
            .checked,
        isTrue);
  });

  testWidgets('favorites a new text conversation after its first reply',
      (tester) async {
    final created = <String>[];
    final now = DateTime(2026, 9, 24);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'connection',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        favoriteOnCreate: true,
        onConversationCreated: (id) async => created.add(id),
        sendMessage: (_) async =>
            const CodexChatResult(threadId: 'new-thread', answer: '完成'),
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '你好');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    expect(created, ['new-thread']);
  });

  testWidgets('queues a message during a reply and sends it after completion',
      (tester) async {
    final reply = Completer<CodexChatResult>();
    final watchedJobs = <String>[];
    var sendCount = 0;
    final now = DateTime(2026, 9, 24);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'test-connection',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/workspace',
        conversation: CodexConversation(
          id: 'thread-1',
          cwd: '/workspace',
          updatedAt: now,
          title: '接回任务',
          state: CodexConversationState.running,
        ),
        runningJobId: 'job-1',
        watchRunningJob: (jobId) {
          watchedJobs.add(jobId);
          return reply.future;
        },
        sendMessage: (_) async {
          sendCount++;
          return const CodexChatResult(threadId: 'thread-1', answer: '新回复');
        },
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(watchedJobs, ['job-1']);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '下一条');
    final send =
        tester.widget<IconButton>(find.byKey(const ValueKey('chat-send')));
    expect(send.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    expect(find.textContaining('待发送 1 条'), findsOneWidget);
    expect(sendCount, 0);

    reply.complete(const CodexChatResult(threadId: 'thread-1', answer: '完成'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('chat-send')))
            .onPressed,
        isNotNull);
    expect(sendCount, 1);
    expect(find.textContaining('待发送 1 条'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('can return to the list while a remote reply is running',
      (tester) async {
    final reply = Completer<CodexChatResult>();
    final queued = <String>[];
    final now = DateTime(2026, 9, 23);
    final connection = SshConnection(
      id: 'test-connection',
      name: 'test',
      host: 'localhost',
      username: 'test',
      createdAt: now,
      updatedAt: now,
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => CodexChatScreen(
                connection: connection,
                workDir: '/workspace',
                sendMessage: (prompt) {
                  if (prompt == '测试消息') return reply.future;
                  queued.add(prompt);
                  return Future.value(const CodexChatResult(
                      threadId: 'thread-1', answer: '后续完成'));
                },
              ),
            )),
            child: const Text('聊天列表'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('聊天列表'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '测试消息');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    expect(find.textContaining('等待远端输出'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '排队消息');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();

    await tester.tap(find.byTooltip('返回对话列表'));
    await tester.pumpAndSettle();
    expect(find.text('聊天列表'), findsOneWidget);
    expect(find.byType(CodexChatScreen), findsNothing);

    reply.complete(const CodexChatResult(threadId: 'thread-1', answer: '完成'));
    await tester.pump();
    expect(queued, ['排队消息']);
    expect(tester.takeException(), isNull);
  });
}
