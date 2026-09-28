import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_notification_history_screen.dart';
import 'package:ssh_tool_app/services/notification_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('codex-notice-ui-');
    Hive.init(storage.path);
    Hive.registerAdapter(SshConnectionAdapter());
    await Hive.openBox<SshConnection>('connections');
    await Hive.openBox('settings');
  });
  tearDownAll(() async {
    await storage.delete(recursive: true);
  });

  testWidgets('system notification and history both return to history',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    await tester.runAsync(() async {
      await StorageService.saveConnection(SshConnection(
        id: 'connection-1',
        name: 'linux',
        host: 'localhost',
        username: 'test',
        createdAt: now,
        updatedAt: now,
      ));
      await NotificationService.recordCodexFinished(
          'connection-1', 'thread-123', 'job-1',
          title: '修复工作台环境安装提示');
    });
    await tester.pumpWidget(MaterialApp(
      home: CodexNotificationHistoryScreen(
        initialTarget:
            const CodexCompletionTarget('connection-1', 'thread-123', 'job-1'),
        conversationBuilder: (connection, threadId) => Scaffold(
          appBar: AppBar(title: Text(threadId)),
          body: const Text('对话内容'),
        ),
      ),
    ));
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('对话内容'), findsOneWidget);
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (!StorageService.getCodexCompletionNotices().first.read &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(StorageService.getCodexCompletionNotices().first.read, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('通知历史'), findsOneWidget);
    expect(find.text('修复工作台环境安装提示 · 已完成'), findsOneWidget);
    await tester.tap(find.text('修复工作台环境安装提示 · 已完成'));
    await tester.pumpAndSettle();
    expect(find.text('对话内容'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('通知历史'), findsOneWidget);
  });

}
