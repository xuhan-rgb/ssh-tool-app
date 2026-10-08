import 'dart:convert';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/codex_goal.dart';
import 'ssh_service.dart';
import 'codex_chat_service.dart';
import 'remote_state_service.dart';
import 'storage_service.dart';
import 'conversation_sync.dart';
import 'remote_python_script.dart';

class OpenedCodexSession {
  final String name;
  final String workDir;
  final String? conversationId;
  final String activity;

  const OpenedCodexSession({
    required this.name,
    required this.workDir,
    this.conversationId,
    this.activity = 'idle',
  });
}

enum CodexConversationState {
  notStarted,
  running,
  pending,
  complete,
  aborted,
  unknown,
}

extension CodexConversationStateLabel on CodexConversationState {
  String get label => switch (this) {
        CodexConversationState.notStarted => '尚无对话',
        CodexConversationState.running => '正在执行',
        CodexConversationState.pending => '末轮未完成',
        CodexConversationState.complete => '已完成',
        CodexConversationState.aborted => '已中止',
        CodexConversationState.unknown => '日志读取失败',
      };
}

enum CodexConversationLaunch {
  resume,
  fork,
}

/// Codex CLI 在远端保存的一条会话。
class CodexConversation {
  final String id;
  final String cwd;
  final DateTime? updatedAt;
  final DateTime? completedAt;
  final String title;
  final CodexConversationState state;
  final bool writerLocked;
  final bool sharedService;
  /// Whether a remote Codex instance holds this conversation; null if unknown.
  final bool? remoteOpen;
  final bool directoryExists;
  final String preview;
  final bool isSubagent;
  final String? parentConversationId;

  const CodexConversation({
    required this.id,
    required this.cwd,
    required this.updatedAt,
    this.completedAt,
    required this.title,
    this.state = CodexConversationState.unknown,
    this.writerLocked = false,
    this.sharedService = false,
    this.remoteOpen,
    this.directoryExists = true,
    this.preview = '',
    this.isSubagent = false,
    this.parentConversationId,
  });

  String get shortId => id.length > 8 ? id.substring(0, 8) : id;

  String get displayTitle =>
      title.trim().isEmpty ? '对话 $shortId' : title.trim();

  bool get canTakeover =>
      !isSubagent &&
      (state == CodexConversationState.complete ||
          state == CodexConversationState.aborted) &&
      directoryExists;

  bool get canResume =>
      (sharedService &&
          !isSubagent &&
          directoryExists &&
          (state == CodexConversationState.complete ||
              state == CodexConversationState.aborted ||
              state == CodexConversationState.notStarted)) ||
      (!writerLocked &&
          (canTakeover ||
              (!isSubagent &&
                  directoryExists &&
                  remoteOpen == false &&
                  state == CodexConversationState.pending)));

  String get recoveryReason {
    if (isSubagent) {
      final parent = parentConversationId;
      return parent == null || parent.isEmpty
          ? '子代理，需从父对话进入'
          : '子代理，需先恢复父对话 ${parent.length > 8 ? parent.substring(0, 8) : parent}';
    }
    if (!directoryExists) return '对话所在目录不存在';
    if (writerLocked && canTakeover && !sharedService) return 'writer 正在占用，需先接管';
    return switch (state) {
      CodexConversationState.notStarted => '尚未开始一轮对话',
      CodexConversationState.complete => '最后一轮已完成',
      CodexConversationState.running => '最后一轮正在执行',
      CodexConversationState.pending => '最近消息后没有完成记录',
      CodexConversationState.aborted => '最后一轮已中止',
      CodexConversationState.unknown => '无法读取最后一轮日志',
    };
  }
}

class CodexConversationRecord {
  final String kind;
  final DateTime? timestamp;
  final String text;
  final CodexTokenUsage? tokenUsage;
  final String? reasoningEffort;
  final String? model;
  final String? terminalSummary;
  final String? terminalDetails;

  const CodexConversationRecord({
    required this.kind,
    required this.timestamp,
    required this.text,
    this.tokenUsage,
    this.reasoningEffort,
    this.model,
    this.terminalSummary,
    this.terminalDetails,
  });
}

class CodexTokenUsage {
  final int input;
  final int output;
  final int? cachedInput;

  const CodexTokenUsage({
    required this.input,
    required this.output,
    this.cachedInput,
  });

  int get total => input + output;

  String get displayText => '输入 $input · 输出 $output · '
      '缓存命中 ${cachedInput ?? '—'} · '
      '命中率 ${cachedInput == null || input <= 0 ? '—' : '${(cachedInput! * 100 / input).toStringAsFixed(1)}%'}';
}

/// 解析远端脚本输出的 JSON Lines。
class CodexConversationParser {
  static List<CodexConversation> parse(String raw) {
    final conversations = <CodexConversation>[];

    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      try {
        final json = jsonDecode(trimmed);
        if (json is! Map) continue;

        final id = json['id'] as String? ?? '';
        final cwd = json['cwd'] as String? ?? '';
        if (id.isEmpty || cwd.isEmpty) continue;

        final timestamp =
            (json['updatedAt'] as String?) ?? (json['timestamp'] as String?);
        conversations.add(
          CodexConversation(
            id: id,
            cwd: cwd,
            updatedAt: timestamp == null ? null : DateTime.tryParse(timestamp),
            completedAt:
                DateTime.tryParse(json['completedAt'] as String? ?? ''),
            title: (json['title'] as String? ?? '').trim(),
            state: _parseState(json['state'] as String?),
            writerLocked: json['writerLocked'] == true,
            sharedService: json['sharedService'] == true,
            remoteOpen: json['remoteOpen'] as bool?,
            directoryExists: json['directoryExists'] != false,
            preview: (json['preview'] as String? ?? '').trim(),
            isSubagent: json['isSubagent'] == true,
            parentConversationId: json['parentConversationId'] as String?,
          ),
        );
      } catch (_) {
        // 忽略损坏或非 JSON 行，单条会话不应阻塞整个列表。
      }
    }

    conversations.sort((a, b) {
      final aTime = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bTime = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bTime.compareTo(aTime);
    });
    return conversations;
  }

  static List<CodexConversationRecord> parseRecords(String raw) {
    final records = <CodexConversationRecord>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final json = jsonDecode(trimmed);
        if (json is! Map<String, dynamic>) continue;
        final text = (json['text'] as String? ?? '').trim();
        if (text.isEmpty) continue;
        records.add(
          CodexConversationRecord(
            kind: json['kind'] as String? ?? 'other',
            timestamp: DateTime.tryParse(json['timestamp'] as String? ?? ''),
            text: text,
            model: json['model'] is String ? (json['model'] as String).trim() : null,
            terminalSummary: json['terminalSummary'] is String
                ? json['terminalSummary'] as String
                : null,
            terminalDetails: json['terminalDetails'] is String
                ? json['terminalDetails'] as String
                : null,
            reasoningEffort: json['reasoningEffort'] is String
                ? (json['reasoningEffort'] as String).trim()
                : null,
            tokenUsage: switch (json['tokenUsage']) {
              {'input_tokens': int input, 'output_tokens': int output} =>
                CodexTokenUsage(
                  input: input,
                  output: output,
                  cachedInput: switch (json['tokenUsage']) {
                    {'cached_input_tokens': int cached} => cached,
                    _ => null,
                  },
                ),
              _ => null,
            },
          ),
        );
      } catch (_) {
        // 忽略损坏的单条记录。
      }
    }
    return records;
  }

  static CodexConversationState _parseState(String? value) {
    return switch (value) {
      'not_started' => CodexConversationState.notStarted,
      'running' => CodexConversationState.running,
      'pending' => CodexConversationState.pending,
      'complete' => CodexConversationState.complete,
      'aborted' => CodexConversationState.aborted,
      _ => CodexConversationState.unknown,
    };
  }
}

enum CodexMessageRoute { steer, queue, start }

class CodexPendingMessage {
  final String text;
  CodexMessageRoute route;
  final int occurrence;
  final DateTime timestamp = DateTime.now();
  bool queued;

  CodexPendingMessage(this.text, this.occurrence,
      {required this.queued, required this.route});
}

/// 正在发送或等待远程日志确认的消息，生命周期独立于查看窗口。
class CodexPendingMessages extends ChangeNotifier {
  final List<CodexPendingMessage> _messages = [];

  List<CodexPendingMessage> get messages => List.unmodifiable(_messages);

  bool get isNotEmpty => _messages.isNotEmpty;

  int _occurrences(List<CodexConversationRecord> records, String text) => records
      .where((record) => record.kind == 'user' && record.text.trim() == text.trim())
      .length;

