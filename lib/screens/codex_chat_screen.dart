import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/ssh_connection.dart';
import '../services/codex_chat_service.dart';
import '../services/codex_session_service.dart';
import '../services/remote_image_service.dart';
import '../services/remote_html_preview_service.dart';
import '../services/notification_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/chat_markdown.dart';
import '../widgets/codex_goal_card.dart';
import 'remote_html_preview_screen.dart';
import 'remote_file_preview_screen.dart';

class CodexChatScreen extends StatefulWidget {
  final SshConnection connection;
  final String workDir;
  final CodexConversation? conversation;
  final String? runningJobId;
  final bool favoriteOnCreate;
  final bool forkOnFirstSend;
  final Future<CodexChatResult> Function(String prompt)? sendMessage;
  final Future<void> Function(String threadId)? onConversationCreated;
  final Future<CodexChatResult> Function(String jobId)? watchRunningJob;
  final Future<CodexRemoteSessionStatus> Function(String threadId)?
      getRemoteSession;
  final Future<void> Function(String threadId)? closeRemoteSession;

  const CodexChatScreen({
    super.key,
    required this.connection,
    required this.workDir,
    this.conversation,
    this.runningJobId,
    this.favoriteOnCreate = false,
    this.forkOnFirstSend = false,
    this.sendMessage,
    this.onConversationCreated,
    this.watchRunningJob,
    this.getRemoteSession,
    this.closeRemoteSession,
  });

  @override
  State<CodexChatScreen> createState() => _CodexChatScreenState();
}

