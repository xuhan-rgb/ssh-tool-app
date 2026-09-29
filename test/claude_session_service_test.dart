import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/claude_session_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

Future<String> runScript(String script, String home,
    [List<String> args = const []]) async {
  final result = await Process.run('python3', ['-c', script, ...args],
      environment: {...Platform.environment, 'HOME': home});
  if (result.exitCode != 0) {
    throw StateError('Python exited ${result.exitCode}: ${result.stderr}');
  }
  return result.stdout as String;
}

void main() {
  test('lists indexed and unindexed Claude sessions from temporary HOME',
      () async {
    final home = await Directory.systemTemp.createTemp('claude-sessions-');
    addTearDown(() async {
      ClaudeSessionService.runPythonOverride = null;
      await home.delete(recursive: true);
    });
    final projects = await Directory('${home.path}/.claude/projects')
        .create(recursive: true);
    final indexedProject = await Directory('${projects.path}/indexed').create();
    final rawProject = await Directory('${projects.path}/raw').create();
    await Directory('${home.path}/work/project').create(recursive: true);
    await Directory('${home.path}/work/new-project').create(recursive: true);
    const indexedId = 'indexed-123';
    const rawId = 'raw-456';
    await File('${indexedProject.path}/sessions-index.json')
        .writeAsString(jsonEncode({
      'entries': [
        {
          'sessionId': indexedId,
          'fullPath': '${indexedProject.path}/$indexedId.jsonl',
          'summary': 'Indexed summary',
          'firstPrompt': 'Indexed first prompt',
          'projectPath': '${home.path}/work/project',
          'modified': '2026-09-28T10:30:00Z',
        },
        {
          'sessionId': 'missing-directory',
          'summary': 'Missing workspace',
          'firstPrompt': 'First prompt',
          'projectPath': '${home.path}/does-not-exist',
          'modified': '2026-09-27T10:30:00Z',
        },
      ],
    }));
    await File('${indexedProject.path}/$indexedId.jsonl').writeAsString([
      jsonEncode({
        'type': 'user',
        'sessionId': indexedId,
        'cwd': '${home.path}/work/new-project',
        'timestamp': '2026-09-29T11:00:00Z',
        'message': {'content': 'New prompt'}
      }),
      jsonEncode({
        'type': 'assistant',
        'sessionId': indexedId,
        'cwd': '${home.path}/work/new-project',
        'timestamp': '2026-09-29T11:00:05Z',
        'message': {'content': 'Done', 'stop_reason': 'end_turn'}
      }),
      jsonEncode({
        'type': 'ai-title',
        'sessionId': indexedId,
        'aiTitle': 'Transcript title',
        'timestamp': '2026-09-29T11:00:06Z'
      }),
    ].join('\n'));
    await File('${rawProject.path}/$rawId.jsonl').writeAsString([
      '{not json',
      jsonEncode({
        'type': 'user',
        'sessionId': rawId,
        'cwd': '${home.path}/work/project',
        'timestamp': '2026-09-29T01:00:00Z',
        'message': {'content': 'How are you?'}
      }),
      jsonEncode({
        'type': 'assistant',
        'sessionId': rawId,
        'cwd': '${home.path}/work/project',
        'timestamp': '2026-09-29T01:00:05Z',
        'message': {
          'content': [
            {'type': 'text', 'text': 'I am well.'}
          ],
          'stop_reason': 'end_turn'
        }
      }),
      jsonEncode({
        'type': 'ai-title',
        'sessionId': rawId,
        'aiTitle': 'Raw log title',
        'timestamp': '2026-09-29T01:00:06Z'
      }),
    ].join('\n'));
    final brokenIndex = File('${projects.path}/broken/sessions-index.json');
    await brokenIndex.parent.create(recursive: true);
    await brokenIndex.writeAsString('{broken');

    ClaudeSessionService.runPythonOverride =
        (connectionId, script, args) async {
      expect(connectionId, 'remote-1');
      expect(args, isEmpty);
      expect(script, ClaudeSessionService.listScript);
      return runScript(script, home.path, args);
    };
    final conversations = await ClaudeSessionService.listAll('remote-1');
    expect(conversations.map((item) => item.id),
        containsAll([indexedId, rawId, 'missing-directory']));
    final indexed = conversations.singleWhere((item) => item.id == indexedId);
    expect(indexed.title, 'Transcript title');
    expect(indexed.preview, 'Indexed first prompt');
    expect(indexed.updatedAt, DateTime.parse('2026-09-29T11:00:06Z'));
    expect(indexed.state, CodexConversationState.complete);
    expect(indexed.cwd, '${home.path}/work/new-project');
    expect(indexed.directoryExists, isTrue);
    final missing =
        conversations.singleWhere((item) => item.id == 'missing-directory');
    expect(missing.directoryExists, isFalse);
    final raw = conversations.singleWhere((item) => item.id == rawId);
    expect(raw.title, 'Raw log title');
    expect(raw.preview, 'How are you?');
    expect(raw.cwd, '${home.path}/work/project');
    expect(raw.state, CodexConversationState.complete);
    expect(raw.updatedAt, DateTime.parse('2026-09-29T01:00:06Z'));
  });

  test('reads text and paired tool results and rejects unsafe session ids',
      () async {
    final home = await Directory.systemTemp.createTemp('claude-read-');
    addTearDown(() async {
      ClaudeSessionService.runPythonOverride = null;
      await home.delete(recursive: true);
    });
    final project = await Directory('${home.path}/.claude/projects/project')
        .create(recursive: true);
    const id = 'readable-789';
    await File('${project.path}/$id.jsonl').writeAsString([
      jsonEncode({
        'type': 'user',
        'message': {'content': 'Question'}
      }),
      jsonEncode({
        'type': 'assistant',
        'effort': 'high',
        'message': {
          'model': 'claude-sonnet',
          'content': [
            {'type': 'text', 'text': 'Working'},
            {
              'type': 'tool_use',
              'id': 'tool-1',
              'name': 'Read',
              'input': {'file_path': '/tmp/a'}
            },
            {
              'type': 'tool_use',
              'id': 'tool-2',
              'name': 'Bash',
              'input': {'command': 'cat /tmp/a\nprintf done'},
            },
            {
              'type': 'tool_use',
              'id': 'tool-3',
              'name': 'Bash',
              'input': {'command': 'false'},
            },
          ]
        }
      }),
      jsonEncode({
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'tool-1',
              'content': 'file body'
            },
            {
              'type': 'tool_result',
              'tool_use_id': 'tool-2',
              'content': 'done',
            },
            {
              'type': 'tool_result',
              'tool_use_id': 'tool-3',
              'content': 'command failed',
              'is_error': true,
            },
          ]
        }
      }),
      jsonEncode({
        'type': 'user',
        'message': {'content': 'New turn'}
      }),
      jsonEncode({
        'type': 'assistant',
        'effort': 'low',
        'message': {
          'model': 'claude-opus',
          'content': [
            {'type': 'text', 'text': 'Again'}
          ]
        }
      }),
    ].join('\n'));
    ClaudeSessionService.runPythonOverride =
        (connectionId, script, args) async {
      expect(script, ClaudeSessionService.readScript);
      return runScript(script, home.path, args);
    };
    final records = await ClaudeSessionService.readConversation('remote-1', id);
    expect(
        records
            .where((record) => record.kind == 'user')
            .map((record) => record.text),
        contains('Question'));
    expect(
        records
            .where((record) => record.kind == 'assistant')
            .map((record) => record.text),
        contains('Working'));
    final assistant = records.singleWhere((record) => record.text == 'Working');
    expect(assistant.model, 'claude-sonnet');
    expect(assistant.reasoningEffort, 'high');
    final question = records.singleWhere((record) => record.text == 'Question');
    expect(question.reasoningEffort, isNull);
    final call = records.singleWhere((record) =>
        record.kind == 'tool_call' && record.text.contains('tool-1'));
    expect(call.text, contains('"input": {"file_path": "/tmp/a"}'));
    expect(call.terminalSummary, 'Completed Read /tmp/a');
    expect(call.terminalDetails, 'file body');
    expect(call.model, 'claude-sonnet');
    expect(call.reasoningEffort, 'high');
    final bashCall = records.singleWhere((record) =>
        record.kind == 'tool_call' && record.text.contains('tool-2'));
    expect(bashCall.terminalSummary, 'Ran cat /tmp/a …');
    expect(bashCall.terminalDetails, 'done');
    final failedCall = records.singleWhere((record) =>
        record.kind == 'tool_call' && record.text.contains('tool-3'));
    expect(failedCall.terminalSummary, 'Failed false');
    expect(failedCall.terminalDetails, 'command failed');
    final toolOutputs =
        records.where((record) => record.kind == 'tool_output').toList();
    expect(toolOutputs, hasLength(3));
    expect(
        toolOutputs.every((record) => record.model == 'claude-sonnet'), isTrue);
    expect(toolOutputs.first.text, contains('file body'));
    final nextUser = records.singleWhere((record) => record.text == 'New turn');
    expect(nextUser.reasoningEffort, isNull);
    final nextAssistant =
        records.singleWhere((record) => record.text == 'Again');
    expect(nextAssistant.model, 'claude-opus');
    expect(nextAssistant.reasoningEffort, 'low');
    await expectLater(
        ClaudeSessionService.readConversation('remote-1', '../escape'),
        throwsArgumentError);
  });
}
