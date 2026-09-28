import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'ssh_service.dart';
import 'storage_service.dart';
import 'notification_service.dart';

class CodexChatResult {
  final String threadId;
  final String answer;
  final int? durationSeconds;

  const CodexChatResult(
      {required this.threadId, required this.answer, this.durationSeconds});
}

class CodexModel {
  final String id;
  final String name;
  final bool isDefault;
  final String defaultEffort;
  final List<CodexReasoningEffort> efforts;

  const CodexModel({
    required this.id,
    required this.name,
    this.isDefault = false,
    required this.defaultEffort,
    required this.efforts,
  });
}

class CodexReasoningEffort {
  final String id;
  final String description;

  const CodexReasoningEffort(this.id, this.description);
}

class CodexChatService {
  static const defaultModel = 'gpt-6-sol';
  static final Set<String> _installedWorkers = {};
  static final ValueNotifier<Map<String, Set<String>>> activeJobsNotifier =
      ValueNotifier({});

  static void _trackJob(String connectionId, String jobId, bool active) {
    final jobs = activeJobsNotifier.value.map(
      (key, value) => MapEntry(key, Set<String>.from(value)),
    );
    if (active) {
      jobs.putIfAbsent(connectionId, () => <String>{}).add(jobId);
    } else {
      jobs[connectionId]?.remove(jobId);
      if (jobs[connectionId]?.isEmpty ?? false) jobs.remove(connectionId);
    }
    activeJobsNotifier.value = jobs;
  }

  static String _quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

