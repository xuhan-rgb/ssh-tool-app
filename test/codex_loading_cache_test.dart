import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final connection = SshConnection(
    id: 'cache-host',
    name: 'test',
    host: 'localhost',
    username: 'test',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
  const conversation = CodexConversation(
    id: 'thread',
    cwd: '/project',
    updatedAt: null,
    title: '缓存的对话',
    state: CodexConversationState.complete,
  );

  String record(String text) => jsonEncode({'kind': 'assistant', 'text': text});

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('codex-loading-cache');
    Hive.init(directory.path);
    await Hive.openBox('settings');
    // These tests exercise loading, so keep read-state disk writes outside fakeAsync.
    await StorageService.markCodexConversationViewed(connection.id, conversation.id,
        viewedAt: DateTime.now().add(const Duration(days: 1)));
  });
  setUp(() {
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = null;
  });
  tearDown(() {
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = null;
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('picker shows previous list while SSH reconnects',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionService.runPythonOverride = (_, __, ___) async => jsonEncode({
          'id': 'thread',
          'cwd': '/project',
          'title': '缓存的对话',
          'remoteOpen': true,
          'state': 'complete',
        });
    await CodexSessionService.listAll(connection.id);
    final connecting = Completer<void>();
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationPickerScreen(
        connection: connection,
        connect: () => connecting.future,
      ),
    ));
    await tester.pump();
    expect(find.text('缓存的对话'), findsOneWidget);
    expect(connecting.isCompleted, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('picker retries failed SSH authentication on the next automatic refresh',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Keep bundled-script reads in fakeAsync, so the test can settle without real I/O.
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async => ByteData.sublistView(
          File(utf8.decode(message!.buffer.asUint8List())).readAsBytesSync()),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null));
    rootBundle.evict('assets/codex_steer_message.py');
    final firstConnection = Completer<void>();
    final retryConnection = Completer<void>();
    var attempts = 0;
    CodexSessionService.runPythonOverride = (_, __, ___) async => '';
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationPickerScreen(
        connection: connection,
        connect: () {
          attempts++;
          return attempts == 1 ? firstConnection.future : retryConnection.future;
        },
      ),
    ));
    await tester.pump();
    expect(attempts, 1);
    firstConnection.completeError(Exception('认证中断: 连接被服务器关闭'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('认证中断'), findsOneWidget);
    await tester.pump(const Duration(seconds: 60));
    await tester.pump();
    expect(attempts, 2);
    retryConnection.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('认证中断'), findsNothing);
    expect(find.text('当前没有远程打开的对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'viewer retains cached records while refreshing and after failure',
      (tester) async {
    CodexSessionService.runPythonOverride =
        (_, __, ___) async => record('已有答复');
    await CodexSessionService.readConversation(connection.id, conversation.id);
    final refresh = Completer<String>();
    CodexSessionService.runPythonOverride = (_, __, ___) => refresh.future;
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        connectionId: connection.id,
        conversation: conversation,
        loadRecords: (id) =>
            CodexSessionService.readConversation(connection.id, id),
      ),
    ));
    await tester.pump();
    expect(find.text('已有答复'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    refresh.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.text('已有答复'), findsOneWidget);
    CodexSessionService.runPythonOverride =
        (_, __, ___) async => record('最新答复');
    await tester.tap(find.byTooltip('刷新记录'));
    await tester.pumpAndSettle();
    expect(find.text('最新答复'), findsOneWidget);
    expect(find.text('已有答复'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selected conversation read is reused when its viewer opens',
      (tester) async {
    final refresh = Completer<String>();
    var reads = 0;
    CodexSessionService.runPythonOverride = (_, script, ___) {
      if (script.contains("'method': 'thread/goal/get'")) {
        return Future.value('null');
      }
      reads++;
      return refresh.future;
    };
    final preload =
        CodexSessionService.readConversation(connection.id, conversation.id);
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        connectionId: connection.id,
        conversation: conversation,
        loadRecords: (id) =>
            CodexSessionService.readConversation(connection.id, id),
      ),
    ));
    expect(reads, 1);
    refresh.complete(record('本次点击的新答复'));
    await preload;
    await tester.pump();
    expect(find.text('本次点击的新答复'), findsOneWidget);
    expect(reads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('chat displays cached history then updates it in place',
      (tester) async {
    await tester.runAsync(() => StorageService.setOpenedCodexConversations(
        connection.id, {conversation.id}));
    CodexSessionService.runPythonOverride =
        (_, __, ___) async => record('已有聊天内容');
    await CodexSessionService.readConversation(connection.id, conversation.id);
    final refresh = Completer<String>();
    CodexSessionService.runPythonOverride = (_, __, ___) => refresh.future;
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: connection,
        workDir: '/project',
        conversation: conversation,
        forkOnFirstSend: true,
      ),
    ));
    await tester.pump();
    expect(find.text('已有聊天内容'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    refresh.complete(record('刷新后的聊天内容'));
    await tester.pump();
    expect(find.text('刷新后的聊天内容'), findsOneWidget);
    expect(find.text('已有聊天内容'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cached chat starts at the latest message during refresh',
      (tester) async {
    await tester.runAsync(() => StorageService.setOpenedCodexConversations(
        connection.id, {conversation.id}));
    CodexSessionService.runPythonOverride = (_, __, ___) async =>
        List.generate(40, (index) => record('历史答复 $index')).join('\n');
    await CodexSessionService.readConversation(connection.id, conversation.id);
    final refresh = Completer<String>();
    CodexSessionService.runPythonOverride = (_, __, ___) => refresh.future;
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: connection,
        workDir: '/project',
        conversation: conversation,
        forkOnFirstSend: true,
      ),
    ));
    await tester.pump();
    final scroll = tester
        .widget<ListView>(find.byKey(const ValueKey('chat-messages')))
        .controller!;
    expect(scroll.position.pixels, greaterThan(0));
    expect(scroll.position.extentAfter, lessThan(80));
    expect(find.text('历史答复 39'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
