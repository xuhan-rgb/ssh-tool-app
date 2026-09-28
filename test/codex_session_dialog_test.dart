import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/storage_service.dart';
import 'package:ssh_tool_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory settingsDirectory;
  setUpAll(() async {
    settingsDirectory =
        await Directory.systemTemp.createTemp('ssh_tool_settings');
    Hive.init(settingsDirectory.path);
    await Hive.openBox('settings');
  });
  setUp(() async => Hive.box('settings').clear());
  tearDownAll(() async {
    await Hive.close();
    await settingsDirectory.delete(recursive: true);
  });

  testWidgets('all conversations load without waiting for the directory',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Completer<RemoteDirectoryListing>();
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '~',
        startWithAllConversations: true,
        loadConversations: (_) async => const [],
        loadAllConversations: () async {
          loads++;
          return const [
            CodexConversation(
              id: 'ready-thread',
              cwd: '/project',
              updatedAt: null,
              title: '不等待目录的对话',
              state: CodexConversationState.complete,
            ),
          ];
        },
        loadRecords: (_) async => const [],
        loadDirectories: (_) => directory.future,
      ),
    ));
    await tester.pump();
    expect(loads, 1);
    expect(find.text('不等待目录的对话'), findsOneWidget);
    directory.complete(
        const RemoteDirectoryListing(path: '/home/user', dirs: []));
    await tester.pump();
    expect(loads, 1);
    expect(find.text('不等待目录的对话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selecting cached conversation starts reading during refresh',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const conversations = [
      CodexConversation(
        id: 'first',
        cwd: '/project',
        updatedAt: null,
        title: '第一条对话',
        state: CodexConversationState.complete,
      ),
      CodexConversation(
        id: 'selected',
        cwd: '/project',
        updatedAt: null,
        title: '点击这条对话',
        state: CodexConversationState.complete,
      ),
    ];
    final directory = Completer<RemoteDirectoryListing>();
    final refresh = Completer<List<CodexConversation>>();
    final reads = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '~',
        startWithAllConversations: true,
        initialConversations: conversations,
        loadConversations: (_) async => const [],
        loadAllConversations: () => refresh.future,
        loadRecords: (id) async {
          reads.add(id);
          return const [];
        },
        loadDirectories: (_) => directory.future,
      ),
    ));
    await tester.pump();
    expect(reads, containsAll(['first', 'selected']));
    reads.clear();
    await tester.tap(find.text('点击这条对话'));
    await tester.pump();
    expect(reads, ['selected']);
    refresh.complete(conversations);
    directory.complete(
        const RemoteDirectoryListing(path: '/home/user', dirs: []));
    await tester.pump();
    expect(
      tester.widget<Icon>(find.byKey(
          const ValueKey('conversation-leading-selected'))).icon,
      Icons.radio_button_checked,
    );
    await tester.tap(find.byKey(const ValueKey('view-conversation-selected')));
    await tester.pump();
    expect(
      tester.widget<CodexConversationViewerDialog>(
          find.byType(CodexConversationViewerDialog)).conversation.id,
      'selected',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('viewing a conversation selects it and keeps selection on return',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/project',
        startWithAllConversations: true,
        loadConversations: (_) async => const [],
        loadAllConversations: () async => const [
          CodexConversation(id: 'first', cwd: '/project', updatedAt: null,
              title: '第一条', state: CodexConversationState.complete),
          CodexConversation(id: 'viewed', cwd: '/project', updatedAt: null,
              title: '正在查看', state: CodexConversationState.complete),
        ],
        loadRecords: (_) async => const [],
        loadDirectories: (_) async =>
            const RemoteDirectoryListing(path: '/project', dirs: []),
      ),
    ));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('view-conversation-viewed')));
    await tester.pumpAndSettle();
    expect(tester.widget<CodexConversationViewerDialog>(
        find.byType(CodexConversationViewerDialog)).conversation.id, 'viewed');
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(tester.widget<Icon>(find.byKey(
        const ValueKey('conversation-leading-viewed'))).icon,
        Icons.radio_button_checked);
    expect(tester.widget<Icon>(find.byKey(
        const ValueKey('conversation-leading-first'))).icon,
        Icons.chat_bubble);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('conversation eye keeps compact layout with an expanded hit area',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/project',
        loadConversations: (_) async => const [
          CodexConversation(id: 'eye-target', cwd: '/project', updatedAt: null,
              title: '点击边缘', state: CodexConversationState.complete),
        ],
        loadRecords: (_) async => const [],
        loadDirectories: (_) async =>
            const RemoteDirectoryListing(path: '/project', dirs: []),
      ),
    ));
    await tester.pump();
    final eye = find.byKey(const ValueKey('view-conversation-eye-target'));
    expect(tester.getSize(eye), const Size(28, 28));
    await tester.tapAt(tester.getCenter(eye) + const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(find.byType(CodexConversationViewerDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('running filter includes remote tasks and leaves favorites intact',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => StorageService.setFavoriteCodexConversations(
        'filter-running', {'done'}));
    await tester.runAsync(() => StorageService.markCodexConversationViewed(
        'filter-running', 'done'));
    var runningLoads = 0;
    var running = true;
    final preloaded = <String>[];
    await tester.pumpWidget(MaterialApp(home: CodexSessionDialog(
      connectionId: 'filter-running',
      defaultName: 'codex', defaultWorkDir: '/project',
      startWithAllConversations: true,
      loadConversations: (_) async => const [],
      loadAllConversations: () async => const [
        CodexConversation(id: 'done', cwd: '/project', updatedAt: null,
            title: '已收藏的完成对话', state: CodexConversationState.complete),
      ],
      loadRunningConversations: () async {
        runningLoads++;
        return running ? const [
          CodexConversation(id: 'remote-running', cwd: '/project', updatedAt: null,
              title: '首页之外的运行任务', state: CodexConversationState.running),
          CodexConversation(id: 'app-running', cwd: '/project', updatedAt: null,
              title: '本软件的运行任务', state: CodexConversationState.running),
        ] : const [];
      },
      loadOpenedSessions: () async => const [
        OpenedCodexSession(name: 'codex-app', workDir: '/project',
            conversationId: 'app-running'),
      ],
      loadRunningChatJobs: () async => const {},
      loadRecords: (id) async { preloaded.add(id); return const []; },
      loadDirectories: (_) async =>
          const RemoteDirectoryListing(path: '/project', dirs: []),
    )));
    await tester.pump();
    expect(runningLoads, 1);
    expect(preloaded, contains('remote-running'));
    final titleRect = tester.getRect(find.text('远程对话'));
    for (final key in ['conversation-filter-all', 'conversation-filter-running']) {
      final filterRect = tester.getRect(find.byKey(ValueKey(key)));
      expect(filterRect.left, greaterThan(titleRect.right));
      expect(filterRect.center.dy, closeTo(titleRect.center.dy, 1));
    }
    await tester.tap(find.byKey(const ValueKey('conversation-filter-running')));
    await tester.pump();
    expect(find.text('首页之外的运行任务'), findsOneWidget);
    expect(find.text('其他端执行中'), findsOneWidget);
    expect(find.text('本软件执行中'), findsOneWidget);
    expect(find.text('已收藏的完成对话'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('favorites-section-tab')));
    await tester.pump();
    expect(find.text('已收藏的完成对话'), findsOneWidget);
    expect(find.byKey(const ValueKey('conversation-filter-running')), findsNothing);
    await tester.tap(find.text('对话'));
    await tester.pump();
    running = false;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.text('首页之外的运行任务'), findsNothing);
    expect(find.text('当前没有正在执行或24小时内完成的对话'), findsOneWidget);
    running = true;
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.text('首页之外的运行任务'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('running filter keeps read completions for 24 hours only',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.now();
    var completion = now.subtract(const Duration(hours: 1));
    const connectionId = 'recent-results';
    await tester.runAsync(() => StorageService.markCodexConversationViewed(
        connectionId, 'already-viewed', viewedAt: now));
    const running = CodexConversation(id: 'running', cwd: '/p', updatedAt: null,
        title: '仍在执行', state: CodexConversationState.running);
    await tester.pumpWidget(MaterialApp(home: CodexSessionDialog(
      connectionId: connectionId,
      defaultName: 'codex', defaultWorkDir: '/p',
      startWithAllConversations: true,
      loadConversations: (_) async => const [],
      loadAllConversations: () async => [
        CodexConversation(id: 'unread', cwd: '/p', updatedAt: completion,
            completedAt: completion,
            title: '电脑端已完成', state: CodexConversationState.complete),
        CodexConversation(id: 'already-viewed', cwd: '/p', updatedAt: completion,
            completedAt: completion,
            title: '已经看过', state: CodexConversationState.complete),
        CodexConversation(id: 'expired', cwd: '/p', updatedAt: now,
            completedAt: now.subtract(const Duration(hours: 25)),
            title: '超过24小时但日志刚更新', state: CodexConversationState.complete),
        running,
      ],
      loadRunningConversations: () async => const [running],
      loadRecords: (_) async => const [],
      loadDirectories: (_) async =>
          const RemoteDirectoryListing(path: '/p', dirs: []),
    )));
    await tester.pump();
    expect(tester.getSize(find.text('远程对话')).width, greaterThanOrEqualTo(48));
    final headingRow = find.ancestor(
        of: find.text('远程对话'), matching: find.byType(Row)).first;
    final headingCount = find.descendant(of: headingRow, matching: find.text('4 条'));
    expect(tester.getRect(headingCount).left -
        tester.getRect(find.text('远程对话')).right, closeTo(6, 0.1));
    expect(tester.getRect(find.byKey(const ValueKey('conversation-filter-all'))).left -
        tester.getRect(headingCount).right, closeTo(4, 0.1));
    await tester.tap(find.byKey(const ValueKey('conversation-filter-running')));
    await tester.pump();
    expect(find.text('电脑端已完成'), findsOneWidget);
    expect(find.text('已经看过'), findsOneWidget);
    expect(find.text('仍在执行'), findsOneWidget);
    expect(find.text('超过24小时但日志刚更新'), findsNothing);
    expect(StorageService.getCodexConversationViewedAt(connectionId, 'unread'),
        isNull, reason: 'Preloading must not mark results read');
    await tester.tap(find.byKey(const ValueKey('view-conversation-unread')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('电脑端已完成'), findsOneWidget);
    completion = now.subtract(const Duration(hours: 25));
    await tester.pump(const Duration(seconds: 15));
    await tester.pump();
    expect(find.text('电脑端已完成'), findsNothing);
    expect(find.text('已经看过'), findsNothing);
    expect(find.text('仍在执行'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('conversation-filter-all')));
    await tester.pump();
    expect(find.text('电脑端已完成'), findsOneWidget);
    expect(find.text('超过24小时但日志刚更新'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('idle text chat appears in the opened list', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() => StorageService.setOpenedCodexConversations(
        'local-chat', {'existing-thread'}));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: CodexSessionDialog(
          connectionId: 'local-chat',
          defaultName: 'codex',
          defaultWorkDir: '/project',
          startWithAllConversations: true,
          loadConversations: (_) async => const [],
          loadAllConversations: () async => [
            CodexConversation(
              id: 'existing-thread',
              cwd: '/project',
              updatedAt: DateTime(2026, 9, 24),
              title: '之前打开的文字对话',
              state: CodexConversationState.complete,
            ),
          ],
          loadOpenedSessions: () async => const [],
          loadRunningChatJobs: () async => const {},
          loadRecords: (_) async => const [],
          loadDirectories: (_) async =>
              const RemoteDirectoryListing(path: '/project', dirs: []),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('favorites-section-tab')));
    await tester.pump();
    expect(find.text('当前打开 · 1 条'), findsOneWidget);
    expect(find.byKey(const ValueKey('opened-chat-existing-thread')),
        findsOneWidget);
    await tester.runAsync(() => tester.tap(
        find.byKey(const ValueKey('close-opened-chat-existing-thread'))));
    await tester.pump();
    expect(find.text('当前打开 · 0 条'), findsOneWidget);
    expect(StorageService.getOpenedCodexConversations('local-chat'), isEmpty);
  });

  testWidgets('Codex session dialog lays out conversation history',
      (tester) async {
    final conversations = [
      CodexConversation(
        id: 'conversation-123456',
        cwd: '/workspace/project',
        updatedAt: DateTime(2026, 9, 23, 16, 0),
        title: '修复 Linux 启动问题',
        state: CodexConversationState.complete,
        preview: '构建已经完成',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: CodexSessionDialog(
            defaultName: 'codex',
            defaultWorkDir: '/workspace/project',
            loadConversations: (_) async => conversations,
            loadRecords: (_) async => const [],
            loadDirectories: (_) async => const RemoteDirectoryListing(
              path: '/workspace/project',
              dirs: ['lib', 'test', '.codex'],
              homePath: '/home/qwer',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('新建 Codex 会话'), findsOneWidget);
    expect(find.text('项目目录'), findsOneWidget);
    expect(find.text('.codex'), findsNothing);
    expect(find.text('修复 Linux 启动问题'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('.codex'), 100,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('.codex'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('修复 Linux 启动问题'));
    await tester.pump();
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('Kill / 恢复'), findsOneWidget);
    expect(find.text('Fork'), findsOneWidget);
    await tester.tap(find.text('Kill / 恢复'));
    await tester.pumpAndSettle();
    expect(find.text('确认 Kill 并恢复？'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('text chat is the default and mode choice survives reopening',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    expect(StorageService.getCodexChatMode(), isTrue);
    var savedMode = true;

    Widget dialog(Key key) => MaterialApp(
          theme: AppTheme.darkTheme,
          home: KeyedSubtree(
              key: key,
              child: CodexSessionDialog(
                initialOpenAsChat: savedMode,
                onOpenModeChanged: (mode) => savedMode = mode,
                defaultName: 'codex',
                defaultWorkDir: '/project',
                loadConversations: (_) async => const [],
                loadRecords: (_) async => const [],
                loadDirectories: (_) async => const RemoteDirectoryListing(
                  path: '/project',
                  dirs: [],
                ),
              )),
        );
    await tester.pumpWidget(dialog(const ValueKey('first')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-open-mode')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckedPopupMenuItem<bool>>(
                find.widgetWithText(CheckedPopupMenuItem<bool>, '文字聊天'))
            .checked,
        isTrue);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, '终端'));
    await tester.pumpAndSettle();
    expect(savedMode, isFalse);

    await tester.pumpWidget(dialog(const ValueKey('second')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-open-mode')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<CheckedPopupMenuItem<bool>>(
                find.widgetWithText(CheckedPopupMenuItem<bool>, '终端'))
            .checked,
        isTrue);
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, '文字聊天'));
    await tester.pumpAndSettle();
    expect(savedMode, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('new conversation picks a remote directory and favorite default',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionConfig? selected;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Builder(
            builder: (context) => FilledButton(
                  onPressed: () async =>
                      selected = await showDialog<CodexSessionConfig>(
                    context: context,
                    builder: (_) => CodexSessionDialog(
                      defaultName: 'codex',
                      defaultWorkDir: '/project',
                      loadConversations: (_) async => const [],
                      loadRecords: (_) async => const [],
                      loadDirectories: (path) async => RemoteDirectoryListing(
                        path: path,
                        dirs: path == '/project' ? ['child'] : [],
                      ),
                    ),
                  ),
                  child: const Text('打开选择器'),
                )),
      ),
    ));
    await tester.tap(find.text('打开选择器'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建对话'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<CheckboxListTile>(
              find.byKey(const ValueKey('favorite-new-conversation')))
          .value,
      isTrue,
    );
    await tester.tap(find.text('child'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择此目录'));
    await tester.pump();
    expect(find.text('/project/child'), findsWidgets);
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pumpAndSettle();
    expect(selected?.workDir, '/project/child');
    expect(selected?.favoriteOnCreate, isTrue);
  });

  testWidgets('loads completed conversations once without a refresh control',
      (tester) async {
    final conversations = [
      CodexConversation(
        id: 'conversation-refresh',
        cwd: '/workspace/project',
        updatedAt: DateTime(2026, 9, 23, 16, 0),
        title: '后台刷新中的对话',
        state: CodexConversationState.complete,
      ),
    ];
    var loadCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: CodexSessionDialog(
            defaultName: 'codex',
            defaultWorkDir: '/workspace/project',
            loadConversations: (_) {
              loadCount++;
              return Future.value(conversations);
            },
            loadRecords: (_) async => const [],
            loadDirectories: (_) async => const RemoteDirectoryListing(
              path: '/workspace/project',
              dirs: ['lib'],
              homePath: '/home/qwer',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('后台刷新中的对话'), findsOneWidget);
    expect(loadCount, 1);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('后台刷新中的对话'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(loadCount, 1);

    expect(find.byTooltip('刷新远程对话'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refreshes active status quietly and continues checking for new tasks',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var loadCount = 0;
    final refreshed = Completer<List<CodexConversation>>();
    CodexConversation conversation(CodexConversationState state) =>
        CodexConversation(
          id: 'active-thread',
          cwd: '/project',
          updatedAt: DateTime(2026, 9, 23),
          title: '后台任务',
          state: state,
        );

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/project',
        startWithAllConversations: true,
        loadConversations: (_) async => const [],
        loadAllConversations: () {
          loadCount++;
          return loadCount == 1
              ? Future.value([conversation(CodexConversationState.running)])
              : refreshed.future;
        },
        loadRecords: (_) async => const [],
        loadDirectories: (_) async => const RemoteDirectoryListing(
          path: '/project',
          dirs: [],
          homePath: '/home/qwer',
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(loadCount, 1);
    expect(find.descendant(
        of: find.byKey(const ValueKey('conversation-state-active-thread')),
        matching: find.text('正在执行')), findsOneWidget);
    await tester.tap(find.text('后台任务'));
    await tester.pump();

    await tester.pump(const Duration(seconds: 15));
    expect(loadCount, 2);
    expect(find.text('后台任务'), findsOneWidget);
    expect(find.descendant(
        of: find.byKey(const ValueKey('conversation-state-active-thread')),
        matching: find.text('正在执行')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    refreshed.complete([conversation(CodexConversationState.complete)]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('后台任务'), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
    expect(loadCount, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('distinguishes app jobs from other running conversations',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionConfig? selected;
    final checkedIds = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Builder(builder: (context) {
          return FilledButton(
            onPressed: () async {
              selected = await showDialog<CodexSessionConfig>(
                context: context,
                builder: (_) => CodexSessionDialog(
                  defaultName: 'codex',
                  defaultWorkDir: '/project',
                  startWithAllConversations: true,
                  loadConversations: (_) async => const [],
                  loadAllConversations: () async => [
                    CodexConversation(
                      id: 'app-thread',
                      cwd: '/project',
                      updatedAt: DateTime(2026, 9, 24),
                      title: '本软件的任务',
                      state: CodexConversationState.running,
                    ),
                    CodexConversation(
                      id: 'remote-thread',
                      cwd: '/project',
                      updatedAt: DateTime(2026, 9, 23),
                      title: '其他终端的任务',
                      state: CodexConversationState.running,
                    ),
                  ],
                  loadOpenedSessions: () async => const [],
                  loadRunningChatJobs: () async => const {
                    'app-thread': 'job-1',
                  },
                  findRunningChatJob: (id) async {
                    checkedIds.add(id);
                    return id == 'app-thread' ? 'job-1' : null;
                  },
                  loadRecords: (_) async => const [],
                  loadDirectories: (_) async => const RemoteDirectoryListing(
                    path: '/project',
                    dirs: [],
                  ),
                ),
              );
            },
            child: const Text('选择'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-state-app-thread')),
        matching: find.text('本软件执行中'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-state-remote-thread')),
        matching: find.text('其他端执行中'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('favorites-section-tab')));
    await tester.pump();
    expect(find.text('当前打开 · 1 条'), findsOneWidget);
    expect(find.byKey(const ValueKey('opened-chat-app-thread')),
        findsOneWidget);
    await tester.tap(find.text('对话'));
    await tester.pump();

    await tester.tap(find.text('其他终端的任务'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '继续对话'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '继续对话'),
            )
            .onPressed,
        isNull);

    await tester.tap(find.text('本软件的任务'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '接入对话'));
    await tester.pump();
    expect(checkedIds, ['app-thread']);
    expect(selected?.resumeConversation?.id, 'app-thread');
    expect(selected?.openAsChat, isTrue);
    expect(selected?.attachRunningChat, isTrue);
    expect(selected?.runningChatJobId, 'job-1');
    expect(selected?.openSessionName, isNull);
  });

  testWidgets('starts with all conversations without a refresh control',
      (tester) async {
    final conversations = [
      CodexConversation(
        id: 'conversation-all',
        cwd: '/workspace/project',
        updatedAt: DateTime(2026, 9, 23, 16, 0),
        title: '远程全部对话',
        state: CodexConversationState.complete,
      ),
    ];
    var allLoadCount = 0;
    var directoryLoadCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: CodexSessionDialog(
            defaultName: 'codex',
            defaultWorkDir: '/workspace/project',
            startWithAllConversations: true,
            loadConversations: (_) {
              directoryLoadCount++;
              return Future.value(conversations);
            },
            loadAllConversations: () {
              allLoadCount++;
              return Future.value(conversations);
            },
            loadRecords: (_) async => const [],
            loadDirectories: (_) async => const RemoteDirectoryListing(
              path: '/workspace/project',
              dirs: ['lib'],
              homePath: '/home/qwer',
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('远程全部对话'), findsOneWidget);
    expect(allLoadCount, 1);
    expect(directoryLoadCount, 0);

    expect(find.byTooltip('刷新远程对话'), findsNothing);
    expect(directoryLoadCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loads older remote conversations on demand', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var requestedOffset = -1;
    CodexConversation conversation(String id) => CodexConversation(
          id: id,
          cwd: '/project',
          updatedAt: DateTime(2026, 9, 24),
          title: id,
        );
    await tester.pumpWidget(MaterialApp(
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/project',
        startWithAllConversations: true,
        loadConversations: (_) async => const [],
        loadAllConversations: () async => [conversation('recent')],
        loadMoreConversations: (offset) async {
          requestedOffset = offset;
          return [conversation('older')];
        },
        loadRecords: (_) async => const [],
        loadDirectories: (_) async =>
            const RemoteDirectoryListing(path: '/project', dirs: []),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('recent'), findsOneWidget);
    await tester.tap(find.text('加载更早对话'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(requestedOffset, 200);
    expect(find.text('older'), findsOneWidget);
  });

  testWidgets('loads all conversations when directory lookup fails',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: CodexSessionDialog(
          defaultName: 'codex',
          defaultWorkDir: '~',
          startWithAllConversations: true,
          loadConversations: (_) async => const [],
          loadAllConversations: () async => [
            CodexConversation(
              id: 'available',
              cwd: '/remote/project',
              updatedAt: DateTime(2026, 9, 23),
              title: '远端已有对话',
            ),
          ],
          loadRecords: (_) async => const [],
          loadDirectories: (_) async => const RemoteDirectoryListing(
            path: '~',
            dirs: [],
            error: '目录读取失败',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('远端已有对话'), findsOneWidget);
  });

  testWidgets('phone layout keeps conversations without a directory tab',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: CodexSessionDialog(
          defaultName: 'codex',
          defaultWorkDir: '/home/qwer',
          loadConversations: (_) async => [
            CodexConversation(
              id: 'conversation-mobile',
              cwd: '/home/qwer',
              updatedAt: DateTime(2026, 9, 23),
              title: '手机上的远程对话',
              state: CodexConversationState.complete,
            ),
          ],
          loadRecords: (_) async => const [],
          loadDirectories: (_) async => const RemoteDirectoryListing(
            path: '/home/qwer',
            dirs: ['Projects'],
            homePath: '/home/qwer',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('手机上的远程对话'), findsOneWidget);
    expect(find.text('Projects'), findsNothing);
    expect(tester.takeException(), isNull);

    expect(find.text('目录'), findsNothing);
    expect(find.byKey(const ValueKey('conversation-directory-filter')),
        findsOneWidget);
    expect(find.text('手机上的远程对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('saved Codex directory and conversation preferences', () {
    setUp(() async {
      await StorageService.setFavoriteCodexConversations(
          'connection-a', {'older'});
      await StorageService.setFavoriteCodexDirectories(
          'connection-a', {'/project/b'});
      await StorageService.setFilteredCodexDirectories(
          'connection-a', {'/project/b'});
    });

    testWidgets('directory filter and favorites persist per connection',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final conversations = [
        CodexConversation(
            id: 'newer',
            cwd: '/project/a',
            updatedAt: DateTime(2026, 9, 23, 12),
            title: '较新的对话'),
        CodexConversation(
            id: 'older',
            cwd: '/project/b',
            updatedAt: DateTime(2026, 9, 22, 12),
            title: '收藏的旧对话'),
      ];
      Widget dialog() => MaterialApp(
            theme: AppTheme.darkTheme,
            home: CodexSessionDialog(
              connectionId: 'connection-a',
              defaultName: 'codex',
              defaultWorkDir: '/project',
              startWithAllConversations: true,
              loadConversations: (_) async => conversations,
              loadAllConversations: () async => conversations,
              loadRecords: (_) async => const [],
              loadDirectories: (_) async => const RemoteDirectoryListing(
                path: '/project',
                dirs: ['a', 'b'],
                homePath: '/home/qwer',
              ),
            ),
          );

      await tester.pumpWidget(dialog());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('conversation-directory-/project/b')),
          findsOneWidget);
      expect(find.text('收藏的旧对话').last, findsOneWidget);
      expect(find.text('较新的对话'), findsNothing);
      expect(find.byKey(const ValueKey('favorite-conversation-older')),
          findsNothing);
      await tester.tap(find.byKey(const ValueKey('favorites-section-tab')));
      await tester.pump();
      expect(find.text('收藏的旧对话'), findsOneWidget);
      await tester.tap(find.text('对话'));
      await tester.pump();

      expect(find.byTooltip('已筛选 1 个目录'), findsOneWidget);
      expect(
        tester
            .widget<Badge>(find.descendant(
              of: find.byKey(const ValueKey('conversation-directory-filter')),
              matching: find.byType(Badge),
            ))
            .backgroundColor,
        AppTheme.blue,
      );
      expect(find.text('收藏的旧对话').last, findsOneWidget);
      expect(find.text('较新的对话'), findsNothing);
      expect(StorageService.getFavoriteCodexConversations('connection-a'),
          contains('older'));
      expect(StorageService.getFavoriteCodexDirectories('connection-a'),
          contains('/project/b'));
      expect(StorageService.getFilteredCodexDirectories('connection-a'),
          contains('/project/b'));
      expect(
          StorageService.getFilteredCodexDirectories('connection-b'), isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(dialog());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('收藏的旧对话').last, findsOneWidget);
      expect(find.text('较新的对话'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    group('without a directory filter', () {
      setUp(() async =>
          StorageService.setFilteredCodexDirectories('connection-a', {}));

      testWidgets('favorite conversation appears before a newer one',
          (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(MaterialApp(
          theme: AppTheme.darkTheme,
          home: CodexSessionDialog(
            connectionId: 'connection-a',
            defaultName: 'codex',
            defaultWorkDir: '/project',
            loadConversations: (_) async => [
              CodexConversation(
                  id: 'newer',
                  cwd: '/project/a',
                  updatedAt: DateTime(2026, 9, 23, 12),
                  title: '较新的对话'),
              CodexConversation(
                  id: 'older',
                  cwd: '/project/b',
                  updatedAt: DateTime(2026, 9, 22, 12),
                  title: '收藏的旧对话'),
            ],
            loadRecords: (_) async => const [],
            loadDirectories: (_) async => const RemoteDirectoryListing(
              path: '/project',
              dirs: [],
              homePath: '/home/qwer',
            ),
          ),
        ));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getTopLeft(find.text('收藏的旧对话')).dy,
            lessThan(tester.getTopLeft(find.text('较新的对话')).dy));
        expect(tester.takeException(), isNull);
      });
    });
  });

  group('compressed conversation directory tree', () {
    setUp(() async => StorageService.setFilteredCodexDirectories(
        'tree-connection', {'/project'}));

    testWidgets('keeps branching levels and merges empty single-child levels',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final paths = [
        '/home/qwer/a/one',
        '/home/qwer/a/one/child',
        '/home/qwer/b/two',
      ];
      final conversations = [
        for (var i = 0; i < paths.length; i++)
          CodexConversation(
              id: 'branch-$i',
              cwd: paths[i],
              updatedAt: DateTime(2026, 9, 23),
              title: '对话 $i'),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: CodexSessionDialog(
          connectionId: 'branch-connection',
          defaultName: 'codex',
          defaultWorkDir: '/home/qwer',
          startWithAllConversations: true,
          loadConversations: (_) async => conversations,
          loadAllConversations: () async => conversations,
          loadRecords: (_) async => const [],
          loadDirectories: (_) async => const RemoteDirectoryListing(
            path: '/home/qwer',
            dirs: [],
            homePath: '/home/qwer',
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('codex-directory-/home/qwer')),
          findsOneWidget);
      expect(find.text('home/qwer'), findsWidgets);
      expect(find.byKey(const ValueKey('codex-directory-/home/qwer/a')),
          findsNothing);
      expect(find.text('a/one'), findsWidgets);
      expect(find.text('b/two'), findsWidgets);
      expect(
          find.byKey(const ValueKey('codex-directory-/home/qwer/a/one/child')),
          findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('expand-directory-/home/qwer')));
      await tester.pump();
      expect(find.byKey(const ValueKey('codex-directory-/home/qwer/a/one')),
          findsNothing);
      expect(find.byKey(const ValueKey('codex-directory-/home/qwer/b/two')),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('conversation list folds by the same directory hierarchy',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final conversations = [
        CodexConversation(
            id: 'one',
            cwd: '/project/a/one',
            updatedAt: DateTime(2026, 9, 23, 12),
            title: '分支一的对话'),
        CodexConversation(
            id: 'two',
            cwd: '/project/b/two',
            updatedAt: DateTime(2026, 9, 23, 11),
            title: '分支二的对话'),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: CodexSessionDialog(
          connectionId: 'tree-connection',
          defaultName: 'codex',
          defaultWorkDir: '/project',
          startWithAllConversations: true,
          loadConversations: (_) async => conversations,
          loadAllConversations: () async => conversations,
          loadRecords: (_) async => const [],
          loadDirectories: (_) async => const RemoteDirectoryListing(
              path: '/project', dirs: [], homePath: '/home/qwer'),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('conversation-directory-/project')),
          findsOneWidget);
      expect(find.text('a/one'), findsWidgets);
      expect(find.text('b/two'), findsWidgets);
      expect(find.text('分支一的对话'), findsOneWidget);
      expect(find.text('分支二的对话'), findsOneWidget);
      final titleY = tester.getCenter(find.text('分支一的对话')).dy;
      final titleRect = tester.getRect(find.text('分支一的对话'));
      final stateRect =
          tester.getRect(find.byKey(const ValueKey('conversation-state-one')));
      final viewRect =
          tester.getRect(find.byKey(const ValueKey('view-conversation-one')));
      final favoriteRect = tester
          .getRect(find.byKey(const ValueKey('favorite-conversation-one')));
      expect(stateRect.left, greaterThanOrEqualTo(titleRect.right));
      expect(viewRect.left - stateRect.right, greaterThanOrEqualTo(8));
      expect(favoriteRect.left - viewRect.right, greaterThanOrEqualTo(8));
      expect((stateRect.center.dy - titleY).abs(), lessThan(16));
      expect(
          (tester
                      .getCenter(find
                          .byKey(const ValueKey('conversation-leading-one')))
                      .dy -
                  titleY)
              .abs(),
          lessThan(8));
      expect(
          (tester
                      .getCenter(
                          find.byKey(const ValueKey('view-conversation-one')))
                      .dy -
                  titleY)
              .abs(),
          lessThan(16));
      expect(
          (tester
                      .getCenter(find
                          .byKey(const ValueKey('favorite-conversation-one')))
                      .dy -
                  titleY)
              .abs(),
          lessThan(16));
      await tester.tap(
          find.byKey(const ValueKey('conversation-directory-/project/a/one')));
      await tester.pump();
      expect(find.text('分支一的对话'), findsNothing);
      expect(find.text('分支二的对话'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('conversation-directory-/project')));
      await tester.pump();
      expect(
          find.byKey(const ValueKey('conversation-directory-/project/b/two')),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only directories with conversations become tree nodes',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final conversations = [
        CodexConversation(
            id: 'parent',
            cwd: '/project',
            updatedAt: DateTime(2026, 9, 23),
            title: '父目录对话'),
        CodexConversation(
            id: 'child',
            cwd: '/project/a/sub',
            updatedAt: DateTime(2026, 9, 23),
            title: '子目录对话'),
        CodexConversation(
            id: 'other',
            cwd: '/other',
            updatedAt: DateTime(2026, 9, 23),
            title: '其他目录对话'),
      ];
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: CodexSessionDialog(
          connectionId: 'tree-connection',
          defaultName: 'codex',
          defaultWorkDir: '/project',
          startWithAllConversations: true,
          loadConversations: (_) async => conversations,
          loadAllConversations: () async => conversations,
          loadRecords: (_) async => const [],
          loadDirectories: (_) async => const RemoteDirectoryListing(
            path: '/project',
            dirs: [],
            homePath: '/home/qwer',
          ),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('父目录对话'), findsOneWidget);
      expect(find.text('子目录对话'), findsOneWidget);
      expect(find.text('其他目录对话'), findsNothing);
      expect(find.byKey(const ValueKey('codex-directory-/project')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('codex-directory-/project/a/sub')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('codex-directory-/project/a')),
          findsNothing);
      expect(find.text('a/sub'), findsWidgets);
      expect(find.text('已包含'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('expand-directory-/project')));
      await tester.pump();
      expect(find.byKey(const ValueKey('codex-directory-/project/a/sub')),
          findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('quick directory filter limits history and favorites',
      (tester) async {
    var savedDirectories = <String>{};
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: CodexSessionDialog(
        connectionId: 'quick-filter',
        defaultName: 'codex',
        defaultWorkDir: '/project',
        startWithAllConversations: true,
        loadConversations: (_) async => const [],
        loadAllConversations: () async => [
          CodexConversation(
              id: 'a',
              cwd: '/project/a',
              updatedAt: DateTime(2026, 9, 23),
              title: '目录 A 的对话'),
          CodexConversation(
              id: 'b',
              cwd: '/project/b',
              updatedAt: DateTime(2026, 9, 23),
              title: '目录 B 的对话'),
        ],
        loadOpenedSessions: () async => const [
          OpenedCodexSession(name: 'codex-a', workDir: '/project/a'),
          OpenedCodexSession(name: 'codex-b', workDir: '/project/b'),
        ],
        saveFilteredDirectories: (_, paths) async {
          savedDirectories = {...paths};
        },
        saveFavoriteConversations: (_, ids) async {},
        loadRecords: (_) async => const [],
        loadDirectories: (_) async => const RemoteDirectoryListing(
          path: '/project',
          dirs: ['a', 'b'],
          homePath: '/home/qwer',
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('目录 A 的对话'), findsOneWidget);
    expect(find.text('目录 B 的对话'), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-marker-a')), findsNothing);
    expect(find.byKey(const ValueKey('favorite-marker-b')), findsNothing);
    Future<void> favorite(String title) async {
      await tester.tap(find.text(title));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('mobile-conversation-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(PopupMenuItem<String>, '收藏对话'));
      await tester.pumpAndSettle();
    }

    await favorite('目录 A 的对话');
    await favorite('目录 B 的对话');
    expect(find.byKey(const ValueKey('favorite-marker-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('favorite-marker-b')), findsOneWidget);

    await tester
        .tap(find.byKey(const ValueKey('conversation-directory-filter')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('quick-directory-expand-/project')));
    await tester.pump();
    expect(find.byKey(const ValueKey('quick-directory-filter-/project/a')),
        findsNothing);
    await tester
        .tap(find.byKey(const ValueKey('quick-directory-expand-/project')));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey('quick-directory-filter-/project/a')));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭目录筛选'));
    await tester.pumpAndSettle();
    expect(find.text('目录 A 的对话'), findsOneWidget);
    expect(find.text('目录 B 的对话'), findsNothing);
    expect(savedDirectories, {'/project/a'});

    await tester.tap(find.byKey(const ValueKey('favorites-section-tab')));
    await tester.pump();
    expect(find.text('目录 A 的对话'), findsOneWidget);
    expect(find.text('目录 B 的对话'), findsNothing);
    expect(find.text('收藏的对话'), findsOneWidget);
    await tester.tap(find.text('目录 A 的对话'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mobile-conversation-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '取消收藏'));
    await tester.pumpAndSettle();
    expect(find.text('目录 A 的对话'), findsNothing);
    expect(find.widgetWithText(FilledButton, '继续对话'), findsNothing);

    await tester.tap(find.text('对话'));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey('conversation-directory-filter')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey('clear-conversation-directory-filter')));
    await tester.pump();
    await tester.tap(find.byTooltip('关闭目录筛选'));
    await tester.pumpAndSettle();
    expect(find.text('目录 B 的对话'), findsOneWidget);
    expect(savedDirectories, isEmpty);
    expect(find.byKey(const ValueKey('favorite-marker-a')), findsNothing);
    expect(find.byKey(const ValueKey('favorite-marker-b')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('non-resumable conversation offers history view but not chat',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/missing',
        onOpenModeChanged: (_) {},
        loadConversations: (_) async => [
          CodexConversation(
              id: 'missing-directory',
              cwd: '/missing',
              updatedAt: DateTime(2026, 9, 23),
              title: '只能查看历史',
              state: CodexConversationState.complete,
              directoryExists: false),
        ],
        loadRecords: (_) async => const [],
        loadDirectories: (_) async => const RemoteDirectoryListing(
          path: '/missing',
          dirs: [],
          homePath: '/home/qwer',
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('codex-open-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, '文字聊天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('只能查看历史'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '继续对话'), findsOneWidget);
    final button =
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '继续对话'));
    expect(button.onPressed, isNull);
    expect(find.textContaining('请点眼睛查看历史'), findsOneWidget);
    expect(find.byTooltip('查看对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversation row keeps directory tail when path is long',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const path =
        '/home/qwer/Projects/organization/development/very-long-project/ssh_tool_app';
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/home/qwer',
        loadConversations: (_) async => [
          CodexConversation(
              id: 'long-path',
              cwd: path,
              updatedAt: DateTime(2026, 9, 23),
              title: '长路径的对话',
              state: CodexConversationState.complete),
        ],
        loadRecords: (_) async => const [],
        loadDirectories: (_) async => const RemoteDirectoryListing(
          path: '/home/qwer',
          dirs: [],
          homePath: '/home/qwer',
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final pathLabels =
        tester.widgetList<Text>(find.byType(Text)).map((e) => e.data);
    expect(
        pathLabels.any((text) =>
            text != null &&
            text.contains('…/') &&
            text.endsWith('/ssh_tool_app')),
        isTrue);
    expect(find.text('对话目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android landscape keeps the mobile conversation tabs',
      (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme.copyWith(platform: TargetPlatform.android),
      home: CodexSessionDialog(
        defaultName: 'codex',
        defaultWorkDir: '/project',
        loadConversations: (_) async => const [],
        loadRecords: (_) async => const [],
        loadDirectories: (_) async => const RemoteDirectoryListing(
          path: '/project',
          dirs: [],
          homePath: '/home/qwer',
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('对话'), findsOneWidget);
    expect(find.text('目录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone can open a remote conversation record', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CodexConversationViewerDialog(
                  conversation: CodexConversation(
                    id: 'conversation-mobile',
                    cwd: '/home/qwer',
                    updatedAt: DateTime(2026, 9, 23),
                    title: '手机上的远程对话',
                    state: CodexConversationState.complete,
                  ),
                  loadRecords: (_) async => [
                    CodexConversationRecord(
                      kind: 'assistant',
                      timestamp: DateTime(2026, 9, 23),
                      text: '远程对话内容',
                    ),
                  ],
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('远程对话内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversation viewer opens at the latest record', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Builder(
            builder: (context) => FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => CodexConversationViewerDialog(
                      conversation: CodexConversation(
                        id: 'many-records',
                        cwd: '/home/qwer',
                        updatedAt: DateTime(2026, 9, 23),
                        title: '长对话',
                      ),
                      loadRecords: (_) async => [
                        for (var i = 0; i < 50; i++)
                          CodexConversationRecord(
                            kind: 'assistant',
                            timestamp: null,
                            text: i == 49 ? '最后一条消息' : '历史消息 $i',
                          ),
                      ],
                    ),
                  ),
                  child: const Text('查看'),
                )),
      ),
    ));
    await tester.tap(find.text('查看'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('最后一条消息'), findsOneWidget);
    expect(find.text('历史消息 0'), findsNothing);
  });

  testWidgets('aborted conversation shows messages before full event log',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: CodexConversationViewerDialog(
        conversation: CodexConversation(
          id: 'aborted-thread',
          cwd: '/project',
          updatedAt: DateTime(2026, 9, 23),
          title: '已中止的任务',
          state: CodexConversationState.aborted,
        ),
        loadRecords: (_) async => const [
          CodexConversationRecord(kind: 'user', timestamp: null, text: '查看图片'),
          CodexConversationRecord(
              kind: 'tool_output', timestamp: null, text: '大量工具输出'),
          CodexConversationRecord(
              kind: 'user',
              timestamp: null,
              text: '<turn_aborted>中断提示</turn_aborted>'),
          CodexConversationRecord(
              kind: 'turn_aborted', timestamp: null, text: '任务中止：interrupted'),
        ],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('查看图片'), findsOneWidget);
    expect(find.text('任务中止：interrupted'), findsNothing);
    expect(find.text('大量工具输出'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('viewer-log-toggle')));
    await tester.pump();
    expect(find.text('任务中止：interrupted'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('viewer-log-toggle')));
    await tester.pump();
    expect(find.text('查看图片'), findsOneWidget);
    expect(find.text('任务中止：interrupted'), findsNothing);
  });

  testWidgets('resume uses the selected conversation directory',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionConfig? submitted;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                submitted = await showDialog<CodexSessionConfig>(
                  context: context,
                  builder: (_) => CodexSessionDialog(
                    defaultName: 'codex-1',
                    defaultWorkDir: '/home/qwer',
                    startWithAllConversations: true,
                    loadConversations: (_) async => const [],
                    loadAllConversations: () async => [
                      CodexConversation(
                        id: 'unavailable',
                        cwd: '/mnt/data/missing',
                        updatedAt: DateTime(2026, 9, 23, 12),
                        title: '',
                        state: CodexConversationState.complete,
                        directoryExists: false,
                      ),
                      CodexConversation(
                        id: 'recoverable',
                        cwd: '/mnt/data/project',
                        updatedAt: DateTime(2026, 9, 23, 11),
                        title: '可恢复的对话',
                        state: CodexConversationState.complete,
                      ),
                    ],
                    loadRecords: (_) async => const [],
                    loadDirectories: (_) async => const RemoteDirectoryListing(
                      path: '/home/qwer',
                      dirs: [],
                      homePath: '/home/qwer',
                    ),
                  ),
                );
              },
              child: const Text('打开选择器'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开选择器'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('对话 unavaila'), findsWidgets);
    await tester.tap(find.text('对话 unavaila').last);
    await tester.pump();
    expect(find.text('可恢复的对话'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('conversation-directory-/mnt/data/missing')),
        findsOneWidget);
    expect(find.textContaining('不可恢复'), findsWidgets);
    final disabled = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '继续对话'),
    );
    expect(disabled.onPressed, isNull);

    await tester.tap(find.text('可恢复的对话'));
    await tester.pump();
    expect(find.text('对话 unavaila'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('conversation-directory-/mnt/data/project')),
        findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '继续对话'));
    await tester.pump();
    expect(submitted?.workDir, '/mnt/data/project');
    expect(submitted?.effectiveWorkDir, '/mnt/data/project');
    expect(submitted?.resumeConversation?.id, 'recoverable');
    expect(tester.takeException(), isNull);
  });

  testWidgets('text chat selection keeps the chosen conversation id',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionConfig? selected;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              selected = await showDialog<CodexSessionConfig>(
                context: context,
                builder: (_) => CodexSessionDialog(
                  defaultName: 'codex-1',
                  defaultWorkDir: '/home/qwer',
                  onOpenModeChanged: (_) {},
                  loadConversations: (_) async => [
                    CodexConversation(
                      id: 'thread-123',
                      cwd: '/home/qwer/project',
                      updatedAt: DateTime(2026, 9, 23),
                      title: '原来的对话',
                      state: CodexConversationState.complete,
                    ),
                  ],
                  loadRecords: (_) async => const [],
                  loadDirectories: (_) async => const RemoteDirectoryListing(
                    path: '/home/qwer',
                    dirs: [],
                  ),
                ),
              );
            },
            child: const Text('选择'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('原来的对话'));
    await tester.pump();
    expect(find.byKey(const ValueKey('conversation-list-divider')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('resume-chat')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('codex-open-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, '文字聊天'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '继续对话'));
    await tester.pump();
    expect(selected?.openAsChat, isTrue);
    expect(selected?.resumeConversation?.id, 'thread-123');
    expect(selected?.effectiveWorkDir, '/home/qwer/project');
  });

  testWidgets('phone can continue or take over an aborted conversation',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionConfig? selected;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              selected = await showDialog<CodexSessionConfig>(
                context: context,
                builder: (_) => CodexSessionDialog(
                  defaultName: 'codex-1',
                  defaultWorkDir: '/home/qwer',
                  loadConversations: (_) async => [
                    CodexConversation(
                      id: 'thread-123',
                      cwd: '/home/qwer/project',
                      updatedAt: DateTime(2026, 9, 23),
                      title: '已有对话',
                      state: CodexConversationState.aborted,
                    ),
                  ],
                  loadRecords: (_) async => const [],
                  loadDirectories: (_) async => const RemoteDirectoryListing(
                    path: '/home/qwer',
                    dirs: [],
                  ),
                ),
              );
            },
            child: const Text('选择'),
          ),
        ),
      ),
    ));

    Future<void> openSelected() async {
      await tester.tap(find.text('选择'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('已有对话'));
      await tester.pump();
    }

    await openSelected();
    expect(find.widgetWithText(FilledButton, '继续对话'), findsOneWidget);
    expect(
        find.byKey(const ValueKey('mobile-conversation-more')), findsOneWidget);
    expect(find.byKey(const ValueKey('view-conversation-thread-123')),
        findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('mobile-conversation-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Kill 并恢复'));
    await tester.pumpAndSettle();
    expect(find.text('确认 Kill 并恢复？'), findsOneWidget);
    expect(selected, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text('已有对话'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('mobile-conversation-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Kill 并恢复'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Kill 并恢复'));
    await tester.pumpAndSettle();
    expect(selected?.resumeConversation?.id, 'thread-123');
    expect(selected?.stopWriterBeforeLaunch, isTrue);
    expect(selected?.openAsChat, isTrue);

    selected = null;
    await openSelected();
    await tester.tap(find.byKey(const ValueKey('mobile-conversation-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Fork 副本'));
    await tester.pumpAndSettle();
    expect(selected?.launch, CodexConversationLaunch.fork);
    expect(selected?.resumeConversation?.id, 'thread-123');
    expect(selected?.openAsChat, isTrue);
  });

  testWidgets('phone shows favorite conversations and keeps opened status',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionConfig? selected;

    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Builder(builder: (context) {
          return FilledButton(
            onPressed: () async {
              selected = await showDialog<CodexSessionConfig>(
                context: context,
                builder: (_) => CodexSessionDialog(
                  defaultName: 'codex-1',
                  defaultWorkDir: '/home/qwer',
                  onOpenModeChanged: (_) {},
                  loadConversations: (_) async => [
                    CodexConversation(
                      id: 'conversation-123456',
                      cwd: '/home/qwer',
                      updatedAt: DateTime(2026, 9, 23),
                      title: '已经打开的任务',
                      state: CodexConversationState.running,
                    ),
                  ],
                  loadOpenedSessions: () async => const [
                    OpenedCodexSession(
                      name: 'codex-conversat',
                      workDir: '/home/qwer',
                    ),
                    OpenedCodexSession(
                      name: 'codex-abcdef12',
                      workDir: '/workspace/project',
                    ),
                  ],
                  saveFavoriteConversations: (_, ids) async {},
                  loadRecords: (_) async => const [],
                  loadDirectories: (_) async => const RemoteDirectoryListing(
                    path: '/home/qwer',
                    dirs: [],
                    homePath: '/home/qwer',
                  ),
                ),
              );
            },
            child: const Text('选择'),
          );
        }),
      ),
    ));
    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('已经打开的任务'), findsWidgets);
    expect(find.text('已打开'), findsWidgets);
    expect(
        find.byKey(const ValueKey('hide-opened-conversations')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('codex-open-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<bool>, '文字聊天'));
    await tester.pump();
    await tester.tap(find.text('已经打开的任务'));
    await tester.pump();
    expect(
        find.byKey(const ValueKey('favorite-conversation-conversation-123456')),
        findsNothing);
    await tester.tap(find.byKey(const ValueKey('mobile-conversation-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, '收藏对话'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('favorites-section-tab')));
    await tester.pump();
    expect(find.textContaining('当前打开'), findsOneWidget);
    expect(find.byKey(const ValueKey('opened-session-codex-conversat')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('opened-session-codex-abcdef12')),
        findsOneWidget);
    expect(find.text('已经打开的任务'), findsWidgets);
    expect(find.text('收藏的对话'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('opened-session-codex-conversat')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '继续对话'));
    await tester.pump();
    expect(selected?.openSessionName, 'codex-conversat');
    expect(selected?.openAsChat, isTrue);
    expect(selected?.resumeConversation?.id, 'conversation-123456');
    expect(selected?.openedSessionTitles['codex-conversat'], '已经打开的任务');
    expect(selected?.openedSessionTitles['codex-abcdef12'], 'Codex 对话');
  });

  testWidgets('unmatched opened terminal still honors global chat mode',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    CodexSessionConfig? selected;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Builder(
            builder: (context) => FilledButton(
                  onPressed: () async {
                    selected = await showDialog<CodexSessionConfig>(
                      context: context,
                      builder: (_) => CodexSessionDialog(
                        defaultName: 'codex-1',
                        defaultWorkDir: '/project',
                        initialOpenAsChat: true,
                        onOpenModeChanged: (_) {},
                        loadConversations: (_) async => const [],
                        loadOpenedSessions: () async => const [
                          OpenedCodexSession(
                              name: 'codex-1', workDir: '/project'),
                        ],
                        loadRecords: (_) async => const [],
                        loadDirectories: (_) async =>
                            const RemoteDirectoryListing(
                          path: '/project',
                          dirs: [],
                        ),
                      ),
                    );
                  },
                  child: const Text('选择'),
                )),
      ),
    ));
    await tester.tap(find.text('选择'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('favorites-section-tab')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('opened-session-codex-1')));
    await tester.pump();
    expect(selected?.openAsChat, isTrue);
    expect(selected?.openSessionName, 'codex-1');
  });
}