  static List<CodexModel> parseModels(String output) {
    final data = jsonDecode(output) as List;
    return data.whereType<Map<String, dynamic>>().map((item) {
      return CodexModel(
        id: item['id'] as String,
        name: item['name'] as String? ?? item['id'] as String,
        isDefault: item['isDefault'] == true,
        defaultEffort: item['defaultEffort'] as String? ?? 'medium',
        efforts: (item['efforts'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((effort) => CodexReasoningEffort(
                  effort['id'] as String,
                  effort['description'] as String? ?? '',
                ))
            .toList(),
      );
    }).toList();
  }

  static Future<List<CodexModel>> listModels(String connectionId) async {
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');
    final script = base64Encode(utf8.encode(_modelListScript));
    final output = utf8.decode(
      await client.run('printf %s ${_quote(script)} | base64 -d | python3'),
      allowMalformed: true,
    );
    return parseModels(output.trim());
  }

  static const _modelListScript =
      r'''import glob, json, os, select, shutil, subprocess, time
home = os.path.expanduser('~')
candidates = [home + '/.local/bin/codex']
candidates += glob.glob(home + '/.config/nvm/versions/node/*/bin/codex')
candidates += glob.glob(home + '/.nvm/versions/node/*/bin/codex')
codex = next((path for path in reversed(candidates) if os.access(path, os.X_OK)),
             shutil.which('codex') or 'codex')
auth = home + '/.local/bin/codex-auth'
command = ([auth, 'run', '--'] if os.access(auth, os.X_OK) else [codex])
command += ['--dangerously-bypass-approvals-and-sandbox']
command += ['app-server', '--stdio']
requests = [
    {'id': 1, 'method': 'initialize', 'params': {'clientInfo': {'name': 'ssh_tool_app', 'version': '1'}}},
    {'method': 'initialized', 'params': {}},
    {'id': 2, 'method': 'model/list', 'params': {}},
]
process = subprocess.Popen(command, stdin=subprocess.PIPE,
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           env={**os.environ, 'CODEX_AUTH_CODEX_BIN': codex}
                           if os.access(auth, os.X_OK) else None)
try:
    for request in requests:
        process.stdin.write((json.dumps(request) + '\n').encode())
    process.stdin.flush()
    buffer = b''
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            break
        buffer += chunk
        while b'\n' in buffer:
            line, buffer = buffer.split(b'\n', 1)
            try:
                response = json.loads(line)
            except ValueError:
                continue
            if response.get('id') != 2:
                continue
            if 'error' in response:
                raise RuntimeError(str(response['error']))
            models = response.get('result', {}).get('data', [])
            print(json.dumps([{'id': model['id'], 'name': model.get('displayName', model['id']),
                               'isDefault': model.get('isDefault', False),
                               'defaultEffort': model.get('defaultReasoningEffort', 'medium'),
                               'efforts': [{'id': effort['reasoningEffort'],
                                            'description': effort.get('description', '')}
                                           for effort in model.get('supportedReasoningEfforts', [])]}
                              for model in models if not model.get('hidden', False)]))
            raise SystemExit(0)
    raise RuntimeError('model/list 未返回结果')
finally:
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
''';

  static Future<Map<String, dynamic>> _remoteJson(
      String connectionId, String command) async {
    var client = SshService.getClient(connectionId);
    if (client == null) {
      final connection = StorageService.getConnection(connectionId);
      if (connection == null) throw StateError('SSH 连接不存在');
      client = (await SshService.connectClient(connection)).client;
    }
    if (client == null) throw StateError('SSH 连接已断开');
    late List<int> bytes;
    try {
      bytes = await client.run(command);
    } catch (_) {
      final connection = StorageService.getConnection(connectionId);
      if (connection == null) rethrow;
      await SshService.disconnect(connectionId);
      final fresh = await SshService.connectClient(connection);
      bytes = await fresh.client!.run(command);
    }
    final output = utf8.decode(bytes, allowMalformed: true).trim();
    try {
      final response = jsonDecode(output) as Map<String, dynamic>;
      if (response['error'] != null) throw StateError(response['error']);
      return response;
    } on FormatException {
      throw StateError('远端聊天任务返回异常：$output');
    }
  }

  static Future<String> _startJob({
    required String connectionId,
    required String workDir,
    required String prompt,
    required String title,
    required String model,
    required String reasoningEffort,
    String? threadId,
    bool fork = false,
  }) async {
    final jobId = const Uuid().v4().replaceAll('-', '');
    final encodedRequest = base64Encode(utf8.encode(jsonEncode({
      'jobId': jobId,
      'workDir': workDir,
      'prompt': prompt,
      'title': title,
      'model': model,
      'effort': reasoningEffort,
      'threadId': threadId,
      'fork': fork,
    })));
    var command = 'python3 "\$HOME/.ssh_tool/codex_chat_worker.py" '
        'start ${_quote(encodedRequest)}';
    if (!_installedWorkers.contains(connectionId)) {
      final worker = await rootBundle.loadString('assets/codex_chat_worker.py');
      final encodedWorker = base64Encode(utf8.encode(worker));
      command = 'umask 077; mkdir -p "\$HOME/.ssh_tool"; '
          'printf %s ${_quote(encodedWorker)} | base64 -d '
          '> "\$HOME/.ssh_tool/codex_chat_worker.py.$jobId" && '
          'mv "\$HOME/.ssh_tool/codex_chat_worker.py.$jobId" '
          '"\$HOME/.ssh_tool/codex_chat_worker.py" && $command';
    }
    final response = await _remoteJson(connectionId, command);
    if (response['jobId'] != jobId) {
      throw StateError('远端 tmux 未启动聊天任务');
    }
    _installedWorkers.add(connectionId);
    return jobId;
  }

  static Future<String?> findRunningJob(
      String connectionId, String threadId) async {
    final response = await _remoteJson(
      connectionId,
      'if [ -f "\$HOME/.ssh_tool/codex_chat_worker.py" ]; then '
      'python3 "\$HOME/.ssh_tool/codex_chat_worker.py" '
      'find ${_quote(threadId)}; else printf "{}"; fi',
    );
    return response['jobId'] as String?;
  }

  static const _listActiveJobsScript = r'''import json
import subprocess
from pathlib import Path

root = Path.home() / ".ssh_tool" / "chat_jobs"
jobs = {}
if root.is_dir():
    for path in root.iterdir():
        if not path.is_dir():
            continue
        try:
            state = json.loads((path / "state.json").read_text(encoding="utf-8"))
            if state.get("status") not in ("starting", "running"):
                continue
            thread_id = state.get("threadId")
            name = state.get("tmuxName")
            if not thread_id or not name:
                continue
            alive = subprocess.run(
                ["tmux", "has-session", "-t", name],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            ).returncode == 0
            if alive:
                jobs[thread_id] = state["jobId"]
        except (OSError, ValueError, KeyError):
            continue
print(json.dumps(jobs))
''';

  static Future<Map<String, String>> listActiveJobs(String connectionId) async {
    final response = await _remoteJson(
      connectionId,
      'python3 -c ${_quote(_listActiveJobsScript)}',
    );
    return response.map((key, value) => MapEntry(key, value.toString()));
  }

  static Future<CodexChatResult> watchJob({
    required String connectionId,
    required String jobId,
    void Function(String text)? onUpdate,
    void Function(String text)? onActivity,
    void Function(DateTime startedAt)? onStartedAt,
  }) async {
    final progress = CodexJobProgress(
      onUpdate: onUpdate,
      onActivity: onActivity,
      onStartedAt: onStartedAt,
    );
    var reconnects = 0;
    _trackJob(connectionId, jobId, true);
    try {
      while (true) {
        try {
          var client = SshService.getClient(connectionId);
          if (client == null) {
            final connection = StorageService.getConnection(connectionId);
            if (connection == null) throw CodexJobFailure('SSH 连接不存在');
            client = (await SshService.connectClient(connection)).client;
          }
          final session = await client!.execute(
            'python3 "\$HOME/.ssh_tool/codex_chat_worker.py" '
            'follow ${_quote(jobId)} ${progress.offset}',
          );
          try {
            await for (final line in session.stdout
                .cast<List<int>>()
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
              final response = jsonDecode(line) as Map<String, dynamic>;
              if (response['error'] != null) {
                throw CodexJobFailure(response['error'].toString());
              }
              reconnects = 0;
              final result = progress.read(response);
              if (result != null) {
                await NotificationService.showCodexFinished(
                  connectionId,
                  result.threadId,
                  jobId,
                  title: progress.title,
                );
                return result;
              }
            }
            throw StateError('SSH 输出流中断');
          } finally {
            session.close();
          }
        } on CodexJobFailure {
          rethrow;
        } on FormatException {
          rethrow;
        } catch (_) {
          if (++reconnects > 3) rethrow;
          await SshService.disconnect(connectionId);
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    } finally {
      _trackJob(connectionId, jobId, false);
    }
  }

  static Future<CodexChatResult> send({
    required String connectionId,
    required String workDir,
    required String prompt,
    String? title,
    String? threadId,
    bool fork = false,
    String model = defaultModel,
    String reasoningEffort = 'medium',
    void Function(String text)? onUpdate,
    void Function(String text)? onActivity,
    void Function(DateTime startedAt)? onStartedAt,
  }) async {
    final jobId = await _startJob(
      connectionId: connectionId,
      workDir: workDir,
      prompt: prompt,
      title: title ?? prompt,
      model: model,
      reasoningEffort: reasoningEffort,
      threadId: threadId,
      fork: fork,
    );
    return watchJob(
      connectionId: connectionId,
      jobId: jobId,
      onUpdate: onUpdate,
      onActivity: onActivity,
      onStartedAt: onStartedAt,
    );
  }
}

class CodexJobProgress {
  final void Function(String text)? onUpdate;
  final void Function(String text)? onActivity;
  final void Function(DateTime startedAt)? onStartedAt;
  int offset = 0;
  String _draft = '';
  final List<String> _activities = [];
  String? _activityItemId;
  DateTime? startedAt;
  String? title;

  CodexJobProgress({this.onUpdate, this.onActivity, this.onStartedAt});

  CodexChatResult? read(Map<String, dynamic> response) {
    offset = response['offset'] as int;
    final state = response['state'] as Map<String, dynamic>;
    if (state['title'] is String) title = state['title'] as String;
    if (state['startedAt'] is int && startedAt == null) {
      startedAt =
          DateTime.fromMillisecondsSinceEpoch(state['startedAt'] as int);
      onStartedAt?.call(startedAt!);
    }
    for (final event in response['events'] as List) {
      if (event is Map && event['type'] == 'activity') {
        final text = event['text'] as String? ?? '';
        if (text.isNotEmpty) {
          _activityItemId = event['itemId'] as String?;
          _activities.add(text);
          if (_activities.length > 4) _activities.removeAt(0);
          onActivity?.call(_activities.join('\n'));
        }
      } else if (event is Map && event['type'] == 'activityDelta') {
        final delta = event['delta'] as String? ?? '';
        if (delta.isNotEmpty) {
          final itemId = event['itemId'] as String?;
          if (_activities.isEmpty || itemId != _activityItemId) {
            _activities.add('');
            if (_activities.length > 4) _activities.removeAt(0);
            _activityItemId = itemId;
          }
          _activities.last += delta;
          if (_activities.last.length > 1000) {
            _activities.last = '${_activities.last.substring(0, 1000)}…';
          }
          onActivity?.call(_activities.join('\n'));
        }
      }
      if (event is Map && event['type'] == 'partial') {
        if (event['text'] is String) {
          _draft = event['text'] as String;
        } else {
          if (event['reset'] == true) _draft = '';
          _draft += event['delta'] as String? ?? '';
        }
        onUpdate?.call(_draft);
      }
    }
    switch (state['status']) {
      case 'completed':
        final threadId = state['threadId'] as String?;
        if (threadId == null) throw CodexJobFailure('远端任务未返回会话 ID');
        return CodexChatResult(
          threadId: threadId,
          answer: state['answer'] as String? ?? '',
          durationSeconds: state['durationSeconds'] as int?,
        );
      case 'failed':
        throw CodexJobFailure(state['error'] ?? '远端聊天任务失败');
    }
    return null;
  }
}

class CodexJobFailure extends StateError {
  CodexJobFailure(super.message);
}
