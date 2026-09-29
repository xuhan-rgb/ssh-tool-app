import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers structured completed terminal items and deduplicates wrappers per turn', () async {
    final home = await Directory.systemTemp.createTemp('codex-structured-terminal-');
    addTearDown(() => home.delete(recursive: true));
    final sessions = await Directory('${home.path}/sessions').create();
    const id = 'cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd';
    final rollout = File('${sessions.path}/rollout-$id.jsonl');
    String line(String type, Map<String, Object?> payload) =>
        '${jsonEncode({'type': type, 'timestamp': '2026-09-29T00:00:00Z', 'payload': payload})}\n';
    await rollout.writeAsString([
      line('event_msg', {'type': 'task_started'}),
      line('response_item', {
        'type': 'custom_tool_call', 'call_id': 'wrapper', 'name': 'exec', 'input': 'tools.exec_command(...)',
      }),
      line('response_item', {
        'type': 'custom_tool_call_output', 'call_id': 'wrapper', 'output': [
          {'type': 'input_text', 'text': 'Script completed\nWall time: 0.1 seconds\nOutput:\n'},
          {'type': 'input_text', 'text': '{"raw":"wrapper payload"}'},
        ],
      }),
      line('event_msg', {'type': 'item_completed', 'item': {
        'type': 'CommandExecution', 'id': 'cmd-1', 'command': ['/bin/bash', '-lc', 'printf ok'],
        'status': 'completed', 'stdout': 'ok', 'stderr': '', 'aggregated_output': 'ok',
        'formatted_output': 'ok', 'exit_code': 0,
      }}),
      line('event_msg', {'type': 'item_completed', 'item': {
        'type': 'CommandExecution', 'id': 'cmd-2', 'command': ['/bin/bash', '-lc', 'false\necho hidden'],
        'status': 'completed', 'stdout': 'failed', 'stderr': 'error', 'exit_code': 9,
      }}),
      line('response_item', {
        'type': 'custom_tool_call', 'call_id': 'patch-wrapper', 'name': 'apply_patch', 'input': 'patch payload',
      }),
      line('response_item', {
        'type': 'custom_tool_call_output', 'call_id': 'patch-wrapper', 'output': 'Done!',
      }),
      line('event_msg', {'type': 'item_completed', 'item': {
        'type': 'FileChange', 'id': 'file-1', 'status': 'completed', 'stdout': '', 'stderr': '',
        'changes': {
          'lib/changed.dart': {'type': 'update', 'unified_diff': '@@ -1 +1 @@\n-old\n+new', 'move_path': null},
          'lib/new.dart': {'type': 'add', 'unified_diff': '@@ -0,0 +1 @@\n+new file'},
        },
      }}),
      line('response_item', {'type': 'reasoning', 'summary': [
        {'type': 'summary_text', 'text': '**Check output**\nprivate detail'},
      ]}),
      line('event_msg', {'type': 'item_completed', 'item': {
        'type': 'Reasoning', 'summary_text': ['**Check output**\nprivate detail'], 'raw_content': ['secret'],
      }}),
      line('event_msg', {'type': 'item_completed', 'item': {
        'type': 'SubAgentActivity', 'id': 'agent-1', 'kind': 'task', 'agent_path': 'reviewer',
      }}),
      line('event_msg', {'type': 'task_started'}),
      line('event_msg', {'type': 'item_completed', 'item': {
        'type': 'Reasoning', 'summary_text': ['**Check output**\nprivate detail'], 'raw_content': [],
      }}),
      line('response_item', {
        'type': 'custom_tool_call', 'call_id': 'turn2-wrapper', 'name': 'exec', 'input': 'other wrapper',
      }),
      line('response_item', {
        'type': 'custom_tool_call_output', 'call_id': 'turn2-wrapper', 'output': [
          {'type': 'input_text', 'text': 'Script completed\nWall time: 0.1 seconds\nOutput:\nnot structured this turn'},
        ],
      }),
    ].join());

    final source = await File('lib/services/codex_session_service.dart').readAsString();
    final script = RegExp("static const String _readScript = r'''(.*?)''';", dotAll: true)
        .firstMatch(source)!.group(1)!;
    final result = await Process.run('python3', ['-c', script, id], environment: {'CODEX_HOME': home.path});
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final rows = (result.stdout as String).trim().split('\n')
        .map((row) => jsonDecode(row) as Map<String, dynamic>).toList();
    final wrapper = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('tools.exec_command'));
    expect(wrapper['text'], contains('tools.exec_command'));
    expect(wrapper['terminalSummary'], isNull);
    expect(wrapper['terminalDetails'], isNull);
    final command = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('CommandExecution') && row['text'].toString().contains('cmd-1'));
    expect(command['terminalSummary'], 'Ran printf ok');
    expect(command['terminalDetails'], 'ok');
    final failed = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('cmd-2'));
    expect(failed['terminalSummary'], 'Failed (exit 9) false …');
    expect(failed['terminalDetails'], 'failed\nerror');
    final fileRecord = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('FileChange'));
    expect(fileRecord['terminalSummary'], 'Edited 2 files (+2 -1)');
    expect(fileRecord['terminalDetails'], contains('*** Update File: lib/changed.dart\n'));
    expect(fileRecord['terminalDetails'], contains('+new'));
    final patchWrapper = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('patch payload'));
    expect(patchWrapper['terminalSummary'], isNull);
    final reasoning = rows.where((row) => row['kind'] == 'reasoning').toList();
    expect(reasoning, hasLength(2));
    expect(reasoning.every((row) => row['terminalSummary'] == 'Check output'), isTrue);
    final agent = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('SubAgentActivity'));
    expect(agent['terminalSummary'], 'Interacted with reviewer');
    final secondTurnWrapper = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('other wrapper'));
    expect(secondTurnWrapper['terminalSummary'], isNotNull);
  });

  test('reads terminal metadata while retaining raw records', () async {
    final home = await Directory.systemTemp.createTemp('codex-terminal-');
    addTearDown(() => home.delete(recursive: true));
    final sessions = await Directory('${home.path}/sessions').create();
    const id = 'abababab-abab-abab-abab-abababababab';
    final rollout = File('${sessions.path}/rollout-$id.jsonl');
    String line(String type, Map<String, Object?> payload) =>
        '${jsonEncode({'type': type, 'timestamp': '2026-09-29T00:00:00Z', 'payload': payload})}\n';
    await rollout.writeAsString([
      line('response_item', {
        'type': 'function_call', 'call_id': 'cmd1', 'name': 'functions.exec_command',
        'arguments': '{"cmd":"echo hello"}',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'cmd1',
        'output': 'Chunk ID: chunk-1\nWall time: 0.2 seconds\nProcess exited with code 7\nFinal output:\nhello',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'running', 'name': 'functions.exec_command',
        'arguments': '{"cmd":"sleep 30"}',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'long1', 'name': 'functions.exec_command',
        'arguments': '{"cmd":"long job"}',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'long1',
        'output': '{"session_id":"sess-123","yield_time_ms":1000}',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'poll1', 'name': 'functions.write_stdin',
        'arguments': '{"session_id":"sess-123","chars":""}',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'poll1',
        'output': '{"output":"partial output","session_id":"sess-123"}',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'poll2', 'name': 'functions.write_stdin',
        'arguments': '{"session_id":"sess-123","chars":""}',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'poll2',
        'output': '{"output":"job complete","exit_code":0}',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'generic1', 'name': 'functions.lookup',
        'arguments': '{"query":"private raw argument"}',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'generic1',
        'output': 'Output: user body',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'long2', 'name': 'exec_command',
        'arguments': '{"cmd":"another job"}',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'long2',
        'output': 'Chunk ID: chunk-2\nProcess running with session ID text-123',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'poll3', 'name': 'write_stdin',
        'arguments': '{"session_id":"text-123"}',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'poll3',
        'output': 'Process exited with code 3\nFinal output:\nfailed details',
      }),
      line('response_item', {
        'type': 'custom_tool_call', 'call_id': 'patch1', 'name': 'functions.apply_patch',
        'input': '*** Begin Patch\n*** Add File: lib/a.dart\n+one\n+two\n*** Update File: lib/b.dart\n-old\n+new\n*** End Patch',
      }),
      line('response_item', {
        'type': 'custom_tool_call_output', 'call_id': 'patch1', 'output': 'Done!',
      }),
      line('response_item', {
        'type': 'function_call', 'call_id': 'patch2', 'name': 'functions.apply_patch',
        'arguments': '*** Begin Patch\n*** Update File: lib/c.dart\n-old\n+new\n*** End Patch',
      }),
      line('response_item', {
        'type': 'function_call_output', 'call_id': 'patch2', 'output': 'Patch response received',
      }),
      line('response_item', {
        'type': 'reasoning', 'summary': [
          {'type': 'summary_text', 'text': '**Inspecting files**\nFurther details'},
        ],
      }),
      line('event_msg', {'type': 'agent_reasoning', 'text': '**Inspecting files**\nFurther details'}),
      line('response_item', {
        'type': 'reasoning', 'summary': [
          {'type': 'summary_text', 'text': 'No heading here\nsecond line'},
        ],
      }),
      line('event_msg', {'type': 'agent_reasoning', 'text': 'No heading here\nsecond line'}),
      line('event_msg', {'type': 'task_started'}),
      line('event_msg', {'type': 'agent_reasoning', 'text': '**Inspecting files**\nFurther details'}),
      line('response_item', {
        'type': 'reasoning', 'summary': [
          {'type': 'summary_text', 'text': '**Inspecting files**\nFurther details'},
        ],
      }),
    ].join());

    final source = await File('lib/services/codex_session_service.dart').readAsString();
    final script = RegExp("static const String _readScript = r'''(.*?)''';", dotAll: true)
        .firstMatch(source)!.group(1)!;
    final result = await Process.run('python3', ['-c', script, id],
        environment: {'CODEX_HOME': home.path});
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect((result.stdout as String).trim(), isNotEmpty, reason: 'stderr=${result.stderr}');
    final rows = (result.stdout as String)
        .trim()
        .split('\n')
        .map((row) => jsonDecode(row) as Map<String, dynamic>)
        .toList();
    final call = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('echo hello'));
    expect(call['terminalSummary'], 'Failed (exit 7) echo hello');
    expect(call['terminalDetails'], 'hello');
    final running = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('sleep 30'));
    expect(running['terminalSummary'], 'Running sleep 30');
    final longCall = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('long job'));
    expect(longCall['terminalSummary'], 'Ran long job');
    expect(longCall['terminalDetails'], 'partial output\njob complete');
    final pollCalls = rows.where((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('write_stdin'));
    expect(pollCalls, isNotEmpty);
    expect(pollCalls.every((row) => row['terminalSummary'] == null), isTrue);
    final genericCall = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('private raw argument'));
    expect(genericCall['terminalSummary'], 'Finished lookup (status unknown)');
    expect(genericCall['terminalDetails'], 'Output: user body');
    final textSessionCall = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('another job'));
    expect(textSessionCall['terminalSummary'], 'Failed (exit 3) another job');
    expect(textSessionCall['terminalDetails'], 'failed details');
    expect(rows.where((row) => row['kind'] == 'tool_output'), hasLength(9));
    final patch = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('lib/a.dart'));
    expect(patch['terminalSummary'], 'Edited 2 files (+3 -1)');
    expect(patch['terminalDetails'], contains('+new'));
    final unknownPatch = rows.singleWhere((row) => row['kind'] == 'tool_call' && row['text'].toString().contains('lib/c.dart'));
    expect(unknownPatch['terminalSummary'], 'Apply patch status unknown');
    final reasoning = rows.where((row) => row['kind'] == 'reasoning').toList();
    expect(reasoning, hasLength(3));
    expect(reasoning.where((row) => row['terminalSummary'] == 'Inspecting files'), hasLength(2));
    expect(reasoning.where((row) => row['text'] == 'No heading here\nsecond line').single['terminalSummary'], isNull);
  });
}
