import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  test('remote reader keeps latest turn model and effort beyond record limit',
      () async {
    final home = await Directory.systemTemp.createTemp('codex-turn-config-');
    addTearDown(() => home.delete(recursive: true));
    final sessions = await Directory('${home.path}/sessions').create();
    final rollout = File('${sessions.path}/rollout-test-thread.jsonl');
    final lines = <Map<String, Object?>>[];
    void add(String type, Map<String, Object?> payload) =>
        lines.add({'type': type, 'payload': payload});
    add('event_msg', {'type': 'task_started'});
    add('turn_context', {'model': 'gpt-6', 'effort': 'high'});
    for (var i = 0; i < 305; i++) {
      add('response_item', {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'text': 'reply $i'}
        ]
      });
    }
    add('event_msg', {'type': 'task_complete'});
    final source =
        await File('lib/services/codex_session_service.dart').readAsString();
    final script =
        RegExp("static const String _readScript = r'''(.*?)''';", dotAll: true)
            .firstMatch(source)!
            .group(1)!;
    Future<List<CodexConversationRecord>> read() async {
      await rollout.writeAsString(lines.map(jsonEncode).join('\n'));
      final result = await Process.run('python3', ['-c', script, 'thread'],
          environment: {'CODEX_HOME': home.path});
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return CodexConversationParser.parseRecords(result.stdout as String);
    }

    var records = await read();
    expect(records.length, 300);
    expect(records.last.model, 'gpt-6');
    expect(records.last.reasoningEffort, 'high');
    add('event_msg', {'type': 'task_started'});
    records = await read();
    expect(records.last.model, isNull);
    expect(records.last.reasoningEffort, isNull);
    add('turn_context', {'model': 'gpt-6-mini', 'effort': 'low'});
    records = await read();
    expect(records.last.model, 'gpt-6-mini');
    expect(records.last.reasoningEffort, 'low');
    add('turn_context', {'model': 'legacy-model'});
    records = await read();
    expect(records.last.model, 'legacy-model');
    expect(records.last.reasoningEffort, isNull);
    add('turn_context', {
      'model': 123,
      'effort': {'invalid': true}
    });
    records = await read();
    expect(records.last.model, isNull);
    expect(records.last.reasoningEffort, isNull);
  });

  test('older records and malformed metadata remain readable', () {
    final records = CodexConversationParser.parseRecords(
        '${jsonEncode({'kind': 'assistant', 'text': 'old'})}\n'
        '${jsonEncode({
          'kind': 'assistant',
          'text': 'new',
          'model': 123,
          'reasoningEffort': []
        })}');
    expect(records, hasLength(2));
    expect(
        records.every(
            (record) => record.model == null && record.reasoningEffort == null),
        isTrue);
  });

  testWidgets('viewer refreshes model and effort and clears missing values',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        home: CodexConversationViewerDialog(
      conversation: const CodexConversation(
          id: 'config', cwd: '/project', updatedAt: null, title: '配置'),
      loadRecords: (_) async => [
        CodexConversationRecord(
          kind: 'turn_context',
          timestamp: null,
          text: '配置',
          model: reads == 0
              ? 'gpt-6'
              : reads == 1
                  ? 'gpt-6-mini'
                  : null,
          reasoningEffort: reads++ == 0
              ? 'high'
              : reads == 2
                  ? 'low'
                  : null,
        )
      ],
    )));
    await tester.pumpAndSettle();
    expect(find.text('模型：gpt-6 · 思考强度：高（high）'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新记录'));
    await tester.pumpAndSettle();
    expect(find.text('模型：gpt-6-mini · 思考强度：低（low）'), findsOneWidget);
    await tester.tap(find.byTooltip('刷新记录'));
    await tester.pumpAndSettle();
    expect(find.text('模型：未知 · 思考强度：未知'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
