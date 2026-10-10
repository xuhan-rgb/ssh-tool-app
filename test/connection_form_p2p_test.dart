import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/connection_form_screen.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('frp-form-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(SshConnectionAdapter());
    }
    await Hive.openBox('settings');
    await Hive.openBox<SshConnection>('connections');
  });
  tearDown(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  testWidgets('editing exposes P2P settings and saves fallback preference',
      (tester) async {
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = SshConnection.create(
        name: 'linux',
        host: 'relay.example',
        port: 7001,
        username: 'qwer',
        password: 'test',
        useP2p: true,
        p2pOptions: {
          'serverAddr': 'coordinator.example',
          'serverPort': 7000,
          'serverUser': 'provider',
          'serverName': 'ssh-xtcp',
          'token': 'test-token',
          'secretKey': 'test-secret',
          'allowRelayFallback': true
        });
    await tester.runAsync(() =>
        Hive.box<SshConnection>('connections').put(connection.id, connection));
    await tester.pumpWidget(
        MaterialApp(home: ConnectionFormScreen(connection: connection)));
    expect(find.text('自动 P2P（免配置）'), findsOneWidget);
    expect(find.textContaining('在远程 Linux 电脑安装'), findsOneWidget);
    expect(find.textContaining('临时服务进程'), findsOneWidget);
    expect(find.textContaining('不重复上传'), findsOneWidget);
    expect(find.textContaining('不设置开机自启'), findsOneWidget);
    expect(find.text('XTCP 访问密钥'), findsNothing);
    expect(find.text('主机地址'), findsOneWidget);
    expect(find.text('frp 协调服务器地址'), findsNothing);
    await tester.tap(find.text('直连失败时保留原连接'));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('保存修改'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    final saved = Hive.box<SshConnection>('connections').get(connection.id)!;
    expect(saved.useP2p, isTrue);
    expect(saved.p2pOptions!['allowRelayFallback'], isFalse);
    expect(saved.p2pOptions!.keys, ['allowRelayFallback']);

    expect(saved.host, 'relay.example');
    expect(saved.port, 7001);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() => Hive.close());
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('ordinary new connection hides frp credentials', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectionFormScreen()));
    expect(find.text('普通 SSH'), findsOneWidget);
    expect(find.textContaining('在远程 Linux 电脑安装'), findsNothing);
    expect(find.text('XTCP 访问密钥'), findsNothing);
    await tester.tap(find.text('普通 SSH'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动 P2P（免配置）').last);
    await tester.pumpAndSettle();
    expect(find.text('frp 协调服务器地址'), findsNothing);
    expect(find.textContaining('在远程 Linux 电脑安装'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('直连失败时保留原连接'), 300,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('直连失败时保留原连接'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
