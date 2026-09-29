import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';
import 'package:ssh_tool_app/widgets/codex_terminal_record.dart';

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('terminal-view-');
    Hive.init(directory.path);
    await Hive.openBox('settings');
  });
  setUp(() async {
    if (!Hive.isBoxOpen('settings')) await Hive.openBox('settings');
    await Hive.box('settings').clear();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('log level defaults to terminal and persists in local settings',
      () async {
    expect(StorageService.getCodexViewerLogLevel(), 'terminal');
    await StorageService.setCodexViewerLogLevel('full');
    await Hive.box('settings').close();
    await Hive.openBox('settings');
    expect(StorageService.getCodexViewerLogLevel(), 'full');
    await Hive.box('settings')
        .put('codex_viewer_log_level_v1', 'old-invalid-value');
    expect(StorageService.getCodexViewerLogLevel(), 'terminal');
  });

  testWidgets(
      'terminal is default, shows progress and summaries, full log reveals raw records',
      (tester) async {
    await tester.runAsync(() => Hive.box('settings').close());
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var complete = false;
    await tester.pumpWidget(MaterialApp(
        home: CodexConversationViewerDialog(
      conversation: const CodexConversation(
          id: 'terminal-view',
          cwd: '/project',
          updatedAt: null,
          title: '终端视图',
          state: CodexConversationState.running),
      loadRecords: (_) async => [
        CodexConversationRecord(
            kind: 'task_started',
            timestamp: DateTime.now().subtract(const Duration(minutes: 18)),
            text: '任务开始'),
        const CodexConversationRecord(
            kind: 'reasoning',
            timestamp: null,
            text: '**Reviewing test insert issues**\n完整推理正文',
            terminalSummary: 'Reviewing test insert issues'),
        const CodexConversationRecord(
            kind: 'tool_call',
            timestamp: null,
            text: 'raw-call-arguments',
            terminalSummary: 'Failed (exit 1) pytest',
            terminalDetails: '3 failed in 0.09s'),
        const CodexConversationRecord(
            kind: 'tool_output', timestamp: null, text: 'raw-output'),
        const CodexConversationRecord(
            kind: 'assistant', timestamp: null, text: '正在修复测试'),
        if (complete)
          const CodexConversationRecord(
              kind: 'task_complete', timestamp: null, text: '任务完成'),
      ],
    )));
    await tester.pump();
    expect(
        tester
            .widget<DropdownButton<String>>(
                find.byKey(const ValueKey('viewer-log-toggle')))
            .value,
        'terminal');
    expect(find.textContaining('Reviewing test insert issues (18m'),
        findsOneWidget);
    expect(find.text('Failed (exit 1) pytest'), findsOneWidget);
    expect(find.text('raw-call-arguments'), findsNothing);
    expect(find.text('raw-output'), findsNothing);
    expect(find.textContaining('完整推理正文'), findsNothing);

    Future<void> choose(String text) async {
      await tester.tap(find.byKey(const ValueKey('viewer-log-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(text).last);
      await tester.pumpAndSettle();
    }

    await choose('完整日志');
    expect(find.text('raw-call-arguments'), findsOneWidget);
    expect(find.text('raw-output'), findsOneWidget);
    await choose('只看对话');
    expect(find.text('正在修复测试'), findsOneWidget);
    expect(find.byType(CodexTerminalRecord), findsNothing);
    expect(find.byKey(const ValueKey('viewer-terminal-status')), findsNothing);
    await choose('终端视图');
    complete = true;
    await tester.tap(find.byTooltip('刷新记录'));
    await tester.pump();
    expect(find.byKey(const ValueKey('viewer-terminal-status')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'patch details expand and collapse without showing raw tool arguments',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: CodexTerminalRecord(
      record: CodexConversationRecord(
          kind: 'tool_call',
          timestamp: null,
          text: 'raw arguments',
          terminalSummary: 'Edited 1 file (+1 -1)',
          terminalDetails:
              '*** Begin Patch\n*** Update File: src/task.py\n@@\n-old\n+new\n context\n hidden detail\n*** End Patch'),
    ))));
    expect(find.text('└ src/task.py'), findsOneWidget);
    expect(find.text('-old'), findsOneWidget);
    expect(find.text('+new'), findsOneWidget);
    expect(find.text(' hidden detail'), findsNothing);
    await tester.tap(find.text('+ 显示详情'));
    await tester.pump();
    expect(find.text(' hidden detail'), findsOneWidget);
    await tester.tap(find.text('− 收起详情'));
    await tester.pump();
    expect(find.text(' hidden detail'), findsNothing);
  });
  testWidgets('collapsed patch shows a preview for each changed file',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: CodexTerminalRecord(
      record: CodexConversationRecord(
          kind: 'tool_call',
          timestamp: null,
          text: 'patch',
          terminalSummary: 'Edited 2 files (+2 -2)',
          terminalDetails:
              '*** Update File: a.py\n@@\n context one\n context two\n context three\n-old a\n+new a\n context\n extra\n*** Update File: b.py\n@@\n-old b\n+new b'),
    ))));
    expect(find.text('└ a.py'), findsOneWidget);
    expect(find.text('└ b.py'), findsOneWidget);
    expect(find.text('+new a'), findsOneWidget);
    expect(find.text('+new b'), findsOneWidget);
  });
  testWidgets('collapsed long output is bounded in screen rows',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
      child: CodexTerminalRecord(
        key: const ValueKey('entry'),
        record: CodexConversationRecord(
            kind: 'tool_call',
            timestamp: null,
            text: 'raw',
            terminalSummary: 'Ran ${'long command ' * 40}',
            terminalDetails:
                '${'very long output ' * 400}\nsecond\nthird\nfourth\nfifth\nlast detail'),
      ),
    ))));
    final collapsedHeight =
        tester.getSize(find.byKey(const ValueKey('entry'))).height;
    expect(collapsedHeight, lessThan(200));
    expect(find.text('last detail'), findsNothing);
    await tester.tap(find.text('+ 显示详情'));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('entry'))).height,
        greaterThan(collapsedHeight));
    expect(find.text('last detail'), findsOneWidget);
    await tester.ensureVisible(find.text('− 收起详情'));
    await tester.tap(find.text('− 收起详情'));
    await tester.pump();
    expect(tester.getSize(find.byKey(const ValueKey('entry'))).height,
        collapsedHeight);
  });
}
