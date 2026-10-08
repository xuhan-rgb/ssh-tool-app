import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_chat_screen.dart';
import 'package:ssh_tool_app/services/codex_chat_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory settingsDirectory;

  setUpAll(() async {
    settingsDirectory =
        await Directory.systemTemp.createTemp('codex-external-sync-');
    Hive.init(settingsDirectory.path);
    await Hive.openBox('settings');
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
    await settingsDirectory.delete(recursive: true);
  });

  testWidgets('idle chat refreshes a completed turn from another device',
      (tester) async {
    final connection = SshConnection(
      id: 'external-sync-host',
      name: 'test',
      host: 'localhost',
      username: 'test',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    var externalTurnCompleted = false;
    final records = [
      {'kind': 'user', 'text': 'Phone question'},
      {'kind': 'assistant', 'text': 'Phone response'},
      {'kind': 'user', 'text': 'Computer question'},
      {'kind': 'assistant', 'text': 'Computer response'},
    ];
    CodexSessionService.runPythonOverride = (_, __, ___) async {
      return externalTurnCompleted ? records.map(jsonEncode).join('\n') : '';
    };

    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'flutter/assets',
      (message) async => ByteData.sublistView(
        File(utf8.decode(message!.buffer.asUint8List())).readAsBytesSync(),
      ),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: connection,
        workDir: '/project',
        conversation: const CodexConversation(
          id: 'shared-thread',
          cwd: '/project',
          updatedAt: null,
          title: 'Shared thread',
        ),
        sendMessage: (_) async => const CodexChatResult(
          threadId: 'shared-thread',
          answer: 'Phone response',
        ),
        getRemoteSession: (_) async =>
            const CodexRemoteSessionStatus(open: true, busy: false),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('chat-input')), 'Phone question');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pumpAndSettle();
    expect(find.text('Phone question'), findsOneWidget);
    expect(find.text('Phone response'), findsOneWidget);

    externalTurnCompleted = true;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.text('Phone question'), findsOneWidget);
    expect(find.text('Phone response'), findsOneWidget);
    expect(find.text('Computer question'), findsOneWidget);
    expect(find.text('Computer response'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
