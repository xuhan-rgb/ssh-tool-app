import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only confirmed closed pending conversations can be reactivated', () {
    CodexConversation pending({bool? open, bool locked = false,
        bool directoryExists = true, bool subagent = false}) => CodexConversation(
      id: 'pending', cwd: '/project', updatedAt: null, title: 'unfinished',
      state: CodexConversationState.pending, remoteOpen: open,
      writerLocked: locked, directoryExists: directoryExists,
      isSubagent: subagent,
    );
    expect(pending(open: false).canResume, isTrue);
    expect(pending(open: true).canResume, isFalse);
    expect(pending().canResume, isFalse);
    expect(pending(open: false, locked: true).canResume, isFalse);
    expect(pending(open: false, directoryExists: false).canResume, isFalse);
    expect(pending(open: false, subagent: true).canResume, isFalse);
  });

  test('parses remote open state independently of task completion', () {
    for (final open in [true, false, null]) {
      final conversation = CodexConversationParser.parse(jsonEncode({
        'id': 'completed', 'cwd': '/project', 'state': 'complete',
        'remoteOpen': open,
      })).single;
      expect(conversation.state, CodexConversationState.complete);
      expect(conversation.remoteOpen, open);
    }
  });

  test('terminal conversation resolver is bundled with the app', () async {
    final script = await rootBundle.loadString(
      'assets/codex_terminal_session_id.py',
    );
    expect(script, contains('thread-writer-locks'));
  });

  test('parses Codex session metadata and sorts newest first', () {
    final raw = [
      jsonEncode({
        'id': 'older-session',
        'cwd': '/workspace/demo',
        'timestamp': '2026-09-20T10:00:00Z',
        'title': '旧对话',
      }),
      jsonEncode({
        'id': 'newer-session',
        'cwd': '/workspace/demo',
        'timestamp': '2026-09-21T10:00:00Z',
        'completedAt': '2026-09-21T09:59:00Z',
        'title': '新对话',
        'state': 'running',
        'writerLocked': true,
        'preview': '正在处理任务',
      }),
      'not-json',
    ].join('\n');

    final conversations = CodexConversationParser.parse(raw);

    expect(conversations, hasLength(2));
    expect(conversations.first.id, 'newer-session');
    expect(conversations.first.title, '新对话');
    expect(conversations.first.shortId, 'newer-se');
    expect(conversations.first.state, CodexConversationState.running);
    expect(conversations.first.writerLocked, isTrue);
    expect(conversations.first.preview, '正在处理任务');
    expect(conversations.first.completedAt,
        DateTime.parse('2026-09-21T09:59:00Z'));
  });

  test('list script reports the latest task completion timestamp only',
      () async {
    final codexHome =
        await Directory.systemTemp.createTemp('codex-completed-at-');
    Process? writer;
    addTearDown(() async {
      writer?.kill();
      if (writer != null) await writer!.exitCode;
      await codexHome.delete(recursive: true);
    });
    final sessions = await Directory('${codexHome.path}/sessions').create();
    final locks =
        await Directory('${codexHome.path}/thread-writer-locks').create();
    const completeId = 'aaaaaaaa-1111-1111-1111-111111111111';
    const runningId = 'bbbbbbbb-2222-2222-2222-222222222222';
    String record(String type, String timestamp, Map<String, Object> payload) =>
        '${jsonEncode({
              'type': type,
              'timestamp': timestamp,
              'payload': payload
            })}\n';
    Future<void> writeSession(String id, {required bool running}) async {
      final file = File('${sessions.path}/rollout-2026-09-24-$id.jsonl');
      await file.writeAsString(
        record('session_meta', '2026-09-24T00:00:00Z', {
              'id': id,
              'cwd': codexHome.path,
            }) +
            record('event_msg', '2026-09-24T00:10:00Z', {
              'type': 'task_complete',
            }) +
            (running
                ? record('event_msg', '2026-09-24T00:30:00Z', {
                    'type': 'task_started',
                  })
                : record('event_msg', '2026-09-24T00:20:00Z', {
                    'type': 'token_count',
                  })),
      );
    }

    await writeSession(completeId, running: false);
    await writeSession(runningId, running: true);
    writer = await Process.start('python3', [
      '-c',
      'import fcntl,sys,time; f=open(sys.argv[1],"a+"); fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); time.sleep(60)',
      '${locks.path}/$runningId.lock',
    ]);
    expect(await writer.stdout.first, isNotEmpty);

    final source =
        await File('lib/services/codex_session_service.dart').readAsString();
    final script =
        RegExp("static const String _listScript = r'''(.*?)''';", dotAll: true)
            .firstMatch(source)!
            .group(1)!;
    final result = await Process.run('python3', ['-c', script, '__all__'],
        environment: {'CODEX_HOME': codexHome.path});
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final conversations =
        CodexConversationParser.parse(result.stdout as String).asMap();
    final completed =
        conversations.values.singleWhere((item) => item.id == completeId);
    final running =
        conversations.values.singleWhere((item) => item.id == runningId);
    expect(completed.state, CodexConversationState.complete);
    expect(completed.updatedAt, DateTime.parse('2026-09-24T00:20:00Z'));
    expect(completed.completedAt, DateTime.parse('2026-09-24T00:10:00Z'));
    expect(running.state, CodexConversationState.running);
    expect(running.completedAt, isNull);
  });

  test('parses readable Codex records and builds fork command', () {
    final records = CodexConversationParser.parseRecords(
      [
        jsonEncode({
          'kind': 'user',
          'timestamp': '2026-09-23T08:00:00Z',
          'text': '查看远程任务',
        }),
        jsonEncode({
          'kind': 'assistant',
          'timestamp': '2026-09-23T08:00:02Z',
          'text': '任务已经完成',
          'tokenUsage': {
            'input_tokens': 120,
            'output_tokens': 30,
            'cached_input_tokens': 80,
          },
        }),
      ].join('\n'),
    );

    expect(records, hasLength(2));
    expect(records.first.kind, 'user');
    expect(records.last.text, '任务已经完成');
    expect(records.last.tokenUsage?.total, 150);
    expect(records.last.tokenUsage?.cachedInput, 80);
    expect(records.last.tokenUsage?.displayText,
        '输入 120 · 输出 30 · 缓存命中 80 · 命中率 66.7%');
    expect(
      CodexSessionService.forkCommand('session-123'),
      "codex --dangerously-bypass-approvals-and-sandbox -p yolo fork 'session-123'",
    );
  });

  test('token display does not divide by zero or invent missing cache data',
      () {
    expect(
        const CodexTokenUsage(input: 0, output: 2, cachedInput: 0).displayText,
        '输入 0 · 输出 2 · 缓存命中 0 · 命中率 —');
    expect(const CodexTokenUsage(input: 10, output: 2).displayText,
        '输入 10 · 输出 2 · 缓存命中 — · 命中率 —');
  });

  test('attributes completed turn token usage to its final assistant reply',
      () async {
    final home = await Directory.systemTemp.createTemp('codex-records-');
    addTearDown(() => home.delete(recursive: true));
    final sessions = await Directory('${home.path}/sessions').create();
    const id = '11111111-1111-1111-1111-111111111111';
    final rollout =
        File('${sessions.path}/rollout-2026-09-24T00-00-00-$id.jsonl');
    String line(String type, Map<String, Object> payload) => '${jsonEncode({
              'type': type,
              'timestamp': '2026-09-24T00:00:00Z',
              'payload': payload
            })}\n';
    await rollout.writeAsString(
      line('event_msg', {'type': 'task_started'}) +
          line('response_item', {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': '答复'}
            ],
          }) +
          line('event_msg', {
            'type': 'token_count',
            'info': {
              'last_token_usage': {
                'input_tokens': 120,
                'output_tokens': 30,
                'cached_input_tokens': 80,
              }
            },
          }) +
          line('event_msg', {'type': 'task_complete'}),
    );
    final source =
        await File('lib/services/codex_session_service.dart').readAsString();
    final script =
        RegExp("static const String _readScript = r'''(.*?)''';", dotAll: true)
            .firstMatch(source)!
            .group(1)!;
    final result = await Process.run('python3', ['-c', script, id],
        environment: {'CODEX_HOME': home.path});
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final records =
        CodexConversationParser.parseRecords(result.stdout as String);
    expect(
        records
            .singleWhere((record) => record.kind == 'assistant')
            .tokenUsage
            ?.total,
        150);
    expect(
        records
            .singleWhere((record) => record.kind == 'assistant')
            .tokenUsage
            ?.cachedInput,
        80);
  });

  test('builds a shell-safe Codex resume command', () {
    expect(
      CodexSessionService.resumeCommand("session'with-quote"),
      "codex --dangerously-bypass-approvals-and-sandbox -p yolo resume 'session'\"'\"'with-quote'",
    );
  });

  test('session preview ignores internal heartbeat messages', () async {
    final home = await Directory.systemTemp.createTemp('codex-heartbeat-');
    addTearDown(() => home.delete(recursive: true));
    final sessions = await Directory('${home.path}/sessions').create();
    const id = '77777777-7777-7777-7777-777777777777';
    String line(String type, Map<String, Object> payload) =>
        '${jsonEncode({'type': type, 'payload': payload})}\n';
    await File('${sessions.path}/rollout-2026-09-24-$id.jsonl').writeAsString(
      line('session_meta', {'id': id, 'cwd': home.path}) +
          line('response_item', {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': '检查激光检测'}
            ],
          }) +
          line('response_item', {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': '检查完成'}
            ],
          }) +
          line('response_item', {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': '<heartbeat>internal</heartbeat>'}
            ],
          }) +
          line('event_msg', {'type': 'task_complete'}),
    );
    final source =
        await File('lib/services/codex_session_service.dart').readAsString();
    final script =
        RegExp("static const String _listScript = r'''(.*?)''';", dotAll: true)
            .firstMatch(source)!
            .group(1)!;
    final result = await Process.run('python3', ['-c', script, '__all__'],
        environment: {'CODEX_HOME': home.path});
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(
        CodexConversationParser.parse(result.stdout as String).single.preview,
        '检查完成');
  });

  test('remote session listing can read an older page', () async {
    final home = await Directory.systemTemp.createTemp('codex-history-');
    addTearDown(() => home.delete(recursive: true));
    final sessions = await Directory('${home.path}/sessions').create();
    final ids = [
      '11111111-1111-1111-1111-111111111111',
      '22222222-2222-2222-2222-222222222222',
    ];
    for (var index = 0; index < ids.length; index++) {
      final file =
          File('${sessions.path}/rollout-2026-09-24-${ids[index]}.jsonl');
      await file.writeAsString(
        '${jsonEncode({
              'type': 'session_meta',
              'payload': {'id': ids[index], 'cwd': home.path}
            })}\n'
        '${jsonEncode({
              'type': 'response_item',
              'payload': {
                'type': 'message',
                'role': 'user',
                'content': [
                  {'type': 'input_text', 'text': '问题 $index'}
                ]
              }
            })}\n'
        '${jsonEncode({
              'type': 'event_msg',
              'payload': {'type': 'task_complete'}
            })}\n',
      );
      await file.setLastModified(DateTime(2026, 9, 24, 10, index));
    }
    final source =
        await File('lib/services/codex_session_service.dart').readAsString();
    final script =
        RegExp("static const String _listScript = r'''(.*?)''';", dotAll: true)
            .firstMatch(source)!
            .group(1)!;
    final result = await Process.run('python3', ['-c', script, '__all__', '1'],
        environment: {'CODEX_HOME': home.path});
    expect(result.exitCode, 0, reason: result.stderr.toString());
    expect(CodexConversationParser.parse(result.stdout as String).single.id,
        ids.first);
  });

  test('running listing finds locked sessions outside recent history',
      () async {
    final home = await Directory.systemTemp.createTemp('codex-running-');
    addTearDown(() => home.delete(recursive: true));
    final sessions = await Directory('${home.path}/sessions').create();
    final locks = await Directory('${home.path}/thread-writer-locks').create();
    String uuid(int value) =>
        '${value.toRadixString(16).padLeft(8, '0')}-1111-1111-1111-111111111111';
    Future<void> writeSession(String id, String event) async {
      await File('${sessions.path}/rollout-2026-09-24-$id.jsonl').writeAsString(
        '${jsonEncode({
              'type': 'session_meta',
              'payload': {'id': id, 'cwd': home.path}
            })}\n'
        '${jsonEncode({
              'type': 'response_item',
              'payload': {
                'type': 'message',
                'role': 'user',
                'content': [
                  {'type': 'input_text', 'text': '任务'}
                ]
              }
            })}\n'
        '${jsonEncode({
              'type': 'event_msg',
              'payload': {'type': event}
            })}\n',
      );
    }

    // More than 200 newer completed sessions must not hide an older running one.
    for (var index = 0; index < 205; index++) {
      await writeSession(uuid(index + 10), 'task_complete');
      await File(
              '${sessions.path}/rollout-2026-09-24-${uuid(index + 10)}.jsonl')
          .setLastModified(DateTime(2026, 9, 25, 0, index));
    }
    final runningId = uuid(1);
    final completedId = uuid(2);
    await writeSession(runningId, 'task_started');
    await writeSession(completedId, 'task_complete');
    final lockProcesses = <Process>[];
    for (final id in [runningId, completedId]) {
      final process = await Process.start('python3', [
        '-c',
        'import fcntl,sys,time; f=open(sys.argv[1],"a+"); fcntl.flock(f,fcntl.LOCK_EX); print("locked",flush=True); time.sleep(60)',
        '${locks.path}/$id.lock',
      ]);
      lockProcesses.add(process);
      expect(await process.stdout.first, isNotEmpty);
    }
    addTearDown(() async {
      for (final process in lockProcesses) {
        process.kill();
        await process.exitCode;
      }
    });

    final previousOverride = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (connectionId, script, args) async {
      final result = await Process.run('python3', ['-c', script, ...args],
          environment: {'CODEX_HOME': home.path});
      expect(result.exitCode, 0, reason: result.stderr.toString());
      return result.stdout as String;
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previousOverride);
    final conversations = await CodexSessionService.listRunning('fixture');
    expect(conversations.map((conversation) => conversation.id), [runningId]);
    expect(conversations.single.state, CodexConversationState.running);
  });

  test('running listing coalesces loads and clear blocks stale cache writes',
      () async {
    CodexSessionService.clearCache();
    final responses = <Completer<String>>[];
    final started = [Completer<void>(), Completer<void>()];
    var calls = 0;
    CodexSessionService.runPythonOverride = (connectionId, script, args) {
      calls++;
      final response = Completer<String>();
      responses.add(response);
      started[calls - 1].complete();
      return response.future;
    };
    addTearDown(() {
      CodexSessionService.runPythonOverride = null;
      CodexSessionService.clearCache();
    });
    String result(String id) => jsonEncode({
          'id': id,
          'cwd': '/workspace/demo',
          'state': 'running',
        });

    final first = CodexSessionService.listRunning('connection');
    final joined = CodexSessionService.listRunning('connection');
    await started[0].future;
    expect(calls, 1);
    expect(
        CodexSessionService.cachedRunningConversations('connection'), isNull);

    CodexSessionService.clearCache('connection');
    final replacement = CodexSessionService.listRunning('connection');
    await started[1].future;
    expect(calls, 2);
    responses[0].complete(result('stale'));
    expect((await first).single.id, 'stale');
    expect((await joined).single.id, 'stale');
    expect(
        CodexSessionService.cachedRunningConversations('connection'), isNull);

    responses[1].complete('');
    expect(await replacement, isEmpty);
    expect(
        CodexSessionService.cachedRunningConversations('connection'), isEmpty);
  });

  test('failed running refresh keeps the last successful snapshot', () async {
    CodexSessionService.clearCache();
    addTearDown(() {
      CodexSessionService.runPythonOverride = null;
      CodexSessionService.clearCache();
    });
    CodexSessionService.runPythonOverride =
        (connectionId, script, args) async => jsonEncode({
              'id': 'cached',
              'cwd': '/workspace/demo',
              'state': 'running',
            });
    await CodexSessionService.listRunning('connection');
    final snapshot =
        CodexSessionService.cachedRunningConversations('connection');
    expect(snapshot?.single.id, 'cached');

    CodexSessionService.runPythonOverride = (connectionId, script, args) async {
      throw StateError('offline');
    };
    await expectLater(CodexSessionService.listRunning('connection'),
        throwsA(isA<StateError>()));
    expect(CodexSessionService.cachedRunningConversations('connection'),
        same(snapshot));
  });

  test('an aborted conversation can resume or be taken over', () {
    final aborted = CodexConversation(
      id: 'aborted',
      cwd: '/workspace/project',
      updatedAt: null,
      title: '已中止的对话',
      state: CodexConversationState.aborted,
    );
    expect(aborted.canResume, isTrue);
    expect(aborted.canTakeover, isTrue);
    expect(aborted.recoveryReason, '最后一轮已中止');

    final occupied = CodexConversation(
      id: 'aborted-occupied',
      cwd: '/workspace/project',
      updatedAt: null,
      title: '仍被占用的对话',
      state: CodexConversationState.aborted,
      writerLocked: true,
    );
    expect(occupied.canResume, isFalse);
    expect(occupied.canTakeover, isTrue);
  });

  test(
      'marks only completed conversations with an existing directory as recoverable',
      () {
    final conversations = CodexConversationParser.parse([
      jsonEncode({
        'id': 'complete',
        'cwd': '/workspace/one',
        'state': 'complete',
        'directoryExists': true,
      }),
      jsonEncode({
        'id': 'missing-directory',
        'cwd': '/workspace/deleted',
        'state': 'complete',
        'directoryExists': false,
      }),
      jsonEncode({
        'id': 'running',
        'cwd': '/workspace/two',
        'state': 'running',
        'directoryExists': true,
      }),
      jsonEncode({
        'id': 'occupied',
        'cwd': '/workspace/three',
        'state': 'complete',
        'writerLocked': true,
        'directoryExists': true,
      }),
    ].join('\n'));

    expect(conversations[0].canResume, isTrue);
    expect(conversations[1].canResume, isFalse);
    expect(conversations[1].recoveryReason, '对话所在目录不存在');
    expect(conversations[2].canResume, isFalse);
    expect(conversations[2].recoveryReason, '最后一轮正在执行');
    expect(conversations[0].displayTitle, '对话 complete');
    final occupied = conversations.singleWhere((item) => item.id == 'occupied');
    expect(occupied.canResume, isFalse);
    expect(occupied.canTakeover, isTrue);
  });

  test('does not reuse an old completed turn after large rollout records',
      () async {
    final codexHome = await Directory.systemTemp.createTemp('codex-state-');
    try {
      final sessions = await Directory('${codexHome.path}/sessions').create();
      final rollout = File('${sessions.path}/rollout-2026-09-23T00-00-00-'
          '11111111-1111-1111-1111-111111111111.jsonl');
      String record(String type, Map<String, Object> payload) =>
          '${jsonEncode({'type': type, 'payload': payload})}\n';
      await rollout.writeAsString(
        record('session_meta', {
              'id': '11111111-1111-1111-1111-111111111111',
              'cwd': codexHome.path,
            }) +
            record('event_msg', {'type': 'task_complete'}) +
            record('response_item', {'output': 'x' * (5 * 1024 * 1024)}) +
            record('event_msg', {'type': 'task_started'}) +
            record('response_item', {'output': 'x' * (5 * 1024 * 1024)}),
      );

      final source =
          await File('lib/services/codex_session_service.dart').readAsString();
      final script = RegExp("static const String _listScript = r'''(.*?)''';",
              dotAll: true)
          .firstMatch(source)!
          .group(1)!;
      final result = await Process.run('python3', ['-c', script, '__all__'],
          environment: {'CODEX_HOME': codexHome.path});
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final conversations =
          CodexConversationParser.parse(result.stdout as String);
      expect(conversations, hasLength(1));
      expect(conversations.single.state, CodexConversationState.pending);
      expect(conversations.single.remoteOpen, isFalse);
      expect(conversations.single.canResume, isTrue);
    } finally {
      await codexHome.delete(recursive: true);
    }
  });

  test('task start followed by user message is running only with a live writer',
      () async {
    final codexHome = await Directory.systemTemp.createTemp('codex-state-');
    Process? writer;
    try {
      final sessions = await Directory('${codexHome.path}/sessions').create();
      const id = '55555555-5555-5555-5555-555555555555';
      final rollout = File('${sessions.path}/rollout-2026-09-23-$id.jsonl');
      String record(String type, Map<String, Object> payload) =>
          '${jsonEncode({'type': type, 'payload': payload})}\n';
      await rollout.writeAsString(record('session_meta', {
            'id': id,
            'cwd': codexHome.path,
          }) +
          record('event_msg', {'type': 'task_started'}) +
          record('event_msg', {'type': 'user_message'}) +
          record('response_item', {'type': 'message', 'role': 'assistant'}));
      final lockDir =
          await Directory('${codexHome.path}/thread-writer-locks').create();
      final lockPath = '${lockDir.path}/$id.lock';
      writer = await Process.start('python3', [
        '-c',
        'import fcntl,sys; f=open(sys.argv[1],"a+"); '
            'fcntl.flock(f,fcntl.LOCK_EX); print("ready",flush=True); input()',
        lockPath,
      ]);
      await writer.stdout.first;

      final source =
          await File('lib/services/codex_session_service.dart').readAsString();
      final script = RegExp("static const String _listScript = r'''(.*?)''';",
              dotAll: true)
          .firstMatch(source)!
          .group(1)!;
      Future<CodexConversation> classify() async {
        final result = await Process.run('python3', ['-c', script, '__all__'],
            environment: {'CODEX_HOME': codexHome.path});
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return CodexConversationParser.parse(result.stdout as String).single;
      }

      expect((await classify()).state, CodexConversationState.running);
      writer.kill();
      await writer.exitCode;
      writer = null;
      expect((await classify()).state, CodexConversationState.pending);
    } finally {
      writer?.kill();
      await codexHome.delete(recursive: true);
    }
  });

  test('omits named sessions that have no conversation turns', () async {
    final codexHome = await Directory.systemTemp.createTemp('codex-empty-');
    try {
      final sessions = await Directory('${codexHome.path}/sessions').create();
      const id = '66666666-6666-6666-6666-666666666666';
      final rollout = File('${sessions.path}/rollout-2026-09-23-$id.jsonl');
      String record(String type, Map<String, Object> payload) =>
          '${jsonEncode({'type': type, 'payload': payload})}\n';
      await rollout.writeAsString(record('session_meta', {
            'id': id,
            'cwd': codexHome.path,
          }) +
          record('event_msg', {'type': 'thread_settings_applied'}));
      await File('${codexHome.path}/session_index.jsonl').writeAsString(
          '${jsonEncode({'id': id, 'thread_name': '命名但未开始的会话'})}\n');

      final source =
          await File('lib/services/codex_session_service.dart').readAsString();
      final script = RegExp("static const String _listScript = r'''(.*?)''';",
              dotAll: true)
          .firstMatch(source)!
          .group(1)!;
      final result = await Process.run('python3', ['-c', script, '__all__'],
          environment: {'CODEX_HOME': codexHome.path});
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(CodexConversationParser.parse(result.stdout as String), isEmpty);
    } finally {
      await codexHome.delete(recursive: true);
    }
  });

  test('skips injected plugin context when choosing a conversation title',
      () async {
    final codexHome = await Directory.systemTemp.createTemp('codex-title-');
    try {
      final sessions = await Directory('${codexHome.path}/sessions').create();
      const id = '22222222-2222-2222-2222-222222222222';
      final rollout =
          File('${sessions.path}/rollout-2026-09-23T00-00-00-$id.jsonl');
      String record(String type, Map<String, Object> payload) =>
          '${jsonEncode({'type': type, 'payload': payload})}\n';
      await rollout.writeAsString(
        record('session_meta', {'id': id, 'cwd': codexHome.path}) +
            record('response_item', {
              'type': 'message',
              'role': 'user',
              'content': [
                {
                  'type': 'input_text',
                  'text': '<recommended_plugins>helper</recommended_plugins>'
                }
              ],
            }) +
            record('response_item', {
              'type': 'message',
              'role': 'user',
              'content': [
                {'type': 'input_text', 'text': '修复远端连接问题'}
              ],
            }),
      );
      await File('${codexHome.path}/session_index.jsonl').writeAsString(
        '${jsonEncode({
              'id': id,
              'thread_name': '<recommended_plugins>helper'
            })}\n',
      );

      final source =
          await File('lib/services/codex_session_service.dart').readAsString();
      final script = RegExp("static const String _listScript = r'''(.*?)''';",
              dotAll: true)
          .firstMatch(source)!
          .group(1)!;
      final result = await Process.run('python3', ['-c', script, '__all__'],
          environment: {'CODEX_HOME': codexHome.path});
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final conversations =
          CodexConversationParser.parse(result.stdout as String);
      expect(conversations.single.title, '修复远端连接问题');
    } finally {
      await codexHome.delete(recursive: true);
    }
  });

  test('recognizes subagents and omits empty threads from rollout metadata',
      () async {
    final codexHome = await Directory.systemTemp.createTemp('codex-subagent-');
    try {
      final sessions = await Directory('${codexHome.path}/sessions').create();
      const childId = '33333333-3333-3333-3333-333333333333';
      const emptyId = '44444444-4444-4444-4444-444444444444';
      String record(String type, Map<String, Object> payload) =>
          '${jsonEncode({'type': type, 'payload': payload})}\n';
      await File('${sessions.path}/rollout-2026-09-23T01-00-00-$childId.jsonl')
          .writeAsString(
        record('session_meta', {
              'id': childId,
              'cwd': codexHome.path,
              'thread_source': 'subagent',
              'parent_thread_id': 'parent-thread-id',
              'source': {
                'subagent': {
                  'thread_spawn': {'parent_thread_id': 'parent-thread-id'}
                }
              },
            }) +
            record('event_msg', {'type': 'task_complete'}),
      );
      await File('${sessions.path}/rollout-2026-09-23T01-01-00-$emptyId.jsonl')
          .writeAsString(record('session_meta', {
        'id': emptyId,
        'cwd': codexHome.path,
      }));
      final source =
          await File('lib/services/codex_session_service.dart').readAsString();
      final script = RegExp("static const String _listScript = r'''(.*?)''';",
              dotAll: true)
          .firstMatch(source)!
          .group(1)!;
      final result = await Process.run('python3', ['-c', script, '__all__'],
          environment: {'CODEX_HOME': codexHome.path});
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final conversations =
          CodexConversationParser.parse(result.stdout as String);
      final child = conversations.singleWhere((item) => item.id == childId);
      expect(child.isSubagent, isTrue);
      expect(child.parentConversationId, 'parent-thread-id');
      expect(child.canResume, isFalse);
      expect(child.canTakeover, isFalse);
      expect(child.recoveryReason, contains('子代理'));
      expect(conversations.any((item) => item.id == emptyId), isFalse);
    } finally {
      await codexHome.delete(recursive: true);
    }
  });

  test('lists live tmux sessions even without a saved state record', () {
    final sessions = CodexSessionService.openedFromRemote(
      const {
        'codex-live': {
          'workDir': '/workspace/project',
          'conversationId': 'thread-123',
        },
        'stale': {'workDir': '/workspace/old'},
      },
      {'codex-legacy', 'codex-live'},
    );
    expect(sessions, hasLength(2));
    expect(sessions.first.name, 'codex-legacy');
    expect(sessions.first.workDir, '~');
    expect(sessions.last.conversationId, 'thread-123');
    expect(sessions.any((session) => session.name == 'stale'), isFalse);
  });

  test('does not guess a conversation when a tmux name prefix is ambiguous',
      () {
    final conversations = [
      CodexConversation(
        id: '01a0caa9-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
        cwd: '/project/one',
        updatedAt: null,
        title: '第一个子代理',
      ),
      CodexConversation(
        id: '01a0caa9-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
        cwd: '/project/two',
        updatedAt: null,
        title: '第二个子代理',
      ),
    ];
    const ambiguous = OpenedCodexSession(
      name: 'codex-01a0caa9',
      workDir: '/project/index.html',
    );
    expect(
      CodexSessionService.matchOpenedConversation(ambiguous, conversations),
      isNull,
    );
    const exact = OpenedCodexSession(
      name: 'codex-01a0caa9',
      workDir: '/project/index.html',
      conversationId: '01a0caa9-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
    );
    expect(
      CodexSessionService.matchOpenedConversation(exact, conversations)?.title,
      '第二个子代理',
    );
    expect(
      CodexSessionService.matchOpenedConversation(
        ambiguous,
        [conversations.first],
      )?.title,
      '第一个子代理',
    );
  });
}
