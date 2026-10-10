import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/home_screen.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/screens/codex_chat_screen.dart';
import 'package:ssh_tool_app/screens/codex_setup_screen.dart';
import 'package:ssh_tool_app/services/claude_session_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/codex_setup_service.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

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
  }
      .entries
      .map((e) => '${e.key}\t${base64Encode(utf8.encode(e.value))}')
      .join('\n');

  setUp(() async {
    connection = SshConnection.create(
        name: 'Recovery host', host: 'localhost', username: 'test');
    rootBundle.evict('assets/codex_environment.sh');
    directory = await Directory.systemTemp.createTemp('home-codex-recovery-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(0))
      Hive.registerAdapter(SshConnectionAdapter());
    await Hive.openBox('settings');
    await Hive.openBox<SshConnection>('connections');
    await Hive.box<SshConnection>('connections').put(connection.id, connection);
    CodexSessionService.clearCache();
    CodexSessionService.runPythonOverride = (_, __, ___) async => '';
    ClaudeSessionService.runPythonOverride = (_, __, ___) async => '';
    SshService.connectClientOverride =
        (_) async => TerminalSession(connection.id);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'flutter/assets',
            (message) async => ByteData.sublistView(
                File(utf8.decode(message!.buffer.asUint8List()))
                    .readAsBytesSync()));
    rootBundle.evict('assets/codex_steer_message.py');
    await rootBundle.loadString('assets/codex_steer_message.py');
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

  testWidgets(
      'first tap opens the list without waiting for environment inspection',
      (tester) async {
    var inspections = 0;
    final pending = Completer<String>();
    CodexSetupService.runOverride = (_, __) {
      inspections++;
      return pending.future;
    };
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('选择 Codex 对话'), findsWidgets);
    expect(inspections, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reopening retains the latest remote completion status',
      (tester) async {
    final now = DateTime.now();
    await tester.runAsync(() => StorageService.markCodexConversationViewed(
        connection.id, 'completed-thread',
        viewedAt: now.subtract(const Duration(hours: 1))));
    var remoteReads = 0;
    final pending = Completer<String>();
    CodexSessionService.runPythonOverride = (_, __, args) async {
      if (args.first == '__running__') return '';
      final remote = args.first == '__opened__';
      if (remote && ++remoteReads > 1) return pending.future;
      return jsonEncode({
        'id': 'completed-thread',
        'cwd': '/project',
        'title': 'Completed task',
        'updatedAt': now.toIso8601String(),
        'state': remote ? 'complete' : 'running',
        'remoteOpen': true,
      });
    };
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.descendant(
        of: find.byKey(const ValueKey('conversation-state-completed-thread')),
        matching: find.text('新回复')), findsOneWidget);
    Navigator.of(tester.element(find.byType(CodexSessionDialog))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.descendant(
        of: find.byKey(const ValueKey('conversation-state-completed-thread')),
        matching: find.text('新回复')), findsOneWidget);
    expect(find.text('正在执行'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stays on home while SSH is pending, then opens the cached list',
      (tester) async {
    CodexSetupService.runOverride = (_, __) => Completer<String>().future;
    CodexSessionService.runPythonOverride = (_, __, ___) async => jsonEncode({
          'id': 'cached-thread',
          'cwd': '/project',
          'title': 'Already loaded conversation',
          'state': 'complete',
          'remoteOpen': true,
        });
    await tester.runAsync(() => CodexSessionService.listAll(connection.id));
    final connecting = Completer<TerminalSession>();
    var attempts = 0;
    SshService.connectClientOverride = (_) {
      attempts++;
      return connecting.future;
    };
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Already loaded conversation'), findsNothing);
    expect(find.text('正在连接…'), findsOneWidget);
    expect(find.text('>_ SSH 终端'), findsOneWidget);
    await tester.tap(find.text('Recovery host'));
    expect(attempts, 1);
    connecting.complete(TerminalSession(connection.id));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Already loaded conversation'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rejected credentials stay on home and offer editing',
      (tester) async {
    SshService.connectClientOverride = (_) async =>
        throw SSHAuthFailError('All authentication methods failed');
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pumpAndSettle();
    expect(find.text('>_ SSH 终端'), findsOneWidget);
    expect(find.text('选择 Codex 对话'), findsNothing);
    expect(find.textContaining('用户名或密码错误'), findsOneWidget);
    expect(find.text('编辑连接'), findsOneWidget);
    expect(find.text('正在连接…'), findsNothing);
  });

  testWidgets('unreachable host stays on home with a network error',
      (tester) async {
    SshService.connectClientOverride = (_) async =>
        throw const SocketException('Network is unreachable');
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pumpAndSettle();
    expect(find.text('>_ SSH 终端'), findsOneWidget);
    expect(find.text('选择 Codex 对话'), findsNothing);
    expect(find.textContaining('网络连接失败'), findsOneWidget);
  });

  testWidgets('timeout stays on home with an explicit timeout message',
      (tester) async {
    SshService.connectClientOverride = (_) async =>
        throw TimeoutException('connection timed out');
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pumpAndSettle();
    expect(find.text('>_ SSH 终端'), findsOneWidget);
    expect(find.text('选择 Codex 对话'), findsNothing);
    expect(find.textContaining('连接超时'), findsOneWidget);
  });

  testWidgets('returning and reopening never repeats the environment preflight',
      (tester) async {
    var inspections = 0;
    CodexSetupService.runOverride = (_, __) async {
      inspections++;
      return ready;
    };
    await launch(tester);
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Recovery host'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('选择 Codex 对话'), findsWidgets);
      if (i == 0) {
        Navigator.of(tester.element(find.byType(CodexSessionDialog))).pop();
        await tester.pumpAndSettle();
      }
    }
    expect(inspections, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('verified host launches without another environment inspection',
      (tester) async {
    await tester.runAsync(
        () => StorageService.markCodexEnvironmentVerified(connection));
    var inspections = 0;
    CodexSetupService.runOverride = (_, __) async {
      inspections++;
      return ready;
    };
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    Navigator.of(tester.element(find.byType(CodexSessionDialog))).pop(
        const CodexSessionConfig(
            name: 'codex-1', workDir: '/project', openAsChat: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(CodexChatScreen), findsOneWidget);
    expect(inspections, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'launch still checks the environment and shows progress and recovery',
      (tester) async {
    final pending = Completer<String>();
    var inspections = 0;
    CodexSetupService.runOverride = (_, __) {
      inspections++;
      return pending.future;
    };
    await launch(tester);
    await tester.tap(find.text('Recovery host'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    Navigator.of(tester.element(find.byType(CodexSessionDialog))).pop(
        const CodexSessionConfig(
            name: 'codex-1', workDir: '/project', openAsChat: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(inspections, 1);
    expect(find.text('正在检查 Codex 环境…'), findsOneWidget);
    expect(find.byType(CodexChatScreen), findsNothing);
    pending.completeError(const SocketException('connection unavailable'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法检测 Codex 环境'), findsOneWidget);
    expect(find.byType(CodexChatScreen), findsNothing);
    CodexSetupService.runOverride = (_, __) => Completer<String>().future;
    await tester.tap(find.text('检查环境'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(CodexSetupScreen), findsOneWidget);
    expect(find.textContaining('无法检测 Codex 环境'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
