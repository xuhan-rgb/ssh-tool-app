import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_chat_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('parses the remote Codex model picker response', () {
    final models = CodexChatService.parseModels('''
[{"id":"gpt-6-sol","name":"GPT-6-Sol","isDefault":false,
  "defaultEffort":"medium","efforts":[{"id":"low","description":"Fast"},
                                  {"id":"medium","description":"Balanced"}]},
 {"id":"future-model","name":"Future Model","isDefault":true,
  "defaultEffort":"high","efforts":[{"id":"high","description":"Deep"}]}]
''');
    expect(models.map((model) => model.id), ['gpt-6-sol', 'future-model']);
    expect(models.last.isDefault, isTrue);
    expect(models.first.efforts.map((effort) => effort.id), ['low', 'medium']);
    expect(models.last.defaultEffort, 'high');
  });

  test('parses owned session status and session-list CLI responses', () {
    final status =
        CodexChatService.parseRemoteSessionStatus({'open': true, 'busy': true});
    expect(status.open, isTrue);
    expect(status.busy, isTrue);
    expect(
      CodexChatService.parseRemoteSessionStatus({'open': false, 'busy': false})
          .open,
      isFalse,
    );
    expect(
      CodexChatService.parseOpenSessions({
        'threadIds': ['first', 'second', 3, null]
      }),
      {'first', 'second'},
    );
    expect(CodexChatService.parseOpenSessions({}), isEmpty);
  });

  test('owned session worker CLI lists, closes idle, and rejects busy sessions',
      () async {
    final home = await Directory.systemTemp.createTemp('ssh-chat-sessions-');
    try {
      final sessions =
          await Directory('${home.path}/.ssh_tool/chat_jobs/sessions')
              .create(recursive: true);
      final bin = await Directory('${home.path}/bin').create();
      final tmux = File('${bin.path}/tmux');
      const threadId = 'owned-thread';
      final encoded =
          base64Url.encode(utf8.encode(threadId)).replaceAll('=', '');
      final metadata = File('${sessions.path}/$encoded.json');
      await tmux.writeAsString(
          '#!/bin/sh\ngrep -q closeRequested ${metadata.path} && exit 1\nexit 0\n');
      await Process.run('chmod', ['+x', tmux.path]);
      Future<void> writeSession({required bool busy}) =>
          metadata.writeAsString(jsonEncode({
            'threadId': threadId,
            'ownerJobId': 'a' * 32,
            'queueId': 'queue',
            'tmuxName': 'ssh-chat-owned',
            'busy': busy,
          }));
      await writeSession(busy: false);
      final worker = File('assets/codex_chat_worker.py').absolute.path;
      Future<ProcessResult> invoke(String command) => Process.run(
            'python3',
            [worker, command, if (command != 'sessions') threadId],
            environment: {
              'HOME': home.path,
              'PATH': '${bin.path}:/usr/bin:/bin',
            },
          );

      final status = await invoke('session');
      expect(status.exitCode, 0, reason: status.stderr.toString());
      expect(
          jsonDecode(status.stdout as String), {'open': true, 'busy': false});
      final listed = await invoke('sessions');
      expect(listed.exitCode, 0, reason: listed.stderr.toString());
      expect(jsonDecode(listed.stdout as String), {
        'threadIds': [threadId]
      });
      final closed = await invoke('close');
      expect(closed.exitCode, 0, reason: closed.stderr.toString());
      expect(
          jsonDecode(closed.stdout as String), {'closed': true, 'open': false});
      expect(
          jsonDecode(await metadata.readAsString())['closeRequested'], isTrue);

      await writeSession(busy: true);
      final rejected = await invoke('close');
      expect(rejected.exitCode, 1);
      expect(
          jsonDecode(rejected.stdout as String)['error'], contains('仍有任务运行'));
    } finally {
      await home.delete(recursive: true);
    }
  });

  test('background job reports partial text and a completed same-id answer',
      () {
    final updates = <String>[];
    final progress = CodexJobProgress(onUpdate: updates.add);
    expect(
        progress.read({
          'offset': 80,
          'events': [
            {'type': 'started', 'threadId': 'thread-123'},
            {'type': 'partial', 'text': '你'},
            {'type': 'partial', 'text': '你好'},
          ],
          'state': {
            'status': 'running',
            'threadId': 'thread-123',
            'title': '修复工作台环境安装提示',
          },
        }),
        isNull);
    expect(progress.offset, 80);
    expect(progress.title, '修复工作台环境安装提示');
    expect(updates, ['你', '你好']);
    final result = progress.read({
      'offset': 120,
      'events': [
        {'type': 'completed', 'answer': '你好！'},
      ],
      'state': {
        'status': 'completed',
        'threadId': 'thread-123',
        'answer': '你好！',
      },
    });
    expect(result?.threadId, 'thread-123');
    expect(result?.answer, '你好！');
  });

  test('background job exposes a remote failure', () {
    final progress = CodexJobProgress();
    expect(
      () => progress.read({
        'offset': 0,
        'events': [],
        'state': {'status': 'failed', 'error': '远端 tmux 任务已结束'},
      }),
      throwsA(isA<StateError>()
          .having((error) => error.message, 'message', '远端 tmux 任务已结束')),
    );
  });

  test('streamed deltas rebuild the answer across reconnects', () {
    final updates = <String>[];
    final progress = CodexJobProgress(onUpdate: updates.add);
    progress.read({
      'offset': 40,
      'events': [
        {'type': 'partial', 'delta': '你', 'reset': true},
      ],
      'state': {'status': 'running'},
    });
    progress.read({
      'offset': 70,
      'events': [
        {'type': 'partial', 'delta': '好', 'reset': false},
      ],
      'state': {'status': 'running'},
    });
    expect(updates, ['你', '你好']);
    expect(progress.offset, 70);
  });

  test('background job forwards activity, reasoning summary and elapsed time',
      () {
    final activities = <String>[];
    final progress = CodexJobProgress(onActivity: activities.add);
    progress.read({
      'offset': 90,
      'events': [
        {'type': 'activity', 'itemId': 'command', 'text': 'rg -n widget lib'},
        {'type': 'activityDelta', 'itemId': 'reason', 'delta': '检查相关代码'},
      ],
      'state': {'status': 'running', 'startedAt': 1750000000000},
    });
    expect(activities, [
      'rg -n widget lib',
      'rg -n widget lib\n检查相关代码',
    ]);
    expect(
        progress.startedAt, DateTime.fromMillisecondsSinceEpoch(1750000000000));
    final result = progress.read({
      'offset': 120,
      'events': [],
      'state': {
        'status': 'completed',
        'threadId': 'thread-123',
        'answer': '好了',
        'durationSeconds': 73,
      },
    });
    expect(result?.durationSeconds, 73);
  });

  test('progress keeps different Codex items separate', () {
    final activities = <String>[];
    final progress = CodexJobProgress(onActivity: activities.add);
    progress.read({
      'offset': 120,
      'events': [
        {'type': 'activityDelta', 'itemId': 'reason', 'delta': '检查文件'},
        {'type': 'activity', 'itemId': 'command', 'text': 'rg -n foo lib'},
        {
          'type': 'activityDelta',
          'itemId': 'command',
          'delta': '\nlib/a.dart:2'
        },
        {'type': 'activityDelta', 'itemId': 'reason-2', 'delta': '继续分析'},
      ],
      'state': {'status': 'running'},
    });
    expect(activities.last, '检查文件\nrg -n foo lib\nlib/a.dart:2\n继续分析');
  });

  test('tmux worker is bundled for deployment to the remote host', () async {
    final worker = await rootBundle.loadString('assets/codex_chat_worker.py');
    expect(worker, contains('tmux'));
    expect(worker, contains('app-server'));
  });

  test('active chat jobs require a live app-owned tmux session', () async {
    final home = await Directory.systemTemp.createTemp('ssh-chat-jobs-');
    try {
      final jobs = await Directory('${home.path}/.ssh_tool/chat_jobs')
          .create(recursive: true);
      Future<void> addJob(String name, String thread, String status) async {
        final path = await Directory('${jobs.path}/$name').create();
        await File('${path.path}/state.json').writeAsString(jsonEncode({
          'jobId': name,
          'threadId': thread,
          'tmuxName': 'ssh-chat-$name',
          'status': status,
        }));
      }

      await addJob('live', 'app-thread', 'running');
      await addJob('stale', 'stale-thread', 'running');
      await addJob('done', 'done-thread', 'completed');
      final bin = await Directory('${home.path}/bin').create();
      final tmux = File('${bin.path}/tmux');
      await tmux.writeAsString('#!/bin/sh\n[ "\$3" = "ssh-chat-live" ]\n');
      await Process.run('chmod', ['+x', tmux.path]);
      final source =
          await File('lib/services/codex_chat_service.dart').readAsString();
      final script = RegExp(
        "static const _listActiveJobsScript = r'''(.*?)''';",
        dotAll: true,
      ).firstMatch(source)!.group(1)!;
      final result = await Process.run('python3', [
        '-c',
        script
      ], environment: {
        'HOME': home.path,
        'PATH': '${bin.path}:/usr/bin:/bin',
      });
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect(jsonDecode(result.stdout as String), {'app-thread': 'live'});
    } finally {
      await home.delete(recursive: true);
    }
  });
}
