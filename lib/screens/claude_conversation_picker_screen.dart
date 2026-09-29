import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import '../models/ssh_connection.dart';
import '../services/claude_runtime_service.dart';
import '../services/claude_session_service.dart';
import '../services/codex_session_service.dart';
import '../services/ssh_service.dart';
import 'tmux_workspace_screen.dart';

class ClaudeConversationPickerScreen extends StatefulWidget {
  final SshConnection connection;
  final Future<RemoteDirectoryListing> Function(String path)? loadDirectories;

  const ClaudeConversationPickerScreen({
    super.key,
    required this.connection,
    this.loadDirectories,
  });

  @override
  State<ClaudeConversationPickerScreen> createState() =>
      _ClaudeConversationPickerScreenState();
}

class _ClaudeConversationPickerScreenState
    extends State<ClaudeConversationPickerScreen> {
  late final Future<void> _connectFuture;
  Future<_ClaudeSnapshot>? _snapshotFuture;
  Map<String, ClaudeRuntimeSession> _runtime = const {};
  bool _runtimeErrorShown = false;

  String get _favoriteConversationsKey =>
      'claude_favorites_${widget.connection.id}';
  String get _favoriteDirectoriesKey =>
      'claude_favorite_directories_${widget.connection.id}';
  String get _filteredDirectoriesKey =>
      'claude_filtered_directories_${widget.connection.id}';
  String get _openAsChatKey => 'claude_open_as_chat_${widget.connection.id}';

  @override
  void initState() {
    super.initState();
    _connectFuture = SshService.connectClient(widget.connection);
  }

  Set<String> _readSet(String key) {
    if (!Hive.isBoxOpen('settings')) return {};
    final value = Hive.box('settings').get(key);
    if (value is Iterable) return value.whereType<String>().toSet();
    return {};
  }

  Future<void> _saveSet(String key, Set<String> values) async {
    if (Hive.isBoxOpen('settings')) {
      await Hive.box('settings').put(key, values.toList());
    }
  }

  bool get _openAsChat {
    if (!Hive.isBoxOpen('settings')) return true;
    return Hive.box('settings').get(_openAsChatKey) != false;
  }

  Future<RemoteDirectoryListing> _loadDirectories(String path) async {
    await _connectFuture;
    return widget.loadDirectories?.call(path) ??
        RemoteDirectoryService.list(widget.connection.id, path);
  }

  Future<_ClaudeSnapshot> _loadSnapshot() {
    final pending = _snapshotFuture;
    if (pending != null) return pending;
    late final Future<_ClaudeSnapshot> request;
    request = _fetchSnapshot().whenComplete(() {
      if (identical(_snapshotFuture, request)) _snapshotFuture = null;
    });
    _snapshotFuture = request;
    return request;
  }

  Future<_ClaudeSnapshot> _fetchSnapshot() async {
    await _connectFuture;
    final historyFuture = ClaudeSessionService.listAll(widget.connection.id);
    Map<String, ClaudeRuntimeSession>? loadedRuntime;
    Object? runtimeError;
    final runtimeFuture =
        ClaudeRuntimeService.listSessions(widget.connection.id).then<void>(
            (sessions) => loadedRuntime = sessions,
            onError: (Object error) => runtimeError = error);
    final history = await historyFuture;
    await runtimeFuture;
    Map<String, ClaudeRuntimeSession> runtime = _runtime;
    if (runtimeError == null) {
      runtime = loadedRuntime!;
      _runtimeErrorShown = false;
      if (mounted) setState(() => _runtime = runtime);
    } else {
      if (mounted && !_runtimeErrorShown) {
        _runtimeErrorShown = true;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Claude 运行状态读取失败，历史记录仍可查看：$runtimeError')),
        );
      }
    }

    final conversations = <String, CodexConversation>{};
    for (final item in history) {
      final active = runtime[item.id];
      conversations[item.id] = CodexConversation(
        id: item.id,
        cwd: item.cwd.isNotEmpty ? item.cwd : active?.workDir ?? '',
        updatedAt: active?.updatedAt ?? item.updatedAt,
        completedAt: item.completedAt,
        title: item.title,
        state: _stateFor(item.state, active),
        directoryExists: item.directoryExists,
        preview: item.preview,
      );
    }
    for (final session in runtime.values) {
      conversations.putIfAbsent(
        session.sessionId,
        () => CodexConversation(
          id: session.sessionId,
          cwd: session.workDir,
          updatedAt: session.updatedAt,
          title:
              'Claude 对话 ${session.sessionId.substring(0, session.sessionId.length > 8 ? 8 : session.sessionId.length)}',
          state: _stateFor(CodexConversationState.notStarted, session),
        ),
      );
    }
    final merged = conversations.values.toList()
      ..sort((a, b) => (b.updatedAt ?? DateTime(1970))
          .compareTo(a.updatedAt ?? DateTime(1970)));
    return _ClaudeSnapshot(merged, runtime);
  }

  CodexConversationState _stateFor(
      CodexConversationState historical, ClaudeRuntimeSession? session) {
    if (session == null || !session.isAlive) return historical;
    return switch (session.status) {
      'busy' => CodexConversationState.running,
      'ready' => historical,
      'starting' || 'awaiting_input' => CodexConversationState.pending,
      _ => historical,
    };
  }

  Future<List<CodexConversation>> _loadAllConversations() async =>
      (await _loadSnapshot()).conversations;

  Future<List<CodexConversation>> _loadForDirectory(String path) async {
    final all = await _loadAllConversations();
    return all
        .where((item) =>
            item.cwd == path ||
            item.cwd.startsWith(path == '/' ? '/' : '$path/'))
        .toList();
  }

  Future<List<OpenedCodexSession>> _loadOpenedSessions() async {
    final snapshot = await _loadSnapshot();
    return snapshot.runtime.values
        .where((session) => session.isAlive)
        .map((session) => OpenedCodexSession(
              name: session.tmuxSession,
              workDir: session.workDir,
              conversationId: session.sessionId,
              activity: session.status,
            ))
        .toList();
  }

  Future<void> _createConversation(bool openAsChat) async {
    final options =
        await showDialog<({String cwd, String? model, String? effort})>(
      context: context,
      builder: (_) => const _NewClaudeConversationDialog(),
    );
    if (options == null || !mounted) return;
    try {
      await _connectFuture;
      final session = await ClaudeRuntimeService.ensureSession(
        widget.connection.id,
        sessionId: const Uuid().v4(),
        workDir: options.cwd,
        resume: false,
        model: options.model,
        effort: options.effort,
      );
      if (!mounted) return;
      if (openAsChat) {
        await _view(CodexConversation(
          id: session.sessionId,
          cwd: session.workDir,
          title: '新对话',
          updatedAt: session.updatedAt,
        ));
      } else {
        await _openTerminal(session);
      }
      await _loadSnapshot();
    } catch (error) {
      if (mounted) _showError('启动 Claude 对话失败：$error');
    }
  }

  Future<void> _continueConversation(
      CodexConversation conversation, bool openAsChat) async {
    try {
      await _connectFuture;
      final session = await ClaudeRuntimeService.ensureSession(
        widget.connection.id,
        sessionId: conversation.id,
        workDir: conversation.cwd,
        resume: true,
      );
      if (!mounted) return;
      if (openAsChat) {
        await _view(CodexConversation(
          id: conversation.id,
          cwd: session.workDir,
          updatedAt: session.updatedAt ?? conversation.updatedAt,
          completedAt: conversation.completedAt,
          title: conversation.title,
          state: conversation.state,
          directoryExists: conversation.directoryExists,
          preview: conversation.preview,
        ));
      } else {
        await _openTerminal(session);
      }
      await _loadSnapshot();
    } catch (error) {
      if (mounted) _showError('继续 Claude 对话失败：$error');
    }
  }

  Future<void> _view(CodexConversation conversation) => showDialog<void>(
        context: context,
        builder: (_) => CodexConversationViewerDialog(
          isClaude: true,
          connectionId: widget.connection.id,
          conversation: conversation,
          loadRecords: (id) async {
            await _connectFuture;
            return ClaudeSessionService.readConversation(
                widget.connection.id, id);
          },
        ),
      );

  Future<void> _openTerminal(ClaudeRuntimeSession session) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TmuxWorkspaceScreen(
        connection: widget.connection,
        initialSessionName: session.tmuxSession,
        initialConversationId: session.sessionId,
      ),
    ));
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => CodexSessionDialog(
        connectionId: widget.connection.id,
        isClaude: true,
        defaultName: 'claude-1',
        defaultWorkDir: '~',
        dialogTitle: '选择 Claude 对话',
        loadConversations: _loadForDirectory,
        loadAllConversations: _loadAllConversations,
        startWithAllConversations: true,
        initialConversations: const [],
        loadRecords: (id) async {
          await _connectFuture;
          return ClaudeSessionService.readConversation(
              widget.connection.id, id);
        },
        loadDirectories: _loadDirectories,
        loadOpenedSessions: _loadOpenedSessions,
        onCreateConversation: _createConversation,
        onContinueConversation: _continueConversation,
        initialFavoriteConversations: _readSet(_favoriteConversationsKey),
        initialFavoriteDirectories: _readSet(_favoriteDirectoriesKey),
        initialFilteredDirectories: _readSet(_filteredDirectoriesKey),
        saveFavoriteConversations: (connectionId, values) =>
            _saveSet(_favoriteConversationsKey, values),
        saveFavoriteDirectories: (connectionId, values) =>
            _saveSet(_favoriteDirectoriesKey, values),
        saveFilteredDirectories: (connectionId, values) =>
            _saveSet(_filteredDirectoriesKey, values),
        initialOpenAsChat: _openAsChat,
        onOpenModeChanged: (value) => Hive.isBoxOpen('settings')
            ? unawaited(Hive.box('settings').put(_openAsChatKey, value))
            : null,
      );
}

