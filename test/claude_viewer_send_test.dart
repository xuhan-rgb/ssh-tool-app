import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/claude_runtime_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/widgets/codex_goal_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory settingsDirectory;
  setUpAll(() async {
    settingsDirectory =
        await Directory.systemTemp.createTemp('claude-viewer-settings-');
    Hive.init(settingsDirectory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(SshConnectionAdapter());
    }
    await Hive.openBox<SshConnection>('connections');
    await Hive.openBox('settings');
  });
  setUp(() async {
    await Hive.box('settings').clear();
    CodexSessionService.clearCache();
  });
  tearDown(() {
    ClaudeRuntimeService.requestOverride = null;
    CodexSessionService.runPythonOverride = null;
  });
  tearDownAll(() async {
    await Hive.close();
    await settingsDirectory.delete(recursive: true);
  });

  const connectionId = 'claude-viewer-connection';
  const sessionId = 'claude-viewer-session';

  Map<String, Object?> session(String status) => {
        'sessionId': sessionId,
        'tmuxSession': 'claude-session',
        'workDir': '/project',
        'status': status,
        'alive': true,
      };

  Map<String, Object?> receipt(String id, String text, String status,
          {String? error}) =>
      {
        'id': id,
        'text': text,
        'status': status,
        'createdAt': 1700000000,
        if (error != null) 'error': error,
      };

  Widget viewer(
          Future<List<CodexConversationRecord>> Function(String) loadRecords) =>
      MaterialApp(
        home: CodexConversationViewerDialog(
          connectionId: connectionId,
          isClaude: true,
          conversation: const CodexConversation(
            id: sessionId,
            cwd: '/project',
            title: 'Claude history',
            updatedAt: null,
            state: CodexConversationState.complete,
          ),
          loadRecords: loadRecords,
        ),
      );

  Future<void> disposeViewer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets(
      'busy Claude queues text, preserves remote receipt on reopen, and skips Codex services',
      (tester) async {
    final requests = <(String, Map<String, dynamic>)>[];
    final remoteMessages = <Map<String, Object?>>[];
    var codexCalls = 0;
    CodexSessionService.runPythonOverride = (connectionId, script, args) async {
      codexCalls++;
      throw StateError('Codex service must not be called');
    };
    ClaudeRuntimeService.requestOverride =
        (connectionId, action, payload) async {
      requests.add((action, payload));
      if (action == 'status') {
        return {'session': session('busy'), 'messages': remoteMessages};
      }
      if (action == 'send') {
        remoteMessages.add(receipt(payload['messageId'] as String,
            payload['text'] as String, 'queued'));
        return <String, Object?>{};
      }
      fail('Unexpected Claude runtime action: $action');
    };

    await tester.pumpWidget(viewer((_) async => const []));
    await tester.pump();
    expect(find.text('远程记录为空'), findsOneWidget);
    expect(find.text('Claude 正在执行 · 新消息会排队'), findsOneWidget);
    expect(find.byType(CodexGoalCard), findsNothing);
    final input = find.byKey(const ValueKey('claude-message-input'));
    final send = find.byKey(const ValueKey('claude-send-message'));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'Inspect this change');
    await tester.tap(send);
    await tester.pump();
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    final sendRequest = requests.singleWhere((request) => request.$1 == 'send');
    expect(sendRequest.$2['sessionId'], sessionId);
    expect(sendRequest.$2['text'], 'Inspect this change');
    final messageId = sendRequest.$2['messageId'] as String;
    expect(messageId, isNotEmpty);
    expect(find.text('已排队 · 等待 Claude 空闲'), findsOneWidget);
    expect(codexCalls, 0);

    await disposeViewer(tester);
    await tester.pumpWidget(viewer((_) async => const []));
    await tester.pump();
    expect(find.text('已排队 · 等待 Claude 空闲'), findsOneWidget);
    expect(find.text('Inspect this change'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(codexCalls, 0);
    await disposeViewer(tester);
  });

  testWidgets('failed send retries with same id and edited draft gets a new id',
      (tester) async {
    final sent = <Map<String, dynamic>>[];
    var failuresRemaining = 2;
    ClaudeRuntimeService.requestOverride =
        (connectionId, action, payload) async {
      if (action == 'status') {
        return {'session': session('busy'), 'messages': <Object>[]};
      }
      if (action == 'send') {
        sent.add(Map<String, dynamic>.from(payload));
        if (failuresRemaining-- > 0) {
          throw StateError('runtime send failed');
        }
        return <String, Object?>{};
      }
      fail('Unexpected Claude runtime action: $action');
    };
    await tester.pumpWidget(viewer((_) async => const []));
    await tester.pump();
    final input = find.byKey(const ValueKey('claude-message-input'));
    final send = find.byKey(const ValueKey('claude-send-message'));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'retry this');
    await tester.tap(send);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'retry this');
    expect(find.textContaining('runtime send failed'), findsOneWidget);
    final firstId = sent.single['messageId'];

    await tester.tap(send);
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, 'retry this');
    expect(sent[1]['messageId'], firstId);

    await tester.enterText(input, 'changed draft');
    await tester.tap(send);
    await tester.pump();
    await tester.pump();
    expect(sent[2]['text'], 'changed draft');
    expect(sent[2]['messageId'], isNot(firstId));
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    await disposeViewer(tester);
  });

  testWidgets('unknown runtime status disables continue after a runtime error',
      (tester) async {
    var ensureCalls = 0;
    ClaudeRuntimeService.requestOverride =
        (connectionId, action, payload) async {
      if (action == 'status') throw StateError('runtime unavailable');
      if (action == 'ensure') {
        ensureCalls++;
        return session('ready');
      }
      fail('Unexpected Claude runtime action: $action');
    };
    await tester.pumpWidget(viewer((_) async => const []));
    await tester.pump();
    expect(find.textContaining('运行状态读取失败'), findsOneWidget);
    final continueButton =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '继续此对话'));
    expect(continueButton.onPressed, isNull);
    await tester.tap(find.text('继续此对话'), warnIfMissed: false);
    await tester.pump();
    expect(ensureCalls, 0);
    await disposeViewer(tester);
  });

  testWidgets(
      'awaiting input warns and an uncertain receipt is not shown as accepted',
      (tester) async {
    final messages = <Map<String, Object?>>[];
    ClaudeRuntimeService.requestOverride =
        (connectionId, action, payload) async {
      if (action == 'status') {
        return {'session': session('awaiting_input'), 'messages': messages};
      }
      if (action == 'send') {
        messages.add(receipt(payload['messageId'] as String,
            payload['text'] as String, 'uncertain',
            error: 'Claude 等待终端确认'));
        return <String, Object?>{};
      }
      fail('Unexpected Claude runtime action: $action');
    };
    await tester.pumpWidget(viewer((_) async => const []));
    await tester.pump();
    expect(find.text('Claude 等待确认 · 请打开终端处理'), findsOneWidget);
    final input = find.byKey(const ValueKey('claude-message-input'));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'Answer the prompt');
    await tester.tap(find.byKey(const ValueKey('claude-send-message')));
    await tester.pump();
    await tester.pump();
    expect(find.text('Claude 等待终端确认'), findsOneWidget);
    expect(find.text('Claude 已收到'), findsNothing);
    await disposeViewer(tester);
  });
}
