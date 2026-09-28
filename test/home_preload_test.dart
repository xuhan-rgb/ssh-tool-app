import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/home_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';

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
}