  int nextOccurrence(List<CodexConversationRecord> records, String text) {
    var count = _occurrences(records, text);
    for (final message in _messages) {
      if (message.text.trim() == text.trim() && message.occurrence > count) {
        count = message.occurrence;
      }
    }
    return count + 1;
  }

  CodexPendingMessage add(String text, int occurrence,
      {bool queued = true, CodexMessageRoute route = CodexMessageRoute.queue}) {
    final message = CodexPendingMessage(text, occurrence, queued: queued, route: route);
    _messages.add(message);
    notifyListeners();
    return message;
  }

  void markQueued(CodexPendingMessage message, {CodexMessageRoute? route}) {
    if (!_messages.contains(message)) return;
    if (route != null) message.route = route;
    message.queued = true;
    notifyListeners();
  }

  void remove(CodexPendingMessage message) {
    if (_messages.remove(message)) notifyListeners();
  }

  void reconcile(List<CodexConversationRecord> records) {
    final before = _messages.length;
    _messages.removeWhere((message) =>
        _occurrences(records, message.text) >= message.occurrence);
    if (_messages.length != before) notifyListeners();
  }
}

/// 查询和接管远端 Codex 会话。
class CodexSessionService {
  static final _recordSync = ConversationSync();
  static final LinkedHashMap<String, List<CodexConversation>> _conversationCache =
      LinkedHashMap();
  static final LinkedHashMap<String, List<CodexConversation>> _runningConversationCache =
      LinkedHashMap();
  static final LinkedHashMap<String, List<CodexConversationRecord>> _recordCache =
      LinkedHashMap();
  static final Map<String, Future<List<CodexConversation>>> _conversationLoads = {};
  static final Map<String, Future<List<CodexConversation>>> _runningConversationLoads = {};
  static final Map<String, Future<List<CodexConversationRecord>>> _recordLoads = {};

  static final Map<String, CodexPendingMessages> _pendingMessages = {};

  static CodexPendingMessages pendingMessages(
          String connectionId, String conversationId) =>
      _pendingMessages.putIfAbsent(_recordKey(connectionId, conversationId),
          CodexPendingMessages.new);

  @visibleForTesting
  static Future<String> Function(
          String connectionId, String script, List<String> args)?
      runPythonOverride;

  static List<CodexConversation>? cachedConversations(String connectionId) =>
      _conversationCache[connectionId];

  static List<CodexConversation>? cachedRunningConversations(
          String connectionId) =>
      _runningConversationCache[connectionId];

  static List<CodexConversationRecord>? cachedRecords(
          String connectionId, String conversationId) =>
      _recordCache[_recordKey(connectionId, conversationId)];

  static void clearCache([String? connectionId]) {
    _recordSync.clear(connectionId);
    if (connectionId == null) {
      _conversationCache.clear();
      _runningConversationCache.clear();
      _recordCache.clear();
      _pendingMessages.clear();
      _conversationLoads.clear();
      _runningConversationLoads.clear();
      _recordLoads.clear();
      return;
    }
    _conversationCache.remove(connectionId);
    _runningConversationCache.remove(connectionId);
    _conversationLoads.remove(connectionId);
    _runningConversationLoads.remove(connectionId);
    final prefix = '$connectionId\u0000';
    _recordCache.removeWhere((key, _) => key.startsWith(prefix));
    _pendingMessages.removeWhere((key, _) => key.startsWith(prefix));
    _recordLoads.removeWhere((key, _) => key.startsWith(prefix));
  }

  static Future<CodexGoal?> readGoal(
      String connectionId, String conversationId) async {
    final raw = await _runPython(connectionId, _readGoalScript, [conversationId]);
    final value = jsonDecode(raw);
    return value == null
        ? null
        : CodexGoal.fromJson(Map<String, dynamic>.from(value as Map));
  }

  /// Query fresh remote state for each send; never route from the viewer snapshot.
  static Future<CodexMessageRoute> sendMessage(
    String connectionId,
    String conversationId,
    String message,
  ) async {
    if (conversationId.trim().isEmpty || message.trim().isEmpty) {
      throw ArgumentError('对话 ID 和消息不能为空');
    }
    final conversation = await findById(connectionId, conversationId);
    if (conversation == null) throw StateError('远端找不到这个 Codex 对话');
    if (conversation.isSubagent) throw StateError('不能直接向子代理对话发送消息');
    if (conversation.state == CodexConversationState.unknown) {
      throw StateError('无法确认远端运行状态，本次未发送');
    }
    final running = conversation.state == CodexConversationState.running ||
        (conversation.state == CodexConversationState.pending &&
            conversation.writerLocked);
    if (running) {
      await steerMessage(connectionId, conversationId, message);
      return CodexMessageRoute.steer;
    }
    await queueMessage(connectionId, conversationId, message);
    return CodexMessageRoute.queue;
  }

