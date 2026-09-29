import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/claude_conversation_picker_screen.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/claude_runtime_service.dart';
import 'package:ssh_tool_app/services/claude_session_service.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dataDirectory;
  late SshConnection connection;

  setUpAll(() async {
    dataDirectory = await Directory.systemTemp.createTemp('claude-picker-');
    Hive.init(dataDirectory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(SshConnectionAdapter());
    }
    await Hive.openBox<SshConnection>('connections');
    await Hive.openBox('settings');
  });

  setUp(() {
    connection = SshConnection(
      id: 'connection-1',
      name: 'test',
      host: 'example.test',
      username: 'tester',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    SshService.connectClientOverride =
        (_) async => TerminalSession('connection-1');
    ClaudeSessionService.runPythonOverride = (_, __, args) async => args.isEmpty
        ? jsonEncode({
            'id': 'history-1',
            'cwd': '/work/project',
            'title': '历史 Claude 对话',
            'updatedAt': '2026-09-01T01:00:00Z',
            'state': 'complete',
            'preview': '历史预览',
          })
        : '';
    ClaudeRuntimeService.requestOverride = (_, action, payload) async {
      if (action == 'list') return [];
      if (action == 'status') return {'session': null, 'messages': []};
      if (action == 'ensure') {
        return {
          'sessionId': payload['sessionId'],
          'tmuxSession': 'claude-test',
          'workDir':
              payload['workDir'] == '~' ? '/home/tester' : payload['workDir'],
          'status': 'ready',
          'alive': true,
        };
      }
      throw StateError('Unexpected runtime action: $action');
    };
  });

  tearDown(() {
    SshService.connectClientOverride = null;
    ClaudeSessionService.runPythonOverride = null;
    ClaudeRuntimeService.requestOverride = null;
  });

  tearDownAll(() async {
    await Hive.close();
    await dataDirectory.delete(recursive: true);
  });

  Future<void> pumpPicker(WidgetTester tester, {Size? size}) async {
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }
    await tester.pumpWidget(MaterialApp(
      home: ClaudeConversationPickerScreen(
        connection: connection,
        loadDirectories: (path) async => RemoteDirectoryListing(
          path: path == '~' ? '/home/tester' : path,
          dirs: const [],
          homePath: '/home/tester',
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('runtime lookup errors preserve visible Claude history',
      (tester) async {
    ClaudeRuntimeService.requestOverride = (_, action, __) async {
      expect(action, 'list');
      throw StateError('runtime unavailable');
    };
    await pumpPicker(tester, size: const Size(390, 844));
    expect(find.byType(CodexSessionDialog), findsOneWidget);
    expect(find.text('历史 Claude 对话'), findsOneWidget);
    expect(find.text('历史预览'), findsOneWidget);
    expect(find.textContaining('运行状态读取失败'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('runtime-only session appears in the running filter',
      (tester) async {
    ClaudeRuntimeService.requestOverride = (_, action, __) async {
      if (action == 'list') {
        return [
          {
            'sessionId': 'runtime-only-1234',
            'tmuxSession': 'claude-runtime',
            'workDir': '/work/live',
            'status': 'busy',
            'alive': true,
          }
        ];
      }
      if (action == 'status') return {'session': null, 'messages': []};
      throw StateError('Unexpected runtime action: $action');
    };
    await pumpPicker(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('conversation-filter-running')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Claude 对话 runtime-'), findsOneWidget);
    expect(find.byTooltip('/work/live'), findsOneWidget);
    expect(find.text('历史 Claude 对话'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('create passes directory, model, effort and a v4 session id',
      (tester) async {
    Map<String, dynamic>? ensurePayload;
    ClaudeRuntimeService.requestOverride = (_, action, payload) async {
      if (action == 'list') return [];
      if (action == 'status') return {'session': null, 'messages': []};
      expect(action, 'ensure');
      ensurePayload = payload;
      return {
        'sessionId': payload['sessionId'],
        'tmuxSession': 'claude-test',
        'workDir': '/resolved/project',
        'status': 'ready',
        'alive': true,
      };
    };
    await pumpPicker(tester, size: const Size(390, 844));
    await tester.tap(find.byTooltip('新建对话'));
    await tester.pumpAndSettle();
    expect(find.text('~'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '/work/new-project');
    await tester.enterText(find.byType(TextField).last, 'custom-model');
    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('high').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();

    expect(ensurePayload!['resume'], isFalse);
    expect(ensurePayload!['workDir'], '/work/new-project');
    expect(ensurePayload!['model'], 'custom-model');
    expect(ensurePayload!['effort'], 'high');
    expect(
      ensurePayload!['sessionId'],
      matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
    );
    Navigator.of(tester.element(find.byType(CodexConversationViewerDialog)))
        .pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('continue passes resume true to the runtime', (tester) async {
    Map<String, dynamic>? ensurePayload;
    ClaudeRuntimeService.requestOverride = (_, action, payload) async {
      if (action == 'list') return [];
      if (action == 'status') return {'session': null, 'messages': []};
      expect(action, 'ensure');
      ensurePayload = payload;
      return {
        'sessionId': payload['sessionId'],
        'tmuxSession': 'claude-history',
        'workDir': payload['workDir'],
        'status': 'ready',
        'alive': true,
      };
    };
    await pumpPicker(tester, size: const Size(390, 844));
    await tester.tap(find.text('继续对话'));
    await tester.pumpAndSettle();
    expect(ensurePayload, {
      'sessionId': 'history-1',
      'workDir': '/work/project',
      'resume': true,
      'model': null,
      'effort': null,
    });
    Navigator.of(tester.element(find.byType(CodexConversationViewerDialog)))
        .pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Claude favorites persist independently by connection',
      (tester) async {
    await pumpPicker(tester, size: const Size(390, 844));
    await tester.tap(find.text('历史 Claude 对话'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('mobile-conversation-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏对话'));
      await Hive.box('settings').flush();
    });
    expect(Hive.box('settings').get('claude_favorites_connection-1'),
        ['history-1']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
