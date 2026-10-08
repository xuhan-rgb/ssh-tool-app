import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_setup_screen.dart';
import 'package:ssh_tool_app/services/codex_setup_service.dart';
import 'package:ssh_tool_app/widgets/connection_card.dart';

void main() {
  final connection = SshConnection(
    id: 'setup-test',
    name: 'Test host',
    host: 'example.test',
    username: 'user',
    createdAt: DateTime(2025),
    updatedAt: DateTime(2025),
  );

  CodexSetupStatus status({
    bool prepared = false,
    bool shortcutAvailable = false,
    bool loggedIn = true,
  }) =>
      CodexSetupStatus(
        system: 'Linux',
        codexPath: '/usr/local/bin/codex',
        version: 'codex 1.0',
        detail: 'Ready to use',
        pythonAvailable: true,
        tmuxAvailable: true,
        loggedIn: loggedIn,
        compatible: true,
        prepared: prepared,
        shortcutAvailable: shortcutAvailable,
      );

  testWidgets('shows checklist and prepares with the injected callback', (
    tester,
  ) async {
    var prepareCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CodexSetupScreen(
          connection: connection,
          inspect: (_) async => status(),
          prepare: (_) async {
            prepareCalls++;
            return status(prepared: true);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('检测详情'), findsOneWidget);
    expect(find.text('Codex CLI'), findsNothing);
    await tester.tap(find.text('检测详情'));
    await tester.pumpAndSettle();
    expect(find.text('Codex CLI'), findsOneWidget);
    expect(find.text('Codex 已登录'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('一键准备'), findsOneWidget);
    await tester.tap(find.text('一键准备'));
    await tester.pumpAndSettle();

    expect(prepareCalls, 1);
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('环境已就绪'), findsOneWidget);
    expect(find.text('一键准备'), findsNothing);
  });

  for (final prepared in [false, true]) {
    for (final shortcutAvailable in [false, true]) {
      testWidgets(
        'shows standard Codex instructions (prepared=$prepared, shortcut=$shortcutAvailable)',
        (tester) async {
          await tester.pumpWidget(MaterialApp(
            home: CodexSetupScreen(
              connection: connection,
              inspect: (_) async => status(
                prepared: prepared,
                shortcutAvailable: shortcutAvailable,
              ),
            ),
          ));
          await tester.pumpAndSettle();
          await tester.drag(find.byType(ListView), const Offset(0, -600));
          await tester.pumpAndSettle();
          expect(find.text('电脑端启动'), findsOneWidget);
          expect(find.byType(SelectableText), findsNothing);
          expect(find.text('配置电脑命令'), findsNothing);
          expect(find.textContaining('.bashrc'), findsNothing);
          await tester.tap(find.text('电脑端启动'));
          await tester.pumpAndSettle();
          expect(find.text('cd /你的项目目录'), findsOneWidget);
          expect(find.text('codex'), findsOneWidget);
          expect(find.text('codex resume <对话 ID>'), findsOneWidget);
          expect(find.text('手机选择同一个对话即可继续聊天。'), findsOneWidget);
          expect(find.text('独立启动'), findsNothing);
          expect(find.text('手机准备后连接'), findsNothing);
          expect(find.textContaining('codex-phone'), findsNothing);
          expect(find.textContaining('codex-yolo'), findsNothing);
          expect(find.text('一键准备'), prepared ? findsNothing : findsOneWidget);
        },
      );
    }
  }

  testWidgets('does not show network options or proxy inputs', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: CodexSetupScreen(
      connection: connection,
      inspect: (_) async => status(),
    )));
    await tester.pumpAndSettle();
    expect(find.text('网络设置'), findsNothing);
    expect(find.byType(TextFormField), findsNothing);
  });

  testWidgets('shows command generation errors on the setup screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CodexSetupScreen(
          connection: connection,
          inspect: (_) async => CodexSetupStatus(
            system: 'Linux',
            codexPath: '/usr/local/bin/codex',
            version: 'codex 1.0',
            detail: 'Not logged in',
            pythonAvailable: true,
            tmuxAvailable: true,
            loggedIn: false,
            compatible: true,
            prepared: false,
          ),
          login: (_) => Stream.error(StateError('SSH command failed')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('登录 Codex'));
    await tester.pumpAndSettle();
    expect(find.text('登录失败。请检查远端电脑网络配置（包括代理）和可用地区。'), findsOneWidget);
    await tester.tap(find.text('错误详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SSH command failed'), findsOneWidget);
  });

  testWidgets('shows split authorization URL and code in the page', (
    tester,
  ) async {
    var inspections = 0;
    final login = StreamController<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: CodexSetupScreen(
          connection: connection,
          inspect: (_) async => status(loggedIn: ++inspections > 1),
          login: (_) => login.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录 Codex'));
    await tester.pump();
    login.add(
      'Warning: https://example.invalid/help; use \u001b[36mhttps://auth.openai.com/cod',
    );
    await tester.pump();
    expect(find.text('等待 Codex 授权…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('https://auth.openai.com/cod'), findsOneWidget);
    expect(find.textContaining('https://example.invalid'), findsNothing);
    login.add('/device?user=code\u001b[0m and enter ABCD-');
    login.add('1234');
    await tester.pump();
    expect(
      find.textContaining('https://auth.openai.com/cod/device?user=code'),
      findsOneWidget,
    );
    expect(find.textContaining('ABCD-1234'), findsOneWidget);
    await tester.tap(find.text('登录输出'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('https://example.invalid'), findsOneWidget);
    await tester.tap(find.text('登录输出'));
    await tester.pump(const Duration(milliseconds: 300));
    await login.close();
    await tester.pumpAndSettle();
    expect(find.text('在终端中打开'), findsNothing);
    expect(find.text('登录 Codex'), findsNothing);
    await tester.tap(find.text('检测详情'));
    await tester.pumpAndSettle();
    expect(find.text('已登录'), findsWidgets);
  });

  testWidgets('login can be retried after a stream error', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CodexSetupScreen(
          connection: connection,
          inspect: (_) async => status(loggedIn: false),
          login: (_) => ++calls == 1
              ? Stream.error(StateError('temporary network failure'))
              : Stream.value('waiting for authorization'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录 Codex'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('错误详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining('temporary network failure'), findsOneWidget);
    await tester.tap(find.text('登录 Codex'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('等待 Codex 授权…'), findsNothing);
  });

  testWidgets('login stream is cancelled when the screen is disposed', (
    tester,
  ) async {
    var cancelled = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CodexSetupScreen(
          connection: connection,
          inspect: (_) async => status(loggedIn: false),
          login: (_) => Stream<String>.multi((controller) {
            controller.onCancel = () => cancelled = true;
          }),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录 Codex'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(cancelled, isTrue);
  });

  testWidgets('login can be cancelled and retried', (tester) async {
    var cancelledFirst = false;
    var calls = 0;
    final firstLogin = StreamController<String>(
      onCancel: () => cancelledFirst = true,
    );
    final secondLogin = StreamController<String>();
    await tester.pumpWidget(
      MaterialApp(
        home: CodexSetupScreen(
          connection: connection,
          inspect: (_) async => status(loggedIn: false),
          login: (_) => calls++ == 0 ? firstLogin.stream : secondLogin.stream,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('登录 Codex'));
    await tester.pump();
    await tester.tap(find.text('取消登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(cancelledFirst, isTrue);
    expect(find.text('登录 Codex'), findsOneWidget);
    await tester.tap(find.text('登录 Codex'));
    await tester.pump();
    secondLogin.add('retry stream is active');
    await tester.pump();
    expect(find.text('等待 Codex 授权…'), findsOneWidget);
    expect(find.text('取消登录'), findsOneWidget);
    await tester.tap(find.text('取消登录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    secondLogin.close();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'environment configuration is available only through the card menu',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var prepareCalls = 0;
      var connectCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionCard(
              connection: connection,
              onTap: () => connectCalls++,
              onEdit: () {},
              onDelete: () {},
              onCodexSetup: () => prepareCalls++,
            ),
          ),
        ),
      );

      expect(find.text('环境'), findsNothing);
      expect(find.text('Codex 环境配置'), findsNothing);
      expect(find.text('电脑端启动'), findsNothing);
      final withActionHeight = tester.getSize(find.byType(Card)).height;
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('Codex 环境配置'), findsOneWidget);
      await tester.tap(find.text('Codex 环境配置'));
      await tester.pumpAndSettle();
      expect(prepareCalls, 1);
      expect(connectCalls, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConnectionCard(
              connection: connection,
              onTap: () => connectCalls++,
              onEdit: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      final withoutActionHeight = tester.getSize(find.byType(Card)).height;
      expect(withActionHeight, closeTo(withoutActionHeight, 0.1));
    },
  );
}
