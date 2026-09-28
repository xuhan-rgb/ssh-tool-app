import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/home_screen.dart';
import 'package:ssh_tool_app/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    await Hive.close();
    tempDir = await Directory.systemTemp.createTemp(
      'ssh_tool_app_widget_test_',
    );
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(SshConnectionAdapter());
    }
    await Hive.openBox<SshConnection>('connections');
    await Hive.openBox('settings');
    SshService.activeSessionsNotifier.value = <String>{};
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  testWidgets('home screen shows empty state when no connections exist', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: HomeScreen(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('还没有 SSH 连接'), findsOneWidget);
    expect(find.text('点击下方按钮添加第一个连接'), findsOneWidget);
    expect(find.text('新建连接'), findsOneWidget);
  });
}
