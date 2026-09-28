import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/notification_service.dart';
import 'package:ssh_tool_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('codex-completed-marker-');
    Hive.init(storage.path);
    await Hive.openBox('settings');
  });
  tearDownAll(() async {
    await Hive.close();
    await storage.delete(recursive: true);
  });

  testWidgets('newly completed conversation is marked until viewed',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => NotificationService.recordCodexFinished(
        'notice-server', 'completed-thread', 'job-1'));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: CodexSessionDialog(
          connectionId: 'notice-server',
          defaultName: 'codex',
          defaultWorkDir: '/project',
          startWithAllConversations: true,
          loadConversations: (_) async => const [],
          loadAllConversations: () async => [
            CodexConversation(
              id: 'completed-thread',
              cwd: '/project',
              updatedAt: DateTime(2026, 9, 24),
              title: '刚完成的任务',
              state: CodexConversationState.complete,
            ),
          ],
          loadRecords: (_) async => const [],
          loadDirectories: (_) async =>
              const RemoteDirectoryListing(path: '/project', dirs: []),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('newly-completed-completed-thread')),
        findsOneWidget);
    await tester.runAsync(() => NotificationService.markCodexConversationViewed(
        'notice-server', 'completed-thread'));
    await tester.pump();
    expect(find.byKey(const ValueKey('newly-completed-completed-thread')),
        findsNothing);
  });

  testWidgets('returning to picker keeps cached conversations while refreshing',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<List<CodexConversation>>();
    List<CodexConversation>? refreshed;
    final cached = CodexConversation(
      id: 'cached-thread',
      cwd: '/project',
      updatedAt: DateTime(2026, 9, 24),
      title: '之前的对话',
      state: CodexConversationState.running,
    );
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: CodexSessionDialog(
          connectionId: 'cache-server',
          defaultName: 'codex',
          defaultWorkDir: '/project',
          startWithAllConversations: true,
          initialConversations: [cached],
          onConversationsLoaded: (items) => refreshed = items,
          loadConversations: (_) async => const [],
          loadAllConversations: () => pending.future,
          loadRecords: (_) async => const [],
          loadDirectories: (_) async =>
              const RemoteDirectoryListing(path: '/project', dirs: []),
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('之前的对话'), findsOneWidget);
    expect(find.text('正在读取远程 Codex 对话…'), findsNothing);
    pending.complete([
      CodexConversation(
        id: 'cached-thread',
        cwd: '/project',
        updatedAt: DateTime(2026, 9, 24),
        title: '更新后的对话',
        state: CodexConversationState.complete,
      ),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.text('更新后的对话'), findsOneWidget);
    expect(refreshed?.single.title, '更新后的对话');
  });
}