class _ClaudeSnapshot {
  final List<CodexConversation> conversations;
  final Map<String, ClaudeRuntimeSession> runtime;

  const _ClaudeSnapshot(this.conversations, this.runtime);
}

class _NewClaudeConversationDialog extends StatefulWidget {
  const _NewClaudeConversationDialog();

  @override
  State<_NewClaudeConversationDialog> createState() =>
      _NewClaudeConversationDialogState();
}

class _NewClaudeConversationDialogState
    extends State<_NewClaudeConversationDialog> {
  final _directory = TextEditingController(text: '~');
  final _model = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String? _effort;

  @override
  void dispose() {
    _directory.dispose();
    _model.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('新建 Claude 对话'),
        content: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: _directory,
              decoration: const InputDecoration(labelText: '远程目录'),
              validator: (value) =>
                  value == null || value.trim().isEmpty ? '请输入远程目录' : null,
            ),
            TextField(
              controller: _model,
              decoration: const InputDecoration(labelText: '模型（可选）'),
            ),
            DropdownButtonFormField<String?>(
              initialValue: _effort,
              decoration: const InputDecoration(labelText: '思考强度'),
              items: const [
                DropdownMenuItem(value: null, child: Text('默认')),
                DropdownMenuItem(value: 'low', child: Text('low')),
                DropdownMenuItem(value: 'medium', child: Text('medium')),
                DropdownMenuItem(value: 'high', child: Text('high')),
                DropdownMenuItem(value: 'xhigh', child: Text('xhigh')),
                DropdownMenuItem(value: 'max', child: Text('max')),
              ],
              onChanged: (value) => setState(() => _effort = value),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (_formKey.currentState!.validate()) {
                Navigator.pop(context, (
                  cwd: _directory.text.trim(),
                  model: _model.text.trim().isEmpty ? null : _model.text.trim(),
                  effort: _effort,
                ));
              }
            },
            child: const Text('开始'),
          ),
        ],
      );
}
