import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/widgets/connection_card.dart';

void main() {
  final connection = SshConnection.create(
      name: 'Test host', host: 'localhost', username: 'test');

  Future<void> showCard(WidgetTester tester,
      {required bool active, int? latency}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ConnectionCard(
        connection: connection,
        isActive: active,
        latencyMs: latency,
        onTap: () {},
        onEdit: () {},
        onDelete: () {},
      )),
    ));
  }

  testWidgets('connected card shows latency next to connection status',
      (tester) async {
    await showCard(tester, active: true, latency: 123);
    expect(find.text('● 已连接'), findsOneWidget);
    expect(find.text('123 ms'), findsOneWidget);
    expect(find.byTooltip('SSH 往返延迟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing sample is unknown and disconnected card hides latency',
      (tester) async {
    await showCard(tester, active: true);
    expect(find.text('— ms'), findsOneWidget);
    await showCard(tester, active: false, latency: 123);
    expect(find.byTooltip('SSH 往返延迟'), findsNothing);
    expect(find.text('123 ms'), findsNothing);
  });
  testWidgets('P2P card reports actual relay route and fallback reason', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConnectionCard(
      connection: connection.copyWith(useP2p: true), isActive: true,
      latencyMs: 300, route: '原连接', fallbackReason: '打洞失败',
      onTap: () {}, onEdit: () {}, onDelete: () {},
    ))));
    expect(find.text('原连接'), findsOneWidget);
    expect(find.byTooltip('打洞失败'), findsOneWidget);
    expect(find.text('300 ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('connecting card shows current stage and hides it when finished',
      (tester) async {
    for (final connecting in [true, false]) {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: ConnectionCard(
        connection: connection, isConnecting: connecting,
        connectionProgress: '正在上传远程辅助程序（首次连接或版本更新）…',
        onTap: () {}, onEdit: () {}, onDelete: () {},
      ))));
      expect(find.textContaining('正在上传远程辅助程序'),
          connecting ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

}
