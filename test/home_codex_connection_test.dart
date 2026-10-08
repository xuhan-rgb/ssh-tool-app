import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/home_screen.dart';
import 'package:ssh_tool_app/services/claude_session_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/codex_setup_service.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SshConnection connection;
  final ready = {
    'system': 'Linux',
    'codexPath': '/usr/bin/codex',
    'version': 'codex-cli 0.161.0',
    'python': 'true',
    'tmux': 'true',
    'loggedIn': 'true',
    'compatible': 'true',
    'prepared': 'true',
    'detail': '共享会话服务已就绪',
  }.entries.map((e) => '${e.key}\t${base64Encode(utf8.encode(e.value))}').join('\n');

  setUp(() async {
    connection = SshConnection.create(
        name: 'Recovery host', host: 'localhost', username: 'test');
    rootBundle.evict('assets/codex_environment.sh');
    directory = await Directory.systemTemp.createTemp('home-codex-recovery-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(SshConnectionAdapter());
    await Hive.openBox('settings');
    await Hive.openBox<SshConnection>('connections');
    await Hive.box<SshConnection>('connections').put(connection.id, connection);
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = (_, __, ___) async => '';
    ClaudeSessionService.runPythonOverride = (_, __, ___) async => '';
    SshService.connectClientOverride = (_) async => TerminalSession(connection.id);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async =>
            ByteData.sublistView(File(utf8.decode(message!.buffer.asUint8List()))
                .readAsBytesSync()));
  });

  tearDown(() async {
    CodexSetupService.runOverride = null;
    CodexSessionService.runPythonOverride = null;
    CodexSessionService.clearCache();
    ClaudeSessionService.runPythonOverride = null;
    SshService.connectClientOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  Future<void> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await tester.pumpAndSettle();
  }

  testWidgets('opening environment recovery clears the old connection error',
      (tester) async {
    var attempts = 0;
    CodexSetupService.runOverride = (_, __) async {
      if (attempts++ < 2) throw const SocketException('connection unavailable');
      return ready;
    };
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法检测 Codex 环境'), findsOneWidget);
    await tester.tap(find.text('Recovery host'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查环境'));
    await tester.pumpAndSettle();
    expect(find.text('环境已就绪'), findsOneWidget);
    expect(find.text('一键准备'), findsNothing);
    expect(find.textContaining('无法检测 Codex 环境'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('successful retry clears the old error before opening conversations',
      (tester) async {
    var attempts = 0;
    CodexSetupService.runOverride = (_, __) async {
      if (attempts++ == 0) throw const SocketException('connection unavailable');
      return ready;
    };
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法检测 Codex 环境'), findsOneWidget);
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('选择 Codex 对话'), findsWidgets);
    expect(find.textContaining('无法检测 Codex 环境'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late failed inspection cannot report an error over a connected route',
      (tester) async {
    final pending = Completer<String>();
    var attempts = 0;
    CodexSetupService.runOverride = (_, __) => attempts++ == 0
        ? pending.future
        : Future.value(ready);
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('选择 Codex 对话'), findsWidgets);
    pending.completeError(const SocketException('old request failed'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('无法检测 Codex 环境'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