  static Future<CodexMessageRoute> sendMessageWithModel(String connectionId,
      String conversationId, String message, String model, String effort,
      {required String workDir}) async {
    if ([conversationId, message, model, effort].any((value) => value.trim().isEmpty)) {
      throw ArgumentError('对话、消息、模型和思考级别不能为空');
    }
    final source = await rootBundle.loadString('assets/codex_steer_message.py');
    final script = '${source.split('\ndef steer(').first}\n$_sendWithModelScript';
    final output = await _runPython(connectionId, script,
        [conversationId, message, model, effort, workDir], allowReconnect: false);
    if (output.trim().isNotEmpty) {
      final jobId = (jsonDecode(output) as Map<String, dynamic>)['jobId'] as String?;
      if (jobId != null) {
        await CodexChatService.watchJob(connectionId: connectionId, jobId: jobId);
      }
    }
    return CodexMessageRoute.start;
  }

  static const _sendWithModelScript = r'''thread_id, message, model, effort, work_dir = sys.argv[1:6]
# Phone-owned sessions retain a dedicated worker; submit through that owner.
worker_path = Path.home() / '.ssh_tool/codex_chat_worker.py'
if worker_path.is_file():
    import importlib.util
    spec = importlib.util.spec_from_file_location('chat_worker', worker_path)
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    status = worker.session_info(thread_id)
    if status['open']:
        if status['busy']:
            raise RuntimeError('当前任务仍在执行，请结束后发送，所选模型将在下一轮生效')
        request = {'jobId': uuid.uuid4().hex, 'threadId': thread_id, 'prompt': message,
            'title': message, 'model': model, 'effort': effort, 'workDir': work_dir}
        worker.start(base64.b64encode(json.dumps(request).encode()).decode())
        sys.exit(0)
rpc = RpcConnection(control_socket_path(Path(os.environ.get('CODEX_HOME', '~/.codex')).expanduser()))
try:
    rpc.request('initialize', {'clientInfo': {'name': 'ssh_tool_model', 'version': '1'}, 'capabilities': {'experimentalApi': True}})
    rpc.send({'method': 'initialized', 'params': {}})
    thread = rpc.request('thread/read', {'threadId': thread_id, 'includeTurns': False})['thread']
    if thread.get('canAcceptDirectInput') is False:
        raise RuntimeError('目标对话不接受直接输入，本次未发送')
    if thread['status']['type'] == 'active':
        raise RuntimeError('当前任务仍在执行，请结束后发送，所选模型将在下一轮生效')
    if thread['status']['type'] not in ('idle', 'notLoaded'):
        raise RuntimeError('无法确认远程对话状态，本次未发送')
    if thread['status']['type'] == 'notLoaded':
        rpc.request('thread/resume', {'threadId': thread_id, 'excludeTurns': True})
    rpc.request('turn/start', {'threadId': thread_id,
        'input': [{'type': 'text', 'text': message}], 'model': model, 'effort': effort})
finally:
    rpc.close()
''';

  static Future<void> steerMessage(
    String connectionId,
    String conversationId,
    String message,
  ) async {
    if (conversationId.trim().isEmpty || message.trim().isEmpty) {
      throw ArgumentError('对话 ID 和消息不能为空');
    }
    final script = await rootBundle.loadString('assets/codex_steer_message.py');
    await _runPython(connectionId, script, [conversationId, message],
        allowReconnect: false);
  }

  static Future<void> queueMessage(
    String connectionId,
    String conversationId,
    String message,
  ) async {
    if (conversationId.trim().isEmpty) {
      throw ArgumentError.value(conversationId, 'conversationId', '不能为空');
    }
    if (message.trim().isEmpty) {
      throw ArgumentError.value(message, 'message', '不能为空');
    }
    await _runPython(
      connectionId,
      _queueMessageScript,
      [conversationId, message],
      allowReconnect: false,
    );
  }

  static String _recordKey(String connectionId, String conversationId) =>
      '$connectionId\u0000$conversationId';

  static void _saveSnapshot<T>(
      LinkedHashMap<String, List<T>> cache, String key, List<T> value, int limit) {
    cache.remove(key);
    cache[key] = List<T>.unmodifiable(value);
    if (cache.length > limit) cache.remove(cache.keys.first);
  }

  static Future<String?> findTerminalConversationId(
    String connectionId,
    String sessionName,
  ) async {
    final script =
        await rootBundle.loadString('assets/codex_terminal_session_id.py');
    final id = (await _runPython(connectionId, script, [sessionName])).trim();
    return RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(id)
        ? id
        : null;
  }

  static Future<bool> isTerminalCodexRunning(
    String connectionId,
    String sessionName,
  ) async {
    final status = await _runPython(
      connectionId,
      _terminalCodexScript,
      [sessionName, 'status'],
    );
    return status == 'running';
  }

  static Future<void> waitForTerminalCodexExit(
    String connectionId,
    String sessionName,
  ) async {
    await _runPython(connectionId, _terminalCodexScript, [sessionName, 'wait']);
  }

  static Future<void> resumeInTmux(
    String connectionId,
    String sessionName,
    String conversationId,
  ) async {
    await _runPython(
      connectionId,
      _terminalCodexScript,
      [
        sessionName,
        'resume',
        conversationId,
        commandForConversation(conversationId,
            startupCommand: StorageService.getCodexTerminalCommand(connectionId)),
      ],
    );
  }

  static Future<void> waitForWriterUnlock(
    String connectionId,
    String conversationId,
  ) async {
    await _runPython(
      connectionId,
      _waitForWriterUnlockScript,
      [conversationId],
    );
  }

  static CodexConversation? matchOpenedConversation(
    OpenedCodexSession session,
    List<CodexConversation> conversations,
  ) {
    final id = session.conversationId;
    if (id != null && id.isNotEmpty) {
      for (final conversation in conversations) {
        if (conversation.id == id) return conversation;
      }
      return null;
    }
    final prefix = session.name.startsWith('codex-')
        ? session.name.substring(6)
        : session.name.startsWith('fork-')
            ? session.name.substring(5)
            : '';
    if (prefix.length < 6) return null;
    CodexConversation? match;
    for (final conversation in conversations) {
      if (!conversation.id.startsWith(prefix)) continue;
      if (match != null) return null;
      match = conversation;
    }
    return match;
  }

  static Future<List<OpenedCodexSession>> listOpened(
      String connectionId) async {
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');
    final results = await Future.wait([
      RemoteStateService.readState(client),
      RemoteStateService.queryAliveTmux(client),
    ]);
    final state = results[0] as Map<String, dynamic>;
    final alive = results[1] as Set<String>;
    return openedFromRemote(state, alive);
  }

  static Future<OpenedCodexSession?> findOpenedById(
    String connectionId,
    String conversationId,
  ) async {
    final sessions = await listOpened(connectionId);
    for (final session in sessions) {
      if (session.conversationId == conversationId) return session;
    }
    return null;
  }

  static List<OpenedCodexSession> openedFromRemote(
      Map<String, dynamic> state, Set<String> alive) {
    final sessions = <OpenedCodexSession>[];
    for (final name in alive) {
      final rawInfo = state[name];
      final info =
          rawInfo is Map<String, dynamic> ? rawInfo : const <String, dynamic>{};
      sessions.add(OpenedCodexSession(
        name: name,
        workDir: info['workDir'] as String? ?? '~',
        conversationId: info['conversationId'] as String?,
        activity: info['activity'] as String? ?? 'idle',
      ));
    }
    return sessions..sort((a, b) => a.name.compareTo(b.name));
  }

  static Future<List<CodexConversation>> listForDirectory(
    String connectionId,
    String workDir,
  ) async {
    final raw = await _runPython(
      connectionId,
      await _listScriptWithRpc(),
      [workDir],
    );
    return CodexConversationParser.parse(raw)
        .where((conversation) => !conversation.isSubagent)
        .take(200)
        .toList();
  }

  static Future<List<CodexConversation>> listAll(String connectionId) async {
    return listAllPage(connectionId, 0);
  }

  static Future<List<CodexConversation>> listRemoteOpen(String connectionId) async {
    final raw = await _runPython(connectionId, await _listScriptWithRpc(), ['__opened__']);
    return CodexConversationParser.parse(raw)
        .where((item) => item.remoteOpen == true && !item.isSubagent)
        .toList();
  }

  static Future<List<CodexConversation>> listRunning(String connectionId) async {
    final existing = _runningConversationLoads[connectionId];
    if (existing != null) return existing;
    late final Future<List<CodexConversation>> request;
    request = _fetchRunning(connectionId).then((value) {
      if (identical(_runningConversationLoads[connectionId], request)) {
        _saveSnapshot(_runningConversationCache, connectionId, value, 12);
        _runningConversationLoads.remove(connectionId);
      }
      return value;
    }, onError: (Object error, StackTrace stack) {
      if (identical(_runningConversationLoads[connectionId], request)) {
        _runningConversationLoads.remove(connectionId);
      }
      Error.throwWithStackTrace(error, stack);
    });
    _runningConversationLoads[connectionId] = request;
    return request;
  }

  static Future<List<CodexConversation>> _fetchRunning(
      String connectionId) async {
    final raw = await _runPython(
      connectionId,
      await _listScriptWithRpc(),
      ['__running__'],
    );
    return CodexConversationParser.parse(raw)
        .where((conversation) =>
            conversation.state == CodexConversationState.running &&
            !conversation.isSubagent)
        .toList();
  }

  static Future<List<CodexConversation>> listAllPage(
      String connectionId, int offset) async {
    if (offset == 0) {
      final existing = _conversationLoads[connectionId];
      if (existing != null) return existing;
      late final Future<List<CodexConversation>> request;
      request = _fetchAllPage(connectionId, offset).then((value) {
        if (identical(_conversationLoads[connectionId], request)) {
          _saveSnapshot(_conversationCache, connectionId, value, 12);
          _conversationLoads.remove(connectionId);
        }
        return value;
      }, onError: (Object error, StackTrace stack) {
        if (identical(_conversationLoads[connectionId], request)) {
          _conversationLoads.remove(connectionId);
        }
        Error.throwWithStackTrace(error, stack);
      });
      _conversationLoads[connectionId] = request;
      return request;
    }
    return _fetchAllPage(connectionId, offset);
  }

  static Future<List<CodexConversation>> _fetchAllPage(
      String connectionId, int offset) async {
    final raw = await _runPython(
      connectionId,
      await _listScriptWithRpc(),
      ['__all__', '$offset'],
    );
    return CodexConversationParser.parse(raw)
        .where((conversation) => !conversation.isSubagent)
        .take(200)
        .toList();
  }

  static Future<CodexConversation?> findById(
    String connectionId,
    String conversationId,
  ) async {
    final raw = await _runPython(
      connectionId,
      await _listScriptWithRpc(),
      ['id:$conversationId'],
    );
    return CodexConversationParser.parse(raw).firstOrNull;
  }

  static Future<List<CodexConversationRecord>> readConversation(
    String connectionId,
    String conversationId,
  ) async {
    final key = _recordKey(connectionId, conversationId);
    final existing = _recordLoads[key];
    if (existing != null) return existing;
    late final Future<List<CodexConversationRecord>> request;
    request = _fetchConversation(connectionId, conversationId).then((value) {
      if (identical(_recordLoads[key], request)) {
        _saveSnapshot(_recordCache, key, value, 24);
        _recordLoads.remove(key);
      }
      return value;
    }, onError: (Object error, StackTrace stack) {
      if (identical(_recordLoads[key], request)) _recordLoads.remove(key);
      Error.throwWithStackTrace(error, stack);
    });
    _recordLoads[key] = request;
    return request;
  }

  static Future<List<CodexConversationRecord>> _fetchConversation(
      String connectionId, String conversationId) async {
    final raw = await _recordSync.read(connectionId, conversationId,
        (version) => _runPython(connectionId,
            ConversationSync.script(_readScript, 'codex'),
            [conversationId, version], reuseScript: true));
    return CodexConversationParser.parseRecords(raw);
  }

  /// 终止持有 thread writer lock 的远程进程。
  ///
  /// 返回 null 表示成功；返回字符串表示远程操作失败原因。
  static Future<String?> stopWriter(
    String connectionId,
    String conversationId,
    String workDir,
  ) async {
    late final String raw;
    try {
      raw = await _runPython(
        connectionId,
        _stopWriterScript,
        [conversationId],
        workDir: workDir,
        allowReconnect: false,
      );
    } catch (error) {
      return error.toString();
    }
    if (raw.trim().isEmpty) return '远程没有返回 kill 结果';

    for (final line in raw.trim().split('\n').reversed) {
      try {
        final result = jsonDecode(line);
        if (result is! Map<String, dynamic>) continue;
        if (result['ok'] == true) return null;
        return result['message'] as String? ?? '无法终止远程 Codex writer';
      } catch (_) {
        // 继续寻找最后一条 JSON 结果。
      }
    }
    return '远程 kill 结果格式异常：${raw.trim()}';
  }

  static String commandForConversation(
    String conversationId, {
    CodexConversationLaunch launch = CodexConversationLaunch.resume,
    String startupCommand = StorageService.defaultCodexTerminalCommand,
  }) {
    final command = launch == CodexConversationLaunch.fork ? 'fork' : 'resume';
    return '$startupCommand $command ${_shellQuote(conversationId)}';
  }

  static String resumeCommand(String conversationId) {
    return commandForConversation(conversationId);
  }

  static String forkCommand(String conversationId) {
    return commandForConversation(
      conversationId,
      launch: CodexConversationLaunch.fork,
    );
  }

  static Future<String> _runPython(
      String connectionId, String script, List<String> args,
      {String? workDir, bool allowReconnect = true, bool reuseScript = false}) async {
    final override = runPythonOverride;
    if (override != null) return override(connectionId, script, args);
    final encoded = base64Encode(utf8.encode(script));
    final command = [
      if (workDir != null) 'cd ${_shellQuote(workDir)} &&',
      'printf %s ${_shellQuote(encoded)}',
      '| base64 -d | python3 -',
      ...args.map(_shellQuote),
    ].join(' ');
    final remoteCommand =
        '$command 2>&1; printf "\\n__SSH_TOOL_EXIT__%s\\n" "\$?"';
    var client = SshService.getClient(connectionId);
    final connection = StorageService.getConnection(connectionId);
    if (client == null && allowReconnect && connection != null) {
      client = (await SshService.connectClient(connection)).client;
    }
    if (client == null) throw StateError('SSH 连接已断开');

    Future<String> execute(String command) async {
      try {
        return utf8.decode(await client!.run(command), allowMalformed: true);
      } catch (_) {
        if (!allowReconnect || !client!.isClosed || connection == null) rethrow;
        await SshService.disconnect(connectionId);
        client = (await SshService.connectClient(connection)).client;
        return utf8.decode(await client!.run(command), allowMalformed: true);
      }
    }
    final output = reuseScript
        ? await RemotePythonScript.run(script: script, args: args, execute: execute)
        : await execute(remoteCommand);
    final marker = RegExp(r'__SSH_TOOL_EXIT__(\d+)\s*$').firstMatch(output);
    if (marker == null) throw StateError('远端命令未返回执行状态：$output');
    final body = output.substring(0, marker.start).trim();
    if (reuseScript && body.isEmpty) {
      throw StateError('Remote conversation sync returned no response');
    }
    if (marker.group(1) != '0') {
      throw StateError('远端 Codex 查询失败：$body');
    }
    return body;
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  static const String _readGoalScript = r'''import glob
import json
import os
import select
import shutil
import subprocess
import sys
import time

home = os.path.expanduser('~')
candidates = [home + '/.local/bin/codex']
candidates += sorted(glob.glob(home + '/.config/nvm/versions/node/*/bin/codex')
                     + glob.glob(home + '/.nvm/versions/node/*/bin/codex'), reverse=True)
candidates += [shutil.which('codex') or '']
last_error = '未找到支持 Goal 的 Codex CLI'
for candidate in dict.fromkeys(candidates):
    if not candidate or not os.access(candidate, os.X_OK):
        continue
    process = None
    try:
        env = dict(os.environ)
        env['PATH'] = os.path.dirname(candidate) + os.pathsep + os.environ.get('PATH', os.defpath)
        process = subprocess.Popen([candidate, 'app-server'],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.DEVNULL, env=env)
        def send(request):
            process.stdin.write((json.dumps(request) + '\n').encode())
            process.stdin.flush()
        send({'id': 1, 'method': 'initialize', 'params': {
            'clientInfo': {'name': 'ssh_tool_goal', 'version': '1'},
            'capabilities': {'experimentalApi': True},
        }})
        buffer = b''
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            ready, _, _ = select.select([process.stdout], [], [],
                                         max(0, deadline - time.monotonic()))
            if not ready:
                raise RuntimeError('读取 Goal 超时')
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError('Codex Goal 读取进程已退出')
            buffer += chunk
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get('id') not in (1, 2):
                    continue
                if 'error' in event:
                    raise RuntimeError(str(event['error']))
                if event['id'] == 1:
                    send({'method': 'initialized', 'params': {}})
                    # 只查询持久目标，不恢复或启动 turn，不取得对话 writer lock。
                    send({'id': 2, 'method': 'thread/goal/get',
                          'params': {'threadId': sys.argv[1]}})
                else:
                    print(json.dumps(event['result']['goal'], ensure_ascii=False))
                    sys.exit(0)
        raise RuntimeError('读取 Goal 超时')
    except (OSError, RuntimeError, KeyError, TypeError) as error:
        last_error = str(error)
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
print('读取远端 Goal 失败：' + last_error, file=sys.stderr)
sys.exit(1)
''';

  static const String _queueMessageScript = r'''import json
from pathlib import Path
import glob
import os
import shutil
import subprocess
import sys

thread_id, message = sys.argv[1:3]
# Prepared official installations submit via the owning daemon, not a version-specific queue CLI.
runtime_config = Path.home() / '.ssh_tool/codex_runtime/connection.json'
if runtime_config.is_file():
    import base64, importlib.util, uuid
    sys.path.insert(0, str(Path.home() / '.ssh_tool'))
    from codex_runtime import read_config, RpcConnection
    rpc = RpcConnection(Path(read_config()['socketPath']))
    try:
        rpc.request('initialize', {'clientInfo': {'name': 'ssh_tool_submit', 'version': '1'}})
        rpc.send({'method': 'initialized', 'params': {}})
        thread = rpc.request('thread/read', {'threadId': thread_id, 'includeTurns': False})['thread']
        if thread['status']['type'] not in ('idle', 'notLoaded'):
            raise RuntimeError('目标对话状态已变化，本次未发送，请刷新后重试')
        models = rpc.request('model/list', {})['data']
        model = next((model for model in models if model.get('isDefault')), models[0] if models else None)
        if model is None:
            raise RuntimeError('远端没有可用的 Codex 模型')
        request = {'jobId': uuid.uuid4().hex, 'threadId': thread_id, 'prompt': message,
            'title': message, 'workDir': thread['cwd'], 'model': model['id'],
            'effort': model.get('defaultReasoningEffort', 'medium')}
    finally:
        rpc.close()
    worker_path = Path.home() / '.ssh_tool/codex_chat_worker.py'
    spec = importlib.util.spec_from_file_location('chat_worker', worker_path)
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    worker.start(base64.b64encode(json.dumps(request).encode()).decode())
    sys.exit(0)
home = os.path.expanduser('~')
local_codex = home + '/.local/bin/codex'
nvm_codex = sorted(
    glob.glob(home + '/.config/nvm/versions/node/*/bin/codex')
    + glob.glob(home + '/.nvm/versions/node/*/bin/codex'),
    reverse=True,
)
candidates = [local_codex] + nvm_codex + [shutil.which('codex') or '']
available = [path for path in candidates if path and os.access(path, os.X_OK)]
if not available:
    print('未找到 Codex CLI（检查 ~/.local/bin、nvm 和 PATH）', file=sys.stderr)
    sys.exit(127)

codex = None
command_env = None
for candidate in dict.fromkeys(available):
    # SSH 非交互环境不加载 nvm；探测和发送必须使用同一份 Node/PATH 环境。
    candidate_env = dict(os.environ)
    candidate_env['PATH'] = os.path.dirname(candidate) + os.pathsep + os.environ.get('PATH', os.defpath)
    try:
        probe = subprocess.run(
            [candidate, 'queue', '--help'], capture_output=True, text=True,
            env=candidate_env, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        continue
    help_text = probe.stdout + probe.stderr
    # 旧版会把 queue 当成普通 prompt，甚至返回成功的顶层 help。
    if probe.returncode == 0 and '--thread' in help_text and '--message' in help_text:
        codex, command_env = candidate, candidate_env
        break

if codex is None:
    print('远端已安装的 Codex 不支持 queue --thread --message，或运行环境不可用。请检查远端 Codex 版本。', file=sys.stderr)
    sys.exit(2)

# 只有只读能力探测可以尝试多个版本，实际发送失败后不能换版本重发。
result = subprocess.run(
    [codex, 'queue', '--thread', thread_id, '--message', message],
    capture_output=True,
    text=True,
    env=command_env,
)
if result.stdout:
    sys.stdout.write(result.stdout)
if result.stderr:
    sys.stderr.write(result.stderr)
sys.exit(result.returncode)
''';

  static Future<String> _listScriptWithRpc() async {
    // Share the dependency-free transport; do not include the message-sending entry point.
    final source = await rootBundle.loadString('assets/codex_steer_message.py');
    return '${source.split('\ndef steer(').first}\n$_listScript';
  }

  /// 读取指定工作目录下的会话状态。状态判定与 codex-thread-inspect.sh 一致。
  static const String _listScript = r'''import datetime
import json
import os
import sys
import fcntl
from pathlib import Path


requested_value = sys.argv[1] if len(sys.argv) > 1 else "__all__"
offset = max(0, int(sys.argv[2])) if len(sys.argv) > 2 else 0
requested_id = requested_value[3:] if requested_value.startswith("id:") else None
requested_dir = (
    None
    if requested_value in ("", "__all__", "__running__", "__opened__") or requested_id is not None
    else Path(os.path.expanduser(requested_value)).resolve()
)
codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
runtime_config = Path.home() / ".ssh_tool/codex_runtime/connection.json"
sessions_dir = codex_home / "sessions"
session_index_path = codex_home / "session_index.jsonl"
HEAD_BYTES = 128 * 1024
TAIL_BYTES = 64 * 1024
MAX_SESSIONS = 200
shared_daemon_state = None


def control_socket_path():
    config = Path.home() / '.ssh_tool/codex_runtime/connection.json'
    if config.is_file():
        return Path(json.loads(config.read_text(encoding='utf-8'))['socketPath'])
    return codex_home / 'app-server-control' / 'app-server-control.sock'


def load_session_index():
    records = {}
    if not session_index_path.is_file():
        return records
    try:
        with session_index_path.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    item = json.loads(line)
                except Exception:
                    continue
                if not isinstance(item, dict):
                    continue
                thread_id = item.get("id")
                if isinstance(thread_id, str) and thread_id:
                    records[thread_id] = item
    except OSError:
        pass
    return records


session_index = load_session_index()


def text_from_content(content):
    parts = []
    if not isinstance(content, list):
        return ""
    for part in content:
        if not isinstance(part, dict):
            continue
        value = part.get("text")
        if isinstance(value, str):
            parts.append(value)
    return " ".join("".join(parts).split())


def is_injected_context(text):
    return text.startswith((
        "<environment_context>",
        "<recommended_plugins>",
        "<heartbeat>",
        "# AGENTS.md instructions",
    ))


def json_lines(raw):
    for line in raw.splitlines():
        try:
            item = json.loads(line)
        except Exception:
            continue
        if isinstance(item, dict):
            yield item


def timestamp_to_sort(value, fallback):
    if isinstance(value, str) and value:
        try:
            return datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            pass
    return fallback


def lock_is_held(thread_id):
    lock_path = codex_home / "thread-writer-locks" / f"{thread_id}.lock"
    try:
        with lock_path.open("rb") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
            return False
    except BlockingIOError:
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return None


def shared_daemon_threads():
    global shared_daemon_state
    if shared_daemon_state is not None:
        return shared_daemon_state
    socket_path = control_socket_path()
    shared_inodes = set()
    shared_pids = {}
    if socket_path.exists():
        for line in Path("/proc/locks").read_text().splitlines():
            fields = line.split()
            if len(fields) < 8 or fields[1] != "FLOCK" or fields[3] != "WRITE":
                continue
            pid = fields[4]
            if pid not in shared_pids:
                try:
                    args = (Path("/proc") / pid / "cmdline").read_bytes().split(b"\0")
                    endpoint = ("unix://" + str(socket_path)).encode()
                    shared_pids[pid] = b"app-server" in args and (
                        endpoint in args or
                        (b"--managed-daemon" in args and b"unix://" in args)
                    )
                except OSError:
                    shared_pids[pid] = False
            if shared_pids[pid]:
                major, minor, inode = fields[5].split(":")
                shared_inodes.add((int(major, 16), int(minor, 16), int(inode)))
    loaded = set()
    if shared_inodes:
        rpc = RpcConnection(socket_path)
        try:
            rpc.request("initialize", {
                "clientInfo": {"name": "ssh_tool_discovery", "version": "1"},
                "capabilities": {"experimentalApi": True},
            })
            rpc.send({"method": "initialized", "params": {}})
            cursor = None
            while True:
                page = rpc.request("thread/loaded/list", {"cursor": cursor})
                loaded.update(page["data"])
                cursor = page.get("nextCursor")
                if not cursor:
                    break
        finally:
            rpc.close()
    shared_daemon_state = loaded, shared_inodes
    return shared_daemon_state


def remote_is_open(thread_id, writer_locked):
    if writer_locked is not True:
        return writer_locked
    loaded, shared_inodes = shared_daemon_threads()
    try:
        stat = (codex_home / "thread-writer-locks" / f"{thread_id}.lock").stat()
        identity = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    except OSError:
        return None
    # A shared daemon may retain a writer after its terminal has unsubscribed.
    return thread_id in loaded if identity in shared_inodes else True


def is_shared_service_thread(thread_id, writer_locked):
    if not runtime_config.is_file() or writer_locked is not True:
        return False
    loaded, shared_inodes = shared_daemon_threads()
    if thread_id not in loaded:
        return False
    try:
        stat = (codex_home / "thread-writer-locks" / f"{thread_id}.lock").stat()
        identity = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
    except OSError:
        return False
    return identity in shared_inodes


def latest_turn_state(path, writer_locked):
    # 从末尾倒读完整 JSONL 行；文件头中的旧 task_complete 不能代表当前状态。
    remaining = path.stat().st_size
    partial = b""
    user_after_task = False
    with path.open("rb") as stream:
        while remaining:
            size = min(TAIL_BYTES, remaining)
            remaining -= size
            stream.seek(remaining)
            lines = (stream.read(size) + partial).split(b"\n")
            partial = lines[0]
            for line in reversed(lines[1:]):
                try:
                    item = json.loads(line)
                except Exception:
                    continue
                payload = item.get("payload", {})
                if not isinstance(payload, dict):
                    continue
                if item.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
                    user_after_task = True
                elif item.get("type") == "event_msg":
                    event_type = payload.get("type")
                    if event_type == "user_message":
                        user_after_task = True
                    elif event_type in ("task_started", "task_complete", "turn_aborted"):
                        if event_type == "task_started":
                            return ("running" if writer_locked else "pending"), None
                        if user_after_task:
                            return "pending", None
                        if event_type == "task_complete":
                            return "complete", item.get("timestamp")
                        return "aborted", None
    return ("pending" if user_after_task else "not_started"), None


def current_turn_state(thread_id, state, completed_at):
    if state != "running":
        return state, completed_at
    loaded, shared_inodes = shared_daemon_threads()
    if thread_id not in loaded:
        return state, completed_at
    rpc = None
    try:
        stat = (codex_home / "thread-writer-locks" / f"{thread_id}.lock").stat()
        if (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino) not in shared_inodes:
            return state, completed_at
        rpc = RpcConnection(control_socket_path())
        rpc.request("initialize", {
            "clientInfo": {"name": "ssh_tool_turn_status", "version": "1"},
            "capabilities": {"experimentalApi": True},
        })
        rpc.send({"method": "initialized", "params": {}})
        thread = rpc.request("thread/read", {"threadId": thread_id, "includeTurns": False})["thread"]
        if thread.get("status", {}).get("type") != "idle":
            return state, completed_at
        turns = rpc.request("thread/turns/list", {
            "threadId": thread_id, "limit": 1, "sortDirection": "desc", "itemsView": "notLoaded",
        })["data"]
        if turns:
            turn = turns[0]
            if turn.get("status") == "completed":
                finished = turn.get("completedAt")
                stamp = datetime.datetime.fromtimestamp(finished, datetime.timezone.utc).isoformat().replace("+00:00", "Z") if isinstance(finished, (int, float)) else None
                return "complete", stamp
            if turn.get("status") in ("interrupted", "failed"):
                return "aborted", None
    except Exception:
        # Older servers or a concurrent unload must not remove the session from the list.
        pass
    finally:
        if rpc is not None:
            rpc.close()
    return state, completed_at


def inspect_session(path):
    try:
        file_stat = path.stat()
        mtime = datetime.datetime.fromtimestamp(
            file_stat.st_mtime, datetime.timezone.utc
        ).isoformat().replace("+00:00", "Z")
        # 尾部按字节定位，使用二进制读取；截断的首行由 json_lines 跳过。
        with path.open("rb") as stream:
            first = json.loads(stream.readline())
            meta = first.get("payload", {})
            if first.get("type") != "session_meta":
                return None
            cwd = meta.get("cwd")
            thread_id = meta.get("id") or meta.get("session_id")
            if not cwd or not thread_id:
                return None
            source = meta.get("source")
            is_subagent = meta.get("thread_source") == "subagent" or (
                isinstance(source, dict) and "subagent" in source
            )
            parent_id = meta.get("parent_thread_id")
            if not parent_id and isinstance(source, dict):
                subagent = source.get("subagent")
                if isinstance(subagent, dict):
                    spawn = subagent.get("thread_spawn")
                    if isinstance(spawn, dict):
                        parent_id = spawn.get("parent_thread_id")
            if requested_dir is not None and Path(cwd).expanduser().resolve() != requested_dir:
                return None

            index_item = session_index.get(thread_id, {})
            index_title = index_item.get("thread_name")
            if not isinstance(index_title, str):
                index_title = ""
            index_title = index_title.strip()
            if is_injected_context(index_title):
                index_title = ""
            index_updated = index_item.get("updated_at")
            if not isinstance(index_updated, str) or not index_updated:
                index_updated = None

            # 全量列表优先使用 session_index 的标题和时间，只读文件尾部判断状态；
            # 目录筛选或旧版本没有索引时，再读取一小段文件头作为标题兜底。
            if file_stat.st_size <= TAIL_BYTES:
                stream.seek(0)
                head = stream.read()
                tail = ""
            elif index_title:
                head = ""
                stream.seek(max(0, file_stat.st_size - TAIL_BYTES))
                tail = stream.read(TAIL_BYTES)
            else:
                head = stream.read(HEAD_BYTES)
                stream.seek(max(0, file_stat.st_size - TAIL_BYTES))
                tail = stream.read(TAIL_BYTES)

            title = index_title
            preview = ""
            latest_timestamp = index_updated or meta.get("timestamp") or mtime
            def consume(item):
                nonlocal title, preview, latest_timestamp
                timestamp = item.get("timestamp")
                if isinstance(timestamp, str) and timestamp:
                    latest_timestamp = timestamp
                payload = item.get("payload", {})
                if not isinstance(payload, dict):
                    return

                if item.get("type") != "response_item":
                    return
                role = payload.get("role")
                if payload.get("type") != "message" or role not in ("user", "assistant"):
                    return
                text = text_from_content(payload.get("content"))
                if not text:
                    return
                if is_injected_context(text):
                    return
                if role == "user" and not title:
                    title = text[:160]
                preview = text[:240]

            for item in json_lines(head):
                consume(item)
            if tail:
                for item in json_lines(tail):
                    consume(item)

            writer_locked = lock_is_held(thread_id)
            remote_open = remote_is_open(thread_id, writer_locked)
            shared_service = is_shared_service_thread(thread_id, writer_locked)
            state, completed_at = latest_turn_state(path, remote_open)
            state, completed_at = current_turn_state(thread_id, state, completed_at)
            if state == "not_started" and not writer_locked:
                return None

            return {
                "id": thread_id,
                "cwd": cwd,
                "updatedAt": latest_timestamp,
                "completedAt": completed_at if state == "complete" else None,
                "title": title,
                "preview": preview,
                "state": state,
                "writerLocked": writer_locked is True,
                "sharedService": shared_service,
                "remoteOpen": remote_open,
                "directoryExists": os.path.isdir(cwd),
                "isSubagent": is_subagent,
                "parentConversationId": parent_id,
                "_sortTime": timestamp_to_sort(index_updated, file_stat.st_mtime),
            }
    except Exception:
        return None


def path_thread_id(path):
    # rollout 文件名的前缀本身也包含连字符，UUID 取末尾 36 个字符。
    return path.stem[-36:]


def candidate_paths():
    if requested_id is not None:
        if len(requested_id) != 36 or any(
            character not in "0123456789abcdefABCDEF-" for character in requested_id
        ):
            return []
        return list(sessions_dir.rglob(f"*-{requested_id}.jsonl"))[:1]
    if requested_value in ("__running__", "__opened__"):
        candidates = []
        for path in sessions_dir.rglob("rollout-*.jsonl"):
            thread_id = path_thread_id(path)
            if len(thread_id) == 36 and lock_is_held(thread_id):
                candidates.append(path)
        return candidates
    paths = []
    for path in sessions_dir.rglob("rollout-*.jsonl"):
        try:
            paths.append((path.stat().st_mtime, path))
        except OSError:
            continue

    if requested_dir is None:
        # 新会话可能尚未写入索引，按文件时间参与同一次排序后再分页。
        paths.sort(
            key=lambda value: timestamp_to_sort(
                session_index.get(path_thread_id(value[1]), {}).get("updated_at"),
                value[0],
            ),
            reverse=True,
        )
        paths = paths[offset:offset + MAX_SESSIONS]
    return [path for _, path in paths]


if sessions_dir.is_dir():
    shared_daemon_threads()
    results = []
    for session_path in candidate_paths():
        item = inspect_session(session_path)
        if item and (
            requested_value != "__running__"
            or (item["state"] == "running" and not item["isSubagent"])
        ) and (
            requested_value != "__opened__"
            or (item["remoteOpen"] is True and not item["isSubagent"])
        ):
            results.append(item)
    results.sort(key=lambda item: item.get("_sortTime", 0), reverse=True)
    for item in results if requested_value in ("__running__", "__opened__") else results[:MAX_SESSIONS]:
        item.pop("_sortTime", None)
        print(json.dumps(item, ensure_ascii=False))
''';

  /// 等待终端中的 Codex 退出，或在同一 tmux 终端恢复原对话。
  static const String _terminalCodexScript = r'''import subprocess
import sys
import time

session_name, action = sys.argv[1:3]
pane = subprocess.run(
    ["tmux", "display-message", "-pt", session_name, "#{pane_pid}"],
    capture_output=True, text=True,
)
if pane.returncode != 0 or not pane.stdout.strip().isdigit():
    raise SystemExit("找不到目标 tmux 终端")
pane_pid = pane.stdout.strip()

def codex_running():
    children = subprocess.run(
        ["pgrep", "-P", pane_pid, "-f", "codex"],
        capture_output=True,
    )
    return children.returncode == 0

if action == "status":
    print("running" if codex_running() else "idle")
    raise SystemExit(0)

if action == "wait":
    for _ in range(60):
        if not codex_running():
            print("ready")
            raise SystemExit(0)
        time.sleep(0.25)
    raise SystemExit("终端里的 Codex 尚未退出，请先清空未发送的输入")

if codex_running():
    raise SystemExit("目标终端里的 Codex 已在运行")
command = sys.argv[4]
result = subprocess.run(
    ["tmux", "send-keys", "-t", session_name, command, "Enter"],
    capture_output=True, text=True,
)
if result.returncode != 0:
    raise SystemExit(result.stderr.strip() or "无法恢复终端")
print("ready")
''';

  /// 输出与 codex-thread-inspect.sh 相同语义的可读记录。
  static const String _waitForWriterUnlockScript = r'''import fcntl
import os
import sys
import time
from pathlib import Path

thread_id = sys.argv[1]
codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
lock_path = codex_home / "thread-writer-locks" / f"{thread_id}.lock"
for _ in range(60):
    if not lock_path.is_file():
        print("ready")
        raise SystemExit(0)
    with lock_path.open("rb") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lock_file, fcntl.LOCK_UN)
            print("ready")
            raise SystemExit(0)
        except BlockingIOError:
            pass
    time.sleep(0.25)
raise SystemExit("Codex 仍在执行，请稍后重试")
''';

  static const String _readScript = r'''import json
import os
import sys
from pathlib import Path


thread_id = sys.argv[1]
codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
sessions_dir = codex_home / "sessions"


def text_from_content(content):
    parts = []
    if isinstance(content, list):
        for part in content:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                parts.append(part["text"])
    return "\n".join(parts).strip()


def first_heading(value):
    import re
    match = re.search(r"\*\*(.+?)\*\*", value)
    return match.group(1).strip() if match else None


def command_label(command):
    if isinstance(command, list):
        command = command[-1] if len(command) >= 3 and command[1] == "-lc" else " ".join(str(part) for part in command)
    lines = str(command or "command").strip().splitlines()
    return (lines[0] if lines else "command")[:200] + (" …" if len(lines) > 1 else "")


def diff_counts(diff):
    added = sum(1 for line in diff.splitlines() if line.startswith("+") and not line.startswith("+++"))
    deleted = sum(1 for line in diff.splitlines() if line.startswith("-") and not line.startswith("---"))
    return added, deleted


if not sessions_dir.is_dir():
    raise SystemExit(0)

for path in sessions_dir.rglob(f"*-{thread_id}.jsonl"):
    records = []
    calls = {}
    session_calls = {}
    last_assistant = None
    reasoning_texts = set()
    turn_number = 0
    structured_by_turn = {}
    last_usage = None
    reasoning_effort = None
    model = None
    try:
        with path.open(encoding="utf-8") as stream:
            for line_number, line in enumerate(stream):
                try:
                    item = json.loads(line)
                except Exception:
                    continue
                if not isinstance(item, dict):
                    continue
                timestamp = item.get("timestamp")
                payload = item.get("payload", {})
                if not isinstance(payload, dict):
                    continue

                kind = None
                text = ""
                terminal_summary = None
                terminal_details = None
                if item.get("type") == "turn_context":
                    model_value = payload.get("model")
                    model = model_value.strip() if isinstance(model_value, str) and model_value.strip() else None
                    effort = payload.get("effort")
                    reasoning_effort = effort.strip() if isinstance(effort, str) and effort.strip() else None
                    kind, text = "turn_context", "模型：" + (model or "未知") + " · 思考强度：" + (reasoning_effort or "未知")
                    terminal_summary = text
                elif item.get("type") == "response_item":
                    payload_type = payload.get("type")
                    if payload_type == "message" and payload.get("role") in ("user", "assistant"):
                        kind = payload.get("role")
                        text = text_from_content(payload.get("content"))
                    elif payload_type == "reasoning":
                        kind = "reasoning"
                        text = "\n".join(
                            part.get("text", "")
                            for part in payload.get("summary", [])
                            if isinstance(part, dict)
                        ).strip()
                        import re
                        heading = re.search(r"\*\*(.+?)\*\*", text)
                        terminal_summary = heading.group(1).strip() if heading else None
                        if text in reasoning_texts:
                            kind = None
                        else:
                            reasoning_texts.add(text)
                    elif payload_type in ("custom_tool_call", "function_call"):
                        kind = "tool_call"
                        tool_name = payload.get("name") or payload.get("tool") or "tool"
                        normalized_tool = str(tool_name).split(".")[-1]
                        raw_input = payload.get("input", payload.get("arguments", ""))
                        original_input = raw_input if isinstance(raw_input, str) else json.dumps(raw_input, ensure_ascii=False)
                        parsed_input = raw_input
                        if isinstance(raw_input, str):
                            try: parsed_input = json.loads(raw_input)
                            except Exception: pass
                        command = (parsed_input.get("cmd") or parsed_input.get("command") or original_input) if isinstance(parsed_input, dict) else original_input
                        input_text = original_input
                        text = "tool: " + str(tool_name) + "\n" + input_text
                        command = str(command).strip()
                        is_shell = normalized_tool in ("shell", "exec_command", "bash")
                        label = command.splitlines()[0][:200] if is_shell and command else normalized_tool
                        terminal_summary = "Running " + (label if is_shell else str(tool_name))
                        wrapper_source = "exec" if normalized_tool == "exec" else ("command" if normalized_tool in ("shell", "exec_command", "bash") else ("file" if normalized_tool == "apply_patch" else None))
                        call_id = payload.get("call_id") or payload.get("id")
                        if call_id:
                            parent = session_calls.get(str(parsed_input.get("session_id"))) if normalized_tool == "write_stdin" and isinstance(parsed_input, dict) else None
                            calls[str(call_id)] = {"record": None, "tool": normalized_tool, "command": command, "label": label, "parent": parent, "wrapperSource": wrapper_source}
                    elif payload_type in ("custom_tool_call_output", "function_call_output"):
                        kind = "tool_output"
                        output = payload.get("output", payload.get("result", ""))
                        text = output if isinstance(output, str) else json.dumps(output, ensure_ascii=False)
                        readable_output = text_from_content(output) if isinstance(output, list) else text
                        call_id = payload.get("call_id")
                        matched = calls.get(str(call_id)) if call_id else None
                        if matched:
                            import re
                            parsed = output if isinstance(output, dict) else None
                            if parsed is None and isinstance(output, str):
                                try: parsed = json.loads(output)
                                except Exception: pass
                            exit_code = parsed.get("exit_code") if isinstance(parsed, dict) else None
                            if exit_code is None and isinstance(parsed, dict) and isinstance(parsed.get("metadata"), dict):
                                exit_code = parsed["metadata"].get("exit_code")
                            if exit_code is None:
                                found = re.search(r"Process exited with code (-?\d+)", text)
                                if found: exit_code = int(found.group(1))
                            if isinstance(exit_code, (int, float)) and not isinstance(exit_code, bool):
                                exit_code = int(exit_code)
                            else:
                                exit_code = None
                            details = text
                            if isinstance(output, list):
                                details = readable_output
                            if isinstance(parsed, dict):
                                display_output = parsed.get("output", parsed.get("stdout"))
                                details = display_output if isinstance(display_output, str) else ""
                            elif isinstance(output, str):
                                transport = re.match(r"(?s)^(?:Chunk ID:|Wall time:|Process exited with code |Process running with session ID )", output)
                                if transport:
                                    final_output = re.search(r"(?m)^(?:Final output|Output):\s*", output)
                                    if final_output:
                                        details = output[final_output.end():]
                                    else:
                                        details = ""
                            running_match = re.search(r"Process running with session ID\s+(\S+)", text)
                            if session_id := (parsed.get("session_id") if isinstance(parsed, dict) else None):
                                pass
                            elif running_match:
                                session_id = running_match.group(1)
                            target = matched.get("parent") or matched
                            if session_id and matched["tool"] == "exec_command":
                                session_calls[str(session_id)] = matched
                                target["details"] = details
                                target["record"]["terminalSummary"] = "Running " + matched["label"]
                                target["record"]["terminalDetails"] = details[:12000]
                            elif matched["tool"] == "write_stdin" and matched.get("parent") is not None:
                                if exit_code is not None:
                                    prefix = "Ran " if int(exit_code) == 0 else "Failed (exit %s) " % exit_code
                                    target["record"]["terminalSummary"] = prefix + target["label"]
                                    previous = target.get("details", "")
                                    target["details"] = previous + (("\n" if previous and details else "") + details)
                                    target["record"]["terminalDetails"] = target["details"][-12000:]
                                else:
                                    target["record"]["terminalSummary"] = "Running " + target["label"]
                                    previous = target.get("details", "")
                                    target["details"] = previous + (("\n" if previous and details else "") + details)
                                    target["record"]["terminalDetails"] = target["details"][-12000:]
                            elif exit_code is None and isinstance(parsed, dict) and parsed.get("session_id"):
                                matched["record"]["terminalSummary"] = "Running " + (matched["command"] or matched["tool"])
                            elif matched["tool"] == "apply_patch":
                                succeeded = exit_code == 0 or (exit_code is None and ("Done!" in text or "Success" in text))
                                failed = (exit_code is not None and int(exit_code) != 0) or (isinstance(parsed, dict) and parsed.get("is_error") is True) or "Error:" in text
                                summary = "Edited %d files (+%d -%d)" % (len(matched["paths"]), matched["added"], matched["deleted"])
                                matched["record"]["terminalSummary"] = summary if succeeded else ("Failed: " + summary if failed else "Apply patch status unknown")
                                matched["record"]["terminalDetails"] = (matched["patch"] + ("\n" if matched["patch"] and details else "") + details)[:12000]
                            elif exit_code is not None:
                                prefix = "Ran " if int(exit_code) == 0 else "Failed (exit %s) " % exit_code
                                target["record"]["terminalSummary"] = prefix + target["label"]
                                target["record"]["terminalDetails"] = details[:12000]
                            else:
                                matched["record"]["terminalSummary"] = "Finished " + matched["tool"] + " (status unknown)"
                                matched["record"]["terminalDetails"] = details[:12000]
                            terminal_summary = None
                        else:
                            terminal_summary = readable_output.splitlines()[0][:200] if readable_output.strip() else "Tool completed"
                elif item.get("type") == "event_msg":
                    event_type = payload.get("type")
                    if event_type == "item_completed":
                        completed = payload.get("item") or {}
                        if isinstance(completed, dict):
                            completed_type = completed.get("type")
                            terminal_source = None
                            text = json.dumps(completed, ensure_ascii=False)
                            if completed_type == "CommandExecution":
                                kind = "tool_call"
                                label = command_label(completed.get("command"))
                                exit_code = completed.get("exit_code")
                                if isinstance(exit_code, (int, float)) and not isinstance(exit_code, bool):
                                    exit_code = int(exit_code)
                                    terminal_summary = ("Ran " if exit_code == 0 else "Failed (exit %s) " % exit_code) + label
                                elif completed.get("status") in ("completed", "complete"):
                                    terminal_summary = "Ran " + label
                                else:
                                    terminal_summary = "Finished command (status unknown)"
                                detail = completed.get("aggregated_output")
                                if not isinstance(detail, str):
                                    detail = "\n".join(part for part in (completed.get("stdout"), completed.get("stderr")) if isinstance(part, str) and part)
                                if not detail:
                                    detail = completed.get("formatted_output")
                                terminal_details = detail[:12000] if detail else None
                                terminal_source = "command"
                            elif completed_type == "FileChange":
                                kind = "tool_call"
                                changes = completed.get("changes") if isinstance(completed.get("changes"), dict) else {}
                                details = []
                                added = deleted = 0
                                for file_path, change in changes.items():
                                    if not isinstance(change, dict):
                                        continue
                                    change_type = str(change.get("type", "update")).lower()
                                    verb = "Add" if "add" in change_type or "create" in change_type else ("Delete" if "delete" in change_type or "remove" in change_type else "Update")
                                    diff = change.get("unified_diff") if isinstance(change.get("unified_diff"), str) else ""
                                    plus, minus = diff_counts(diff)
                                    added += plus
                                    deleted += minus
                                    details.append("*** %s File: %s\n%s" % (verb, file_path, diff))
                                terminal_summary = "Edited %d files (+%d -%d)" % (len(changes), added, deleted) if completed.get("status") in ("completed", "complete") else "File changes (status unknown)"
                                terminal_details = "\n".join(details)[:12000] if details else None
                                terminal_source = "file"
                            elif completed_type == "SubAgentActivity":
                                kind = "tool_call"
                                terminal_summary = "Interacted with " + str(completed.get("agent_path") or "subagent")
                            elif completed_type == "Reasoning":
                                summary = completed.get("summary_text", [])
                                summary_text = "\n".join(str(part.get("text", "")) if isinstance(part, dict) else str(part) for part in summary).strip() if isinstance(summary, list) else str(summary).strip()
                                if summary_text and summary_text not in reasoning_texts:
                                    kind = "reasoning"
                                    text = summary_text
                                    reasoning_texts.add(summary_text)
                                    terminal_summary = first_heading(summary_text)
                            if kind and text.strip():
                                record = {"kind": kind, "timestamp": timestamp, "text": text[:12000], "reasoningEffort": reasoning_effort, "model": model, "terminalSummary": terminal_summary, "terminalDetails": terminal_details, "_turn": turn_number, "_structured": terminal_source}
                                record["_syncId"] = str(line_number)
                                records.append(record)
                                if terminal_source:
                                    structured_by_turn.setdefault(turn_number, set()).add(terminal_source)
                                kind = None
                    elif event_type == "task_started":
                        turn_number += 1
                        reasoning_effort = None
                        model = None
                        last_assistant = None
                        last_usage = None
                        reasoning_texts = set()
                        kind, text = "task_started", "任务开始"
                        terminal_summary = text
                    elif event_type == "token_count":
                        info = payload.get("info") or {}
                        if isinstance(info, dict) and isinstance(info.get("last_token_usage"), dict):
                            last_usage = info["last_token_usage"]
                    elif event_type == "task_complete":
                        if last_assistant is not None and last_usage is not None:
                            last_assistant["tokenUsage"] = last_usage
                        kind, text = "task_complete", "任务完成"
                        terminal_summary = text
                    elif event_type == "turn_aborted":
                        kind, text = "turn_aborted", "任务中止：" + str(payload.get("reason", "未知原因"))
                        terminal_summary = text
                    elif event_type == "agent_reasoning":
                        summary = payload.get("text") or payload.get("summary")
                        if isinstance(summary, str) and summary.strip():
                            kind, text = "reasoning", summary.strip()
                            import re
                            heading = re.search(r"\*\*(.+?)\*\*", text)
                            terminal_summary = heading.group(1).strip() if heading else None
                            if text in reasoning_texts:
                                kind = None
                            else:
                                reasoning_texts.add(text)

                if kind and text.strip():
                    record = {
                        "kind": kind,
                        "timestamp": timestamp,
                        "text": text[:12000],
                        "reasoningEffort": reasoning_effort,
                        "model": model,
                        "terminalSummary": terminal_summary,
                        "terminalDetails": terminal_details,
                    }
                    if kind == "tool_call":
                        call_id = payload.get("call_id") or payload.get("id")
                        if call_id:
                            entry = calls[str(call_id)]
                            entry["record"] = record
                            entry["patch"] = text.split("\n", 1)[1] if entry["tool"] == "apply_patch" and "\n" in text else ""
                            import re
                            entry["paths"] = re.findall(r"(?m)^\*\*\*(?: Add| Update| Delete) File: (.+)$", entry["patch"])
                            entry["added"] = sum(1 for row in entry["patch"].splitlines() if row.startswith("+") and not row.startswith("+++"))
                            entry["deleted"] = sum(1 for row in entry["patch"].splitlines() if row.startswith("-") and not row.startswith("---"))
                            if entry["tool"] == "write_stdin":
                                record["terminalSummary"] = None
                                record["terminalDetails"] = None
                            elif entry["tool"] == "apply_patch":
                                record["terminalSummary"] = "Editing"
                                record["terminalDetails"] = entry["patch"][:12000]
                            if entry.get("wrapperSource"):
                                record["_wrapperSource"] = entry["wrapperSource"]
                                record["_turn"] = turn_number
                    record["_syncId"] = str(line_number)
                    records.append(record)
                    if kind == "assistant":
                        last_assistant = record
        for item in records:
            wrapper = item.get("_wrapperSource")
            available = structured_by_turn.get(item.get("_turn"), set())
            if (wrapper == "command" and "command" in available) or (wrapper == "file" and "file" in available) or (wrapper == "exec" and available.intersection(("command", "file"))):
                item["terminalSummary"] = None
                item["terminalDetails"] = None
            item.pop("_wrapperSource", None)
            item.pop("_turn", None)
            item.pop("_structured", None)
        for item in records[-300:]:
            print(json.dumps(item, ensure_ascii=False))
    except Exception:
        raise
    break
''';

  /// 终止 writer lock 持有进程，等待锁释放后返回。
  static const String _stopWriterScript = r'''import fcntl
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


thread_id = sys.argv[1]
codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser()
sessions_dir = codex_home / "sessions"
lock_path = codex_home / "thread-writer-locks" / f"{thread_id}.lock"


def output(ok, message):
    print(json.dumps({"ok": ok, "message": message}, ensure_ascii=False))


def turn_state():
    if not sessions_dir.is_dir():
        return "unknown"
    session_path = next(sessions_dir.rglob(f"*-{thread_id}.jsonl"), None)
    if session_path is None:
        return "unknown"

    last_task_type = None
    last_task_position = None
    last_user_position = None
    try:
        with session_path.open(encoding="utf-8") as stream:
            for position, line in enumerate(stream):
                try:
                    item = json.loads(line)
                except Exception:
                    continue
                if not isinstance(item, dict):
                    continue
                payload = item.get("payload", {})
                if not isinstance(payload, dict):
                    continue
                if item.get("type") == "event_msg" and payload.get("type") in (
                    "task_started", "task_complete", "turn_aborted"
                ):
                    last_task_type = payload.get("type")
                    last_task_position = position
                elif (
                    item.get("type") == "response_item"
                    and payload.get("type") == "message"
                    and payload.get("role") == "user"
                ):
                    last_user_position = position
    except Exception:
        return "unknown"

    if last_task_position is None:
        return "unknown"
    if last_user_position is not None and last_user_position > last_task_position:
        return "pending"
    if last_task_type == "task_complete":
        return "complete"
    if last_task_type == "task_started":
        return "running"
    return "aborted"


state = turn_state()
if state != "complete":
    output(False, f"最后一轮状态为 {state}，未执行 kill")
    raise SystemExit(0)


if not lock_path.exists():
    output(True, "没有发现活动的 writer lock")
    raise SystemExit(0)

lock_stream = None
try:
    lock_stream = lock_path.open("a+")
    try:
        fcntl.flock(lock_stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(lock_stream.fileno(), fcntl.LOCK_UN)
        output(True, "writer lock 当前未被占用")
        raise SystemExit(0)
    except BlockingIOError:
        pass
finally:
    if lock_stream is not None:
        lock_stream.close()


try:
    raw = subprocess.check_output(
        ["lsof", "-t", str(lock_path)],
        stderr=subprocess.DEVNULL,
        text=True,
    )
    pids = sorted({int(value) for value in raw.split() if value.isdigit()})
except Exception:
    pids = []

if not pids:
    output(False, "writer lock 正在占用，但找不到持有进程；未执行 kill")
    raise SystemExit(0)

for pid in pids:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except OSError as error:
        output(False, f"无法终止 PID {pid}: {error}")
        raise SystemExit(0)

deadline = time.time() + 5
while time.time() < deadline:
    try:
        with lock_path.open("a+") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
            output(True, "writer 已终止，writer lock 已释放")
            raise SystemExit(0)
    except BlockingIOError:
        time.sleep(0.2)
    except OSError:
        time.sleep(0.2)

output(False, "writer lock 在 5 秒内没有释放；未启动新的 resume")
''';
}