class _CodexChatScreenState extends State<CodexChatScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _scroll = ScrollController();
  List<CodexConversationRecord> _records = const [];
  List<CodexConversationRecord> _archivedRecords = const [];
  String? _threadId;
  String? _error;
  bool _loading = false;
  bool _sending = false;
  bool _remoteSessionOpen = false;
  bool _remoteSessionClosedByUser = false;
  bool _closingRemoteSession = false;
  int _remoteSessionRequest = 0;
  bool _forkPending = false;
  bool _contextCleared = false;
  bool _clearPending = false;
  bool _topMenuOpen = false;
  TextEditingValue? _draftBeforeTopMenu;
  double _keyboardInset = 0;
  int _historyRequest = 0;
  final List<String> _queuedPrompts = [];
  bool _showMessageTime = true;
  bool _showTokenUsage = false;
  String _streamedAnswer = '';
  String _activity = '';
  DateTime? _turnStartedAt;
  int? _lastTurnDurationSeconds;
  Timer? _elapsedTimer;
  Timer? _streamRefresh;
  List<CodexModel> _models = const [];
  String _model = CodexChatService.defaultModel;
  String _effort = 'medium';
  final Map<String, Future<Uint8List>> _imageLoads = {};
  late final String _detachedConnectionId;
  late final String _detachedWorkDir;
  late final Future<CodexChatResult> Function(String)? _detachedSendMessage;
  late final bool _favoriteOnCreate;
  late final Future<void> Function(String)? _onConversationCreated;

  Future<Uint8List> _loadImage(String path) =>
      _imageLoads.putIfAbsent(path, () {
        if (_imageLoads.length >= 24) {
          _imageLoads.remove(_imageLoads.keys.first);
        }
        return RemoteImageService.read(
          connectionId: widget.connection.id,
          workDir: widget.conversation?.cwd ?? widget.workDir,
          path: path,
        );
      });

  String get _title {
    if (!_contextCleared && widget.conversation != null) {
      return widget.conversation!.displayTitle;
    }
    for (final record in _records) {
      if (record.kind == 'user' && record.text.trim().isNotEmpty) {
        final text = record.text.trim().replaceAll('\n', ' ');
        return text.length > 24 ? '${text.substring(0, 24)}…' : text;
      }
    }
    return '新对话';
  }

  String get _workDir => widget.conversation?.cwd ?? widget.workDir;

  String get _remoteSessionLabel {
    if (_closingRemoteSession) return '正在关闭远程会话…';
    if (_remoteSessionOpen) return '等待消息·远程已打开';
    if (_remoteSessionClosedByUser) return '等待消息·远程已关闭';
    return '等待消息·远程状态待确认';
  }

  String _compactWorkDir(BuildContext context, double width, TextStyle style) {
    final path = _workDir;
    bool fits(String value) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: style),
        textDirection: Directionality.of(context),
      )..layout();
      final result = painter.width <= width;
      painter.dispose();
      return result;
    }

    if (fits(path) || !path.contains('/')) return path;
    final tail = path.split('/').where((part) => part.isNotEmpty).last;
    final short = '${path.startsWith('/') ? '/' : ''}…/$tail';
    return fits(short) ? short : '…/$tail';
  }

  String? get _readOnlyReason {
    if (_contextCleared) return null;
    final conversation = widget.conversation;
    if (conversation?.isSubagent == true) {
      return conversation!.recoveryReason;
    }
    if (conversation?.directoryExists == false) {
      return conversation!.recoveryReason;
    }
    return null;
  }

  bool _isVisibleChatRecord(CodexConversationRecord record) {
    if (record.kind == 'assistant') return true;
    if (record.kind != 'user') return false;
    final text = record.text.trimLeft();
    return !text.startsWith('<environment_context>') &&
        !text.startsWith('<recommended_plugins>') &&
        !text.startsWith('<heartbeat>') &&
        !text.startsWith('<turn_aborted>') &&
        !text.startsWith('# AGENTS.md instructions');
  }

  @override
  void initState() {
    super.initState();
    _detachedConnectionId = widget.connection.id;
    _detachedWorkDir = widget.workDir;
    _detachedSendMessage = widget.sendMessage;
    _favoriteOnCreate = widget.favoriteOnCreate;
    _onConversationCreated = widget.onConversationCreated;
    WidgetsBinding.instance.addObserver(this);
    _input.addListener(_restoreMenuDraft);
    _keyboardInset = WidgetsBinding
            .instance.platformDispatcher.views.firstOrNull?.viewInsets.bottom ??
        0;
    _threadId = widget.conversation?.id;
    if (_threadId != null) {
      _records = (CodexSessionService.cachedRecords(
                  widget.connection.id, _threadId!) ?? const [])
          .where(_isVisibleChatRecord)
          .toList();
      if (_records.isNotEmpty) _scrollToEnd();
      unawaited(StorageService.addOpenedCodexConversation(
          widget.connection.id, _threadId!));
      unawaited(NotificationService.markCodexConversationViewed(
          widget.connection.id, _threadId!));
    }
    _forkPending = widget.forkOnFirstSend;
    _showTokenUsage = StorageService.getCodexShowTokenUsage();
    _showMessageTime = StorageService.getCodexShowMessageTime();
    if (_threadId != null) {
      if (_forkPending) {
        unawaited(_loadHistory());
      } else if (widget.runningJobId != null) {
        _sending = true;
        unawaited(
            _loadHistory().then((_) => _watchRunningJob(widget.runningJobId!)));
      } else {
        unawaited(_loadHistory().then((_) => _recoverRunningTurn()));
      }
      if (!_forkPending) unawaited(_refreshRemoteSession());
    }
    unawaited(_loadModels());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamRefresh?.cancel();
    _elapsedTimer?.cancel();
    _inputFocus.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    final inset = WidgetsBinding
            .instance.platformDispatcher.views.firstOrNull?.viewInsets.bottom ??
        0;
    if (inset > _keyboardInset && _inputFocus.hasFocus) _scrollToEnd();
    _keyboardInset = inset;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshRemoteSession());
    }
  }

  Future<void> _refreshRemoteSession() async {
    final threadId = _threadId;
    if (threadId == null || _sending || _forkPending || _closingRemoteSession) {
      return;
    }
    final request = ++_remoteSessionRequest;
    try {
      final status = await (widget.getRemoteSession?.call(threadId) ??
          CodexChatService.getRemoteSession(widget.connection.id, threadId));
      if (!mounted ||
          _threadId != threadId ||
          request != _remoteSessionRequest ||
          _sending ||
          _forkPending) {
        return;
      }
      setState(() {
        _remoteSessionOpen = status.open;
        if (status.open) _remoteSessionClosedByUser = false;
      });
    } catch (_) {
      // Older remote workers do not expose persistent session state.
    }
  }

  Future<void> _closeRemoteSession() async {
    final threadId = _threadId;
    if (threadId == null || !_remoteSessionOpen || _sending || _forkPending || _closingRemoteSession) {
      return;
    }
    _remoteSessionRequest++;
    setState(() => _closingRemoteSession = true);
    try {
      await (widget.closeRemoteSession?.call(threadId) ??
          CodexChatService.closeRemoteSession(widget.connection.id, threadId));
      if (mounted) {
        setState(() {
          if (_threadId == threadId) {
            _remoteSessionOpen = false;
            _remoteSessionClosedByUser = true;
          }
          _closingRemoteSession = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _closingRemoteSession = false;
          _error = '关闭远程会话失败：$error';
        });
      }
    }
  }

  Future<void> _loadHistory() async {
    final id = _threadId;
    if (id == null) return;
    final request = ++_historyRequest;
    setState(() => _loading = true);
    try {
      final records = await CodexSessionService.readConversation(
        widget.connection.id,
        id,
      );
      if (!mounted || request != _historyRequest) return;
      final followLatest = !_scroll.hasClients ||
          _scroll.position.extentAfter < 80;
      setState(() {
        _records = [
          ..._archivedRecords,
          ...records.where(_isVisibleChatRecord),
        ];
        _loading = false;
        _error = null;
      });
      if (followLatest) _scrollToEnd();
    } catch (error) {
      if (!mounted || request != _historyRequest) return;
      setState(() {
        _loading = false;
        _error = '读取对话失败：$error';
      });
    }
  }

  Future<void> _loadModels() async {
    try {
      final models = await CodexChatService.listModels(widget.connection.id);
      if (!mounted) return;
      setState(() {
        _models = models;
        if (models.isNotEmpty && !models.any((model) => model.id == _model)) {
          final selected =
              models.where((model) => model.isDefault).firstOrNull ??
                  models.first;
          _model = selected.id;
          _effort = selected.defaultEffort;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _error = '读取远端模型失败：$error');
    }
  }

  Future<void> _chooseModel(String modelId) async {
    final model = _models.where((item) => item.id == modelId).firstOrNull;
    if (model == null || _sending) return;
    final efforts = model.efforts.isEmpty
        ? [CodexReasoningEffort(model.defaultEffort, '')]
        : model.efforts;
    final current = efforts.any((effort) => effort.id == _effort)
        ? _effort
        : model.defaultEffort;
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: (efforts.length * 64 + 68).toDouble().clamp(
                160.0,
                MediaQuery.sizeOf(context).height * 0.75,
              ),
          child: Column(
            children: [
              ListTile(title: Text('${model.name} · 选择思考级别')),
              Expanded(
                child: ListView.builder(
                  itemCount: efforts.length,
                  itemBuilder: (context, index) {
                    final effort = efforts[index];
                    return ListTile(
                      title: Text(effort.id),
                      subtitle: effort.description.isEmpty
                          ? null
                          : Text(effort.description,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: effort.id == current
                          ? Icon(Icons.check, color: AppTheme.blue)
                          : null,
                      onTap: () => Navigator.of(context).pop(effort.id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _model = model.id;
        _effort = selected;
      });
    }
  }

  void _scrollToEnd() {
    if (_topMenuOpen) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_topMenuOpen && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _restoreMenuDraft() {
    final draft = _draftBeforeTopMenu;
    if (_topMenuOpen &&
        draft != null &&
        draft.text.isNotEmpty &&
        _input.text.isEmpty) {
      _input.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length),
      );
    }
  }

  void _finishTopMenu() {
    _topMenuOpen = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final draft = _draftBeforeTopMenu;
      if (mounted &&
          draft != null &&
          draft.text.isNotEmpty &&
          _input.text.isEmpty) {
        _input.value = TextEditingValue(
          text: draft.text,
          selection: TextSelection.collapsed(offset: draft.text.length),
        );
      }
      _draftBeforeTopMenu = null;
    });
  }

  void _updateStreamedAnswer(String text) {
    _streamedAnswer = text;
    _refreshStream();
  }

  void _updateActivity(String text) {
    _activity = text;
    _refreshStream();
  }

  void _setTurnStartedAt(DateTime startedAt) {
    _turnStartedAt = startedAt;
    _refreshStream();
  }

  void _startElapsedTimer() {
    _turnStartedAt ??= DateTime.now();
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _sending) setState(() {});
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  String _formatDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    if (minutes < 60) return '${minutes}m ${remainder}s';
    return '${minutes ~/ 60}h ${minutes % 60}m ${remainder}s';
  }

  void _refreshStream() {
    if (!mounted || _streamRefresh != null) return;
    _streamRefresh = Timer(const Duration(milliseconds: 60), () {
      _streamRefresh = null;
      if (mounted) {
        final followLatest = _scroll.hasClients &&
            _scroll.position.extentAfter < 80;
        setState(() {});
        if (followLatest) _scrollToEnd();
      }
    });
  }

  Future<void> _recoverRunningTurn() async {
    final threadId = _threadId;
    if (threadId == null || _sending) return;
    try {
      final jobId = await CodexChatService.findRunningJob(
        widget.connection.id,
        threadId,
      );
      if (!mounted || jobId == null || _threadId != threadId) return;
      await _watchRunningJob(jobId);
    } catch (error) {
      if (mounted) setState(() => _error = '读取远端任务失败：$error');
    }
  }

  Future<void> _watchRunningJob(String jobId) async {
    if (!mounted || _threadId == null) return;
    _remoteSessionRequest++;
    if (!_sending) setState(() => _sending = true);
    _activity = '';
    _turnStartedAt = null;
    _startElapsedTimer();
    try {
      final result = await (widget.watchRunningJob?.call(jobId) ??
          CodexChatService.watchJob(
            connectionId: widget.connection.id,
            jobId: jobId,
            onUpdate: _updateStreamedAnswer,
            onActivity: _updateActivity,
            onStartedAt: _setTurnStartedAt,
          ));
      _stopElapsedTimer();
      if (!mounted) {
        unawaited(_drainDetachedQueue(result.threadId));
        return;
      }
      unawaited(NotificationService.markCodexConversationViewed(
          widget.connection.id, result.threadId));
      _streamRefresh?.cancel();
      _streamRefresh = null;
      setState(() {
        _sending = false;
        _streamedAnswer = '';
        _lastTurnDurationSeconds = result.durationSeconds ??
            DateTime.now().difference(_turnStartedAt!).inSeconds;
      });
      await _loadHistory();
      unawaited(_refreshRemoteSession());
      _sendNextQueued();
    } catch (error) {
      _stopElapsedTimer();
      if (!mounted) return;
      _streamRefresh?.cancel();
      _streamRefresh = null;
      setState(() {
        _sending = false;
        _streamedAnswer = '';
        _error = '读取远端任务失败：$error';
        _clearPending = false;
      });
    }
  }

  Future<void> _send() async {
    final prompt = _input.text.trim();
    if (prompt.isEmpty || _readOnlyReason != null || _closingRemoteSession) return;
    if (prompt == '/clear') {
      _input.clear();
      _requestClearContext();
      return;
    }
    if (_clearPending) return;
    if (_sending) {
      _input.clear();
      setState(() => _queuedPrompts.add(prompt));
      return;
    }
    _input.clear();
    await _sendPrompt(prompt);
  }

  Future<void> _sendPrompt(String prompt) async {
    final creatingConversation = _threadId == null;
    _remoteSessionRequest++;
    setState(() {
      _sending = true;
      _streamedAnswer = '';
      _activity = '';
      _turnStartedAt = DateTime.now();
      _lastTurnDurationSeconds = null;
      _error = null;
      _records = [
        ..._records,
        CodexConversationRecord(
          kind: 'user',
          timestamp: DateTime.now(),
          text: prompt,
        ),
      ];
    });
    _scrollToEnd();
    _startElapsedTimer();
    try {
      final result = await (widget.sendMessage?.call(prompt) ??
          CodexChatService.send(
            connectionId: widget.connection.id,
            workDir: widget.workDir,
            prompt: prompt,
            title: creatingConversation ? prompt : _title,
            threadId: _threadId,
            fork: _forkPending,
            model: _model,
            reasoningEffort: _effort,
            onUpdate: _updateStreamedAnswer,
            onActivity: _updateActivity,
            onStartedAt: _setTurnStartedAt,
          ));
      unawaited(StorageService.addOpenedCodexConversation(
          _detachedConnectionId, result.threadId));
      if (mounted) {
        unawaited(NotificationService.markCodexConversationViewed(
            _detachedConnectionId, result.threadId));
      }
      _stopElapsedTimer();
      if (creatingConversation && _favoriteOnCreate) {
        _favoriteCreatedConversation(result.threadId);
      }
      if (!mounted) {
        unawaited(_drainDetachedQueue(result.threadId));
        return;
      }
      _streamRefresh?.cancel();
      _streamRefresh = null;
      final followLatest = _scroll.hasClients &&
          _scroll.position.extentAfter < 80;
      setState(() {
        _threadId = result.threadId;
        _remoteSessionOpen = true;
        _remoteSessionClosedByUser = false;
        _forkPending = false;
        _sending = false;
        _streamedAnswer = '';
        _lastTurnDurationSeconds = result.durationSeconds ??
            DateTime.now().difference(_turnStartedAt!).inSeconds;
        if (result.answer.isNotEmpty) {
          _records = [
            ..._records,
            CodexConversationRecord(
              kind: 'assistant',
              timestamp: DateTime.now(),
              text: result.answer,
            ),
          ];
        }
      });
      if (followLatest) _scrollToEnd();
      if (widget.sendMessage == null) await _loadHistory();
      _sendNextQueued();
    } catch (error) {
      _stopElapsedTimer();
      if (!mounted) return;
      _streamRefresh?.cancel();
      _streamRefresh = null;
      if (_input.text.isEmpty) _input.text = prompt;
      setState(() {
        _sending = false;
        _streamedAnswer = '';
        _error = error.toString();
        _clearPending = false;
      });
      if (_threadId != null) unawaited(_loadHistory());
    }
  }

  void _favoriteCreatedConversation(String threadId) {
    final callback = _onConversationCreated;
    if (callback != null) {
      unawaited(callback(threadId));
      return;
    }
    final favorites =
        StorageService.getFavoriteCodexConversations(_detachedConnectionId);
    favorites.add(threadId);
    unawaited(StorageService.setFavoriteCodexConversations(
        _detachedConnectionId, favorites));
  }

  void _sendNextQueued() {
    if (!mounted || _sending) return;
    if (_queuedPrompts.isEmpty) {
      if (_clearPending) _clearContextNow();
      return;
    }
    final next = _queuedPrompts.removeAt(0);
    setState(() {});
    unawaited(_sendPrompt(next));
  }

  void _requestClearContext() {
    if (_sending || _queuedPrompts.isNotEmpty) {
      setState(() => _clearPending = true);
      if (!_sending) _sendNextQueued();
      return;
    }
    _clearContextNow();
  }

  void _clearContextNow() {
    _historyRequest++;
    setState(() {
      _archivedRecords = [
        ..._records,
        CodexConversationRecord(
          kind: 'context_clear',
          timestamp: DateTime.now(),
          text: '上下文已清空 · 后续消息将作为新对话',
        ),
      ];
      _contextCleared = true;
      _clearPending = false;
      _threadId = null;
      _remoteSessionOpen = false;
      _remoteSessionClosedByUser = false;
      _remoteSessionRequest++;
      _forkPending = false;
      _records = _archivedRecords;
      _loading = false;
      _streamedAnswer = '';
      _activity = '';
      _error = null;
      _turnStartedAt = null;
      _lastTurnDurationSeconds = null;
    });
  }

  Future<void> _drainDetachedQueue(String threadId) async {
    var currentThreadId = threadId;
    while (_queuedPrompts.isNotEmpty) {
      final prompt = _queuedPrompts.first;
      try {
        final result = await (_detachedSendMessage?.call(prompt) ??
            CodexChatService.send(
              connectionId: _detachedConnectionId,
              workDir: _detachedWorkDir,
              prompt: prompt,
              title: _title,
              threadId: currentThreadId,
              model: _model,
              reasoningEffort: _effort,
            ));
        currentThreadId = result.threadId;
        _queuedPrompts.removeAt(0);
      } catch (_) {
        return;
      }
    }
  }

  void _leave() {
    Navigator.of(context).pop();
  }

  Future<void> _showImage(String path) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showDialog<void>(
      context: context,
      builder: (context) {
        final content = SafeArea(
          child: Column(
            children: [
              ListTile(
                title: Text(path.split('/').last,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(path,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              Flexible(
                child: FutureBuilder(
                  future: _loadImage(path),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text('无法读取远端图片：${snapshot.error}'),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Padding(
                        padding: EdgeInsets.all(32),
                        child: CircularProgressIndicator(),
                      );
                    }
                    return InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 6,
                      child: Image.memory(
                        snapshot.data!,
                        width: double.infinity,
                        height: double.infinity,
                        fit: BoxFit.contain,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
        return MediaQuery.sizeOf(context).shortestSide < 600
            ? Dialog.fullscreen(child: content)
            : Dialog(
                child: SizedBox(width: 1100, height: 800, child: content),
              );
      },
    );
  }

  Future<void> _showImageList(List<String> paths) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.7,
        child: Column(
          children: [
            ListTile(title: Text('图片列表 · ${paths.length} 张')),
            Expanded(
              child: ListView.builder(
                itemCount: paths.length,
                itemBuilder: (context, index) {
                  final path = paths[index];
                  return ListTile(
                    leading: const Icon(Icons.image_outlined),
                    title: Text(path.split('/').last),
                    subtitle: path.contains('/')
                        ? Text(path,
                            maxLines: 1, overflow: TextOverflow.ellipsis)
                        : null,
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _showImage(path);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _markdown(String text) => ChatMarkdown(text,
    onTapLink: (_, href, __) => openRemoteFileLink(context,
      connectionId: widget.connection.id, workDir: _workDir, href: href));

  List<Widget> _messageContent(String text, bool isUser) {
    if (isUser) return [_markdown(text)];
    final references = RemoteImageService.inlineReferences(text);
    if (references.isEmpty) return [_markdown(text)];
    final linked = references.where((reference) => !reference.embedded).toList();
    if (references.length >= 3) {
      return [
        _markdown(text),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            onPressed: () => _showImageList(
                references.map((reference) => reference.path).toList()),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text('查看图片列表 · ${references.length} 张'),
          ),
        ),
      ];
    }
    final embedded = references.where((reference) => reference.embedded).toList();
    final content = <Widget>[];
    var start = 0;
    for (final reference in embedded) {
      final before = text.substring(start, reference.end);
      if (before.trim().isNotEmpty) content.add(_markdown(before));
      content.add(_imagePreview(reference.path));
      start = reference.end;
    }
    final remaining = text.substring(start);
    if (remaining.trim().isNotEmpty) content.add(_markdown(remaining));
    if (linked.isNotEmpty) {
      content.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: OutlinedButton.icon(
          onPressed: () => _showImageList(
              linked.map((reference) => reference.path).toList()),
          icon: const Icon(Icons.photo_library_outlined),
          label: Text('查看图片列表 · ${linked.length} 张'),
        ),
      ));
    }
    return content;
  }

  Widget _imagePreview(String path) => Padding(
        key: ValueKey('inline-image-$path'),
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(path.split('/').last,
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            FutureBuilder<Uint8List>(
              future: _loadImage(path),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return snapshot.hasError
                      ? TextButton.icon(
                          onPressed: () => _showImage(path),
                          icon: const Icon(Icons.broken_image_outlined),
                          label: const Text('无法加载图片，点击重试'),
                        )
                      : const SizedBox(
                          height: 48,
                          width: 48,
                          child: Center(child: CircularProgressIndicator()),
                        );
                }
                return InkWell(
                  onTap: () => _showImage(path),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      snapshot.data!,
                      width: (MediaQuery.sizeOf(context).width - 80)
                          .clamp(160.0, 320.0),
                      height: 220,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) =>
                          const Text('图片格式无法预览'),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      );

  void _showHtml(String path) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RemoteHtmlPreviewScreen(
        connectionId: widget.connection.id,
        workDir: widget.conversation?.cwd ?? widget.workDir,
        path: path,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回对话列表',
          onPressed: _leave,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
            LayoutBuilder(builder: (context, constraints) {
              final style = TextStyle(
                fontSize: 11,
                color: AppTheme.textMuted,
                fontFamily: 'monospace',
              );
              return Tooltip(
                message: _workDir,
                child: Text(
                  _compactWorkDir(context, constraints.maxWidth, style),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              );
            }),
          ],
        ),
        actions: [
          Listener(
            onPointerDown: (_) => _draftBeforeTopMenu = _input.value,
            child: PopupMenuButton<String>(
              key: const ValueKey('chat-display-options'),
              tooltip: '更多',
              icon: const Icon(Icons.more_vert),
              requestFocus: false,
              onOpened: () {
                _draftBeforeTopMenu ??= _input.value;
                _topMenuOpen = true;
                _restoreMenuDraft();
              },
              onCanceled: _finishTopMenu,
              onSelected: (value) {
                _finishTopMenu();
                if (value == 'clear') {
                  _requestClearContext();
                  return;
                }
                if (value == 'close-session') {
                  unawaited(_closeRemoteSession());
                  return;
                }
                setState(() {
                  if (value == 'time') _showMessageTime = !_showMessageTime;
                  if (value == 'tokens') _showTokenUsage = !_showTokenUsage;
                });
                if (value == 'time') {
                  unawaited(StorageService.setCodexShowMessageTime(
                      _showMessageTime));
                } else if (value == 'tokens') {
                  unawaited(StorageService.setCodexShowTokenUsage(
                      _showTokenUsage));
                }
              },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'time',
                  checked: _showMessageTime,
                  child: const Text('显示消息时间'),
                ),
                CheckedPopupMenuItem(
                  value: 'tokens',
                  checked: _showTokenUsage,
                  child: const Text('显示 Token 用量'),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'clear',
                  enabled: !_clearPending,
                  child: const Text('清空上下文'),
                ),
                PopupMenuItem(
                  value: 'close-session',
                  enabled: _remoteSessionOpen && !_sending && !_forkPending && !_closingRemoteSession,
                  child: const Text('关闭远程会话'),
                ),
              ],
            ),
          ),
          Listener(
            onPointerDown: (_) => _draftBeforeTopMenu = _input.value,
            child: PopupMenuButton<String>(
              key: const ValueKey('chat-model-menu'),
              tooltip: '切换模型',
              enabled: !_sending && _models.isNotEmpty,
              requestFocus: false,
              initialValue: _model,
              onOpened: () {
                _draftBeforeTopMenu ??= _input.value;
                _topMenuOpen = true;
                _restoreMenuDraft();
              },
              onCanceled: _finishTopMenu,
              onSelected: (model) {
                _finishTopMenu();
                unawaited(_chooseModel(model));
              },
              itemBuilder: (_) => [
                for (final model in _models)
                  PopupMenuItem<String>(
                    value: model.id,
                    child: Text(model.name),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _models
                              .where((model) => model.id == _model)
                              .firstOrNull
                              ?.name ??
                          '模型',
                      style: const TextStyle(fontSize: 12),
                    ),
                    Text(_effort,
                        style: TextStyle(
                            fontSize: 10, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_threadId != null && !_sending && !_forkPending)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _remoteSessionLabel,
                  key: const ValueKey('chat-remote-session-status'),
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
              ),
            ),
          if (_threadId != null)
            CodexGoalCard(
              connectionId: widget.connection.id,
              conversationId: _threadId!,
            ),
          if (_readOnlyReason != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_readOnlyReason!,
                  style: TextStyle(color: AppTheme.orange)),
            ),
          if (_error != null)
            MaterialBanner(
              content: Text(_error!),
              actions: [
                TextButton(
                  onPressed: () => setState(() => _error = null),
                  child: const Text('关闭'),
                ),
              ],
            ),
          if (_clearPending)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '当前答复和待发送消息完成后清空上下文',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _clearPending = false),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _loading && _records.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _records.isEmpty
                    ? Center(
                        child: Text(
                            _threadId == null
                                ? '尚未启动·发送首条消息后启动远程会话'
                                : _forkPending
                                    ? '发送首条消息后启动 Fork 远程会话'
                                    : _remoteSessionLabel,
                            style: TextStyle(color: AppTheme.textMuted)),
                      )
                    : ListView.builder(
                        key: const ValueKey('chat-messages'),
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: _records.length + (_sending ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (index == _records.length) {
                            return Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 5),
                                padding: const EdgeInsets.all(12),
                                constraints:
                                    const BoxConstraints(maxWidth: 720),
                                decoration: BoxDecoration(
                                  color: AppTheme.bgCard,
                                  border:
                                      Border.all(color: AppTheme.borderSubtle),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      '${_activity.isEmpty ? '等待远端输出' : _activity}  ·  ${_formatDuration(DateTime.now().difference(_turnStartedAt ?? DateTime.now()).inSeconds.clamp(0, 864000))}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                    if (_streamedAnswer.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: _markdown(_streamedAnswer),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          }
                          final record = _records[index];
                          if (record.kind == 'context_clear') {
                            return Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Text(record.text,
                                    style: TextStyle(color: AppTheme.textMuted)),
                              ),
                            );
                          }
                          final isUser = record.kind == 'user';
                          return Align(
                            alignment: isUser
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 5),
                              padding: const EdgeInsets.all(12),
                              constraints: const BoxConstraints(maxWidth: 720),
                              decoration: BoxDecoration(
                                color: isUser
                                    ? AppTheme.chatUserBubble
                                    : AppTheme.bgCard,
                                border: Border.all(
                                  color: isUser
                                      ? AppTheme.blue.withValues(alpha: 0.5)
                                      : AppTheme.borderSubtle,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ..._messageContent(record.text, isUser),
                                  if (!isUser &&
                                      index == _records.length - 1 &&
                                      !_sending &&
                                      _lastTurnDurationSeconds != null)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        '耗时 ${_formatDuration(_lastTurnDurationSeconds!)}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppTheme.textMuted,
                                        ),
                                      ),
                                    ),
                                  if (!isUser &&
                                      (Platform.isAndroid ||
                                          Platform.isIOS ||
                                          Platform.isMacOS))
                                    for (final path
                                        in RemoteHtmlPreviewService.references(
                                            record.text))
                                      Padding(
                                        padding: const EdgeInsets.only(top: 8),
                                        child: OutlinedButton.icon(
                                          onPressed: () => _showHtml(path),
                                          icon: const Icon(Icons.preview),
                                          label: Text(
                                              '预览 HTML · ${path.split('/').last}'),
                                        ),
                                      ),
                                  if ((_showMessageTime &&
                                          record.timestamp != null) ||
                                      (_showTokenUsage &&
                                          record.tokenUsage != null))
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        [
                                          if (_showMessageTime &&
                                              record.timestamp != null)
                                            DateFormat('MM-dd HH:mm').format(
                                                record.timestamp!.toLocal()),
                                          if (_showTokenUsage &&
                                              record.tokenUsage != null)
                                            record.tokenUsage!.displayText,
                                        ].join('  ·  '),
                                        style: TextStyle(
                                            fontSize: 11,
                                            color: AppTheme.textMuted),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
          if (_queuedPrompts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                      child: Text(
                    '待发送 ${_queuedPrompts.length} 条 · ${_queuedPrompts.first}',
                    key: const ValueKey('chat-queue'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppTheme.textMuted),
                  )),
                  if (!_sending)
                    TextButton(
                        onPressed: _sendNextQueued, child: const Text('重试')),
                  IconButton(
                    tooltip: '移除首条待发送消息',
                    onPressed: () => setState(() => _queuedPrompts.removeAt(0)),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ],
              ),
            ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat-input'),
                    controller: _input,
                    focusNode: _inputFocus,
                    onTap: _scrollToEnd,
                    enabled: _readOnlyReason == null,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.send,
                    decoration: InputDecoration(
                      hintText: _sending
                          ? '输入后发送，将排队等待'
                          : _forkPending
                              ? '发送首条消息时创建 Fork 副本'
                              : '发送消息',
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const ValueKey('chat-send'),
                  onPressed: _readOnlyReason != null || _closingRemoteSession ? null : _send,
                  icon: Icon(_sending ? Icons.queue : Icons.send),
                  tooltip: _sending ? '加入待发送队列' : '发送',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
