import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/models/codex_goal.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

Future<ProcessResult> _runPython(
  String script,
  List<String> args,
  Map<String, String> environment,
) async {
  final process = await Process.start(
    '/usr/bin/python3',
    ['-', ...args],
    runInShell: false,
    environment: environment,
    includeParentEnvironment: false,
  );
  process.stdin.write(script);
  await process.stdin.close();
  final stdout = await process.stdout.transform(utf8.decoder).join();
  final stderr = await process.stderr.transform(utf8.decoder).join();
  return ProcessResult(process.pid, await process.exitCode, stdout, stderr);
}

const _fakeCodex = '''#!/usr/bin/python3
import json
import os
import sys

with open(os.environ['RPC_LOG'], 'a') as log:
    for line in sys.stdin:
        request = json.loads(line)
        log.write(json.dumps({'request': request, 'path': os.environ['PATH']}) + '\\n')
        log.flush()
        if request.get('id') == 1:
            response = {'id': 1, 'result': {}}
        elif request.get('method') == 'thread/goal/get':
            if os.environ.get('GOAL_ERROR') and '/.local/bin/' in sys.argv[0]:
                response = {'id': 2, 'error': {'code': -32601, 'message': 'Method not found'}}
            else:
                response = {'id': 2, 'result': {'goal': json.loads(os.environ['GOAL_JSON'])}}
        else:
            continue
        print(json.dumps(response), flush=True)
''';

Future<File> _installCodex(Directory directory) async {
  await directory.create(recursive: true);
  final file = File('${directory.path}/codex');
  await file.writeAsString(_fakeCodex);
  await Process.run('chmod', ['+x', file.path]);
  return file;
}

Future<ProcessResult> _runCapturedScript({
  required String script,
  required List<String> args,
  required Directory home,
  required Directory path,
  required String logPath,
  String goalJson = 'null',
  bool methodMissing = false,
}) =>
    _runPython(script, args, {
      'HOME': home.path,
      'PATH': path.path,
      'RPC_LOG': logPath,
      'GOAL_JSON': goalJson,
      if (methodMissing) 'GOAL_ERROR': '1',
    });

void main() {
  test('decodes goal fields with null or populated token budget', () async {
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, __, ___) async =>
        '{"objective":"ship feature","status":"active","tokenBudget":null,"tokensUsed":12,"timeUsedSeconds":34}';
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    final withoutBudget = await CodexSessionService.readGoal('connection', 'thread');
    expect(withoutBudget, isA<CodexGoal>());
    expect(withoutBudget!.objective, 'ship feature');
    expect(withoutBudget.status, 'active');
    expect(withoutBudget.tokenBudget, isNull);
    expect(withoutBudget.tokensUsed, 12);
    expect(withoutBudget.timeUsedSeconds, 34);

    CodexSessionService.runPythonOverride = (_, __, ___) async =>
        '{"objective":"ship feature","status":"active","tokenBudget":500,"tokensUsed":12,"timeUsedSeconds":34}';
    final withBudget = await CodexSessionService.readGoal('connection', 'thread');
    expect(withBudget!.tokenBudget, 500);
  });

  test('returns null when the thread has no goal', () async {
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, __, ___) async => 'null';
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    expect(await CodexSessionService.readGoal('connection', 'thread'), isNull);
  });

  test('uses only read-only RPC methods for the exact thread id', () async {
    final temp = await Directory.systemTemp.createTemp('codex-goal-rpc-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    final localBin = Directory('${home.path}/.local/bin');
    await _installCodex(localBin);
    final logPath = '${temp.path}/rpc.jsonl';
    String? script;
    List<String>? args;
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, capturedScript, capturedArgs) async {
      script = capturedScript;
      args = capturedArgs;
      final result = await _runCapturedScript(
        script: capturedScript,
        args: capturedArgs,
        home: home,
        path: Directory('/usr/bin'),
        logPath: logPath,
        goalJson: '{"objective":"goal","status":"active"}',
      );
      if (result.exitCode != 0) throw StateError(result.stderr.trim());
      return result.stdout;
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    final goal = await CodexSessionService.readGoal('connection', 'thread-exact');
    expect(goal!.objective, 'goal');
    expect(args, ['thread-exact']);
    expect(script, contains("'thread/goal/get'"));
    final entries = File(logPath)
        .readAsLinesSync()
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    final requests = entries.map((entry) => entry['request'] as Map).toList();
    expect(requests.map((request) => request['method']),
        ['initialize', 'initialized', 'thread/goal/get']);
    expect(requests.last['params'], {'threadId': 'thread-exact'});
    expect(requests.map((request) => request['method']),
        isNot(contains(anyOf('thread/resume', 'turn/start', 'thread/goal/set'))));
  });

  test('falls back from old CLI with missing method to nvm CLI and prefixes PATH', () async {
    final temp = await Directory.systemTemp.createTemp('codex-goal-fallback-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    final localBin = Directory('${home.path}/.local/bin');
    final nvmBin = Directory('${home.path}/.nvm/versions/node/v99/bin');
    await _installCodex(localBin);
    await _installCodex(nvmBin);
    final logPath = '${temp.path}/rpc.jsonl';
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      final result = await _runCapturedScript(
        script: script,
        args: args,
        home: home,
        path: Directory('/usr/bin'),
        logPath: logPath,
        goalJson: '{"objective":"nvm goal","status":"active"}',
        methodMissing: true,
      );
      if (result.exitCode != 0) throw StateError(result.stderr.trim());
      return result.stdout;
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    // The local CLI reports method-missing; switch behavior when the nvm
    // executable is selected by having the fixture distinguish its own path.
    // (The environment flag is passed to both, so override the fake below.)
    final goal = await CodexSessionService.readGoal('connection', 'thread');
    expect(goal!.objective, 'nvm goal');
    final entries = File(logPath)
        .readAsLinesSync()
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
    expect(entries, hasLength(6));
    expect(entries.last['path'], startsWith('${nvmBin.path}:'));
    final methods = entries
        .map((entry) => (entry['request'] as Map)['method'])
        .toList();
    expect(methods, [
      'initialize',
      'initialized',
      'thread/goal/get',
      'initialize',
      'initialized',
      'thread/goal/get',
    ]);
  });

  test('does not treat unsupported goal RPC as a missing goal', () async {
    final temp = await Directory.systemTemp.createTemp('codex-goal-unsupported-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    await _installCodex(Directory('${home.path}/.local/bin'));
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      final result = await _runCapturedScript(
        script: script,
        args: args,
        home: home,
        path: Directory('/usr/bin'),
        logPath: '${temp.path}/rpc.jsonl',
        methodMissing: true,
      );
      if (result.exitCode != 0) throw StateError(result.stderr.trim());
      return result.stdout;
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    await expectLater(
      CodexSessionService.readGoal('connection', 'thread'),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('Method not found'),
      )),
    );
  });
}
