import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/screens/codex_chat_screen.dart';
import 'package:ssh_tool_app/services/codex_chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('codex-image-layout-');
    Hive.init(storage.path);
    await Hive.openBox('settings');
  });
  tearDownAll(() async {
    await storage.delete(recursive: true);
  });

  testWidgets('each parsed image stays by its name and full view fills phone',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 9, 24);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'image-layout',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        sendMessage: (_) async => const CodexChatResult(
          threadId: 'thread-image',
          answer: '第一张：![预览](/tmp/first.png)\n比较说明\n第二张：![预览](/tmp/second.png)',
        ),
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '查看图片');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    await tester.pump();

    final first = find.byKey(const ValueKey('inline-image-/tmp/first.png'));
    final second = find.byKey(const ValueKey('inline-image-/tmp/second.png'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(find.text('first.png'), findsOneWidget);
    expect(find.text('second.png'), findsOneWidget);
    expect(tester.getTopLeft(find.textContaining('第一张')).dy,
        lessThan(tester.getTopLeft(first).dy));
    expect(tester.getTopLeft(first).dy,
        lessThan(tester.getTopLeft(find.textContaining('比较说明')).dy));
    expect(tester.getTopLeft(find.textContaining('比较说明')).dy,
        lessThan(tester.getTopLeft(second).dy));

    await tester.pump();
    await tester.tap(find.text('无法加载图片，点击重试').first);
    await tester.pumpAndSettle();
    final dialog = find.byType(Dialog);
    expect(dialog, findsOneWidget);
    expect(tester.getSize(dialog).width, 390);
    expect(tester.getSize(dialog).height, 1000);
  });

  testWidgets('ordinary image paths stay as selectable file names',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'image-reference',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        sendMessage: (_) async => const CodexChatResult(
          threadId: 'thread-reference',
          answer: '文件：`result.png`，另见 [原图](other.png)',
        ),
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '查看图片');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    await tester.pump();

    expect(find.text('查看图片列表 · 2 张'), findsOneWidget);
    expect(find.byKey(const ValueKey('inline-image-result.png')), findsNothing);
    expect(find.byKey(const ValueKey('inline-image-other.png')), findsNothing);
    expect(find.text('无法加载图片，点击重试'), findsNothing);
  });

  testWidgets('many images show a list and load only the selected image',
      (tester) async {
    final now = DateTime(2026, 9, 24);
    await tester.pumpWidget(MaterialApp(
      home: CodexChatScreen(
        connection: SshConnection(
          id: 'image-list',
          name: 'test',
          host: 'localhost',
          username: 'test',
          createdAt: now,
          updatedAt: now,
        ),
        workDir: '/project',
        sendMessage: (_) async => const CodexChatResult(
          threadId: 'thread-list',
          answer: '`a.png` `b.png` `c.png`',
        ),
      ),
    ));
    await tester.enterText(find.byKey(const ValueKey('chat-input')), '图片');
    await tester.tap(find.byKey(const ValueKey('chat-send')));
    await tester.pump();
    await tester.pump();

    expect(find.text('查看图片列表 · 3 张'), findsOneWidget);
    expect(find.byKey(const ValueKey('inline-image-a.png')), findsNothing);
    expect(find.text('无法加载图片，点击重试'), findsNothing);

    await tester.tap(find.text('查看图片列表 · 3 张'));
    await tester.pumpAndSettle();
    expect(find.text('图片列表 · 3 张'), findsOneWidget);
    expect(find.text('a.png'), findsOneWidget);
    expect(find.text('b.png'), findsOneWidget);
    expect(find.text('c.png'), findsOneWidget);
    await tester.tap(find.text('b.png').first);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.textContaining('无法读取远端图片'), findsOneWidget);
  });
}
