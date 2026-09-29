import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/home_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/claude_session_service.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const conversationId = '11111111-1111-1111-1111-111111111111';

  setUp(() async {
    await Hive.close();
    directory = await Directory.systemTemp.createTemp('home-preload-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(SshConnectionAdapter());
    }
    await Hive.openBox<SshConnection>('connections');
    await Hive.openBox('settings');
    CodexSessionService.clearCache();
    ClaudeSessionService.runPythonOverride = (_, __, ___) async => '';
    SshService.connectClientOverride =
        (_) async => TerminalSession('preloaded');
    CodexSessionService.runPythonOverride = (_, __, args) async {
      if (args.first == '__all__' || args.first == '__running__') {
        return jsonEncode({
          'id': conversationId,
          'cwd': '/workspace',
          'title': 'cached before opening',
          'state': args.first == '__running__' ? 'running' : 'complete',
        });
      }
      return jsonEncode({'kind': 'user', 'text': 'record loaded in advance'});
    };
  });

  tearDown(() async {
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = null;
    ClaudeSessionService.runPythonOverride = null;
    SshService.connectClientOverride = null;
    await Hive.close();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  testWidgets('preloads conversation and records on the visible home screen',
      (tester) async {
    final connection = SshConnection(
      id: 'preloaded',
      name: 'preloaded',
      host: 'localhost',
      username: 'user',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await tester.runAsync(() =>
        Hive.box<SshConnection>('connections').put(connection.id, connection));
    var queryCount = 0;
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (id, script, args) async {
      queryCount++;
      return previous!(id, script, args);
    };

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();

    expect(
        CodexSessionService.cachedConversations(connection.id), hasLength(1));
    expect(
      CodexSessionService.cachedRecords(connection.id, conversationId)
          ?.single
          .text,
      'record loaded in advance',
    );
    expect(queryCount, 3);

    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(queryCount, 6);

    unawaited(Navigator.of(tester.element(find.byType(HomeScreen))).push<void>(
      MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('other'))),
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    expect(queryCount, 6);
  });
  test('home assistant defaults to Codex and persists Claude selection',
      () async {
    expect(StorageService.getHomeAssistant(), 'codex');
    await StorageService.setHomeAssistant('claude');
    await Hive.box('settings').close();
    await Hive.openBox('settings');
    expect(StorageService.getHomeAssistant(), 'claude');
  });

  testWidgets('home mode selector defaults to Codex and saves selection',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    final selector = find.byKey(const ValueKey('home-assistant-mode'));
    expect(
        tester.widget<SegmentedButton<String>>(selector).selected, {'codex'});
    await tester.runAsync(() async {
      await tester.tap(find.text('Claude'));
      await Hive.box('settings').flush();
    });
    await tester.pumpAndSettle();
    expect(
        tester.widget<SegmentedButton<String>>(selector).selected, {'claude'});
    expect(StorageService.getHomeAssistant(), 'claude');
    expect(find.byTooltip('通知历史'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    expect(
        tester.widget<SegmentedButton<String>>(selector).selected, {'claude'});
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Claude home mode skips Codex background preload',
      (tester) async {
    await tester.runAsync(() => StorageService.setHomeAssistant('claude'));
    var queries = 0;
    CodexSessionService.runPythonOverride = (_, __, ___) async {
      queries++;
      return '';
    };
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 30));
    expect(queries, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Claude connection opens Claude conversations directly',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = SshConnection(
        id: 'claude-test',
        name: 'Claude server',
        host: 'localhost',
        username: 'user',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026));
    await tester.runAsync(() async {
      await StorageService.setHomeAssistant('claude');
      await Hive.box<SshConnection>('connections')
          .put(connection.id, connection);
    });
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude server'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('选择 Claude 对话'), findsOneWidget);
    expect(find.textContaining('没有找到 Claude 对话'), findsOneWidget);
    expect(find.text('Shell'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Claude history opens read-only viewer without Codex controls',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = SshConnection(
        id: 'claude-history',
        name: 'History server',
        host: 'localhost',
        username: 'user',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026));
    await tester.runAsync(() async {
      await StorageService.setHomeAssistant('claude');
      await Hive.box<SshConnection>('connections')
          .put(connection.id, connection);
    });
    ClaudeSessionService.runPythonOverride = (_, __, args) async {
      if (args.isEmpty) {
        return jsonEncode({
          'id': 'test-session',
          'cwd': '/project',
          'title': 'Claude history'
        });
      }
      return jsonEncode({
        'kind': 'assistant',
        'text': 'Claude response',
        'model': 'claude-test',
        'reasoningEffort': 'high'
      });
    };
    var codexCalls = 0;
    CodexSessionService.runPythonOverride = (_, __, ___) async {
      codexCalls++;
      return '';
    };
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('History server'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('查看对话'));
    await tester.pumpAndSettle();
    expect(find.text('Claude response'), findsOneWidget);
    expect(find.textContaining('claude-test'), findsOneWidget);
    expect(find.byKey(const ValueKey('viewer-message-input')), findsNothing);
    expect(find.text('终端视图'), findsOneWidget);
    expect(codexCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
