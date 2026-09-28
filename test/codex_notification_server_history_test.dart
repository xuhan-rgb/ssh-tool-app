import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/codex_completion_notice.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_notification_history_screen.dart';
import 'package:ssh_tool_app/services/notification_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('codex-server-history-');
    Hive.init(storage.path);
    Hive.registerAdapter(SshConnectionAdapter());
    await Hive.openBox<SshConnection>('connections');
    await Hive.openBox('settings');
  });
  tearDownAll(() async => storage.delete(recursive: true));

  testWidgets('server history shows only its notices without server names',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    await tester.runAsync(() async {
      for (final id in ['server-a', 'server-b']) {
        await StorageService.saveConnection(SshConnection(
          id: id,
          name: id,
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ));
        await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
          id: '$id:job-$id',
          connectionId: id,
          threadId: 'thread-$id',
          title: id == 'server-a' ? '修复工作台环境安装提示' : null,
          completedAt: now,
        ));
      }
    });
    await tester.pumpWidget(const MaterialApp(
      home: CodexNotificationHistoryScreen(connectionId: 'server-a'),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('thread-s'), findsOneWidget);
    expect(find.textContaining('server-a'), findsNothing);
    expect(find.textContaining('server-b'), findsNothing);
    expect(find.text('修复工作台环境安装提示 · 已完成'), findsOneWidget);
  });

  testWidgets('server notification bell tracks only this server unread count',
      (tester) async {
    await tester.runAsync(() async {
      await NotificationService.recordCodexFinished(
          'badge-server-a', 'thread-one', 'job-one');
      await NotificationService.recordCodexFinished(
          'badge-server-b', 'thread-other', 'job-other');
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [
          const CodexServerNotificationButton(connectionId: 'badge-server-a'),
        ]),
      ),
    ));
    expect(find.text('1'), findsOneWidget);
    await tester.runAsync(() async {
      await NotificationService.recordCodexFinished(
          'badge-server-a', 'thread-two', 'job-two');
    });
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    await tester.runAsync(() async {
      await NotificationService.markCodexConversationViewed(
          'badge-server-a', 'thread-one');
    });
    await tester.pump();
    expect(find.text('1'), findsOneWidget);
  });
}
