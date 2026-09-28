import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';
import 'package:xterm/src/core/buffer/cell_offset.dart';
import '../models/ssh_connection.dart';
import '../services/macos_keyboard_bridge.dart';
import '../services/notification_service.dart';
import '../services/codex_session_service.dart';
import '../services/codex_chat_service.dart';
import '../services/remote_state_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/terminal_clipboard_service.dart';
import '../services/tmux_config_service.dart';
import '../theme/app_theme.dart';
import '../widgets/history_panel.dart';
import '../widgets/chat_markdown.dart';
import '../widgets/codex_goal_card.dart';
import 'codex_chat_screen.dart';
import 'codex_notification_history_screen.dart';

/// Claude 工作状态
enum ClaudeActivity {
  idle, // 等待用户输入（`>` 提示符）
  generating, // 正在流式回答（Braille spinner）
  asking, // 需要用户确认（权限菜单）
  finished, // 刚完成回答
}

/// 会话类型
enum SessionType {
  shell, // 普通终端
  claude, // Claude Code
  codex, // Codex CLI
}

extension SessionTypeExt on SessionType {
  String get label => switch (this) {
        SessionType.shell => 'Shell',
        SessionType.claude => 'Claude',
        SessionType.codex => 'Codex',
      };

  Color get color => switch (this) {
        SessionType.shell => AppTheme.shellColor,
        SessionType.claude => AppTheme.claudeColor,
        SessionType.codex => AppTheme.codexColor,
      };

  Color get dimColor => switch (this) {
        SessionType.shell => AppTheme.cyanDim,
        SessionType.claude => AppTheme.purpleDim,
        SessionType.codex => AppTheme.blueDim,
      };

  IconData get icon => switch (this) {
        SessionType.shell => Icons.terminal,
        SessionType.claude => Icons.auto_awesome,
        SessionType.codex => Icons.code,
      };

  /// 进入 tmux 后自动执行的命令
  String? get autoCommand => switch (this) {
        SessionType.shell => null,
        SessionType.claude => 'claude',
        SessionType.codex =>
          'codex --dangerously-bypass-approvals-and-sandbox -p yolo',
      };

  static SessionType fromString(String? s) => switch (s) {
        'claude' => SessionType.claude,
        'codex' => SessionType.codex,
        _ => SessionType.shell,
      };
}

enum _TmuxPaneDirection { left, right, up, down }

extension _TmuxPaneDirectionExt on _TmuxPaneDirection {
  String get tmuxFlag => switch (this) {
        _TmuxPaneDirection.left => '-L',
        _TmuxPaneDirection.right => '-R',
        _TmuxPaneDirection.up => '-U',
        _TmuxPaneDirection.down => '-D',
      };

  String get terminalEscape => switch (this) {
        _TmuxPaneDirection.left => '\x1b[D',
        _TmuxPaneDirection.right => '\x1b[C',
        _TmuxPaneDirection.up => '\x1b[A',
        _TmuxPaneDirection.down => '\x1b[B',
      };
}

enum _TmuxSplitDirection {
  horizontal, // 上下分割
  vertical, // 左右分割
}

extension _TmuxSplitDirectionExt on _TmuxSplitDirection {
  String get label => switch (this) {
        _TmuxSplitDirection.horizontal => '水平分割（上下）',
        _TmuxSplitDirection.vertical => '垂直分割（左右）',
      };

  String get tmuxFlag => switch (this) {
        _TmuxSplitDirection.horizontal => '-v',
        _TmuxSplitDirection.vertical => '-h',
      };
}

/// 单个 Tab 的终端状态
class _TabSession {
  String name;
  final SessionType type;
  String workDir;
  String? displayTitle;
  String? resumeConversationId;
  final CodexConversationLaunch resumeLaunch;
  Terminal? terminal;
  TerminalController? controller;
  final GlobalKey<TerminalViewState> terminalViewKey =
      GlobalKey<TerminalViewState>();
  final ScrollController scrollController = ScrollController();
  StreamSubscription? subscription;
  bool isConnecting = false;
  bool isConnected = false;
  String? errorMessage;
  bool isNewlyCreated; // 只有首次创建才发 autoCommand
  bool pausedForChat = false;

  // 终端焦点节点
  final FocusNode focusNode = FocusNode();

  // 选区文本缓存（tmux 刷新可能导致 CellAnchor detach，选区丢失）
  String? cachedSelectionText;
  bool selectionCacheBound = false;

  // 拖选期间暂停终端输出，防止 tmux 刷新清除选区
  bool outputPaused = false;
  final List<String> _outputBuffer = [];
  Timer? _delayedResumeTimer;

  void pauseOutput() {
    _delayedResumeTimer?.cancel();
    _delayedResumeTimer = null;
    outputPaused = true;
  }

  void resumeOutput({bool discardBuffer = false}) {
    _delayedResumeTimer?.cancel();
    _delayedResumeTimer = null;
    outputPaused = false;
    if (_outputBuffer.isNotEmpty && terminal != null) {
      if (discardBuffer) {
        _outputBuffer.clear();
      } else {
        final merged = _outputBuffer.join();
        _outputBuffer.clear();
        terminal!.write(merged);
      }
    }
  }

  /// 延迟恢复输出（拖选结束后保持选区可见，给用户时间 Cmd+C 复制）
  void resumeOutputDelayed({Duration delay = const Duration(seconds: 3)}) {
    _delayedResumeTimer?.cancel();
    _delayedResumeTimer = Timer(delay, () {
      _delayedResumeTimer = null;
      resumeOutput();
    });
  }

  /// 写入终端（暂停期间缓冲）
  void writeToTerminal(String data) {
    if (outputPaused) {
      _outputBuffer.add(data);
      return;
    }
    terminal?.write(data);
  }

  void ensureTmuxMouseReporting() {
    terminal?.setMouseMode(MouseMode.upDownScrollDrag);
    terminal?.setMouseReportMode(MouseReportMode.sgr);
  }

  // tmux copy-mode 状态（滚轮翻页时进入）
  bool inTmuxCopyMode = false;
  String? copyModePaneId; // 缓存 copy-mode 时的 pane ID，供拖选滚动用
  int? lastKnownPaneCount;

  // Ctrl+C 防连按
  DateTime? _lastCtrlCTime;

  // Claude 状态检测
  ClaudeActivity claudeActivity = ClaudeActivity.idle;
  String _recentOutput = ''; // 滑动窗口，最近 2KB 输出
  Timer? _idleTimer; // finished → idle 定时器
  String? lastQuestion; // 最近提问文本（用于通知）

  _TabSession(
      {required this.name,
      this.type = SessionType.shell,
      this.workDir = '~',
      this.displayTitle,
      this.resumeConversationId,
      this.resumeLaunch = CodexConversationLaunch.resume,
      this.isNewlyCreated = false});

  String get displayName {
    if (displayTitle?.trim().isNotEmpty == true) return displayTitle!.trim();
    if (type == SessionType.codex &&
        (name.startsWith('codex-') || name.startsWith('fork-'))) {
      return 'Codex 对话';
    }
    return name;
  }

  String sessionId(String connectionId) => '$connectionId:$name';

  /// 追加到最近输出缓冲（保留最近 2KB）
  void appendOutput(String text) {
    _recentOutput += text;
    if (_recentOutput.length > 2048) {
      _recentOutput = _recentOutput.substring(_recentOutput.length - 2048);
    }
  }

  void dispose() {
    subscription?.cancel();
    controller?.dispose();
    _idleTimer?.cancel();
    _delayedResumeTimer?.cancel();
    scrollController.dispose();
    focusNode.dispose();
  }
}

class CodexSessionConfig {
  final String name;
  final String workDir;
  final CodexConversation? resumeConversation;
  final CodexConversationLaunch launch;
  final bool stopWriterBeforeLaunch;
  final String? openSessionName;
  final Map<String, String> openedSessionTitles;
  final bool openAsChat;
  final bool attachRunningChat;
  final String? runningChatJobId;
  final bool favoriteOnCreate;

  const CodexSessionConfig({
    required this.name,
    required this.workDir,
    this.resumeConversation,
    this.launch = CodexConversationLaunch.resume,
    this.stopWriterBeforeLaunch = false,
    this.openSessionName,
    this.openedSessionTitles = const {},
    this.openAsChat = false,
    this.attachRunningChat = false,
    this.runningChatJobId,
    this.favoriteOnCreate = false,
  });

  String get effectiveWorkDir => resumeConversation?.cwd ?? workDir;
}

enum _CodexTimeFilter {
  all,
  today,
  yesterday,
  lastSevenDays,
  lastThirtyDays,
}

extension _CodexTimeFilterLabel on _CodexTimeFilter {
  String get label => switch (this) {
        _CodexTimeFilter.all => '全部时间',
        _CodexTimeFilter.today => '今天',
        _CodexTimeFilter.yesterday => '昨天',
        _CodexTimeFilter.lastSevenDays => '近 7 天',
        _CodexTimeFilter.lastThirtyDays => '近 30 天',
      };
}

class CodexSessionDialog extends StatefulWidget {
  final String connectionId;
  final String defaultName;
  final String defaultWorkDir;
  final String dialogTitle;
  final Future<List<CodexConversation>> Function(String workDir)
      loadConversations;
  final Future<List<CodexConversation>> Function()? loadAllConversations;
  final Future<List<CodexConversation>> Function()? loadRunningConversations;
  final Future<List<CodexConversation>> Function(int offset)?
      loadMoreConversations;
  final List<CodexConversation> initialConversations;
  final void Function(List<CodexConversation>)? onConversationsLoaded;
  final bool startWithAllConversations;
  final Future<List<CodexConversationRecord>> Function(String conversationId)
      loadRecords;
  final Future<RemoteDirectoryListing> Function(String path) loadDirectories;
  final Future<List<OpenedCodexSession>> Function()? loadOpenedSessions;
  final Future<Map<String, String>> Function()? loadRunningChatJobs;
  final Future<String?> Function(String conversationId)? findRunningChatJob;
  final bool? initialOpenAsChat;
  final void Function(bool)? onOpenModeChanged;
  final Future<void> Function(String connectionId, Set<String> paths)?
      saveFilteredDirectories;
  final Future<void> Function(String connectionId, Set<String> ids)?
      saveFavoriteConversations;

  const CodexSessionDialog({
    this.connectionId = '',
    required this.defaultName,
    required this.defaultWorkDir,
    this.dialogTitle = '新建 Codex 会话',
    required this.loadConversations,
    this.loadAllConversations,
    this.loadRunningConversations,
    this.loadMoreConversations,
    this.initialConversations = const [],
    this.onConversationsLoaded,
    this.startWithAllConversations = false,
    required this.loadRecords,
    required this.loadDirectories,
    this.loadOpenedSessions,
    this.loadRunningChatJobs,
    this.findRunningChatJob,
    this.initialOpenAsChat,
    this.onOpenModeChanged,
    this.saveFilteredDirectories,
    this.saveFavoriteConversations,
  });

  @override
  State<CodexSessionDialog> createState() => _CodexSessionDialogState();
}

class _CodexDirectoryNode {
  _CodexDirectoryNode(this.path, this.name, this.directCount);

  final String path;
  String name;
  final Map<String, _CodexDirectoryNode> children = {};
  final int directCount;
  int totalCount = 0;
}

class _CodexSessionDialogState extends State<CodexSessionDialog> {
  bool _usesMobileLayout(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide < 600;

  late String _workDir;
  late List<CodexConversation> _conversations;
  late List<CodexConversation> _directoryConversations;
  late Set<String> _favoriteDirectories;
  late Set<String> _favoriteConversations;
  late Set<String> _filteredDirectories;
  final Set<String> _collapsedDirectoryPaths = {};
  final Set<String> _collapsedConversationDirectoryPaths = {};
  List<String> _directories = const [];
  String _homePath = '~';
  List<String> _diskPaths = const [];
  String? _selectedConversationId;
  bool _loadingDirectories = true;
  bool _loadingConversations = true;
  bool _loadingOlderConversations = false;
  bool _runningOnly = false;
  bool _loadingRunning = false;
  bool _preloadingRecords = false;
  bool _preloadRecordsPending = false;
  List<CodexConversation>? _runningConversations;
  String? _runningError;
  bool _hasOlderConversations = true;
  int _nextConversationOffset = 200;
  String? _directoryError;
  String? _conversationError;
  int _directoryRequest = 0;
  int _conversationRequest = 0;
  Timer? _statusRefreshTimer;
  bool _statusRefreshInFlight = false;
  bool _attachingRunningChat = false;
  bool _showHiddenDirectories = false;
  bool _showAllConversations = false;
  late bool _openAsChat;
  int _mobileSection = 0;
  List<OpenedCodexSession> _openedSessions = const [];
  late Set<String> _localOpenedConversationIds;
  Map<String, String> _runningChatJobs = const {};
  bool _openedSessionsKnown = false;
  bool _runningChatJobsKnown = false;
  bool _hasSelectedInitialConversation = false;
  _CodexTimeFilter _timeFilter = _CodexTimeFilter.all;

  CodexConversation? get _selectedConversation {
    final id = _selectedConversationId;
    if (id == null) return null;
    for (final conversation in [
      ..._conversationSource(false),
    ]) {
      if (conversation.id == id) return conversation;
    }
    return null;
  }

  OpenedCodexSession? _openedSessionFor(CodexConversation conversation) =>
      _openedSessions
          .where((session) =>
              session.conversationId == conversation.id ||
              CodexSessionService.matchOpenedConversation(
                      session, _conversations)
                  ?.id ==
              conversation.id)
          .firstOrNull;

  bool _isOpenedConversation(CodexConversation conversation) =>
      _openedSessionFor(conversation) != null;

  bool _isAppConversation(CodexConversation conversation) =>
      _isOpenedConversation(conversation) ||
      _runningChatJobs.containsKey(conversation.id);

  bool _isRecentCompleted(CodexConversation conversation) {
    final completedAt = conversation.completedAt ?? conversation.updatedAt;
    return conversation.state == CodexConversationState.complete &&
        completedAt != null &&
        !completedAt.isBefore(DateTime.now().subtract(const Duration(hours: 24)));
  }

  bool _isUnreadCompleted(CodexConversation conversation) {
    if (widget.connectionId.isEmpty ||
        conversation.state != CodexConversationState.complete) {
      return false;
    }
    final notices = StorageService.getCodexCompletionNotices().where((notice) =>
        notice.connectionId == widget.connectionId &&
        notice.threadId == conversation.id);
    if (notices.any((notice) => !notice.read)) return true;
    final viewedAt = StorageService.getCodexConversationViewedAt(
        widget.connectionId, conversation.id);
    if (viewedAt == null) return notices.isEmpty;
    return conversation.updatedAt?.isAfter(viewedAt) ?? false;
  }

  void _onConversationReadChanged() {
    if (mounted) setState(() {});
  }

  String _conversationStateLabel(CodexConversation conversation) {
    if (_isUnreadCompleted(conversation)) return '已完成·未读';
    if (conversation.state != CodexConversationState.running) {
      return conversation.state.label;
    }
    if (_isAppConversation(conversation)) return '本软件执行中';
    if (_openedSessionsKnown && _runningChatJobsKnown) return '其他端执行中';
    return conversation.state.label;
  }

  bool _matchesConversationFilters(CodexConversation conversation) =>
      _matchesTimeFilter(conversation) &&
      _matchesDirectoryFilter(conversation.cwd);

  bool _matchesDirectoryFilter(String path) =>
      _filteredDirectories.isEmpty ||
      _filteredDirectories
          .any((selected) => _isDirectoryOrChild(path, selected));

  bool _isDirectoryOrChild(String path, String parent) =>
      path == parent || path.startsWith(parent == '/' ? '/' : '$parent/');

  String _openedSessionTitle(OpenedCodexSession session) {
    final prefix = session.name.startsWith('codex-')
        ? session.name.substring(6)
        : session.name.startsWith('fork-')
            ? session.name.substring(5)
            : '';
    final conversation =
        CodexSessionService.matchOpenedConversation(session, _conversations);
    if (conversation?.title.trim().isNotEmpty == true) {
      return conversation!.title.trim();
    }
    if (prefix.isEmpty) return session.name;
    return 'Codex 对话';
  }

  @override
  void initState() {
    super.initState();
    _conversations = widget.initialConversations.isNotEmpty
        ? widget.initialConversations
        : widget.startWithAllConversations
            ? CodexSessionService.cachedConversations(widget.connectionId) ??
                const []
            : const [];
    NotificationService.historyRevision.addListener(_onConversationReadChanged);
    _directoryConversations = _conversations;
    _runningConversations =
        CodexSessionService.cachedRunningConversations(widget.connectionId);
    _favoriteDirectories =
        StorageService.getFavoriteCodexDirectories(widget.connectionId);
    _favoriteConversations =
        StorageService.getFavoriteCodexConversations(widget.connectionId);
    _localOpenedConversationIds =
        StorageService.getOpenedCodexConversations(widget.connectionId);
    _filteredDirectories =
        StorageService.getFilteredCodexDirectories(widget.connectionId);
    _openAsChat = widget.initialOpenAsChat ?? StorageService.getCodexChatMode();
    _workDir = widget.defaultWorkDir;
    _showAllConversations = widget.startWithAllConversations;
    unawaited(
      _loadDirectory(
        _workDir,
        loadAll: widget.startWithAllConversations,
        preserveConversations: _conversations.isNotEmpty,
      ),
    );
    unawaited(_refreshRunningConversations());
    unawaited(_preloadRecentConversations());
    if (widget.loadOpenedSessions != null) unawaited(_loadOpenedSessions());
    if (widget.loadRunningChatJobs != null) unawaited(_loadRunningChatJobs());
    _statusRefreshTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_refreshActiveConversationStates()),
    );
  }

  Future<void> _loadOpenedSessions() async {
    final loader = widget.loadOpenedSessions;
    if (loader == null) return;
    try {
      final sessions = await loader();
      if (!mounted) return;
      setState(() {
        _openedSessions = sessions;
        _openedSessionsKnown = true;
      });
    } catch (_) {}
  }

  Future<void> _loadRunningChatJobs() async {
    final loader = widget.loadRunningChatJobs;
    if (loader == null) return;
    try {
      final jobs = await loader();
      if (!mounted) return;
      setState(() {
        _runningChatJobs = jobs;
        _runningChatJobsKnown = true;
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _statusRefreshTimer?.cancel();
    NotificationService.historyRevision.removeListener(_onConversationReadChanged);
    super.dispose();
  }

  Future<void> _refreshActiveConversationStates() async {
    if (_loadingDirectories ||
        _loadingConversations ||
        _statusRefreshInFlight ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final requestedWorkDir = _workDir;
    final request = ++_conversationRequest;
    _statusRefreshInFlight = true;
    final runningRefresh = _refreshRunningConversations();
    try {
      final conversations =
          _showAllConversations && widget.loadAllConversations != null
              ? await widget.loadAllConversations!()
              : await widget.loadConversations(requestedWorkDir);
      if (!mounted ||
          request != _conversationRequest ||
          requestedWorkDir != _workDir ||
          _loadingDirectories) {
        return;
      }
      final updated = {
        for (final conversation in conversations) conversation.id: conversation
      };
      setState(() {
        _conversations = [
          ...conversations,
          if (_nextConversationOffset > 200)
            ..._conversations.where((item) => !updated.containsKey(item.id)),
        ];
        if (_showAllConversations) _directoryConversations = _conversations;
      });
      unawaited(_preloadRecentConversations());
      await Future.wait([
        _loadOpenedSessions(), _loadRunningChatJobs(), runningRefresh,
      ]);
    } catch (_) {
      // 后台检查失败时保留现有列表。
    } finally {
      _statusRefreshInFlight = false;
    }
  }

  List<CodexConversation> _conversationSource(bool favoritesOnly) =>
      _runningOnly && !favoritesOnly
          ? {
              for (final conversation in _conversations)
                conversation.id: conversation,
              for (final conversation in _runningConversations ?? const <CodexConversation>[])
                conversation.id: conversation,
            }.values.where((conversation) =>
                conversation.state == CodexConversationState.running ||
                _isRecentCompleted(conversation)).toList()
          : _conversations;

  List<CodexConversation> _filteredConversations(bool favoritesOnly) =>
      _conversationSource(favoritesOnly).where((conversation) =>
          _matchesConversationFilters(conversation) &&
          (!_runningOnly || favoritesOnly ||
              conversation.state == CodexConversationState.running ||
              _isRecentCompleted(conversation)) &&
          (!favoritesOnly || _favoriteConversations.contains(conversation.id)))
          .toList();

  void _setRunningOnly(bool value) {
    setState(() {
      _runningOnly = value;
      if (!_filteredConversations(false)
          .any((item) => item.id == _selectedConversationId)) {
        _selectedConversationId = null;
      }
    });
    if (value) unawaited(_refreshRunningConversations());
    unawaited(_preloadRecentConversations());
  }

  Future<void> _refreshRunningConversations() async {
    final loader = widget.loadRunningConversations;
    if (loader == null || _loadingRunning) return;
    setState(() {
      _loadingRunning = true;
      _runningError = null;
    });
    try {
      final conversations = await loader();
      if (!mounted) return;
      setState(() {
        _runningConversations = conversations;
        if (_runningOnly && _mobileSection == 0 &&
            !_filteredConversations(false).any((item) => item.id == _selectedConversationId)) {
          _selectedConversationId = null;
        }
      });
      unawaited(_preloadRecentConversations());
    } catch (error) {
      if (mounted) setState(() => _runningError = error.toString());
    } finally {
      if (mounted) setState(() => _loadingRunning = false);
    }
  }

  Future<void> _preloadRecentConversations() async {
    _preloadRecordsPending = true;
    if (_preloadingRecords || !mounted) return;
    _preloadingRecords = true;
    final loaded = <String>{};
    try {
      while (_preloadRecordsPending && mounted) {
        _preloadRecordsPending = false;
        final ids = <String>{
          if (_selectedConversationId != null) _selectedConversationId!,
          ...?_runningConversations?.map((item) => item.id),
          ..._filteredConversations(_mobileSection == 1).map((item) => item.id),
        }.take(3).where((id) => loaded.add(id)).toList();
        for (var start = 0; start < ids.length && mounted; start += 2) {
          await Future.wait(ids.skip(start).take(2).map(_preloadConversation));
        }
      }
    } finally {
      _preloadingRecords = false;
    }
  }

  Future<void> _loadConversations(
    String requestedWorkDir, {
    bool preserveSelection = false,
    bool loadAll = false,
  }) async {
    final request = ++_conversationRequest;
    setState(() {
      _loadingConversations = true;
      _conversationError = null;
      if (!preserveSelection) _selectedConversationId = null;
    });

    try {
      final conversations = loadAll && widget.loadAllConversations != null
          ? await widget.loadAllConversations!()
          : await widget.loadConversations(requestedWorkDir);
      if (!mounted ||
          request != _conversationRequest ||
          (!loadAll && requestedWorkDir != _workDir)) {
        return;
      }
      final selectedId = preserveSelection ? _selectedConversationId : null;
      setState(() {
        _conversations = conversations;
        if (loadAll) _directoryConversations = conversations;
        if (loadAll) {
          _nextConversationOffset = 200;
          _hasOlderConversations = conversations.isNotEmpty;
        }
        _loadingConversations = false;
        _selectedConversationId = selectedId != null &&
                conversations
                    .any((conversation) => conversation.id == selectedId)
            ? selectedId
            : widget.startWithAllConversations &&
                    !_hasSelectedInitialConversation &&
                    conversations.any((conversation) =>
                        _matchesDirectoryFilter(conversation.cwd))
                ? conversations
                    .firstWhere((conversation) =>
                        _matchesDirectoryFilter(conversation.cwd))
                    .id
                : null;
        if (conversations.isNotEmpty) _hasSelectedInitialConversation = true;
      });
      if (loadAll) widget.onConversationsLoaded?.call(conversations);
      unawaited(_preloadRecentConversations());
    } catch (error) {
      if (!mounted ||
          request != _conversationRequest ||
          (!loadAll && requestedWorkDir != _workDir)) {
        return;
      }
      setState(() {
        _loadingConversations = false;
        if (!preserveSelection && _conversations.isEmpty) {
          _selectedConversationId = null;
        }
        _conversationError = error.toString();
      });
    }
  }

  Future<void> _loadOlderConversations() async {
    final loader = widget.loadMoreConversations;
    if (loader == null || _loadingOlderConversations) return;
    final offset = _nextConversationOffset;
    setState(() => _loadingOlderConversations = true);
    try {
      final older = await loader(offset);
      if (!mounted || !_showAllConversations || offset != _nextConversationOffset) {
        return;
      }
      setState(() {
        _nextConversationOffset += 200;
        _hasOlderConversations = older.isNotEmpty;
        final seen = _conversations.map((item) => item.id).toSet();
        _conversations = [..._conversations, ...older.where((item) => seen.add(item.id))];
        _directoryConversations = _conversations;
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取更早对话失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _loadingOlderConversations = false);
    }
  }

  void _toggleFavoriteDirectory(String path) {
    setState(() {
      if (!_favoriteDirectories.add(path)) _favoriteDirectories.remove(path);
    });
    unawaited(StorageService.setFavoriteCodexDirectories(
        widget.connectionId, _favoriteDirectories));
  }

  void _toggleFavoriteConversation(String id) {
    setState(() {
      if (!_favoriteConversations.add(id)) _favoriteConversations.remove(id);
      if (_mobileSection == 1 &&
          !_favoriteConversations.contains(id) &&
          _selectedConversationId == id) {
        _selectedConversationId = null;
      }
    });
    unawaited((widget.saveFavoriteConversations ??
            StorageService.setFavoriteCodexConversations)(
        widget.connectionId, {..._favoriteConversations}));
  }

  void _toggleDirectoryFilter(String path) {
    setState(() {
      if (!_filteredDirectories.add(path)) {
        _filteredDirectories.remove(path);
      } else {
        _filteredDirectories.removeWhere((selected) =>
            selected != path && _isDirectoryOrChild(selected, path));
      }
      if (_selectedConversation != null &&
          !_matchesDirectoryFilter(_selectedConversation!.cwd)) {
        _selectedConversationId = null;
      }
    });
    _saveFilteredDirectories();
    if (!_showAllConversations && widget.loadAllConversations != null) {
      setState(() => _showAllConversations = true);
      unawaited(_loadConversations(_workDir, loadAll: true));
    }
  }

  void _saveFilteredDirectories() {
    unawaited((widget.saveFilteredDirectories ??
        StorageService.setFilteredCodexDirectories)(
      widget.connectionId,
      {..._filteredDirectories},
    ));
  }

  Map<String, int> get _conversationDirectoryCounts {
    final counts = <String, int>{};
    final source = _directoryConversations.isEmpty
        ? _conversations
        : _directoryConversations;
    for (final conversation in source) {
      if (conversation.cwd.isNotEmpty) {
        counts.update(conversation.cwd, (count) => count + 1,
            ifAbsent: () => 1);
      }
    }
    return counts;
  }

  Widget _compactPath(String path, {double fontSize = 10, String? fullPath}) {
    final style = TextStyle(
      color: AppTheme.textMuted,
      fontFamily: 'monospace',
      fontSize: fontSize,
    );
    return LayoutBuilder(builder: (context, constraints) {
      bool fits(String value) {
        final painter = TextPainter(
          text: TextSpan(text: value, style: style),
          textDirection: Directionality.of(context),
        )..layout();
        final fits = painter.width <= constraints.maxWidth;
        painter.dispose();
        return fits;
      }

      var display = path;
      if (!fits(path) && path.contains('/')) {
        final lastSlash = path.lastIndexOf('/');
        final tail = path.substring(lastSlash);
        var prefix = path.substring(0, lastSlash);
        while (prefix.isNotEmpty) {
          final candidate = '$prefix/…$tail';
          if (fits(candidate)) {
            display = candidate;
            break;
          }
          final slash = prefix.lastIndexOf('/');
          prefix = slash <= 0 ? '' : prefix.substring(0, slash);
        }
        if (display == path && fits('…$tail')) display = '…$tail';
      }
      return Tooltip(
        message: fullPath ?? path,
        child: Text(display,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      );
    });
  }

  List<_CodexDirectoryNode> _directoryTree(Map<String, int> counts) {
    final nodes = <String, _CodexDirectoryNode>{};
    for (final entry in counts.entries) {
      final parts = entry.key.split('/').where((part) => part.isNotEmpty);
      var path = '';
      for (final part in parts) {
        path += '/$part';
        nodes.putIfAbsent(
            path, () => _CodexDirectoryNode(path, part, counts[path] ?? 0));
      }
      if (entry.key == '/') {
        nodes.putIfAbsent(
            '/', () => _CodexDirectoryNode('/', '/', counts['/'] ?? 0));
      }
    }
    final roots = <_CodexDirectoryNode>[];
    for (final node in nodes.values) {
      final parentPath = node.path == '/'
          ? null
          : node.path.substring(0, node.path.lastIndexOf('/'));
      final parent = parentPath == null
          ? null
          : nodes[parentPath.isEmpty ? '/' : parentPath];
      if (parent == null) {
        roots.add(node);
      } else {
        parent.children[node.path] = node;
      }
      node.totalCount = counts.entries
          .where((entry) => _isDirectoryOrChild(entry.key, node.path))
          .fold(0, (sum, entry) => sum + entry.value);
    }
    List<_CodexDirectoryNode> compress(List<_CodexDirectoryNode> siblings) {
      final result = <_CodexDirectoryNode>[];
      for (var node in siblings) {
        while (counts[node.path] == null && node.children.length == 1) {
          final child = node.children.values.single;
          child.name = '${node.name}/${child.name}';
          node = child;
        }
        final children = compress(node.children.values.toList());
        node.children
          ..clear()
          ..addEntries(children.map((child) => MapEntry(child.path, child)));
        result.add(node);
      }
      return result;
    }

    return compress(roots);
  }

  List<Widget> _buildDirectoryNodes(List<_CodexDirectoryNode> nodes,
      {int depth = 0}) {
    nodes.sort((a, b) {
      final favoriteCompare = (_favoriteDirectories.contains(b.path) ? 1 : 0) -
          (_favoriteDirectories.contains(a.path) ? 1 : 0);
      return favoriteCompare != 0 ? favoriteCompare : a.path.compareTo(b.path);
    });
    final rows = <Widget>[];
    for (final node in nodes) {
      final selected = _filteredDirectories.contains(node.path);
      final inherited = !selected &&
          _filteredDirectories.any((path) =>
              node.path != path && _isDirectoryOrChild(node.path, path));
      final hasChildren = node.children.isNotEmpty;
      final collapsed = _collapsedDirectoryPaths.contains(node.path);
      rows.add(Container(
        key: ValueKey('codex-directory-${node.path}'),
        margin: EdgeInsets.only(left: (depth * 16).clamp(0, 80).toDouble()),
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: selected || inherited ? AppTheme.blueDim : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: depth > 0
              ? Border(
                  left: BorderSide(
                      color: AppTheme.textMuted.withValues(alpha: 0.35)))
              : null,
        ),
        child: Row(children: [
          if (hasChildren)
            IconButton(
              key: ValueKey('expand-directory-${node.path}'),
              tooltip: collapsed ? '展开子目录' : '收起子目录',
              onPressed: () => setState(() {
                if (!_collapsedDirectoryPaths.add(node.path)) {
                  _collapsedDirectoryPaths.remove(node.path);
                }
              }),
              icon: Icon(collapsed ? Icons.chevron_right : Icons.expand_more),
              iconSize: 16,
              constraints: const BoxConstraints.tightFor(width: 24, height: 36),
              padding: EdgeInsets.zero,
            )
          else
            SizedBox(
              width: 24,
              child: Icon(Icons.folder_outlined,
                  size: 14, color: AppTheme.textMuted),
            ),
          Expanded(
            child: InkWell(
              onTap: inherited ? null : () => _toggleDirectoryFilter(node.path),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _compactPath(node.name, fontSize: 11, fullPath: node.path),
                  Text(
                      '${node.totalCount} 条${hasChildren ? ' · 本目录 ${node.directCount} 条' : ''}',
                      style:
                          TextStyle(color: AppTheme.textMuted, fontSize: 10)),
                ],
              ),
            ),
          ),
          TextButton(
            key: ValueKey('filter-directory-${node.path}'),
            onPressed:
                inherited ? null : () => _toggleDirectoryFilter(node.path),
            style: TextButton.styleFrom(
              foregroundColor:
                  selected ? AppTheme.blue : AppTheme.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              minimumSize: const Size(38, 32),
              visualDensity: VisualDensity.compact,
            ),
            child: Text(
                inherited
                    ? '已包含'
                    : selected
                        ? '已筛选'
                        : '筛选',
                style: const TextStyle(fontSize: 10)),
          ),
          IconButton(
            key: ValueKey('favorite-directory-${node.path}'),
            tooltip: _favoriteDirectories.contains(node.path)
                ? '取消收藏目录'
                : '收藏目录到快捷区',
            icon: Icon(_favoriteDirectories.contains(node.path)
                ? Icons.star
                : Icons.star_border),
            iconSize: 18,
            color: _favoriteDirectories.contains(node.path)
                ? AppTheme.orange
                : AppTheme.textMuted,
            constraints: const BoxConstraints.tightFor(width: 30, height: 36),
            padding: EdgeInsets.zero,
            onPressed: () => _toggleFavoriteDirectory(node.path),
          ),
        ]),
      ));
      if (hasChildren && !collapsed) {
        rows.addAll(_buildDirectoryNodes(node.children.values.toList(),
            depth: depth + 1));
      }
    }
    return rows;
  }

  Widget _buildConversationDirectories() {
    final counts = _conversationDirectoryCounts;
    final roots = _directoryTree(counts);
    final favorites = _favoriteDirectories
        .where((path) => counts.containsKey(path))
        .toList()
      ..sort();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text(
                _filteredDirectories.isEmpty
                    ? '对话目录 · 全部'
                    : '对话目录 · 已筛选 ${_filteredDirectories.length} 个',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
          if (_filteredDirectories.isNotEmpty)
            TextButton(
              onPressed: () {
                setState(() => _filteredDirectories.clear());
                _saveFilteredDirectories();
              },
              child: const Text('全部'),
            ),
        ]),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text('筛选含子目录；星标收藏为快捷入口。可多选。',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
        ),
        if (favorites.isNotEmpty) ...[
          Text('收藏目录',
              style: TextStyle(
                  color: AppTheme.orange,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          for (final path in favorites)
            InkWell(
              key: ValueKey('favorite-shortcut-$path'),
              onTap: _filteredDirectories.any((selected) =>
                      selected != path && _isDirectoryOrChild(path, selected))
                  ? null
                  : () => _toggleDirectoryFilter(path),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Icon(Icons.star, size: 14, color: AppTheme.orange),
                  const SizedBox(width: 5),
                  Expanded(child: _compactPath(path, fontSize: 11)),
                  Text(
                      _filteredDirectories.contains(path)
                          ? '取消筛选'
                          : _filteredDirectories.any((selected) =>
                                  _isDirectoryOrChild(path, selected))
                              ? '已包含'
                              : '筛选',
                      style: TextStyle(color: AppTheme.blue, fontSize: 10)),
                ]),
              ),
            ),
          const Divider(height: 12),
        ],
        if (roots.isEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('暂无目录记录',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 11)),
          ),
        ..._buildDirectoryNodes(roots),
        const Divider(height: 16),
      ],
    );
  }

  Future<void> _loadDirectory(
    String requestedPath, {
    bool loadAll = false,
    bool preserveConversations = false,
  }) async {
    final request = ++_directoryRequest;
    ++_conversationRequest;
    setState(() {
      _showAllConversations = loadAll;
      _loadingDirectories = true;
      _directoryError = null;
      _loadingConversations = true;
      _conversationError = null;
      if (!preserveConversations) _conversations = const [];
      if (!preserveConversations) _selectedConversationId = null;
    });

    // 全部对话不依赖目录解析，让两项查询同时进行。
    final allConversations = loadAll && widget.loadAllConversations != null
        ? _loadConversations(_workDir, loadAll: true, preserveSelection: true)
        : null;
    try {
      final result = await widget.loadDirectories(
        requestedPath.isEmpty ? '~' : requestedPath,
      );
      if (!mounted || request != _directoryRequest) return;
      setState(() {
        _workDir = result.path;
        _directories = result.dirs;
        _homePath = result.homePath;
        _diskPaths = result.diskPaths;
        _directoryError = result.error;
        _loadingDirectories = false;
      });
      if (result.error != null &&
          !(loadAll && widget.loadAllConversations != null)) {
        setState(() => _loadingConversations = false);
        return;
      }
      if (allConversations != null) {
        await allConversations;
      } else {
        await _loadConversations(result.path,
            loadAll: loadAll,
            preserveSelection: preserveConversations);
      }
    } catch (error) {
      if (!mounted || request != _directoryRequest) return;
      setState(() {
        _loadingDirectories = false;
        _directoryError = error.toString();
      });
      if (allConversations != null) {
        await allConversations;
      } else {
        setState(() => _loadingConversations = false);
      }
    }
  }

  void _submit({
    CodexConversationLaunch launch = CodexConversationLaunch.resume,
    bool stopWriterBeforeLaunch = false,
    bool? openAsChat,
    String? newWorkDir,
    bool favoriteOnCreate = false,
  }) {
    final useChat = openAsChat ?? _openAsChat;
    final conversation = _selectedConversation;
    final opened = conversation == null ||
            stopWriterBeforeLaunch ||
            launch == CodexConversationLaunch.fork
        ? null
        : _openedSessionFor(conversation);
    if (conversation != null &&
        !(stopWriterBeforeLaunch || launch == CodexConversationLaunch.fork
            ? conversation.canTakeover
            : conversation.canResume || opened != null)) {
      return;
    }
    Navigator.pop(
      context,
      CodexSessionConfig(
        name: '',
        workDir: conversation?.cwd ?? newWorkDir ?? _workDir,
        resumeConversation: conversation,
        launch: launch,
        stopWriterBeforeLaunch: stopWriterBeforeLaunch,
        openSessionName: opened?.name,
        openedSessionTitles: {
          for (final session in _openedSessions)
            session.name: _openedSessionTitle(session),
        },
        openAsChat: useChat,
        favoriteOnCreate: conversation == null && favoriteOnCreate,
      ),
    );
  }

  Future<void> _showNewConversationSheet() async {
    var chosenPath = _workDir;
    var favorite = true;
    var listingFuture = widget.loadDirectories(_workDir);
    String? error;
    bool creating = false;
    final selected = await showModalBottomSheet<({String path, bool favorite})>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                16, 12, 16, MediaQuery.viewInsetsOf(context).bottom + 12),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.7,
              child: Column(children: [
                const ListTile(
                  title: Text('新建 Codex 对话'),
                  subtitle: Text('选择远端工作目录；第一条消息成功后创建会话'),
                ),
                KeyedSubtree(
                  key: ValueKey(chosenPath),
                  child: TextFormField(
                    key: const ValueKey('new-conversation-directory'),
                    initialValue: chosenPath,
                    onChanged: (value) => chosenPath = value,
                    decoration: const InputDecoration(
                      labelText: '工作目录',
                      prefixIcon: Icon(Icons.folder_outlined),
                    ),
                  ),
                ),
                if (_favoriteDirectories.isNotEmpty)
                  SizedBox(
                    height: 52,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final path
                            in _favoriteDirectories.toList()..sort())
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ActionChip(
                              label: Text(path,
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              onPressed: () => updateSheet(() {
                                chosenPath = path;
                                listingFuture = widget.loadDirectories(path);
                              }),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: FutureBuilder<RemoteDirectoryListing>(
                    future: listingFuture,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final listing = snapshot.data!;
                      if (listing.error != null) {
                        return Center(child: Text(listing.error!));
                      }
                      return ListView(children: [
                        ListTile(
                          title: Text(listing.path,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: TextButton(
                            onPressed: () => updateSheet(() {
                              chosenPath = listing.path;
                            }),
                            child: const Text('选择此目录'),
                          ),
                        ),
                        if (listing.path != '/')
                          ListTile(
                            leading: const Icon(Icons.arrow_upward),
                            title: const Text('上级目录'),
                            onTap: () => updateSheet(() {
                              listingFuture = widget
                                  .loadDirectories(_parentPath(listing.path));
                            }),
                          ),
                        for (final dir in listing.dirs)
                          ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(dir),
                            onTap: () => updateSheet(() {
                              listingFuture = widget.loadDirectories(
                                  _joinPath(listing.path, dir));
                            }),
                          ),
                      ]);
                    },
                  ),
                ),
                CheckboxListTile(
                  key: const ValueKey('favorite-new-conversation'),
                  value: favorite,
                  onChanged: (value) => updateSheet(() {
                    favorite = value ?? true;
                  }),
                  title: const Text('收藏新对话'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
                if (error != null)
                  Text(error!, style: TextStyle(color: AppTheme.red)),
                Row(children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: creating
                        ? null
                        : () async {
                            updateSheet(() {
                              creating = true;
                              error = null;
                            });
                            final path = chosenPath.trim();
                            final checked = await widget.loadDirectories(path);
                            if (!sheetContext.mounted) return;
                            if (checked.error != null) {
                              updateSheet(() {
                                creating = false;
                                error = checked.error;
                              });
                              return;
                            }
                            Navigator.pop(sheetContext,
                                (path: checked.path, favorite: favorite));
                          },
                    child: const Text('创建'),
                  ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    setState(() => _selectedConversationId = null);
    _submit(newWorkDir: selected.path, favoriteOnCreate: selected.favorite);
  }

  bool _canCheckRunningChat(CodexConversation conversation) =>
      widget.findRunningChatJob != null &&
      (conversation.state == CodexConversationState.running ||
          conversation.state == CodexConversationState.pending) &&
      !_isOpenedConversation(conversation) &&
      (!_runningChatJobsKnown || _runningChatJobs.containsKey(conversation.id));

  Future<void> _attachRunningChat(CodexConversation conversation) async {
    final findJob = widget.findRunningChatJob;
    if (findJob == null || _attachingRunningChat) return;
    setState(() => _attachingRunningChat = true);
    try {
      final jobId = await findJob(conversation.id);
      if (!mounted || _selectedConversationId != conversation.id) return;
      if (jobId == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('没有找到本软件正在执行的聊天任务；可稍后刷新状态'),
        ));
        return;
      }
      Navigator.pop(
        context,
        CodexSessionConfig(
          name: '',
          workDir: conversation.cwd,
          resumeConversation: conversation,
          openAsChat: true,
          attachRunningChat: true,
          runningChatJobId: jobId,
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('接入聊天任务失败：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _attachingRunningChat = false);
    }
  }

  String _formatTime(DateTime? value) {
    if (value == null) return '时间未知';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute';
  }

  DateTime _startOfDay(DateTime value) {
    final local = value.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  bool _matchesTimeFilter(CodexConversation conversation) {
    if (_timeFilter == _CodexTimeFilter.all) return true;
    final updatedAt = conversation.updatedAt;
    if (updatedAt == null) return false;

    final today = _startOfDay(DateTime.now());
    final date = _startOfDay(updatedAt);
    return switch (_timeFilter) {
      _CodexTimeFilter.all => true,
      _CodexTimeFilter.today => date == today,
      _CodexTimeFilter.yesterday =>
        date == today.subtract(const Duration(days: 1)),
      _CodexTimeFilter.lastSevenDays =>
        !date.isBefore(today.subtract(const Duration(days: 6))) &&
            date.isBefore(today.add(const Duration(days: 1))),
      _CodexTimeFilter.lastThirtyDays =>
        !date.isBefore(today.subtract(const Duration(days: 29))) &&
            date.isBefore(today.add(const Duration(days: 1))),
    };
  }

  Color _stateColor(CodexConversationState state) {
    return switch (state) {
      CodexConversationState.notStarted => AppTheme.textMuted,
      CodexConversationState.running => AppTheme.cyan,
      CodexConversationState.pending => AppTheme.orange,
      CodexConversationState.complete => AppTheme.green,
      CodexConversationState.aborted => AppTheme.red,
      CodexConversationState.unknown => AppTheme.textMuted,
    };
  }

  Widget _buildConversationTile(CodexConversation conversation) {
    final selected = conversation.id == _selectedConversationId;
    final stateColor = _stateColor(conversation.state);
    BuildContext? viewButtonContext;
    var openViewerOnTap = false;
    return InkWell(
      onTapDown: (details) {
        final box = viewButtonContext?.findRenderObject() as RenderBox?;
        openViewerOnTap = box != null &&
            (box.localToGlobal(Offset.zero) & box.size)
                .inflate(10)
                .contains(details.globalPosition);
      },
      onTapCancel: () => openViewerOnTap = false,
      onTap: () {
        final openViewer = openViewerOnTap;
        openViewerOnTap = false;
        if (openViewer) {
          unawaited(_openConversationViewer(conversation));
        } else {
          _selectConversation(conversation);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        decoration: BoxDecoration(
          color: selected ? AppTheme.blueDim : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.chat_bubble,
              key: ValueKey('conversation-leading-${conversation.id}'),
              size: 16,
              color: selected ? AppTheme.blue : stateColor,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (_usesMobileLayout(context) &&
                          _favoriteConversations.contains(conversation.id)) ...[
                        Icon(
                          Icons.star_rounded,
                          key: ValueKey('favorite-marker-${conversation.id}'),
                          size: 14,
                          color: AppTheme.orange,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          conversation.displayTitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        key: ValueKey('conversation-state-${conversation.id}'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: stateColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: stateColor.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Text(
                          _conversationStateLabel(conversation),
                          style: TextStyle(color: stateColor, fontSize: 10),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Builder(builder: (context) {
                        viewButtonContext = context;
                        return IconButton(
                        key: ValueKey('view-conversation-${conversation.id}'),
                        tooltip: '查看对话',
                        icon: const Icon(Icons.visibility_outlined),
                        iconSize: 18,
                        color: AppTheme.textMuted,
                        constraints: const BoxConstraints.tightFor(
                            width: 28, height: 28),
                        style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                        padding: EdgeInsets.zero,
                        onPressed: () => _openConversationViewer(conversation),
                        );
                      }),
                      const SizedBox(width: 8),
                      if (!_usesMobileLayout(context))
                        IconButton(
                          key: ValueKey(
                              'favorite-conversation-${conversation.id}'),
                          tooltip:
                              _favoriteConversations.contains(conversation.id)
                                  ? '取消收藏对话'
                                  : '收藏对话',
                          icon: Icon(
                              _favoriteConversations.contains(conversation.id)
                                  ? Icons.star
                                  : Icons.star_border),
                          iconSize: 18,
                          color:
                              _favoriteConversations.contains(conversation.id)
                                  ? AppTheme.orange
                                  : AppTheme.textMuted,
                          constraints: const BoxConstraints.tightFor(
                              width: 28, height: 28),
                          style: IconButton.styleFrom(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          padding: EdgeInsets.zero,
                          onPressed: () =>
                              _toggleFavoriteConversation(conversation.id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(children: [
                    Expanded(
                      child: Text(
                        '${_formatTime(conversation.updatedAt)}  ·  ${conversation.shortId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                    if (_isOpenedConversation(conversation) ||
                        _localOpenedConversationIds
                            .contains(conversation.id)) ...[
                      const SizedBox(width: 4),
                      Text('已打开',
                          style: TextStyle(color: AppTheme.cyan, fontSize: 10)),
                    ] else if (_runningChatJobs
                        .containsKey(conversation.id)) ...[
                      const SizedBox(width: 4),
                      Text('本软件聊天',
                          style: TextStyle(color: AppTheme.cyan, fontSize: 10)),
                    ] else if (!conversation.canResume) ...[
                      const SizedBox(width: 4),
                      Text(
                          conversation.state == CodexConversationState.running
                              ? '等待远端完成'
                              : conversation.canTakeover
                                  ? '需接管'
                                  : '不可恢复',
                          style:
                              TextStyle(color: AppTheme.orange, fontSize: 10)),
                    ],
                  ]),
                  ValueListenableBuilder<int>(
                    valueListenable: NotificationService.historyRevision,
                    builder: (context, _, __) {
                      final newlyCompleted = StorageService
                          .getCodexCompletionNotices()
                          .any((notice) =>
                              notice.connectionId == widget.connectionId &&
                              notice.threadId == conversation.id &&
                              !notice.read);
                      if (!newlyCompleted) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '刚完成 · 点击查看回复',
                          key: ValueKey('newly-completed-${conversation.id}'),
                          style: TextStyle(
                            color: AppTheme.green,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      );
                    },
                  ),
                  if (conversation.preview.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      conversation.preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConversationList({bool favoritesOnly = false}) {
    final runningView = _runningOnly && !favoritesOnly;
    final source = _conversationSource(favoritesOnly);
    final loading = runningView && widget.loadRunningConversations != null
        ? _loadingRunning : _loadingConversations;
    final error = runningView ? _runningError : _conversationError;
    if (loading && source.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppTheme.blue),
            SizedBox(height: 12),
            Text(
              '正在读取远程 Codex 对话…',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (error != null && source.isEmpty) {
      return Center(
        child: Text(
          '读取历史对话失败：$error',
          style: TextStyle(color: AppTheme.orange, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      );
    }

    if (source.isEmpty) {
      return Center(
        child: Text(
          runningView ? '当前没有正在执行或24小时内完成的对话' :
          _showAllConversations ? '远端没有找到 Codex 对话记录' : '当前目录没有找到 Codex 对话',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          textAlign: TextAlign.center,
        ),
      );
    }

    final filtered = _filteredConversations(favoritesOnly);
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          runningView
              ? '当前筛选条件下没有正在执行或24小时内完成的对话'
              : favoritesOnly && _favoriteConversations.isEmpty
              ? '还没有收藏的对话'
              : _filteredDirectories.isNotEmpty
                  ? '所选目录没有符合条件的 Codex 对话'
                  : '${_timeFilter.label}没有 Codex 对话',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
      );
    }

    final byDirectory = <String, List<CodexConversation>>{};
    for (final conversation in filtered) {
      byDirectory.putIfAbsent(conversation.cwd, () => []).add(conversation);
    }
    final counts = {
      for (final entry in byDirectory.entries)
        if (entry.key.isNotEmpty) entry.key: entry.value.length,
    };
    final children = _buildConversationDirectoryNodes(
        _directoryTree(counts), byDirectory, filtered);
    final withoutDirectory = byDirectory[''] ?? const <CodexConversation>[];
    if (withoutDirectory.isNotEmpty) {
      final collapsed = _collapsedConversationDirectoryPaths.contains('');
      children.add(InkWell(
        key: const ValueKey('conversation-directory-unrecorded'),
        onTap: () => setState(() {
          if (!_collapsedConversationDirectoryPaths.add('')) {
            _collapsedConversationDirectoryPaths.remove('');
          }
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 3),
            Icon(Icons.folder_outlined, size: 15, color: AppTheme.cyan),
            const SizedBox(width: 6),
            Expanded(
                child: Text('未记录目录',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11))),
            Text('${withoutDirectory.length} 条',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
          ]),
        ),
      ));
      if (!collapsed) {
        for (final conversation in withoutDirectory) {
          children.add(_buildConversationTile(conversation));
        }
      }
    }
    return ListView(padding: EdgeInsets.zero, children: children);
  }

  List<Widget> _buildConversationDirectoryNodes(
      List<_CodexDirectoryNode> nodes,
      Map<String, List<CodexConversation>> byDirectory,
      List<CodexConversation> filtered,
      {int depth = 0}) {
    List<CodexConversation> descendants(String path) => filtered
        .where((conversation) => _isDirectoryOrChild(conversation.cwd, path))
        .toList();

    nodes.sort((a, b) {
      final aItems = descendants(a.path);
      final bItems = descendants(b.path);
      int priority(_CodexDirectoryNode node, List<CodexConversation> items) =>
          (_favoriteDirectories.contains(node.path) ? 2 : 0) +
          (items.any((item) => _favoriteConversations.contains(item.id))
              ? 1
              : 0);
      final byPriority = priority(b, bItems) - priority(a, aItems);
      if (byPriority != 0) return byPriority;
      final aLatest = aItems
          .map((item) => item.updatedAt?.millisecondsSinceEpoch ?? 0)
          .reduce((a, b) => a > b ? a : b);
      final bLatest = bItems
          .map((item) => item.updatedAt?.millisecondsSinceEpoch ?? 0)
          .reduce((a, b) => a > b ? a : b);
      return bLatest.compareTo(aLatest);
    });

    final rows = <Widget>[];
    for (final node in nodes) {
      final collapsed =
          _collapsedConversationDirectoryPaths.contains(node.path);
      rows.add(InkWell(
        key: ValueKey('conversation-directory-${node.path}'),
        onTap: () => setState(() {
          if (!_collapsedConversationDirectoryPaths.add(node.path)) {
            _collapsedConversationDirectoryPaths.remove(node.path);
          }
        }),
        child: Padding(
          padding: EdgeInsets.only(
              left: (depth * 12).clamp(0, 60).toDouble(), top: 8, bottom: 5),
          child: Row(children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more,
                size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 3),
            Icon(Icons.folder_outlined, size: 15, color: AppTheme.cyan),
            const SizedBox(width: 6),
            Expanded(
                child:
                    _compactPath(node.name, fontSize: 11, fullPath: node.path)),
            Text('${node.totalCount} 条',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10)),
          ]),
        ),
      ));
      if (collapsed) continue;
      final conversations = [...?byDirectory[node.path]]..sort((a, b) {
          final favorite = (_favoriteConversations.contains(b.id) ? 1 : 0) -
              (_favoriteConversations.contains(a.id) ? 1 : 0);
          if (favorite != 0) return favorite;
          return (b.updatedAt?.millisecondsSinceEpoch ?? 0)
              .compareTo(a.updatedAt?.millisecondsSinceEpoch ?? 0);
        });
      for (final conversation in conversations) {
        rows.add(Padding(
          padding:
              EdgeInsets.only(left: ((depth + 1) * 12).clamp(0, 72).toDouble()),
          child: _buildConversationTile(conversation),
        ));
      }
      rows.addAll(_buildConversationDirectoryNodes(
          node.children.values.toList(), byDirectory, filtered,
          depth: depth + 1));
    }
    return rows;
  }

  String _joinPath(String base, String name) {
    return base == '/' ? '/$name' : '$base/$name';
  }

  String _parentPath(String path) {
    if (path.isEmpty || path == '/' || path == '~') return path;
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = normalized.lastIndexOf('/');
    if (index <= 0) return '/';
    return normalized.substring(0, index);
  }

  List<String> get _visibleDirectories {
    if (_showHiddenDirectories) return _directories;
    return _directories.where((dir) => !dir.startsWith('.')).toList();
  }

  Widget _buildDirectoryTile({
    required String label,
    required String path,
    required IconData icon,
    Color? iconColor,
  }) {
    final selected = path == _workDir;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, size: 18, color: iconColor ?? AppTheme.cyan),
      title: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: label == path
          ? null
          : Text(
              path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
      selected: selected,
      selectedTileColor: AppTheme.blueDim,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      onTap: _loadingDirectories
          ? null
          : () {
              if (_usesMobileLayout(context)) {
                setState(() => _mobileSection = 0);
              }
              unawaited(_loadDirectory(path));
            },
    );
  }

  Widget _buildDirectoryPane() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.folder_open, size: 17, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '项目目录',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: _showHiddenDirectories ? '隐藏隐藏目录' : '显示隐藏目录',
                onPressed: () => setState(
                  () => _showHiddenDirectories = !_showHiddenDirectories,
                ),
                icon: Icon(
                  _showHiddenDirectories
                      ? Icons.visibility
                      : Icons.visibility_off,
                  size: 17,
                ),
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: '刷新目录',
                onPressed: _loadingDirectories
                    ? null
                    : () => _loadDirectory(
                          _workDir,
                          loadAll: _showAllConversations,
                        ),
                icon: const Icon(Icons.refresh, size: 17),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          Text(
            _workDir,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 10,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          if (_loadingDirectories)
            Expanded(
              child: Center(
                child: CircularProgressIndicator(color: AppTheme.cyan),
              ),
            )
          else if (_directoryError != null)
            Expanded(
              child: Center(
                child: Text(
                  '目录读取失败：$_directoryError',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.orange,
                    fontSize: 12,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _buildConversationDirectories(),
                  _buildDirectoryTile(
                    label: '主目录',
                    path: _homePath,
                    icon: Icons.home,
                    iconColor: AppTheme.blue,
                  ),
                  if (_diskPaths.isNotEmpty) ...[
                    Padding(
                      padding: EdgeInsets.only(left: 4, top: 8, bottom: 2),
                      child: Text(
                        '磁盘目录',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    for (final path in _diskPaths)
                      _buildDirectoryTile(
                        label: path,
                        path: path,
                        icon: Icons.storage,
                        iconColor: AppTheme.purple,
                      ),
                  ],
                  const Divider(height: 12),
                  if (_workDir != '/' && _workDir != '~')
                    _buildDirectoryTile(
                      label: '../ 上级目录',
                      path: _parentPath(_workDir),
                      icon: Icons.arrow_upward,
                      iconColor: AppTheme.textSecondary,
                    ),
                  for (final dir in _visibleDirectories)
                    _buildDirectoryTile(
                      label: dir,
                      path: _joinPath(_workDir, dir),
                      icon: Icons.folder,
                    ),
                  if (_visibleDirectories.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        '当前目录没有可显示的子目录',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _selectConversation(CodexConversation conversation) {
    setState(() => _selectedConversationId = conversation.id);
    unawaited(_preloadConversation(conversation.id));
  }

  Future<void> _preloadConversation(String conversationId) async {
    try {
      await widget.loadRecords(conversationId);
    } catch (_) {
      // 预读失败由打开对话后的正常读取重试并显示错误。
    }
  }

  Future<void> _openConversationViewer(CodexConversation conversation) async {
    setState(() => _selectedConversationId = conversation.id);
    await showDialog<void>(
      context: context,
      builder: (_) => CodexConversationViewerDialog(
        connectionId: widget.connectionId,
        conversation: conversation,
        loadRecords: widget.loadRecords,
      ),
    );
    if (mounted) unawaited(_refreshActiveConversationStates());
  }

  Future<void> _confirmKillAndResume(CodexConversation conversation) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认 Kill 并恢复？'),
        content: Text(
          '将停止占用「${conversation.displayTitle}」的远端 Codex 进程，然后恢复这条对话。正在执行的回答会中断。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kill 并恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        _selectedConversation?.id != conversation.id) {
      return;
    }
    _submit(stopWriterBeforeLaunch: true);
  }

  Widget _buildSelectedConversationActions() {
    final conversation = _selectedConversation;
    if (conversation == null) return const SizedBox.shrink();

    final stateColor = _stateColor(conversation.state);
    final canTakeover = conversation.canTakeover;
    final canCheckRunningChat = _canCheckRunningChat(conversation);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 4),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.radio_button_checked, size: 14, color: stateColor),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${_conversationStateLabel(conversation)} · ${conversation.shortId}',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              if (conversation.writerLocked)
                Tooltip(
                  message: '远程 writer 正持有锁',
                  child: Icon(Icons.lock, size: 14, color: AppTheme.orange),
                ),
            ],
          ),
          Text(
            '${canCheckRunningChat ? '可接入' : conversation.state == CodexConversationState.running ? '等待当前执行完成' : conversation.canResume ? '可恢复' : canTakeover ? '需接管' : '不可恢复'} · ${conversation.recoveryReason}\n目录：${conversation.cwd}',
            style: TextStyle(
              color: canTakeover ? AppTheme.green : AppTheme.orange,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              if (canCheckRunningChat)
                TextButton.icon(
                  onPressed: _attachingRunningChat
                      ? null
                      : () => unawaited(_attachRunningChat(conversation)),
                  icon: const Icon(Icons.chat_outlined, size: 15),
                  label: const Text('接入聊天'),
                ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _selectedConversationId = null;
                  if (_usesMobileLayout(context)) {
                    _mobileSection = 0;
                  }
                }),
                icon: const Icon(Icons.add, size: 15),
                label: const Text('新建对话'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              TextButton.icon(
                onPressed: () => _openConversationViewer(conversation),
                icon: const Icon(Icons.visibility, size: 15),
                label: const Text('查看对话'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              OutlinedButton.icon(
                onPressed: canTakeover
                    ? () => _confirmKillAndResume(conversation)
                    : null,
                icon: const Icon(Icons.stop_circle_outlined, size: 15),
                label: const Text('Kill / 恢复'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.orange,
                  disabledForegroundColor: AppTheme.textMuted,
                  side:
                      BorderSide(color: AppTheme.orange.withValues(alpha: 0.5)),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                ),
              ),
              OutlinedButton.icon(
                onPressed: canTakeover
                    ? () => _submit(
                          launch: CodexConversationLaunch.fork,
                        )
                    : null,
                icon: const Icon(Icons.call_split, size: 15),
                label: const Text('Fork'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.purple,
                  disabledForegroundColor: AppTheme.textMuted,
                  side:
                      BorderSide(color: AppTheme.purple.withValues(alpha: 0.5)),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                ),
              ),
            ],
          ),
          if (!canTakeover && !canCheckRunningChat)
            Padding(
              padding: EdgeInsets.only(left: 6, bottom: 3),
              child: Text(
                conversation.directoryExists
                    ? '最后一轮完成后可执行恢复 / Fork'
                    : '请恢复对话原目录后手动刷新',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
              ),
            ),
        ],
      ),
    );
  }

  void _showConversationDirectoryFilter() {
    final roots = _directoryTree(_conversationDirectoryCounts);
    final collapsed = <String>{};
    var query = '';
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, updateSheet) {
          final visible = <(_CodexDirectoryNode, int)>[];
          bool matches(_CodexDirectoryNode node) =>
              node.path.toLowerCase().contains(query.toLowerCase()) ||
              node.children.values.any(matches);
          void collect(List<_CodexDirectoryNode> nodes, int depth) {
            for (final node in nodes) {
              if (query.isNotEmpty && !matches(node)) continue;
              visible.add((node, depth));
              if (query.isNotEmpty || !collapsed.contains(node.path)) {
                collect(node.children.values.toList(), depth + 1);
              }
            }
          }

          collect(roots, 0);
          return SafeArea(
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.72,
              child: Column(children: [
                ListTile(
                  title: const Text('筛选对话目录'),
                  subtitle: const Text('可多选；选择目录会包含子目录'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        key: const ValueKey(
                            'clear-conversation-directory-filter'),
                        onPressed: _filteredDirectories.isEmpty
                            ? null
                            : () {
                                setState(() => _filteredDirectories.clear());
                                _saveFilteredDirectories();
                                updateSheet(() {});
                              },
                        child: const Text('全部'),
                      ),
                      IconButton(
                        tooltip: '关闭目录筛选',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索目录',
                    ),
                    onChanged: (value) => updateSheet(() => query = value),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final (node, depth) = visible[index];
                      final selected = _filteredDirectories.contains(node.path);
                      final inherited = !selected &&
                          _filteredDirectories.any(
                              (path) => _isDirectoryOrChild(node.path, path));
                      return Row(children: [
                        SizedBox(width: depth * 12.0),
                        node.children.isEmpty
                            ? const SizedBox(width: 32)
                            : IconButton(
                                key: ValueKey(
                                    'quick-directory-expand-${node.path}'),
                                tooltip: collapsed.contains(node.path)
                                    ? '展开子目录'
                                    : '收起子目录',
                                onPressed: () => updateSheet(() {
                                  if (!collapsed.add(node.path)) {
                                    collapsed.remove(node.path);
                                  }
                                }),
                                icon: Icon(collapsed.contains(node.path)
                                    ? Icons.chevron_right
                                    : Icons.expand_more),
                                iconSize: 18,
                                constraints:
                                    const BoxConstraints.tightFor(width: 32),
                                padding: EdgeInsets.zero,
                              ),
                        Expanded(
                          child: CheckboxListTile(
                            key:
                                ValueKey('quick-directory-filter-${node.path}'),
                            value: selected || inherited,
                            onChanged: inherited
                                ? null
                                : (_) {
                                    _toggleDirectoryFilter(node.path);
                                    updateSheet(() {});
                                  },
                            controlAffinity: ListTileControlAffinity.leading,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: _compactPath(node.name,
                                fontSize: 12, fullPath: node.path),
                            secondary: Text('${node.totalCount} 条',
                                style: TextStyle(color: AppTheme.textMuted)),
                          ),
                        ),
                      ]);
                    },
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }

  void _selectOpenMode(bool useChat) {
    setState(() => _openAsChat = useChat);
    if (widget.onOpenModeChanged != null) {
      widget.onOpenModeChanged!(useChat);
    } else {
      unawaited(StorageService.setCodexChatMode(useChat));
    }
  }

  Widget _buildOpenedConversationsSection() {
    final activeChats = _conversations
        .where((conversation) =>
            (_runningChatJobs.containsKey(conversation.id) ||
                _localOpenedConversationIds.contains(conversation.id)) &&
            !_isOpenedConversation(conversation))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Text('当前打开 · ${_openedSessions.length + activeChats.length} 条',
              style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 190),
          child: ListView(
            shrinkWrap: true,
            children: [
              ...activeChats.map((conversation) => ListTile(
                    key: ValueKey('opened-chat-${conversation.id}'),
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(Icons.chat_bubble_outline,
                        size: 18, color: AppTheme.cyan),
                    title: Text(conversation.displayTitle,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_runningChatJobs.containsKey(conversation.id)
                        ? '本软件执行中'
                        : '本机文字聊天'),
                    trailing: _localOpenedConversationIds
                                .contains(conversation.id) &&
                            !_runningChatJobs.containsKey(conversation.id)
                        ? IconButton(
                            key: ValueKey('close-opened-chat-${conversation.id}'),
                            tooltip: '从当前打开移除',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              setState(() => _localOpenedConversationIds
                                  .remove(conversation.id));
                              unawaited(StorageService
                                  .setOpenedCodexConversations(
                                      widget.connectionId,
                                      _localOpenedConversationIds));
                            },
                          )
                        : const Icon(Icons.chevron_right, size: 18),
                    onTap: () => _selectConversation(conversation),
                  )),
              ..._openedSessions.map((session) {
              final conversation = CodexSessionService.matchOpenedConversation(
                  session, _conversations);
              return ListTile(
                key: ValueKey('opened-session-${session.name}'),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(Icons.tab, size: 18, color: AppTheme.cyan),
                title: Text(_openedSessionTitle(session),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(session.workDir,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: conversation == null
                    ? Text(_openAsChat ? '识别中' : '终端',
                        style: TextStyle(color: AppTheme.textMuted))
                    : const Icon(Icons.chevron_right, size: 18),
                onTap: () {
                  if (conversation != null) {
                    _selectConversation(conversation);
                    return;
                  }
                  Navigator.pop(
                      context,
                      CodexSessionConfig(
                        name: session.name,
                        workDir: session.workDir,
                        openSessionName: session.name,
                        openAsChat: _openAsChat,
                        openedSessionTitles: {
                          for (final opened in _openedSessions)
                            opened.name: _openedSessionTitle(opened),
                        },
                      ));
                },
              );
              }),
            ],
          ),
        ),
        const Divider(height: 12),
      ],
    );
  }

  Widget _buildConversationPane({bool favoritesOnly = false}) {
    final source = _conversationSource(favoritesOnly);
    final loading = _runningOnly && !favoritesOnly &&
            widget.loadRunningConversations != null
        ? _loadingRunning : _loadingConversations;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (favoritesOnly && _usesMobileLayout(context))
          _buildOpenedConversationsSection(),
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      favoritesOnly
                          ? '收藏的对话'
                          : _usesMobileLayout(context)
                              ? '远程对话'
                              : '远程 Codex 对话',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    loading && source.isEmpty
                        ? '读取中…'
                        : '${_filteredConversations(favoritesOnly).length} 条',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                  ),
                  if (!favoritesOnly) ...[
                    const SizedBox(width: 4),
                    for (final running in [false, true])
                      TextButton(
                        key: ValueKey(running
                            ? 'conversation-filter-running'
                            : 'conversation-filter-all'),
                        onPressed: () => _setRunningOnly(running),
                        style: TextButton.styleFrom(
                          foregroundColor: _runningOnly == running
                              ? AppTheme.blue
                              : AppTheme.textMuted,
                          backgroundColor: _runningOnly == running
                              ? AppTheme.blue.withValues(alpha: 0.12)
                              : Colors.transparent,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                        child: Text(running ? '正在执行' : '全部'),
                      ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            PopupMenuButton<_CodexTimeFilter>(
              tooltip: '按时间筛选',
              initialValue: _timeFilter,
              onSelected: (value) => setState(() => _timeFilter = value),
              itemBuilder: (context) => [
                for (final filter in _CodexTimeFilter.values)
                  PopupMenuItem(
                    value: filter,
                    child: Row(
                      children: [
                        Icon(
                          filter == _timeFilter
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          size: 15,
                        ),
                        const SizedBox(width: 8),
                        Text(filter.label),
                      ],
                    ),
                  ),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.schedule, size: 15),
                  const SizedBox(width: 3),
                  Text(_timeFilter.label),
                  const Icon(Icons.arrow_drop_down, size: 16),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('conversation-directory-filter'),
              tooltip: _filteredDirectories.isEmpty
                  ? '按目录筛选对话'
                  : '已筛选 ${_filteredDirectories.length} 个目录',
              onPressed: _showConversationDirectoryFilter,
              icon: _filteredDirectories.isEmpty
                  ? const Icon(Icons.folder_outlined, size: 18)
                  : Badge.count(
                      count: _filteredDirectories.length,
                      backgroundColor: AppTheme.blue,
                      child: const Icon(Icons.folder_outlined, size: 18),
                    ),
              color: _filteredDirectories.isEmpty
                  ? AppTheme.textSecondary
                  : AppTheme.blue,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(width: 36, height: 36),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
        if (!_usesMobileLayout(context)) _buildSelectedConversationActions(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Container(
            key: const ValueKey('conversation-list-divider'),
            height: 2,
            color: AppTheme.blue.withValues(alpha: 0.45),
          ),
        ),
        Expanded(child: _buildConversationList(favoritesOnly: favoritesOnly)),
        if (_showAllConversations &&
            _hasOlderConversations &&
            widget.loadMoreConversations != null)
          TextButton(
            onPressed: _loadingOlderConversations
                ? null
                : () => unawaited(_loadOlderConversations()),
            child: Text(_loadingOlderConversations ? '正在读取…' : '加载更早对话'),
          ),
      ],
    );
  }

  Widget _buildMobileSelectionBar() {
    final conversation = _selectedConversation;
    if (conversation == null) {
      return Row(
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const Spacer(),
          FilledButton(
            onPressed: () => unawaited(_showNewConversationSheet()),
            child: const Text('新建对话'),
          ),
        ],
      );
    }
    final canContinue =
        conversation.canResume || _isOpenedConversation(conversation);
    final canCheckRunningChat = _canCheckRunningChat(conversation);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: FilledButton(
            onPressed: _attachingRunningChat
                ? null
                : canContinue
                    ? _submit
                    : canCheckRunningChat
                        ? () => unawaited(_attachRunningChat(conversation))
                        : null,
            child: Text(_attachingRunningChat
                ? '正在接入…'
                : canCheckRunningChat
                    ? '接入对话'
                    : '继续对话'),
          ),
        ),
        const SizedBox(width: 8),
        PopupMenuButton<String>(
          key: const ValueKey('mobile-conversation-more'),
          tooltip: '更多操作',
          icon: const Icon(Icons.more_horiz),
          onSelected: (value) {
            if (value == 'favorite') {
              _toggleFavoriteConversation(conversation.id);
            } else if (value == 'kill') {
              _confirmKillAndResume(conversation);
            } else if (value == 'fork') {
              _submit(launch: CodexConversationLaunch.fork);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'favorite',
              child: Text(_favoriteConversations.contains(conversation.id)
                  ? '取消收藏'
                  : '收藏对话'),
            ),
            if (conversation.canTakeover) ...const [
              PopupMenuItem(value: 'fork', child: Text('Fork 副本')),
              PopupMenuItem(value: 'kill', child: Text('Kill 并恢复')),
            ],
          ],
        ),
      ]),
      if (!canContinue && !canCheckRunningChat)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('当前不可继续，请点眼睛查看历史。${conversation.recoveryReason}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.orange, fontSize: 11)),
        ),
    ]);
  }

  Widget _buildModeSelector() => Row(
        children: [
          Text('打开方式', style: TextStyle(color: AppTheme.textSecondary)),
          const Spacer(),
          SegmentedButton<bool>(
            key: const ValueKey('codex-open-mode'),
            segments: const [
              ButtonSegment(value: false, label: Text('终端')),
              ButtonSegment(value: true, label: Text('文字聊天')),
            ],
            selected: {_openAsChat},
            onSelectionChanged: (selected) => _selectOpenMode(selected.first),
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final isResuming = _selectedConversation != null;
    final screenSize = MediaQuery.sizeOf(context);
    if (_usesMobileLayout(context)) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.dialogTitle),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            if (widget.connectionId.isNotEmpty)
              CodexServerNotificationButton(connectionId: widget.connectionId),
            IconButton(
              tooltip: '新建对话',
              icon: const Icon(Icons.add),
              onPressed: () => unawaited(_showNewConversationSheet()),
            ),
            PopupMenuButton<bool>(
              key: const ValueKey('codex-open-mode'),
              tooltip: '打开方式',
              onSelected: _selectOpenMode,
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: false,
                  checked: !_openAsChat,
                  child: const Text('终端'),
                ),
                CheckedPopupMenuItem(
                  value: true,
                  checked: _openAsChat,
                  child: const Text('文字聊天'),
                ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                        _openAsChat
                            ? Icons.chat_bubble_outline
                            : Icons.terminal,
                        size: 18),
                    const SizedBox(width: 4),
                    Text(_openAsChat ? '聊天' : '终端'),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: () => setState(() => _mobileSection = 0),
                        icon: const Icon(Icons.chat_bubble_outline, size: 17),
                        label: const Text('对话'),
                        style: TextButton.styleFrom(
                          foregroundColor: _mobileSection == 0
                              ? AppTheme.blue
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        key: const ValueKey('favorites-section-tab'),
                        onPressed: () => setState(() {
                          _mobileSection = 1;
                          if (!_favoriteConversations
                              .contains(_selectedConversationId)) {
                            _selectedConversationId = null;
                          }
                        }),
                        icon: const Icon(Icons.star_border, size: 17),
                        label: const Text('收藏'),
                        style: TextButton.styleFrom(
                          foregroundColor: _mobileSection == 1
                              ? AppTheme.blue
                              : AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: switch (_mobileSection) {
                    1 => _buildConversationPane(favoritesOnly: true),
                    _ => _buildConversationPane(),
                  },
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: _buildMobileSelectionBar(),
        ),
      );
    }
    final dialogWidth = (screenSize.width - 160).clamp(560.0, 860.0).toDouble();
    final dialogHeight =
        (screenSize.height - 250).clamp(320.0, 520.0).toDouble();
    return AlertDialog(
      scrollable: false,
      title: Row(
        children: [
          Icon(Icons.code, color: AppTheme.blue, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(widget.dialogTitle,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          SizedBox(width: 290, child: _buildModeSelector()),
        ],
      ),
      content: SizedBox(
        width: dialogWidth,
        height: dialogHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 220, child: _buildDirectoryPane()),
            const SizedBox(width: 14),
            Expanded(child: _buildConversationPane()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            gradient: LinearGradient(
              colors: [AppTheme.blue, Color(0xFF4A90E2)],
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _attachingRunningChat
                  ? null
                  : isResuming && _canCheckRunningChat(_selectedConversation!)
                      ? () =>
                          unawaited(_attachRunningChat(_selectedConversation!))
                      : isResuming &&
                              !_selectedConversation!.canResume &&
                              !_isOpenedConversation(_selectedConversation!)
                          ? null
                          : isResuming
                              ? _submit
                              : () => unawaited(_showNewConversationSheet()),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  isResuming
                      ? (_canCheckRunningChat(_selectedConversation!)
                          ? '接入聊天'
                          : _openAsChat
                              ? '打开聊天'
                              : '恢复')
                      : (_openAsChat ? '新建聊天' : '创建'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class CodexConversationViewerDialog extends StatefulWidget {
  final String connectionId;
  final CodexConversation conversation;
  final Future<void> Function(String message)? queueMessage;
  final Future<List<CodexConversationRecord>> Function(String conversationId)
      loadRecords;

  const CodexConversationViewerDialog({
    this.connectionId = '',
    this.queueMessage,
    required this.conversation,
    required this.loadRecords,
  });

  @override
  State<CodexConversationViewerDialog> createState() =>
      _CodexConversationViewerDialogState();
}

class _CodexConversationViewerDialogState
    extends State<CodexConversationViewerDialog> {
  List<CodexConversationRecord> _records = const [];
  Timer? _refreshTimer;
  CodexConversationState? _observedState;
  bool _requestInFlight = false;
  bool _showFullLog = false;
  bool _loading = true;
  String? _error;
  final _messageController = TextEditingController();
  bool _sendingMessage = false;
  String? _sendStatus;
  String? _sendError;
  String? _queuedMessage;
  int _queuedMessageOccurrences = 0;

  int _messageOccurrences(List<CodexConversationRecord> records, String message) =>
      records.where((record) => record.kind == 'user' && record.text == message).length;

  Future<void> _sendRemoteMessage() async {
    final message = _messageController.text;
    if (_sendingMessage || message.trim().isEmpty) return;
    setState(() {
      _sendingMessage = true;
      _sendError = null;
      _sendStatus = null;
    });
    try {
      await (widget.queueMessage?.call(message) ??
          CodexSessionService.queueMessage(
              widget.connectionId, widget.conversation.id, message));
      if (!mounted) return;
      setState(() {
        _messageController.clear();
        _sendStatus = '已发送到远程队列';
        _queuedMessage = message;
        _queuedMessageOccurrences = _messageOccurrences(_records, message);
      });
      _refreshTimer?.cancel();
      _refreshTimer = Timer.periodic(const Duration(seconds: 2),
          (_) => unawaited(_loadRecords(quiet: true)));
      unawaited(_loadRecords(quiet: true));
    } catch (error) {
      if (mounted) setState(() => _sendError = '发送失败：$error');
    } finally {
      if (mounted) setState(() => _sendingMessage = false);
    }
  }


  @override
  void initState() {
    super.initState();
    _records = CodexSessionService.cachedRecords(
            widget.connectionId, widget.conversation.id) ??
        const [];
    unawaited(_loadRecords());
    if (widget.conversation.state == CodexConversationState.running ||
        widget.conversation.state == CodexConversationState.pending) {
      _refreshTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_loadRecords(quiet: true)),
      );
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _loadRecords({bool quiet = false}) async {
    if (_requestInFlight) return;
    _requestInFlight = true;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final records = await widget.loadRecords(widget.conversation.id);
      if (!mounted) return;
      final lastKind = records.isEmpty ? null : records.last.kind;
      if (_queuedMessage != null &&
          _messageOccurrences(records, _queuedMessage!) > _queuedMessageOccurrences) {
        _queuedMessage = null;
      }
      if (_queuedMessage == null &&
          (lastKind == 'task_complete' || lastKind == 'turn_aborted')) {
        _refreshTimer?.cancel();
      }
      setState(() {
        _records = records;
        _loading = false;
        _error = null;
        if (lastKind == 'task_complete') {
          _observedState = CodexConversationState.complete;
        } else if (lastKind == 'turn_aborted') {
          _observedState = CodexConversationState.aborted;
        } else if (_refreshTimer?.isActive == true && records.isNotEmpty) {
          _observedState = CodexConversationState.running;
        }
      });
      if (widget.connectionId.isNotEmpty && records.isNotEmpty) {
        final timestamps = [
          if (widget.conversation.updatedAt != null) widget.conversation.updatedAt!,
          ...records.map((record) => record.timestamp).whereType<DateTime>(),
        ];
        final viewedAt = timestamps.isEmpty ? DateTime.now() :
            timestamps.reduce((a, b) => a.isAfter(b) ? a : b);
        unawaited(NotificationService.markCodexConversationViewed(
            widget.connectionId, widget.conversation.id, viewedAt: viewedAt));
      }
    } catch (error) {
      if (!mounted) return;
      if (quiet && _records.isNotEmpty) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    } finally {
      _requestInFlight = false;
    }
  }

  String _formatTime(DateTime? value) {
    if (value == null) return '';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    final second = local.second.toString().padLeft(2, '0');
    return '$month-$day $hour:$minute:$second';
  }

  String _kindLabel(String kind) {
    return switch (kind) {
      'user' => '用户',
      'assistant' => 'Codex',
      'reasoning' => '推理',
      'tool_call' => '工具调用',
      'tool_output' => '工具输出',
      'task_started' => '任务开始',
      'task_complete' => '任务完成',
      'turn_aborted' => '已中止',
      _ => kind,
    };
  }

  Color _kindColor(String kind) {
    return switch (kind) {
      'user' => AppTheme.blue,
      'assistant' => AppTheme.green,
      'reasoning' => AppTheme.purple,
      'tool_call' || 'tool_output' => AppTheme.orange,
      'task_started' => AppTheme.cyan,
      'task_complete' => AppTheme.green,
      'turn_aborted' => AppTheme.red,
      _ => AppTheme.textMuted,
    };
  }

  bool _isConversationMessage(CodexConversationRecord record) {
    if (record.kind == 'assistant') return true;
    if (record.kind != 'user') return false;
    final text = record.text.trimLeft();
    return !text.startsWith('<environment_context>') &&
        !text.startsWith('<recommended_plugins>') &&
        !text.startsWith('<heartbeat>') &&
        !text.startsWith('<turn_aborted>') &&
        !text.startsWith('# AGENTS.md instructions');
  }

  Widget _buildRecord(CodexConversationRecord record) {
    final color = _kindColor(record.kind);
    final isMessage = record.kind == 'user' || record.kind == 'assistant';
    return Align(
      alignment: record.kind == 'user'
          ? Alignment.centerRight
          : Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: isMessage ? 0.92 : 1,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: record.kind == 'user'
                ? AppTheme.blue.withValues(alpha: 0.08)
                : AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color.withValues(alpha: 0.28)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    _kindLabel(record.kind),
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _formatTime(record.timestamp),
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              if (record.kind == 'user' || record.kind == 'assistant')
                ChatMarkdown(
                  record.text,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                )
              else
                SelectableText(
                  record.text,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewerContent() {
    final visibleRecords = _showFullLog
        ? _records
        : _records.where(_isConversationMessage).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${_queuedMessage != null ? '等待远程处理' : (_observedState ?? widget.conversation.state).label}  ·  ${widget.conversation.id}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            TextButton(
              key: const ValueKey('viewer-log-toggle'),
              onPressed: () => setState(() => _showFullLog = !_showFullLog),
              child: Text(_showFullLog ? '只看对话' : '完整日志'),
            ),
          ],
        ),
        if (widget.connectionId.isNotEmpty)
          CodexGoalCard(
            connectionId: widget.connectionId,
            conversationId: widget.conversation.id,
          ),
        const SizedBox(height: 10),
        Expanded(
          child: _loading && _records.isEmpty
              ? Center(
                  child: CircularProgressIndicator(color: AppTheme.blue),
                )
              : _error != null && _records.isEmpty
                  ? Center(
                      child: Text(
                        '读取远程对话失败：$_error',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppTheme.orange,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : visibleRecords.isEmpty
                      ? Center(
                          child: Text(
                            _records.isEmpty ? '远程记录为空' : '没有可显示的文字对话，可查看完整日志',
                            style: TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                            ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          itemCount: visibleRecords.length,
                          itemBuilder: (context, index) => _buildRecord(
                              visibleRecords[
                                  visibleRecords.length - 1 - index]),
                        ),
        ),
        if (!widget.conversation.isSubagent &&
            (widget.connectionId.isNotEmpty || widget.queueMessage != null)) ...[
          const SizedBox(height: 8),
          if (_sendError != null || _sendStatus != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(_sendError ?? _sendStatus!,
                  style: TextStyle(fontSize: 12,
                      color: _sendError == null ? AppTheme.green : AppTheme.red)),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('viewer-message-input'),
                  controller: _messageController,
                  enabled: !_sendingMessage,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    hintText: '发送消息到当前远程对话',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('viewer-send-message'),
                tooltip: '发送到远程对话',
                onPressed: _sendingMessage ? null : _sendRemoteMessage,
                icon: _sendingMessage
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send, size: 20),
              ),
            ],
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.shortestSide < 600) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.conversation.displayTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: '刷新记录',
              onPressed: _loading ? null : () => unawaited(_loadRecords()),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _buildViewerContent(),
          ),
        ),
      );
    }
    final width = (size.width - 180).clamp(560.0, 900.0).toDouble();
    final height = (size.height - 220).clamp(360.0, 650.0).toDouble();
    return AlertDialog(
      scrollable: false,
      title: Row(
        children: [
          Icon(Icons.article_outlined, color: AppTheme.blue, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.conversation.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '刷新记录',
            onPressed: _loading ? null : () => unawaited(_loadRecords()),
            icon: const Icon(Icons.refresh, size: 17),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
      content: SizedBox(
        width: width,
        height: height,
        child: _buildViewerContent(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class RemoteDirectoryListing {
  final String path;
  final List<String> dirs;
  final String homePath;
  final List<String> diskPaths;
  final String? error;

  const RemoteDirectoryListing({
    required this.path,
    required this.dirs,
    this.homePath = '~',
    this.diskPaths = const [],
    this.error,
  });
}

/// 读取远端目录，供 Codex 选择器和终端工作区共用。
class RemoteDirectoryService {
  static Future<RemoteDirectoryListing> list(
    String connectionId,
    String path,
  ) async {
    final client = SshService.getClient(connectionId);
    if (client == null) {
      return const RemoteDirectoryListing(
        path: '~',
        dirs: [],
        homePath: '~',
        diskPaths: [],
        error: 'SSH 未连接，请先等待连接成功',
      );
    }

    try {
      final quotedPath = _shellQuote(path);
      final result = await client.run(
        "python3 -c \""
        "import json, os, stat, sys\n"
        "raw = sys.argv[1] if len(sys.argv) > 1 else '~'\n"
        "p = os.path.abspath(os.path.expanduser(raw))\n"
        "home = os.path.abspath(os.path.expanduser('~'))\n"
        "disks = []\n"
        "try:\n"
        "  for ln in open('/proc/mounts', 'r', encoding='utf-8', errors='ignore'):\n"
        "    cols = ln.split()\n"
        "    if len(cols) < 2:\n"
        "      continue\n"
        "    fs = cols[0]\n"
        "    mount = cols[1].replace('\\\\040', ' ')\n"
        "    if not fs.startswith('/dev/'):\n"
        "      continue\n"
        "    try:\n"
        "      st = os.stat(os.path.realpath(fs))\n"
        "      if not stat.S_ISBLK(st.st_mode):\n"
        "        continue\n"
        "    except Exception:\n"
        "      continue\n"
        "    if fs.startswith('/dev/loop'):\n"
        "      continue\n"
        "    if mount == '/':\n"
        "      continue\n"
        "    if mount == home or home.startswith(mount + '/'):\n"
        "      continue\n"
        "    if (not os.path.isdir(mount)) or (not os.access(mount, os.R_OK | os.X_OK)):\n"
        "      continue\n"
        "    if mount not in disks:\n"
        "      disks.append(mount)\n"
        "  disks.sort()\n"
        "except Exception:\n"
        "  pass\n"
        "try:\n"
        "  names = sorted(os.listdir(p))\n"
        "  dirs = [n for n in names if os.path.isdir(os.path.join(p, n))]\n"
        "  print(json.dumps({'ok': True, 'cwd': p, 'dirs': dirs, 'home': home, 'disks': disks}, ensure_ascii=False))\n"
        "except Exception as e:\n"
        "  print(json.dumps({'ok': False, 'cwd': p, 'dirs': [], 'error': str(e), 'home': home, 'disks': disks}, ensure_ascii=False))\" "
        "$quotedPath",
      );
      final output = utf8.decode(result, allowMalformed: true).trim();
      final lines = output
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (lines.isEmpty) {
        return RemoteDirectoryListing(
          path: path,
          dirs: const [],
          homePath: '~',
          diskPaths: const [],
          error: '目录读取失败：服务器返回为空',
        );
      }

      Map<String, dynamic>? data;
      for (int i = lines.length - 1; i >= 0; i--) {
        try {
          final parsed = json.decode(lines[i]);
          if (parsed is Map<String, dynamic>) {
            data = parsed;
            break;
          }
        } catch (_) {
          // 忽略非 JSON 行（例如 stderr/提示信息），继续向前寻找。
        }
      }
      if (data == null) {
        final tail = lines.length > 3
            ? lines.sublist(lines.length - 3).join(' | ')
            : lines.join(' | ');
        return RemoteDirectoryListing(
          path: path,
          dirs: const [],
          homePath: '~',
          diskPaths: const [],
          error: '目录读取失败：返回格式异常（$tail）',
        );
      }

      final cwd = (data['cwd'] as String?) ?? path;
      final dirsRaw = data['dirs'] as List<dynamic>? ?? const [];
      final dirs = dirsRaw.map((e) => e.toString()).toList();
      final homePath = (data['home'] as String?)?.trim();
      final diskRaw = data['disks'] as List<dynamic>? ?? const [];
      final diskPaths = diskRaw
          .map((e) => e.toString().trim())
          .where((e) =>
              e.isNotEmpty &&
              _isDiskPathCandidate(
                e,
                (homePath == null || homePath.isEmpty) ? '~' : homePath,
              ))
          .toSet()
          .toList()
        ..sort();
      final normalizedHome =
          (homePath == null || homePath.isEmpty) ? '~' : homePath;
      if (data['ok'] != true) {
        return RemoteDirectoryListing(
          path: cwd,
          dirs: dirs,
          homePath: normalizedHome,
          diskPaths: diskPaths,
          error: (data['error'] as String?) ?? '目录读取失败',
        );
      }
      return RemoteDirectoryListing(
        path: cwd,
        dirs: dirs,
        homePath: normalizedHome,
        diskPaths: diskPaths,
      );
    } catch (e) {
      return RemoteDirectoryListing(
        path: path,
        dirs: const [],
        homePath: '~',
        diskPaths: const [],
        error: '目录读取失败: $e',
      );
    }
  }

  static bool _isDiskPathCandidate(String path, String homePath) {
    final p = path.trim();
    if (p.isEmpty || !p.startsWith('/')) return false;
    if (p == '/') return false;
    if (p == homePath || homePath.startsWith('$p/')) return false;
    return true;
  }

  static String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }
}

class _TmuxPaneSnapshot {
  final List<String> paneIds;
  final String? activePaneId;

  const _TmuxPaneSnapshot({
    required this.paneIds,
    required this.activePaneId,
  });

  int get paneCount => paneIds.length;

  Map<String, Object?> toDebugMap() {
    return <String, Object?>{
      'paneCount': paneCount,
      'paneIds': paneIds,
      'activePaneId': activePaneId,
    };
  }
}

class _ActiveTmuxPaneState {
  final String? paneId;
  final String? currentCommand;
  final SessionType sessionType;

  const _ActiveTmuxPaneState({
    required this.paneId,
    required this.currentCommand,
    required this.sessionType,
  });

  Map<String, Object?> toDebugMap() {
    return <String, Object?>{
      'paneId': paneId,
      'currentCommand': currentCommand,
      'sessionType': sessionType.name,
    };
  }
}

class _ActivityTransition {
  final _TabSession tab;
  final ClaudeActivity prev;
  final ClaudeActivity next;

  const _ActivityTransition({
    required this.tab,
    required this.prev,
    required this.next,
  });
}

class _ClaudeEnvParseResult {
  final List<MapEntry<String, String>> entries;
  final List<String> invalidLines;

  const _ClaudeEnvParseResult({
    required this.entries,
    required this.invalidLines,
  });
}

class _AutoLaunchCommand {
  final String command;
  final List<String> invalidEnvLines;

  const _AutoLaunchCommand({
    required this.command,
    this.invalidEnvLines = const [],
  });
}

class _PaneHistoryContent {
  final String paneId;
  final String text;

  const _PaneHistoryContent({
    required this.paneId,
    required this.text,
  });
}

class TmuxWorkspaceScreen extends StatefulWidget {
  final SshConnection connection;
  final String? initialSessionName;
  final String? initialConversationId;
  final Map<String, String> initialOpenedSessionTitles;
  final CodexSessionConfig? initialCodexConfig;
  final bool openCodexPickerOnOpen;
  final bool openInitialChat;

  const TmuxWorkspaceScreen({
    super.key,
    required this.connection,
    this.initialSessionName,
    this.initialConversationId,
    this.initialOpenedSessionTitles = const {},
    this.initialCodexConfig,
    this.openCodexPickerOnOpen = false,
    this.openInitialChat = false,
  });

  @override
  State<TmuxWorkspaceScreen> createState() => _TmuxWorkspaceScreenState();
}

/// 连接的第一站：先显示已有对话，后台连接并刷新远程数据。
class CodexConversationPickerScreen extends StatefulWidget {
  final SshConnection connection;
  final Future<void> Function()? connect;

  const CodexConversationPickerScreen({
    super.key,
    required this.connection,
    this.connect,
  });

  @override
  State<CodexConversationPickerScreen> createState() =>
      _CodexConversationPickerScreenState();
}

class _CodexConversationPickerScreenState
    extends State<CodexConversationPickerScreen> {
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openPicker());
    });
  }

  Future<void> _openPicker() async {
    if (mounted) {
      setState(() {
        _loading =
            CodexSessionService.cachedConversations(widget.connection.id)
                ?.isNotEmpty != true;
        _error = null;
      });
    }

    try {
      final connecting = widget.connect?.call() ??
          SshService.connectClient(widget.connection).then((_) {});
      // 对话框下一帧构建；提前捕获快速失败，错误仍由各读取入口显示。
      connecting.ignore();
      Future<T> afterConnect<T>(Future<T> Function() load) async {
        await connecting;
        return load();
      }

      final config = await showDialog<CodexSessionConfig>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CodexSessionDialog(
          connectionId: widget.connection.id,
          defaultName: 'codex-1',
          defaultWorkDir: '~',
          dialogTitle: '选择 Codex 对话',
          loadConversations: (workDir) => afterConnect(
              () => CodexSessionService.listForDirectory(
                  widget.connection.id, workDir)),
          loadAllConversations: () => afterConnect(
              () => CodexSessionService.listAll(widget.connection.id)),
          loadRunningConversations: () => afterConnect(
              () => CodexSessionService.listRunning(widget.connection.id)),
          loadMoreConversations: (offset) => afterConnect(
              () => CodexSessionService.listAllPage(widget.connection.id, offset)),
          startWithAllConversations: true,
          loadRecords: (conversationId) => afterConnect(
              () => CodexSessionService.readConversation(
                  widget.connection.id, conversationId)),
          loadDirectories: (path) => afterConnect(
              () => RemoteDirectoryService.list(widget.connection.id, path)),
          loadOpenedSessions: () => afterConnect(
              () => CodexSessionService.listOpened(widget.connection.id)),
          loadRunningChatJobs: () => afterConnect(
              () => CodexChatService.listActiveJobs(widget.connection.id)),
          findRunningChatJob: (conversationId) => afterConnect(
              () => CodexChatService.findRunningJob(
                  widget.connection.id, conversationId)),
        ),
      );
      if (!mounted) return;

      if (config == null) {
        Navigator.of(context).pop();
        return;
      }
      await connecting;
      if (!mounted) return;
      if (config.openAsChat &&
          config.stopWriterBeforeLaunch &&
          config.resumeConversation != null) {
        final error = await CodexSessionService.stopWriter(
          widget.connection.id,
          config.resumeConversation!.id,
          config.effectiveWorkDir,
        );
        if (error != null) throw StateError('Kill 远程 Codex 失败：$error');
        if (!mounted) return;
      }
      if (config.openAsChat && config.openSessionName != null) {
        setState(() => _loading = false);
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => TmuxWorkspaceScreen(
              connection: widget.connection,
              initialSessionName: config.openSessionName,
              initialConversationId: config.resumeConversation?.id,
              initialOpenedSessionTitles: config.openedSessionTitles,
              openInitialChat: true,
            ),
          ),
        );
        if (mounted) unawaited(_openPicker());
        return;
      }

      if (config.openAsChat) {
        setState(() => _loading = false);
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => CodexChatScreen(
              connection: widget.connection,
              workDir: config.effectiveWorkDir,
              conversation: config.resumeConversation,
              runningJobId: config.runningChatJobId,
              favoriteOnCreate: config.favoriteOnCreate,
              forkOnFirstSend: config.launch == CodexConversationLaunch.fork,
            ),
          ),
        );
        if (mounted) unawaited(_openPicker());
        return;
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => TmuxWorkspaceScreen(
            connection: widget.connection,
            initialCodexConfig: config.openSessionName == null ? config : null,
            initialSessionName: config.openSessionName,
            initialConversationId: config.resumeConversation?.id,
            initialOpenedSessionTitles: config.openedSessionTitles,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('选择 Codex 对话'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Center(
        child: _loading
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: AppTheme.blue),
                  SizedBox(height: 14),
                  Text(
                    '正在连接远程电脑…',
                    style: TextStyle(color: AppTheme.textMuted),
                  ),
                ],
              )
            : _error == null
                ? const SizedBox.shrink()
                : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off,
                    size: 36,
                    color: AppTheme.orange,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '无法打开远程 Codex 对话\n${_error ?? ''}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    children: [
                      OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('返回'),
                      ),
                      FilledButton(
                        onPressed: _openPicker,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

/// 远程同步状态
enum SyncStatus {
  idle, // 未开始
  syncing, // 同步中
  synced, // 已同步
  deployed, // 首次部署成功
  failed, // 同步失败
}

class _TmuxWorkspaceScreenState extends State<TmuxWorkspaceScreen> {
  final List<_TabSession> _tabs = [];
  int _currentIndex = 0;
  bool _showMobileSessionCards = true;
  Set<String> _serverAliveSessions = {};
  bool _checkedAlive = false;
  bool _didApplyInitialSession = false;
  bool _didCreateInitialCodexSession = false;
  bool _didOpenCodexPicker = false;
  bool _didOpenInitialChat = false;
  String? _pendingRouteSessionName;
  Future<void> Function()? _pendingAfterReply;
  bool _waitingForCodexReply = false;
  bool _switchingToChat = false;
  bool _chatTransitionPending = false;

  double _fontSize = StorageService.getTerminalFontSize();
  static const double _minFontSize = 6.0;
  static const double _maxFontSize = 24.0;
  static final RegExp _envKeyPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  // 远程自定义 tmux 配置（不依赖用户 ~/.tmux.conf）
  static const _remoteTmuxConfPath = '/tmp/.ssh_tool_tmux.conf';
  bool _tmuxConfigUploaded = false;

  // 远程同步
  SyncStatus _syncStatus = SyncStatus.idle;
  Timer? _pollTimer;
  bool _isLaunchingVscode = false;
  StreamSubscription<MacosShortcutEvent>? _macosShortcutSubscription;
  DateTime? _lastSinglePaneHintTime;
  Offset? _selectionPointerDownPosition;
  int? _selectionPointerTabIndex;
  bool _selectionDragActive = false;
  static const double _selectionDragThreshold = 4.0;

  // ===== 悬浮历史面板 =====
  OverlayEntry? _historyPanelOverlay;
  final ValueNotifier<String> _historyContent = ValueNotifier('');
  final ValueNotifier<String> _historyTitle = ValueNotifier('');
  bool _historyPanelAsPanel = true;
  bool _historyFetchInProgress = false;
  bool _historyRefreshPending = false;
  String? _pendingHistoryPaneId;
  String? _pendingHistoryTitle;

  // 鼠标滚轮 → tmux copy-mode 翻页节流
  Timer? _scrollThrottleTimer;
  bool _scrollPending = false;

  // resize 防抖：避免窗口拖拽时高频发送 SIGWINCH 导致 tmux 乱码
  final Map<String, Timer> _resizeTimers = {};

  @override
  void initState() {
    super.initState();
    _chatTransitionPending = widget.openInitialChat;
    _showMobileSessionCards = widget.initialSessionName == null;
    _historyPanelAsPanel = StorageService.getHistoryViewerAsPanel();
    // 设置当前活跃连接
    NotificationService.activeConnectionId = _connectionId;
    NotificationService.activeSessionName = null;
    NotificationService.routeTargetNotifier.addListener(_onRouteTargetChanged);
    unawaited(_initMacosShortcutBridge());
    _loadSessions();
  }

  @override
  void dispose() {
    _historyPanelOverlay?.remove();
    _historyPanelOverlay = null;
    _historyContent.dispose();
    _historyTitle.dispose();
    _pollTimer?.cancel();
    _scrollThrottleTimer?.cancel();
    for (final t in _resizeTimers.values) {
      t.cancel();
    }
    _resizeTimers.clear();
    for (final tab in _tabs) {
      tab.dispose();
    }
    _macosShortcutSubscription?.cancel();
    unawaited(
      MacosKeyboardBridge.setTmuxShortcutCaptureEnabled(
        false,
        reason: 'tmux screen disposed connection=$_connectionId',
      ),
    );
    // 清除活跃连接
    NotificationService.routeTargetNotifier
        .removeListener(_onRouteTargetChanged);
    NotificationService.activeConnectionId = null;
    NotificationService.activeSessionName = null;
    super.dispose();
  }

  Future<void> _initMacosShortcutBridge() async {
    if (!_isMacOS) {
      return;
    }
    await MacosKeyboardBridge.ensureInitialized();
    await MacosKeyboardBridge.clearLog();
    _macosShortcutSubscription?.cancel();
    _macosShortcutSubscription =
        MacosKeyboardBridge.events.listen(_handleNativeShortcutEvent);
    await MacosKeyboardBridge.setTmuxShortcutCaptureEnabled(
      true,
      reason: 'tmux screen mounted connection=$_connectionId',
    );
    await MacosKeyboardBridge.log(
      'tmux',
      'macOS shortcut bridge ready',
      _keyboardDebugContext(),
    );
  }

  void _handleNativeShortcutEvent(MacosShortcutEvent event) {
    if (!mounted) {
      return;
    }
    unawaited(
      MacosKeyboardBridge.log(
        'tmux',
        'handling native shortcut',
        <String, Object?>{
          ...event.toMap(),
          ..._keyboardDebugContext(),
        },
      ),
    );
    switch (event.action) {
      case 'pane-left':
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.left,
            source: 'native',
          ),
        );
        return;
      case 'pane-right':
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.right,
            source: 'native',
          ),
        );
        return;
      case 'pane-up':
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.up,
            source: 'native',
          ),
        );
        return;
      case 'pane-down':
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.down,
            source: 'native',
          ),
        );
        return;
      case 'tab-left':
        final newIndex = _currentIndex - 1;
        if (newIndex >= 0) {
          _switchTab(newIndex, source: 'native');
        }
        return;
      case 'tab-right':
        final newIndex = _currentIndex + 1;
        if (newIndex < _tabs.length) {
          _switchTab(newIndex, source: 'native');
        }
        return;
    }
  }

  Map<String, Object?> _keyboardDebugContext() {
    final tab = _currentTab;
    return <String, Object?>{
      'connectionId': _connectionId,
      'currentIndex': _currentIndex,
      'tabName': tab?.name,
      'tabConnected': tab?.isConnected,
      'tabConnecting': tab?.isConnecting,
      'focusNodeHasFocus': tab?.focusNode.hasFocus,
      'hasKeyboardConnection':
          tab?.terminalViewKey.currentState?.hasInputConnection == true,
    };
  }

  void _onRouteTargetChanged() {
    final target = NotificationService.routeTargetNotifier.value;
    if (target == null || target.connectionId != _connectionId) return;
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = NotificationService.routeTargetNotifier.value;
      if (current == null || current.connectionId != _connectionId) return;

      final index = _tabs.indexWhere((t) => t.name == current.sessionName);
      if (index >= 0) {
        _switchTab(index);
      } else {
        // 目标会话暂未加载，标记后触发一次远程同步
        _pendingRouteSessionName = current.sessionName;
        _syncRemoteState();
      }

      if (identical(NotificationService.routeTargetNotifier.value, current)) {
        NotificationService.routeTargetNotifier.value = null;
      }
    });
  }

  /// 初始化：先建立 SSH 连接，再同步远程 state.json
  /// 远程 state.json 是唯一数据源——首次使用时远程为空，不创建任何 Tab
  void _loadSessions() {
    _initConnection();
  }

  /// 建立一个基础 SSH 连接（不创建 tmux），用于同步远程状态
  /// 使用 connectClient() 只建立认证，不开 shell，避免 RangeError
  Future<void> _initConnection() async {
    setState(() => _syncStatus = SyncStatus.syncing);

    try {
      // 使用轻量级连接：只建立 SSH 认证，不开 shell
      await SshService.connectClient(widget.connection);

      if (!mounted) return;

      // 连接成功后同步远程状态（重置 syncing 以允许 _syncRemoteState 执行）
      setState(() => _syncStatus = SyncStatus.idle);
      await _syncRemoteState();
      if (!mounted) return;

      if (widget.openInitialChat && !_didOpenInitialChat) {
        _didOpenInitialChat = true;
        if (_currentTab?.resumeConversationId != null) {
          unawaited(_openChatForCurrent());
        } else if (_currentTab?.type == SessionType.codex) {
          unawaited(_resolveAndOpenTerminalChat(_currentIndex));
        } else {
          setState(() => _chatTransitionPending = false);
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('无法识别终端对应的 Codex 对话，请从对话列表中选择'),
          ));
        }
        return;
      }

      final initialCodexConfig = widget.initialCodexConfig;
      if (initialCodexConfig != null && !_didCreateInitialCodexSession) {
        _didCreateInitialCodexSession = true;
        if (initialCodexConfig.stopWriterBeforeLaunch &&
            initialCodexConfig.resumeConversation != null) {
          final error = await CodexSessionService.stopWriter(
            _connectionId,
            initialCodexConfig.resumeConversation!.id,
            initialCodexConfig.effectiveWorkDir,
          );
          if (!mounted) return;
          if (error != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Kill 远程 Codex 失败：$error')),
            );
            return;
          }
        }
        await _createSessionFromConfig(
          SessionType.codex,
          initialCodexConfig,
          _defaultName(SessionType.codex),
        );
        return;
      }

      if (!mounted || !widget.openCodexPickerOnOpen) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _didOpenCodexPicker) return;
        _didOpenCodexPicker = true;
        unawaited(
          _addSessionOfType(
            SessionType.codex,
            codexDialogTitle: '选择 Codex 对话',
            showAllCodexConversations: true,
          ),
        );
      });
    } catch (e) {
      if (mounted) {
        setState(() => _syncStatus = SyncStatus.failed);
      }
    }
  }

  /// 同步远程状态：tmux 确认会话存活，state.json 补充会话信息。
  Future<void> _syncRemoteState() async {
    if (_syncStatus == SyncStatus.syncing) return;
    setState(() => _syncStatus = SyncStatus.syncing);

    try {
      if (SshService.getClient(_connectionId) == null) {
        setState(() => _syncStatus = SyncStatus.failed);
        return;
      }

      final result = await RemoteStateService.sync(_connectionId);

      if (!mounted) return;

      final transitions = <_ActivityTransition>[];
      setState(() {
        _syncStatus =
            result.wasConfigured ? SyncStatus.synced : SyncStatus.deployed;
        _serverAliveSessions = result.aliveTmuxSessions;
        _checkedAlive = true;

        // 远程 state.json 中有记录 且 tmux 仍存活 → 添加 Tab
        for (final entry in result.sessions.entries) {
          final name = entry.key;
          final info = entry.value as Map<String, dynamic>;
          final isAlive = result.aliveTmuxSessions.contains(name);

          if (isAlive && !_tabs.any((t) => t.name == name)) {
            final type = SessionTypeExt.fromString(info['type'] as String?);
            final tab = _TabSession(
              name: name,
              workDir: (info['workDir'] as String?) ?? '~',
              type: type,
              displayTitle: widget.initialOpenedSessionTitles[name],
              resumeConversationId: info['conversationId'] as String? ??
                  (name == widget.initialSessionName
                      ? widget.initialConversationId
                      : null),
            );
            tab.claudeActivity = _parseActivity(info['activity'] as String?);
            _tabs.add(tab);
          }

          // 更新已有 Tab 的状态
          final existing = _tabs.where((t) => t.name == name).firstOrNull;
          if (existing != null) {
            existing.displayTitle ??= widget.initialOpenedSessionTitles[name];
            if (name == widget.initialSessionName) {
              existing.resumeConversationId ??= widget.initialConversationId;
            }
            final newActivity = _parseActivity(info['activity'] as String?);
            if (existing.claudeActivity != newActivity) {
              transitions.add(
                _ActivityTransition(
                  tab: existing,
                  prev: existing.claudeActivity,
                  next: newActivity,
                ),
              );
              existing.claudeActivity = newActivity;
            }
            if (info['workDir'] != null) {
              existing.workDir = info['workDir'] as String;
            }
          }
        }
        for (final name in result.aliveTmuxSessions) {
          if (_tabs.any((tab) => tab.name == name)) continue;
          final type = name.startsWith('codex') || name.startsWith('fork-')
              ? SessionType.codex
              : name.startsWith('claude')
                  ? SessionType.claude
                  : SessionType.shell;
          _tabs.add(_TabSession(
            name: name,
            workDir: '~',
            type: type,
            displayTitle: widget.initialOpenedSessionTitles[name],
            resumeConversationId: name == widget.initialSessionName
                ? widget.initialConversationId
                : null,
          ));
        }
      });

      for (final t in transitions) {
        _notifyClaudeStateTransition(t.tab, t.prev, t.next);
      }

      // 同步到本地存储（作为缓存，不作为数据源）
      _syncLocalStorage();

      // 通知点击后优先切到目标会话
      if (!_didApplyInitialSession && widget.initialSessionName != null) {
        final targetIndex =
            _tabs.indexWhere((t) => t.name == widget.initialSessionName);
        if (targetIndex >= 0) {
          _currentIndex = targetIndex;
          NotificationService.activeSessionName = _tabs[targetIndex].name;
        }
        _didApplyInitialSession = true;
      }

      // 运行中收到通知点击时，优先跳到目标会话
      if (_pendingRouteSessionName != null) {
        final routeIndex =
            _tabs.indexWhere((t) => t.name == _pendingRouteSessionName);
        if (routeIndex >= 0) {
          _currentIndex = routeIndex;
          NotificationService.activeSessionName = _tabs[routeIndex].name;
          _pendingRouteSessionName = null;
        }
      }

      // 自动连接所有未连接的 Tab（避免只连当前 tab，其他 tab 显示为橙色空状态）
      for (int i = 0; i < _tabs.length; i++) {
        if (!_tabs[i].isConnected && !_tabs[i].isConnecting) {
          _connectTab(i);
        }
      }
      if (_tabs.isNotEmpty) {
        final targetIndex = _currentIndex.clamp(0, _tabs.length - 1);
        NotificationService.activeSessionName = _tabs[targetIndex].name;
      }

      // 首次部署提示
      if (!result.wasConfigured && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已自动配置远程服务器（Claude hooks + 状态同步）'),
            duration: Duration(seconds: 3),
          ),
        );
      }

      _startPolling();
    } catch (e) {
      if (mounted) {
        setState(() => _syncStatus = SyncStatus.failed);
      }
    }
  }

  /// 将当前 Tab 列表同步到本地存储（仅作缓存）
  void _syncLocalStorage() {
    for (final tab in _tabs) {
      StorageService.saveTmuxSession(_connectionId, tab.name, tab.workDir,
          type: tab.type.name);
    }
  }

  /// 解析 activity 字符串为枚举
  ClaudeActivity _parseActivity(String? activity) {
    return switch (activity) {
      'generating' => ClaudeActivity.generating,
      'asking' => ClaudeActivity.asking,
      'finished' => ClaudeActivity.finished,
      _ => ClaudeActivity.idle,
    };
  }

  String get _connectionId => widget.connection.id;

  /// 定期轮询远程状态（每 5 秒）
  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _pollRemoteState();
    });
  }

  /// 轮询一次远程 state.json
  Future<void> _pollRemoteState() async {
    try {
      final sessions = await RemoteStateService.poll(_connectionId);
      if (sessions.isEmpty) return;
      if (!mounted) return;

      final transitions = <_ActivityTransition>[];
      setState(() {
        for (final entry in sessions.entries) {
          final name = entry.key;
          final info = entry.value as Map<String, dynamic>;
          final tab = _tabs.where((t) => t.name == name).firstOrNull;
          if (tab != null && tab.type != SessionType.shell) {
            final newActivity = _parseActivity(info['activity'] as String?);
            if (tab.claudeActivity != newActivity) {
              transitions.add(
                _ActivityTransition(
                  tab: tab,
                  prev: tab.claudeActivity,
                  next: newActivity,
                ),
              );
              tab.claudeActivity = newActivity;
            }
          }
        }
      });

      for (final t in transitions) {
        _notifyClaudeStateTransition(t.tab, t.prev, t.next);
      }
    } catch (_) {}
  }

  // ===== Claude 状态检测 =====

  /// Braille spinner 字符范围（Claude Code 使用）
  static final _braillePattern = RegExp(r'[\u2800-\u28FF]');

  /// 权限菜单模式：数字选项或 (y/n)
  static final _askingPattern =
      RegExp(r'(\d\)\s|[Yy]\s*/\s*[Nn]|\(y\/n\)|Yes, and|Do you want)');

  /// 提示符模式：行末 > 后跟空格或换行
  static final _promptPattern = RegExp(r'(?:^|\n)\s*>\s*$');

  /// 解析终端输出，更新 Claude 状态
  void _detectClaudeState(_TabSession tab, String text) {
    if (tab.type == SessionType.shell) return;

    tab.appendOutput(text);
    final prev = tab.claudeActivity;

    // 重置 idle 计时器（有新输出就重置）
    tab._idleTimer?.cancel();

    final hasBraille = _braillePattern.hasMatch(text);
    final hasAskingNow = _askingPattern.hasMatch(text);
    final hasPrompt = _promptPattern.hasMatch(text);

    ClaudeActivity next = prev;

    if (hasBraille) {
      // spinner 活跃 → 正在生成
      next = ClaudeActivity.generating;
    } else if (hasAskingNow) {
      // 出现权限菜单 → 在等用户确认
      next = ClaudeActivity.asking;
      if (prev != ClaudeActivity.asking) {
        // 提取提问文本（最近输出的最后几行）
        final lines = tab._recentOutput.split('\n');
        tab.lastQuestion = lines.length > 3
            ? lines.sublist(lines.length - 4).join('\n').trim()
            : tab._recentOutput.trim();
      }
    } else if (hasPrompt && prev == ClaudeActivity.generating) {
      // 仅从 generating -> finished，避免将 asking(橙色)误判为 finished(红色)
      next = ClaudeActivity.finished;
    }

    if (next != prev) {
      setState(() => tab.claudeActivity = next);
      _notifyClaudeStateTransition(tab, prev, next);
    }

    // finished 状态 3 秒后自动 → idle
    if (tab.claudeActivity == ClaudeActivity.finished) {
      tab._idleTimer = Timer(const Duration(seconds: 3), () {
        if (mounted && tab.claudeActivity == ClaudeActivity.finished) {
          setState(() => tab.claudeActivity = ClaudeActivity.idle);
        }
      });
    }
  }

  /// 状态变化回调：更新 UI + 触发通知
  void _notifyClaudeStateTransition(
      _TabSession tab, ClaudeActivity prev, ClaudeActivity next) {
    if (next == ClaudeActivity.finished && tab == _currentTab) {
      _flushPendingSwitch();
    }
    // 通知逻辑
    switch (next) {
      case ClaudeActivity.asking:
        break;
      case ClaudeActivity.finished:
        NotificationService.showClaudeFinished(_connectionId, tab.name);
        break;
      case ClaudeActivity.idle:
        NotificationService.cancelForSession(
          tab.name,
          connectionId: _connectionId,
        );
        break;
      case ClaudeActivity.generating:
        // 开始生成时取消之前的通知
        NotificationService.cancelForSession(
          tab.name,
          connectionId: _connectionId,
        );
        break;
    }
  }

  /// 连接某个 Tab

  /// 确保远程存在自定义 tmux 配置，不存在才写入
  Future<void> _ensureTmuxConfig(SSHClient client) async {
    if (_tmuxConfigUploaded) return;
    try {
      final tmuxVersion = utf8
          .decode(
            await client.run('tmux -V 2>/dev/null'),
            allowMalformed: true,
          )
          .trim();
      final check = utf8
          .decode(
            await client.run("test -f '$_remoteTmuxConfPath' && echo exists"),
            allowMalformed: true,
          )
          .trim();
      // 检查远端配置是否包含 tmux 原生鼠标复制所需项
      if (check == 'exists') {
        final content = utf8.decode(
          await client.run("cat '$_remoteTmuxConfPath'"),
          allowMalformed: true,
        );
        if (content.contains('mouse on') &&
            content.contains('set-clipboard') &&
            tmuxConfigMatchesClipboardTransport(content, tmuxVersion) &&
            content.contains('MouseDragEnd1Pane') &&
            content.contains('mode-keys vi')) {
          _tmuxConfigUploaded = true;
          return;
        }
        // 旧配置需要更新，继续往下覆盖
      }
      final config = buildTmuxConfig(tmuxVersion);
      await client.run(
        "cat > '$_remoteTmuxConfPath' << 'TMUX_CONF_EOF'\n${config}TMUX_CONF_EOF",
      );
      _tmuxConfigUploaded = true;
    } catch (_) {}
  }

  Future<void> _connectTab(int index) async {
    final tab = _tabs[index];
    if (tab.isConnected || tab.isConnecting) return;

    tab.terminal ??= Terminal(maxLines: 10000);
    tab.ensureTmuxMouseReporting();
    TerminalClipboardService.bind(tab.terminal!);
    tab.controller ??= TerminalController();
    _bindSelectionCache(tab);

    final sessionId = tab.sessionId(widget.connection.id);

    tab.terminal!.onOutput = (data) {
      if (tab.isConnected) {
        // 统一回车为 \r，减少首轮确认（直接按 Enter）的响应延迟
        final normalized = data.replaceAll('\r\n', '\r').replaceAll('\n', '\r');

        // Claude/Codex tab 拦截危险信号，防止误杀
        if (tab.type != SessionType.shell) {
          if (normalized == '\x03') {
            unawaited(_handleCtrlCInput(tab, sessionId));
            return;
          }
          if (normalized == '\x04') {
            unawaited(_handleCtrlDInput(tab, sessionId));
            return;
          }
          tab._lastCtrlCTime = null;
        }

        SshService.sendInput(sessionId, normalized);
      }
    };
    tab.terminal!.onResize = (w, h, pw, ph) {
      if (tab.isConnected) {
        // 防抖：窗口拖拽/字体变化时避免高频 resize 导致 tmux 乱码
        _resizeTimers[sessionId]?.cancel();
        _resizeTimers[sessionId] = Timer(const Duration(milliseconds: 300), () {
          SshService.resizePty(sessionId, w, h);
          _resizeTimers.remove(sessionId);
        });
      }
    };

    setState(() {
      tab.isConnecting = true;
      tab.errorMessage = null;
    });

    try {
      final session =
          await SshService.connect(widget.connection, sessionId: sessionId);
      session.tmuxName = tab.name;
      session.workDir = tab.workDir;
      final isReattach = session.outputBuffer.isNotEmpty;

      tab.subscription = session.rawOutputStream.listen(
        (data) {
          final text = utf8.decode(data, allowMalformed: true);
          tab.writeToTerminal(text);
          if (!tab.outputPaused) {
            _detectClaudeState(tab, text);
          }
        },
        onError: (error) => tab.writeToTerminal('\r\n[错误]: $error\r\n'),
      );

      setState(() {
        tab.isConnected = true;
        tab.isConnecting = false;
      });

      if (mounted && index == _currentIndex) {
        _focusCurrentTerminal(reason: 'connect-tab');
      }

      if (isReattach) {
        // tmux 会话重连：不回放旧 buffer（内含旧尺寸的转义序列，会导致排版错乱）
        // 等 TerminalView 布局完成后，强制 resize 抖动让 tmux 重新发送完整屏幕内容
        WidgetsBinding.instance.addPostFrameCallback((_) {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (!mounted || !tab.isConnected) return;
            final cols = tab.terminal!.viewWidth;
            final rows = tab.terminal!.viewHeight;
            if (cols > 0 && rows > 0) {
              SshService.forceRedraw(sessionId, cols, rows);
            }
          });
        });
      }

      if (!isReattach) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (tab.isConnected) {
          // 上传自定义 tmux 配置（首次连接时）
          final client = SshService.getClient(_connectionId);
          if (client != null) await _ensureTmuxConfig(client);
          final dir = tab.workDir.isNotEmpty ? tab.workDir : '~';
          // 先 source-file，确保已存在的 tmux server 也能拿到新的鼠标复制配置
          SshService.sendInput(
              sessionId,
              "tmux -f '$_remoteTmuxConfPath' start-server"
              " \\; source-file '$_remoteTmuxConfPath'"
              " \\; new-session -A -s ${_shellQuote(tab.name)} -c ${_shellQuote(dir)}"
              r" \; set mouse on \; set history-limit 10000 \; setw -g mode-keys vi \; set status-keys vi"
              "\n");
          // 只有首次创建时才发送 autoCommand（claude/codex），重连不发
          if (tab.isNewlyCreated && tab.type.autoCommand != null) {
            await Future.delayed(const Duration(milliseconds: 800));
            if (tab.isConnected) {
              final autoLaunch = _buildAutoLaunchCommand(tab);
              if (autoLaunch.command.isNotEmpty) {
                SshService.sendInput(sessionId, '${autoLaunch.command}\n');
              }
              if (mounted && autoLaunch.invalidEnvLines.isNotEmpty) {
                final invalidCount = autoLaunch.invalidEnvLines.length;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('已忽略 $invalidCount 行无效环境变量'),
                    backgroundColor: AppTheme.orange,
                  ),
                );
              }
            }
          }
          tab.isNewlyCreated = false;
        }
      }

      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 900),
          () => _refreshPaneCountForTab(index),
        ),
      );
    } catch (e) {
      setState(() {
        tab.isConnecting = false;
        tab.errorMessage = e.toString();
      });
    }
  }

  _TabSession? get _currentTab =>
      _tabs.isNotEmpty ? _tabs[_currentIndex] : null;

  bool get _useMobileSessionCards =>
      defaultTargetPlatform == TargetPlatform.android;

  String get _currentSessionId =>
      _currentTab?.sessionId(widget.connection.id) ?? '';

  void _switchTab(int index, {String source = 'ui'}) {
    if (index == _currentIndex) return;
    if (_currentTab?.claudeActivity == ClaudeActivity.generating) {
      _pendingAfterReply = () async {
        if (index < _tabs.length) _openMobileSession(index);
      };
      unawaited(_waitForCodexReplyIfNeeded(_currentTab!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前 AI 正在回答，完成后切换对话')),
      );
      return;
    }
    setState(() => _currentIndex = index);
    final tab = _tabs[index];
    unawaited(
      MacosKeyboardBridge.log(
        'tmux',
        'switch tab',
        <String, Object?>{
          'source': source,
          'targetIndex': index,
          'targetTab': tab.name,
          ..._keyboardDebugContext(),
        },
      ),
    );

    // 切换后让终端获得焦点，可以直接打字
    _focusCurrentTerminal(reason: 'switch-tab:$source');

    // 聚焦到该 Tab 时：finished/asking → idle，取消通知
    final wasAttentionNeeded = tab.claudeActivity == ClaudeActivity.finished ||
        tab.claudeActivity == ClaudeActivity.asking;
    if (wasAttentionNeeded) {
      tab._idleTimer?.cancel();
      setState(() => tab.claudeActivity = ClaudeActivity.idle);
      unawaited(_markSessionIdleOnRemote(tab.name));
    }
    NotificationService.cancelForSession(tab.name, connectionId: _connectionId);
    NotificationService.activeSessionName = tab.name;

    if (!tab.isConnected && !tab.isConnecting) {
      _connectTab(index);
    } else {
      unawaited(_refreshPaneCountForTab(index));
    }

    // 悬浮历史面板跟随 tab 切换自动刷新
    if (_isHistoryPanelOpen) {
      unawaited(_refreshHistoryPanelContent());
    }
  }

  void _openMobileSession(int index, {bool? openAsChat}) {
    final tab = _tabs[index];
    final useChat = openAsChat ?? StorageService.getCodexChatMode();
    if (useChat &&
        tab.type == SessionType.codex &&
        tab.resumeConversationId != null) {
      if (index != _currentIndex &&
          _currentTab?.claudeActivity == ClaudeActivity.generating) {
        _pendingAfterReply =
            () async => _openMobileSession(index, openAsChat: useChat);
        unawaited(_waitForCodexReplyIfNeeded(_currentTab!));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前 AI 正在回答，完成后切换对话')),
        );
        return;
      }
      if (index != _currentIndex) {
        _switchTab(index, source: 'session-card');
      }
      setState(() {
        _showMobileSessionCards = false;
        _chatTransitionPending = true;
      });
      unawaited(_openChatForCurrent());
      return;
    }
    if (useChat && tab.type == SessionType.codex) {
      setState(() => _chatTransitionPending = true);
      unawaited(_resolveAndOpenTerminalChat(index));
      return;
    }
    if (index != _currentIndex &&
        _currentTab?.claudeActivity == ClaudeActivity.generating) {
      _switchTab(index, source: 'session-card');
      return;
    }
    setState(() => _showMobileSessionCards = false);
    if (index == _currentIndex) {
      _focusCurrentTerminal(reason: 'open-session-card');
    } else {
      _switchTab(index, source: 'session-card');
    }
  }

  Future<void> _resolveAndOpenTerminalChat(int index) async {
    if (index >= _tabs.length) return;
    final tab = _tabs[index];
    try {
      var id = await CodexSessionService.findTerminalConversationId(
        _connectionId,
        tab.name,
      );
      if (id == null) {
        final conversations = await CodexSessionService.listAll(_connectionId);
        id = CodexSessionService.matchOpenedConversation(
          OpenedCodexSession(name: tab.name, workDir: tab.workDir),
          conversations,
        )?.id;
      }
      if (!mounted) return;
      final currentIndex = _tabs.indexOf(tab);
      if (currentIndex < 0) return;
      if (id == null) {
        throw StateError('无法唯一识别此终端的对话 ID，请从对话列表选择');
      }
      setState(() => tab.resumeConversationId = id);
      _openMobileSession(currentIndex, openAsChat: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _chatTransitionPending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切换文字聊天失败：$error')),
      );
    }
  }

  Future<void> _openChatForCurrent() async {
    final tab = _currentTab;
    final id = tab?.resumeConversationId;
    if (tab == null ||
        tab.type != SessionType.codex ||
        id == null ||
        _switchingToChat) {
      return;
    }
    if (!_chatTransitionPending) {
      setState(() => _chatTransitionPending = true);
    }
    if (tab.claudeActivity == ClaudeActivity.generating) {
      _pendingAfterReply = _openChatForCurrent;
      unawaited(_waitForCodexReplyIfNeeded(tab));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前 AI 正在回答，完成后切换到文字聊天')),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _switchingToChat = true;
      _chatTransitionPending = true;
    });
    var returnToPicker = false;
    var waitingForReply = false;
    try {
      final conversation =
          await CodexSessionService.findById(_connectionId, id);
      if (!mounted) return;
      if (conversation == null) throw StateError('远端找不到这个 Codex 对话');
      if (conversation.isSubagent) {
        throw StateError(conversation.recoveryReason);
      }
      if (conversation.state == CodexConversationState.running ||
          conversation.state == CodexConversationState.pending) {
        waitingForReply = true;
        _pendingAfterReply = _openChatForCurrent;
        unawaited(_waitForCodexReplyIfNeeded(tab));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前 AI 正在回答，完成后切换到文字聊天')),
        );
        return;
      }
      if (conversation.state == CodexConversationState.unknown &&
          conversation.writerLocked) {
        throw StateError('无法确认当前回答是否结束，请稍后重试');
      }
      if (!mounted) return;
      if (!tab.pausedForChat) {
        if (!tab.isConnected) await _connectTab(_currentIndex);
        if (!tab.isConnected) throw StateError('终端尚未连接');
        if (await CodexSessionService.isTerminalCodexRunning(
          _connectionId,
          tab.name,
        )) {
          SshService.sendInput(tab.sessionId(_connectionId), '\x04');
          await CodexSessionService.waitForTerminalCodexExit(
            _connectionId,
            tab.name,
          );
        }
        tab.pausedForChat = true;
        await CodexSessionService.waitForWriterUnlock(_connectionId, id);
      }
      if (!mounted) return;
      await _openChat(
        workDir: conversation.cwd,
        conversation: conversation,
      );
      returnToPicker =
          widget.openInitialChat && StorageService.getCodexChatMode();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('切换文字聊天失败：$error')),
      );
    } finally {
      if (mounted) {
        if (!waitingForReply) await _resumePausedTerminal(tab);
        if (mounted) {
          if (returnToPicker) {
            Navigator.of(context).pop();
          } else {
            setState(() {
              _switchingToChat = false;
              if (!waitingForReply) {
                _chatTransitionPending = false;
                if (_useMobileSessionCards &&
                    StorageService.getCodexChatMode()) {
                  _showMobileSessionCards = true;
                }
              }
            });
          }
        }
      }
    }
  }

  void _flushPendingSwitch() {
    final action = _pendingAfterReply;
    _pendingAfterReply = null;
    if (action == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(action());
    });
  }

  Future<void> _waitForCodexReplyIfNeeded(_TabSession tab) async {
    final id = tab.resumeConversationId;
    if (_waitingForCodexReply || tab.type != SessionType.codex || id == null) {
      return;
    }
    _waitingForCodexReply = true;
    try {
      while (mounted && tab == _currentTab && _pendingAfterReply != null) {
        await Future.delayed(const Duration(seconds: 3));
        if (!mounted || tab != _currentTab || _pendingAfterReply == null) {
          return;
        }
        try {
          final state =
              (await CodexSessionService.findById(_connectionId, id))?.state;
          if (state == CodexConversationState.complete ||
              state == CodexConversationState.aborted) {
            if (mounted) {
              setState(() => tab.claudeActivity = ClaudeActivity.finished);
            }
            _flushPendingSwitch();
            return;
          }
        } catch (_) {
          // 终端输出仍会在答复结束时触发切换。
        }
      }
    } finally {
      _waitingForCodexReply = false;
    }
  }

  Future<void> _resumePausedTerminal(_TabSession tab) async {
    if (!tab.pausedForChat || tab.resumeConversationId == null) return;
    tab.pausedForChat = false;
    try {
      await CodexSessionService.resumeInTmux(
        _connectionId,
        tab.name,
        tab.resumeConversationId!,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('恢复终端失败：$error')),
        );
      }
    }
  }

  Future<void> _openChat({
    required String workDir,
    CodexConversation? conversation,
    String? runningJobId,
    bool favoriteOnCreate = false,
    bool forkOnFirstSend = false,
  }) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => CodexChatScreen(
          connection: widget.connection,
          workDir: workDir,
          conversation: conversation,
          runningJobId: runningJobId,
          favoriteOnCreate: favoriteOnCreate,
          forkOnFirstSend: forkOnFirstSend,
        ),
      ),
    );
  }

  void _switchTabByDelta(int delta, {String source = 'ui'}) {
    final newIndex = _currentIndex + delta;
    if (newIndex < 0 || newIndex >= _tabs.length) {
      return;
    }
    _switchTab(newIndex, source: source);
  }

  Future<void> _refreshPaneCountForTab(int index) async {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    final client = SshService.getClient(_connectionId);
    if (client == null || !tab.isConnected) return;

    final previousPaneCount = tab.lastKnownPaneCount;
    await _readTmuxPaneSnapshot(tab, client);
    if (!mounted || index >= _tabs.length || !identical(_tabs[index], tab)) {
      return;
    }

    if (previousPaneCount != tab.lastKnownPaneCount) {
      setState(() {});
    }
  }

  /// 切换 Tab 后让终端自动获得键盘焦点
  void _focusCurrentTerminal({
    int retryCount = 0,
    String reason = 'unknown',
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _tabs.isEmpty) return;
      final tab = _tabs[_currentIndex];
      if (tab.terminal != null && tab.isConnected) {
        FocusScope.of(context).requestFocus(tab.focusNode);
        tab.terminalViewKey.currentState?.requestKeyboard();

        unawaited(
          MacosKeyboardBridge.log(
            'focus',
            'request terminal focus',
            <String, Object?>{
              'reason': reason,
              'retryCount': retryCount,
              ..._keyboardDebugContext(),
            },
          ),
        );

        final hasKeyboard =
            tab.terminalViewKey.currentState?.hasInputConnection == true;
        if ((!tab.focusNode.hasFocus || !hasKeyboard) && retryCount < 4) {
          unawaited(
            MacosKeyboardBridge.log(
              'focus',
              'focus retry scheduled',
              <String, Object?>{
                'reason': reason,
                'retryCount': retryCount,
                'nextRetryCount': retryCount + 1,
                ..._keyboardDebugContext(),
              },
            ),
          );
          Future.delayed(const Duration(milliseconds: 40), () {
            if (!mounted) return;
            _focusCurrentTerminal(
              retryCount: retryCount + 1,
              reason: reason,
            );
          });
        }
      }
    });
  }

  /// 生成默认会话名（如 claude-1, codex-2, shell-3）
  String _defaultName(SessionType type) {
    final prefix = type.name;
    int i = 1;
    while (_tabs.any((t) => t.name == '$prefix-$i')) {
      i++;
    }
    return '$prefix-$i';
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  bool get _isMacOS => !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  _ClaudeEnvParseResult _parseClaudeEnvText(String rawText) {
    final entries = <MapEntry<String, String>>[];
    final invalidLines = <String>[];
    final lines = rawText.split('\n');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty || line.startsWith('#')) continue;

      final eq = line.indexOf('=');
      if (eq <= 0) {
        invalidLines.add('第${i + 1}行: $line');
        continue;
      }

      final key = line.substring(0, eq).trim();
      final value = line.substring(eq + 1);
      if (!_envKeyPattern.hasMatch(key)) {
        invalidLines.add('第${i + 1}行: $line');
        continue;
      }

      entries.add(MapEntry(key, value));
    }

    return _ClaudeEnvParseResult(entries: entries, invalidLines: invalidLines);
  }

  _AutoLaunchCommand _buildAutoLaunchCommand(_TabSession tab) {
    final baseCommand = tab.resumeConversationId == null
        ? tab.type.autoCommand
        : CodexSessionService.commandForConversation(
            tab.resumeConversationId!,
            launch: tab.resumeLaunch,
          );
    if (baseCommand == null) {
      return const _AutoLaunchCommand(command: '');
    }

    if (!_isMacOS || tab.type != SessionType.claude) {
      return _AutoLaunchCommand(command: baseCommand);
    }

    final raw = StorageService.getClaudeEnvText(_connectionId);
    if (raw.isEmpty) {
      return _AutoLaunchCommand(command: baseCommand);
    }

    final parsed = _parseClaudeEnvText(raw);
    if (parsed.entries.isEmpty) {
      return _AutoLaunchCommand(
        command: baseCommand,
        invalidEnvLines: parsed.invalidLines,
      );
    }

    final exports = parsed.entries
        .map((entry) => 'export ${entry.key}=${_shellQuote(entry.value)}')
        .join('; ');
    return _AutoLaunchCommand(
      command: '$exports; $baseCommand',
      invalidEnvLines: parsed.invalidLines,
    );
  }

  String _vscodeRemoteAuthority() {
    final userPrefix = widget.connection.username.trim().isEmpty
        ? ''
        : '${widget.connection.username.trim()}@';
    final portSuffix =
        widget.connection.port == 22 ? '' : ':${widget.connection.port}';
    return 'ssh-remote+$userPrefix${widget.connection.host.trim()}$portSuffix';
  }

  String _vscodeRemotePath() {
    final rawPath = _currentTab?.workDir.trim() ?? '';
    if (rawPath.startsWith('/')) return rawPath;
    if (rawPath == '~' || rawPath.isEmpty) {
      return '/home/${widget.connection.username.trim()}';
    }
    if (rawPath.startsWith('~/')) {
      return '/home/${widget.connection.username.trim()}/${rawPath.substring(2)}';
    }
    return '/home/${widget.connection.username.trim()}';
  }

  Future<void> _openVscodeRemote() async {
    if (!_isMacOS || _isLaunchingVscode) return;

    final authority = _vscodeRemoteAuthority();
    final remotePath = _vscodeRemotePath();
    final codeArgs = ['--remote', authority, remotePath];

    setState(() => _isLaunchingVscode = true);
    try {
      var result = await Process.run('code', codeArgs);
      if (result.exitCode != 0) {
        result = await Process.run(
          'open',
          ['-a', 'Visual Studio Code', '--args', ...codeArgs],
        );
      }
      if (result.exitCode != 0) {
        throw Exception(
          'VSCode 启动失败 (exit=${result.exitCode}): ${result.stderr}',
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已请求 VSCode 打开远程连接')),
      );
    } catch (_) {
      if (!mounted) return;
      final command = 'code ${codeArgs.map(_shellQuote).join(' ')}';
      await Clipboard.setData(ClipboardData(text: command));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('启动失败，命令已复制：$command'),
          backgroundColor: AppTheme.orange,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLaunchingVscode = false);
      }
    }
  }

  String _joinRemotePath(String base, String name) {
    return base == '/' ? '/$name' : '$base/$name';
  }

  String _parentRemotePath(String path) {
    if (path == '/' || path.isEmpty) return '/';
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final idx = normalized.lastIndexOf('/');
    if (idx <= 0) return '/';
    return normalized.substring(0, idx);
  }

  Future<RemoteDirectoryListing> _listRemoteDirectories(String path) {
    return RemoteDirectoryService.list(_connectionId, path);
  }

  Future<String?> _pickRemoteDirectory(String initialPath) async {
    String currentPath = initialPath.isEmpty ? '~' : initialPath;
    bool loading = false;
    String? error;
    List<String> dirs = const [];
    String homePath = '~';
    List<String> diskPaths = const [];
    bool initialized = false;

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        Future<void> load(StateSetter setState, {String? path}) async {
          final nextPath = path ?? currentPath;
          setState(() {
            loading = true;
            error = null;
          });
          final result = await _listRemoteDirectories(nextPath);
          if (!mounted || !ctx.mounted) return;
          setState(() {
            currentPath = result.path;
            dirs = result.dirs;
            homePath = result.homePath;
            diskPaths = result.diskPaths;
            error = result.error;
            loading = false;
          });
        }

        return StatefulBuilder(
          builder: (ctx, setState) {
            if (!initialized) {
              initialized = true;
              Future.microtask(() => load(setState, path: currentPath));
            }

            return AlertDialog(
              title: const Text('选择服务器目录'),
              content: SizedBox(
                width: 420,
                height: 360,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.folder_open,
                            size: 16, color: AppTheme.textMuted),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            currentPath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '刷新',
                          onPressed: loading ? null : () => load(setState),
                          icon: const Icon(Icons.refresh, size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '主目录',
                        style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textMuted,
                            ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _quickPathChip(
                          label: homePath,
                          path: homePath,
                          loading: loading,
                          onTap: () => load(setState, path: homePath),
                        ),
                      ],
                    ),
                    if (diskPaths.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '磁盘目录',
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textMuted,
                              ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final p in diskPaths)
                            _quickPathChip(
                              label: p,
                              path: p,
                              loading: loading,
                              onTap: () => load(setState, path: p),
                            ),
                        ],
                      ),
                    ],
                    if (diskPaths.isEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '磁盘目录：未检测到可访问挂载点',
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                color: AppTheme.textMuted,
                              ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    if (loading)
                      Expanded(
                        child: Center(
                          child: CircularProgressIndicator(
                            color: AppTheme.cyan,
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (error != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  error!,
                                  style: TextStyle(
                                    color: AppTheme.red,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: ListView(
                                children: [
                                  if (currentPath != '/')
                                    ListTile(
                                      dense: true,
                                      leading: const Icon(Icons.arrow_upward,
                                          size: 18),
                                      title: const Text('../ 上级目录'),
                                      onTap: () => load(
                                        setState,
                                        path: _parentRemotePath(currentPath),
                                      ),
                                    ),
                                  for (final dir in dirs)
                                    ListTile(
                                      dense: true,
                                      leading: Icon(Icons.folder,
                                          size: 18, color: AppTheme.cyan),
                                      title: Text(dir),
                                      onTap: () => load(
                                        setState,
                                        path: _joinRemotePath(currentPath, dir),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed:
                      loading ? null : () => Navigator.pop(ctx, currentPath),
                  child: const Text('选择当前目录'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 快速新建会话：先选类型，再命名和目录（可留空用默认值）
  Future<void> _addSessionOfType(
    SessionType type, {
    String? codexDialogTitle,
    bool showAllCodexConversations = false,
  }) async {
    final active = _currentTab;
    if (active?.claudeActivity == ClaudeActivity.generating) {
      _pendingAfterReply = () => _addSessionOfType(
            type,
            codexDialogTitle: codexDialogTitle,
            showAllCodexConversations: showAllCodexConversations,
          );
      unawaited(_waitForCodexReplyIfNeeded(active!));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前 AI 正在回答，完成后再切换对话')),
      );
      return;
    }
    final defaultName = _defaultName(type);
    final defaultWorkDir =
        (_currentTab?.workDir.isNotEmpty ?? false) ? _currentTab!.workDir : '~';

    if (type == SessionType.codex) {
      final config = await showDialog<CodexSessionConfig>(
        context: context,
        builder: (_) => CodexSessionDialog(
          connectionId: _connectionId,
          defaultName: defaultName,
          defaultWorkDir: defaultWorkDir,
          dialogTitle: codexDialogTitle ?? '新建 Codex 会话',
          loadConversations: (workDir) =>
              CodexSessionService.listForDirectory(_connectionId, workDir),
          loadRunningConversations: () =>
              CodexSessionService.listRunning(_connectionId),
          loadAllConversations: showAllCodexConversations
              ? () async {
                  final conversations =
                      await CodexSessionService.listAll(_connectionId);
                  if (conversations.isNotEmpty) return conversations;
                  return CodexSessionService.listForDirectory(
                    _connectionId,
                    defaultWorkDir,
                  );
                }
              : null,
          loadMoreConversations: showAllCodexConversations
              ? (offset) => CodexSessionService.listAllPage(_connectionId, offset)
              : null,
          startWithAllConversations: showAllCodexConversations,
          loadRecords: (conversationId) => CodexSessionService.readConversation(
              _connectionId, conversationId),
          loadDirectories: _listRemoteDirectories,
          loadOpenedSessions: () =>
              CodexSessionService.listOpened(_connectionId),
          loadRunningChatJobs: () =>
              CodexChatService.listActiveJobs(_connectionId),
          findRunningChatJob: (conversationId) =>
              CodexChatService.findRunningJob(_connectionId, conversationId),
        ),
      );
      if (config != null) {
        if (config.openAsChat &&
            config.stopWriterBeforeLaunch &&
            config.resumeConversation != null) {
          final error = await CodexSessionService.stopWriter(
            _connectionId,
            config.resumeConversation!.id,
            config.effectiveWorkDir,
          );
          if (!mounted) return;
          if (error != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Kill 远程 Codex 失败：$error')),
            );
            return;
          }
        }
        if (config.openAsChat && config.openSessionName == null) {
          await _openChat(
            workDir: config.effectiveWorkDir,
            conversation: config.resumeConversation,
            runningJobId: config.runningChatJobId,
            favoriteOnCreate: config.favoriteOnCreate,
            forkOnFirstSend: config.launch == CodexConversationLaunch.fork,
          );
          return;
        }
        if (config.openSessionName != null) {
          for (final tab in _tabs) {
            tab.displayTitle ??= config.openedSessionTitles[tab.name];
          }
          final index =
              _tabs.indexWhere((tab) => tab.name == config.openSessionName);
          if (index >= 0) {
            _tabs[index].resumeConversationId ??= config.resumeConversation?.id;
            _openMobileSession(index, openAsChat: config.openAsChat);
          }
          return;
        }
        if (config.stopWriterBeforeLaunch &&
            config.resumeConversation != null) {
          final error = await CodexSessionService.stopWriter(
            _connectionId,
            config.resumeConversation!.id,
            config.effectiveWorkDir,
          );
          if (!mounted) return;
          if (error != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Kill 远程 Codex 失败：$error')),
            );
            return;
          }
        }
        await _createSessionFromConfig(type, config, defaultName);
      }
      return;
    }

    String sessionNameInput = '';
    String selectedWorkDir = defaultWorkDir;
    bool selectingDir = false;

    final config = await showDialog<CodexSessionConfig>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Row(
          children: [
            Icon(type.icon, color: type.color, size: 20),
            const SizedBox(width: 8),
            Text('新建 ${type.label} 会话'),
          ],
        ),
        content: StatefulBuilder(
          builder: (ctx, setState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                autofocus: true,
                style: TextStyle(
                    fontFamily: 'monospace', color: AppTheme.textPrimary),
                decoration: InputDecoration(
                  hintText: defaultName,
                  labelText: '会话名称（可留空）',
                  prefixIcon: const Icon(Icons.label),
                ),
                onChanged: (value) => sessionNameInput = value,
                onSubmitted: (_) => Navigator.pop(
                  ctx,
                  CodexSessionConfig(
                    name: sessionNameInput.trim(),
                    workDir: selectedWorkDir,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.bgCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.folder, size: 16, color: AppTheme.textMuted),
                        SizedBox(width: 6),
                        Text('工作目录',
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textMuted)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      selectedWorkDir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: selectingDir
                            ? null
                            : () async {
                                setState(() => selectingDir = true);
                                final picked =
                                    await _pickRemoteDirectory(selectedWorkDir);
                                if (!mounted || !ctx.mounted) return;
                                setState(() {
                                  if (picked != null && picked.isNotEmpty) {
                                    selectedWorkDir = picked;
                                  }
                                  selectingDir = false;
                                });
                              },
                        icon: selectingDir
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.folder_open, size: 16),
                        label: const Text('选择服务器目录'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: LinearGradient(
                colors: [type.color, type.color.withValues(alpha: 0.7)],
              ),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => Navigator.pop(
                  ctx,
                  CodexSessionConfig(
                    name: sessionNameInput.trim(),
                    workDir: selectedWorkDir,
                  ),
                ),
                borderRadius: BorderRadius.circular(8),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('创建',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 14)),
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (config == null) return; // 用户取消

    await _createSessionFromConfig(type, config, defaultName);
  }

  Future<void> _createSessionFromConfig(
    SessionType type,
    CodexSessionConfig config,
    String defaultName,
  ) async {
    final safeName = config.name.isEmpty ? defaultName : config.name;
    final resolvedName = config.resumeConversation == null
        ? safeName
        : (config.name.isEmpty
            ? '${config.launch == CodexConversationLaunch.fork ? 'fork-' : 'codex-'}${config.resumeConversation!.shortId}'
            : safeName);
    final safeWorkDir =
        config.effectiveWorkDir.isEmpty ? '~' : config.effectiveWorkDir;

    if (_tabs.any((t) => t.name == resolvedName)) {
      final existingIndex = _tabs.indexWhere((t) => t.name == resolvedName);
      if (existingIndex >= 0 &&
          _tabs[existingIndex].resumeConversationId ==
              config.resumeConversation?.id) {
        _openMobileSession(existingIndex);
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('会话 "$resolvedName" 已存在')),
        );
      }
      return;
    }

    final tab = _TabSession(
      name: resolvedName,
      type: type,
      workDir: safeWorkDir,
      displayTitle: config.resumeConversation?.title,
      resumeConversationId: config.resumeConversation?.id,
      resumeLaunch: config.launch,
      isNewlyCreated: true,
    );
    setState(() {
      _tabs.add(tab);
      _currentIndex = _tabs.length - 1;
      if (_useMobileSessionCards) _showMobileSessionCards = false;
    });
    _connectTab(_currentIndex);

    // 立即推送到远程 state.json + 本地缓存
    _pushSessionToRemote(resolvedName, type.name, safeWorkDir,
        conversationId: config.resumeConversation?.id);
    StorageService.saveTmuxSession(_connectionId, resolvedName, safeWorkDir,
        type: type.name);
  }

  /// 将一条会话记录推送到远程 state.json
  Future<void> _pushSessionToRemote(String name, String type, String workDir,
      {String? conversationId}) async {
    final client = SshService.getClient(_connectionId);
    if (client == null) return;
    try {
      // 用 update_state.py 的逻辑类似，但直接写入指定字段
      await client.run(
        "python3 -c \""
        "import json,os,datetime; "
        "f=os.path.expanduser('~/.ssh_tool/state.json'); "
        "d=json.loads(open(f).read() or '{}') if os.path.exists(f) else {}; "
        "d.setdefault('sessions',{})['$name']="
        "{'type':'$type','activity':'idle','message':'','workDir':'$workDir',"
        "'conversationId':'${conversationId ?? ''}',"
        "'updatedAt':datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}; "
        "json.dump(d,open(f,'w'),indent=2)"
        "\"",
      );
    } catch (_) {}
  }

  /// 用户已查看该会话时，将远端状态从 finished/asking 归档为 idle，避免历史消息重复提醒
  Future<void> _markSessionIdleOnRemote(String name) async {
    final client = SshService.getClient(_connectionId);
    if (client == null) return;
    final quotedName = _shellQuote(name);
    try {
      await client.run(
        "python3 -c \""
        "import datetime,json,os,sys; "
        "n=sys.argv[1]; "
        "f=os.path.expanduser('~/.ssh_tool/state.json'); "
        "d=json.loads(open(f).read() or '{}') if os.path.exists(f) else {}; "
        "ts=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'); "
        "s=d.setdefault('sessions',{}).get(n); "
        "isinstance(s,dict) and s.update({'activity':'idle','message':'','updatedAt':ts}); "
        "json.dump(d,open(f,'w'),indent=2)"
        "\" $quotedName",
      );
    } catch (_) {}
  }

  /// Tab 长按/右键菜单
  void _showTabContextMenu(int index) {
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    final offset = box?.localToGlobal(Offset.zero) ?? Offset.zero;
    _showTabContextMenuAt(index, Offset(offset.dx + 100, offset.dy + 60));
  }

  void _showTabContextMenuAt(int index, Offset position) async {
    final result = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: [
        const PopupMenuItem(
            value: 'rename',
            child: Row(
              children: [
                Icon(Icons.edit, size: 16),
                SizedBox(width: 8),
                Text('重命名')
              ],
            )),
        PopupMenuItem(
            value: 'delete',
            child: Row(
              children: [
                Icon(Icons.delete, size: 16, color: AppTheme.red),
                SizedBox(width: 8),
                Text('删除', style: TextStyle(color: AppTheme.red))
              ],
            )),
      ],
    );
    if (result == 'rename') {
      _renameSession(index);
    } else if (result == 'delete') {
      _deleteSession(index);
    }
  }

  /// 重命名会话
  Future<void> _renameSession(int index) async {
    final tab = _tabs[index];
    final controller = TextEditingController(text: tab.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入新名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty || newName == tab.name) return;

    // 检查名称冲突
    if (_tabs.any((t) => t.name == newName)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('会话名 "$newName" 已存在'),
              backgroundColor: AppTheme.red),
        );
      }
      return;
    }

    final oldName = tab.name;

    // 远程重命名 tmux 会话
    final client = SshService.getClient(_connectionId);
    if (client != null) {
      try {
        await client
            .run("tmux rename-session -t '$oldName' '$newName' 2>/dev/null");
      } catch (_) {}
    }

    // 更新本地状态
    setState(() {
      tab.name = newName;
      if (_serverAliveSessions.contains(oldName)) {
        _serverAliveSessions.remove(oldName);
        _serverAliveSessions.add(newName);
      }
    });

    // 更新远程 state.json
    _removeRemoteSession(oldName);
    _pushSessionToRemote(newName, tab.type.name, tab.workDir,
        conversationId: tab.resumeConversationId);

    // 更新本地缓存
    await StorageService.deleteTmuxSession(widget.connection.id, oldName);
    await StorageService.saveTmuxSession(
        widget.connection.id, newName, tab.workDir,
        type: tab.type.name);
  }

  /// 删除会话 — 同时 kill 服务器上的 tmux 会话
  Future<void> _deleteSession(int index) async {
    final tab = _tabs[index];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭并删除会话'),
        content: Text('确定关闭 tmux 会话 "${tab.name}" 吗？\n这会同时终止服务器上的 tmux 会话。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.red),
            child: const Text('关闭'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final sessionId = tab.sessionId(widget.connection.id);
    await _killRemoteTmuxSession(tab.name);
    _removeRemoteSession(tab.name);

    final removedName = tab.name;
    setState(() {
      _tabs.removeAt(index);
      if (_currentIndex >= _tabs.length) {
        _currentIndex = _tabs.isEmpty ? 0 : _tabs.length - 1;
      }
      _serverAliveSessions.remove(removedName);
      NotificationService.activeSessionName =
          _tabs.isNotEmpty ? _tabs[_currentIndex].name : null;
    });

    if (SshService.isConnected(sessionId)) {
      await SshService.disconnect(sessionId);
    }
    if (mounted) {
      await WidgetsBinding.instance.endOfFrame;
    }
    tab.dispose();
    await StorageService.deleteTmuxSession(widget.connection.id, removedName);
  }

  /// 从远程 state.json 删除会话记录
  Future<void> _removeRemoteSession(String name) async {
    final client = SshService.getClient(_connectionId);
    if (client == null) return;
    try {
      await client.run(
        "python3 -c \""
        "import json,os; "
        "f=os.path.expanduser('~/.ssh_tool/state.json'); "
        "d=json.load(open(f)) if os.path.exists(f) else {'version':1,'sessions':{}}; "
        "d.get('sessions',{}).pop('$name',None); "
        "json.dump(d,open(f,'w'),indent=2)"
        "\"",
      );
    } catch (_) {}
  }

  /// 在服务器上执行 tmux kill-session
  Future<void> _killRemoteTmuxSession(String tmuxName) async {
    final client = SshService.getClient(_connectionId);
    if (client == null) return;
    try {
      await client.run("tmux kill-session -t '$tmuxName' 2>/dev/null || true");
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final showingMobileCards =
        _useMobileSessionCards && _showMobileSessionCards;
    final showingMobileTerminal =
        _useMobileSessionCards && !_showMobileSessionCards;
    return PopScope(
      canPop: _chatTransitionPending || !showingMobileTerminal,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && showingMobileTerminal) {
          setState(() => _showMobileSessionCards = true);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: !_chatTransitionPending && showingMobileTerminal
              ? IconButton(
                  tooltip: '返回对话卡片',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () =>
                      setState(() => _showMobileSessionCards = true),
                )
              : null,
          title: Text(_chatTransitionPending
              ? '正在打开聊天'
              : showingMobileTerminal
                  ? (_currentTab?.displayName ?? widget.connection.name)
                  : widget.connection.name),
          actions: _chatTransitionPending
              ? const []
              : [
                  CodexServerNotificationButton(
                      connectionId: widget.connection.id),
                  if (showingMobileCards)
                    PopupMenuButton<SessionType>(
                      tooltip: '新建会话',
                      icon: const Icon(Icons.add),
                      onSelected: _addSessionOfType,
                      itemBuilder: (_) => [
                        for (final type in [
                          SessionType.claude,
                          SessionType.codex,
                          SessionType.shell
                        ])
                          PopupMenuItem(value: type, child: Text(type.label)),
                      ],
                    ),
                  if (!showingMobileCards) ...[
                    if (_isMacOS &&
                        _currentTab?.type == SessionType.codex)
                      IconButton(
                        icon: const Icon(Icons.chat_bubble_outline, size: 20),
                        tooltip: '切换文字聊天',
                        onPressed: () => _openMobileSession(
                          _currentIndex,
                          openAsChat: true,
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.text_decrease, size: 20),
                      onPressed: _fontSize > _minFontSize
                          ? () {
                              setState(() => _fontSize = (_fontSize - 1)
                                  .clamp(_minFontSize, _maxFontSize));
                              StorageService.setTerminalFontSize(_fontSize);
                            }
                          : null,
                      tooltip: '缩小字体',
                    ),
                    IconButton(
                      icon: const Icon(Icons.text_increase, size: 20),
                      onPressed: _fontSize < _maxFontSize
                          ? () {
                              setState(() => _fontSize = (_fontSize + 1)
                                  .clamp(_minFontSize, _maxFontSize));
                              StorageService.setTerminalFontSize(_fontSize);
                            }
                          : null,
                      tooltip: '放大字体',
                    ),
                    if (!_useMobileSessionCards)
                      PopupMenuButton<_TmuxSplitDirection>(
                        enabled: _currentTab?.isConnected == true,
                        tooltip: 'tmux 分割',
                        icon: const Icon(Icons.call_split, size: 20),
                        onSelected: _splitCurrentTmuxPane,
                        itemBuilder: (_) => [
                          for (final direction in _TmuxSplitDirection.values)
                            PopupMenuItem<_TmuxSplitDirection>(
                              value: direction,
                              child: Text(direction.label),
                            ),
                        ],
                      ),
                    IconButton(
                      icon: Icon(
                        Icons.history,
                        size: 20,
                        color: _isHistoryPanelOpen ? AppTheme.cyan : null,
                      ),
                      tooltip: _isHistoryPanelOpen ? '关闭历史浏览' : '浏览 pane 历史',
                      onPressed: () {
                        if (_isHistoryPanelOpen) {
                          _closeHistoryPanel();
                          setState(() {});
                        } else {
                          unawaited(_openHistoryViewer());
                        }
                      },
                    ),
                    if (_isMacOS)
                      IconButton(
                        icon: _isLaunchingVscode
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.developer_mode, size: 20),
                        onPressed:
                            _isLaunchingVscode ? null : _openVscodeRemote,
                        tooltip: '用 VSCode 打开远程连接',
                      ),
                  ],
                  _buildSyncIndicator(),
                ],
        ),
        body: _chatTransitionPending
            ? Center(
                key: const ValueKey('codex-chat-transition'),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(_pendingAfterReply == null
                        ? '正在切换到文字聊天…'
                        : '等待当前回答完成后切换…'),
                  ],
                ),
              )
            : showingMobileCards
                ? _buildMobileSessionCards()
                : Column(
                    children: [
                      if (!_useMobileSessionCards) _buildTabBar(),
                      Expanded(child: _buildTerminalArea()),
                      if (_currentTab?.isConnected == true && !Platform.isMacOS)
                        _buildQuickKeysBar(),
                    ],
                  ),
      ),
    );
  }

  Widget _buildMobileSessionCards() {
    if (_tabs.isEmpty) {
      return _buildTerminalArea();
    }
    return ListView.builder(
      key: const ValueKey('mobile-session-cards'),
      padding: const EdgeInsets.all(12),
      itemCount: _tabs.length,
      itemBuilder: (context, index) {
        final tab = _tabs[index];
        final activity = tab.isConnecting
            ? '连接中'
            : tab.errorMessage != null && !tab.isConnected
                ? '连接失败'
                : !tab.isConnected
                    ? '未连接'
                    : switch (tab.claudeActivity) {
                        ClaudeActivity.generating => '正在执行',
                        ClaudeActivity.asking => '等待确认',
                        ClaudeActivity.finished => '已完成',
                        ClaudeActivity.idle => '已连接',
                      };
        return Card(
          color: AppTheme.bgCard,
          margin: const EdgeInsets.only(bottom: 10),
          child: InkWell(
            key: ValueKey('mobile-session-${tab.name}'),
            borderRadius: BorderRadius.circular(12),
            onTap: () => _openMobileSession(index),
            onLongPress: () => _showTabContextMenu(index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(tab.type.icon, color: tab.type.color, size: 25),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tab.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 16)),
                        if (tab.displayName != tab.name)
                          Text(tab.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: AppTheme.textMuted, fontSize: 11)),
                        const SizedBox(height: 4),
                        Text('${tab.type.label} · $activity',
                            style: TextStyle(
                                color: AppTheme.textSecondary, fontSize: 12)),
                        if (tab.type != SessionType.codex)
                          Text(tab.workDir,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: AppTheme.textMuted, fontSize: 11)),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: AppTheme.textMuted),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _quickPathChip({
    required String label,
    required String path,
    required bool loading,
    required VoidCallback onTap,
  }) {
    return ActionChip(
      avatar: const Icon(Icons.drive_folder_upload, size: 14),
      label: Text(
        label,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      tooltip: path,
      onPressed: loading ? null : onTap,
      side: BorderSide(color: AppTheme.borderSubtle),
      backgroundColor: AppTheme.bgCard,
      labelStyle: TextStyle(color: AppTheme.textSecondary),
    );
  }

  /// 同步状态指示器
  Widget _buildSyncIndicator() {
    IconData icon;
    Color color;
    String tooltip;

    switch (_syncStatus) {
      case SyncStatus.idle:
        icon = Icons.cloud_off;
        color = AppTheme.textMuted;
        tooltip = '未同步';
      case SyncStatus.syncing:
        icon = Icons.sync;
        color = AppTheme.orange;
        tooltip = '同步中...';
      case SyncStatus.synced:
        icon = Icons.cloud_done;
        color = AppTheme.green;
        tooltip = '已同步';
      case SyncStatus.deployed:
        icon = Icons.cloud_done;
        color = AppTheme.cyan;
        tooltip = '已配置远程服务器';
      case SyncStatus.failed:
        icon = Icons.cloud_off;
        color = AppTheme.red;
        tooltip = '同步失败，点击重试';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip,
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }

  // ===== Tab 栏 =====

  Widget _buildTabBar() {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        border: Border(
          bottom: BorderSide(
            color: AppTheme.textMuted.withValues(alpha: 0.3),
            width: 2,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  for (int i = 0; i < _tabs.length; i++) _buildTab(i),
                ],
              ),
            ),
          ),
          PopupMenuButton<SessionType>(
            onSelected: _addSessionOfType,
            tooltip: '新建会话',
            offset: const Offset(0, 40),
            icon: Icon(Icons.add, size: 18, color: AppTheme.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            itemBuilder: (_) => [
              for (final type in [
                SessionType.claude,
                SessionType.codex,
                SessionType.shell
              ])
                PopupMenuItem(
                  value: type,
                  child: Row(children: [
                    Icon(type.icon, size: 18, color: type.color),
                    const SizedBox(width: 10),
                    Text(type.label,
                        style: TextStyle(
                            fontWeight: FontWeight.w600, color: type.color)),
                  ]),
                ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildTab(int index) {
    final tab = _tabs[index];
    final isSelected = index == _currentIndex;
    final isAlive = _serverAliveSessions.contains(tab.name);
    final hasLocalConn = tab.isConnected;

    // 状态点：基于 ClaudeActivity
    // 蓝(发光)=正在回答  橙(发光)=等待确认  红=完成  类型色淡=空闲
    // Shell 类型：连接=绿  未连接=看服务器状态
    Color dotColor;
    bool glow = false;

    if (tab.type == SessionType.shell) {
      // Shell：简单的连接状态
      if (hasLocalConn) {
        dotColor = AppTheme.green;
        glow = true;
      } else if (_checkedAlive) {
        dotColor = isAlive ? AppTheme.orange : AppTheme.red;
      } else {
        dotColor = AppTheme.textMuted;
      }
    } else if (hasLocalConn) {
      // Claude/Codex：基于活动状态
      switch (tab.claudeActivity) {
        case ClaudeActivity.generating:
          dotColor = AppTheme.blue;
          glow = true;
        case ClaudeActivity.asking:
          dotColor = AppTheme.orange;
          glow = true;
        case ClaudeActivity.finished:
          dotColor = AppTheme.red;
        case ClaudeActivity.idle:
          dotColor = tab.type.color.withValues(alpha: 0.4);
      }
    } else if (_checkedAlive) {
      dotColor = isAlive ? AppTheme.orange : AppTheme.red;
    } else {
      dotColor = AppTheme.textMuted;
    }

    // === Tab 底色规则 ===
    // 聚焦 tab → 绿色底色
    // generating（正在运行）→ 蓝色底色
    // asking（等待确认）→ 橙色底色
    // finished → 红色底色（淡）
    // 其他 → 透明
    Color tabBg;
    Color tabBorder;
    Color textColor;

    if (isSelected) {
      // 当前聚焦：绿色
      tabBg = AppTheme.greenDim;
      tabBorder = AppTheme.green.withValues(alpha: 0.4);
      textColor = AppTheme.green;
    } else if (hasLocalConn &&
        tab.type != SessionType.shell &&
        tab.claudeActivity == ClaudeActivity.generating) {
      // 正在运行：蓝色
      tabBg = AppTheme.blueDim;
      tabBorder = AppTheme.blue.withValues(alpha: 0.4);
      textColor = AppTheme.blue;
    } else if (hasLocalConn &&
        tab.type != SessionType.shell &&
        tab.claudeActivity == ClaudeActivity.asking) {
      // 等待确认：橙色
      tabBg = AppTheme.orangeDim;
      tabBorder = AppTheme.orange.withValues(alpha: 0.4);
      textColor = AppTheme.orange;
    } else if (hasLocalConn &&
        tab.type != SessionType.shell &&
        tab.claudeActivity == ClaudeActivity.finished) {
      // 刚完成：红色淡底
      tabBg = AppTheme.redDim;
      tabBorder = AppTheme.red.withValues(alpha: 0.3);
      textColor = AppTheme.red;
    } else {
      tabBg = AppTheme.bgCard;
      tabBorder = AppTheme.textMuted.withValues(alpha: 0.2);
      textColor = AppTheme.textSecondary;
    }

    return GestureDetector(
      onTap: () => _switchTab(index),
      onLongPress: () => _showTabContextMenu(index),
      onSecondaryTapUp: (details) =>
          _showTabContextMenuAt(index, details.globalPosition),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 5),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: tabBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: tabBorder, width: isSelected ? 1.5 : 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 状态点
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: dotColor,
                boxShadow: glow
                    ? [
                        BoxShadow(
                            color: dotColor.withValues(alpha: 0.5),
                            blurRadius: 6),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 6),
            // 类型图标
            Icon(tab.type.icon, size: 13, color: textColor),
            const SizedBox(width: 4),
            Text(
              tab.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight:
                    isSelected || glow ? FontWeight.w600 : FontWeight.normal,
                color: textColor,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== 终端区域 =====

  Widget _buildTerminalArea() {
    if (_tabs.isEmpty) {
      if (widget.initialCodexConfig != null ||
          widget.initialSessionName != null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_syncStatus == SyncStatus.failed
                  ? '打开所选 Codex 对话失败'
                  : '正在打开所选 Codex 对话…'),
              if (_syncStatus == SyncStatus.failed)
                TextButton(
                  onPressed: _initConnection,
                  child: const Text('重试'),
                ),
            ],
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.terminal,
                size: 56, color: AppTheme.textMuted.withValues(alpha: 0.4)),
            const SizedBox(height: 16),
            Text('还没有 tmux 会话',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary)),
            const SizedBox(height: 6),
            Text('选择类型创建第一个会话',
                style: TextStyle(fontSize: 13, color: AppTheme.textMuted)),
            const SizedBox(height: 20),
            // 三个快速创建按钮
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final type in [
                  SessionType.claude,
                  SessionType.codex,
                  SessionType.shell
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: _typeQuickButton(type),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return IndexedStack(
      index: _currentIndex,
      children: [
        for (int i = 0; i < _tabs.length; i++)
          KeyedSubtree(
            key: ValueKey('tab-content-${_tabs[i].name}'),
            child: _buildTabContent(i),
          ),
      ],
    );
  }

  Widget _buildTabContent(int index) {
    final tab = _tabs[index];

    if (tab.isConnecting) {
      return Center(child: CircularProgressIndicator(color: AppTheme.cyan));
    }

    if (tab.errorMessage != null && !tab.isConnected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: AppTheme.red),
            const SizedBox(height: 12),
            Text('连接失败', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(tab.errorMessage!,
                  style: TextStyle(color: AppTheme.textMuted),
                  textAlign: TextAlign.center),
            ),
            const SizedBox(height: 12),
            _gradientButton(
                icon: Icons.refresh,
                label: '重试',
                onTap: () => _connectTab(index)),
          ],
        ),
      );
    }

    if (tab.terminal == null) {
      return Center(
        child: _gradientButton(
            icon: Icons.play_arrow,
            label: '点击连接',
            onTap: () => _connectTab(index)),
      );
    }

    Widget child = Listener(
      onPointerDown: (event) => _onTerminalPointerDown(index, event),
      onPointerMove: (event) => _onTerminalPointerMove(index, event),
      onPointerCancel: (_) => _onTerminalPointerCancel(index),
      onPointerSignal: (event) {
        if (event is PointerScrollEvent && tab.type != SessionType.shell) {
          _handleTerminalScroll(index, event);
        }
      },
      onPointerUp: (_) {
        _onTerminalPointerUp(index);
        if (_isHistoryPanelOpen && tab.type != SessionType.shell) {
          // 单击后刷新历史面板（用户可能点击切换了 pane）
          unawaited(_refreshHistoryPanelContent());
        }
      },
      child: TerminalView(
        tab.terminal!,
        key: tab.terminalViewKey,
        controller: tab.controller!,
        scrollController: tab.scrollController,
        focusNode: tab.focusNode,
        autofocus: index == _currentIndex,
        theme: AppTheme.terminalTheme,
        textStyle: TerminalStyle(fontSize: _fontSize),
        simulateScroll: false,
        deleteDetection: true,
        // Left-drag should create a local selection even when tmux enables
        // mouse tracking so Cmd+C always has a stable local selection to copy.
        preferLocalSelectionWhenMouseTracking: true,
        enableInternalDragSelection: true,
        enableInternalPointerGestures: true,
        onKeyEvent: _handleTerminalKeyEvent,
        onSecondaryTapUp: (details, cellOffset) =>
            _onSecondaryTapUp(details, cellOffset, index),
      ),
    );

    return child;
  }

  void _onTerminalPointerDown(int index, PointerDownEvent event) {
    final tab = _tabs.length > index ? _tabs[index] : null;
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    _selectionPointerDownPosition = event.position;
    _selectionPointerTabIndex = index;
    _selectionDragActive = false;
    // 立即暂停输出，防止高速 writes 干扰 drag 手势识别
    tab?.pauseOutput();
  }

  void _onTerminalPointerMove(int index, PointerMoveEvent event) {
    if (event.kind != PointerDeviceKind.mouse ||
        _selectionPointerTabIndex != index ||
        (event.buttons & kPrimaryMouseButton) == 0 ||
        _selectionPointerDownPosition == null ||
        _selectionDragActive) {
      return;
    }

    if ((event.position - _selectionPointerDownPosition!).distance <
        _selectionDragThreshold) {
      return;
    }

    final tab = _tabs.length > index ? _tabs[index] : null;
    if (tab == null) {
      _resetTerminalPointerTracking();
      return;
    }

    _selectionDragActive = true;
    // pauseOutput 已在 pointer-down 时调用，此处无需重复
  }

  void _onTerminalPointerUp(int index) {
    // Use the tracked tab index (set at pointer-down). If it was reset by a
    // spurious PointerCancelEvent, fall back to the current index so that
    // drag-selections are still frozen even when tracking state is stale.
    final effectiveIndex = _selectionPointerTabIndex ?? index;
    final tab = _tabs.length > effectiveIndex ? _tabs[effectiveIndex] : null;
    if (tab == null) {
      _resetTerminalPointerTracking();
      return;
    }

    if (_selectionDragActive) {
      final hasFrozenSelection = _freezeTerminalSelection(tab);
      if (hasFrozenSelection) {
        tab.resumeOutputDelayed();
      } else {
        tab.resumeOutput();
      }
    } else {
      // 无 drag（只是点击）也要 resume，因为 pointer-down 已 pause
      tab.resumeOutput();
    }

    _resetTerminalPointerTracking();
  }

  void _onTerminalPointerCancel(int index) {
    final tab = _tabs.length > index ? _tabs[index] : null;
    if (tab != null) {
      tab.resumeOutput();
    }
    _resetTerminalPointerTracking();
  }

  bool _freezeTerminalSelection(_TabSession tab) {
    final controller = tab.controller;
    final terminal = tab.terminal;
    final selection = controller?.selection;
    if (controller == null || terminal == null || selection == null) {
      return false;
    }

    controller.setSelectionOffsets(selection.begin, selection.end);
    try {
      final text = terminal.buffer.getText(controller.selection!);
      if (text.isNotEmpty) {
        tab.cachedSelectionText = text;
      }
    } catch (_) {}

    return true;
  }

  void _resetTerminalPointerTracking() {
    _selectionPointerDownPosition = null;
    _selectionPointerTabIndex = null;
    _selectionDragActive = false;
  }

  /// 空状态的类型快速创建按钮
  Widget _typeQuickButton(SessionType type) {
    return GestureDetector(
      onTap: () => _addSessionOfType(type),
      child: Container(
        width: 90,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: type.dimColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: type.color.withValues(alpha: 0.25)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(type.icon, color: type.color, size: 28),
            const SizedBox(height: 8),
            Text(type.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: type.color,
                )),
          ],
        ),
      ),
    );
  }

  /// 渐变按钮（复用于错误状态）
  Widget _gradientButton(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          colors: [AppTheme.cyan, Color(0xFF2196F3)],
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(label,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===== 快捷键工具栏 =====

  Widget _buildQuickKeysBar() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        border: Border(top: BorderSide(color: AppTheme.borderSubtle, width: 1)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildKeyButton(Icons.keyboard_arrow_up, () => _sendEsc('[A')),
                _buildKeyButton(
                    Icons.keyboard_arrow_down, () => _sendEsc('[B')),
                _buildKeyButton(
                    Icons.keyboard_arrow_left, () => _sendEsc('[D')),
                _buildKeyButton(
                    Icons.keyboard_arrow_right, () => _sendEsc('[C')),
                _buildSlashCommandMenu(),
                _divider(),
                if (!_useMobileSessionCards) ...[
                  _buildTextKey(
                    '上下分割',
                    () => _splitCurrentTmuxPane(_TmuxSplitDirection.horizontal),
                  ),
                  _buildTextKey(
                    '左右分割',
                    () => _splitCurrentTmuxPane(_TmuxSplitDirection.vertical),
                  ),
                  _divider(),
                ],
                _buildTextKey('Tab', () => _sendRaw('\t')),
                _buildTextKey('Esc', () => _sendRaw('\x1b')),
                _divider(),
                _buildTextKey('Ctrl+C', () => _sendRaw('\x03'), accent: 'red'),
                _buildTextKey('Ctrl+L', () => _sendRaw('\x0c')),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: AppTheme.borderSubtle,
      );

  Widget _buildKeyButton(IconData icon, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            width: 38,
            height: 34,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.borderSubtle),
            ),
            child: Icon(icon, size: 18, color: AppTheme.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _buildTextKey(String label, VoidCallback onPressed, {String? accent}) {
    Color textColor = AppTheme.textSecondary;
    Color bgColor = AppTheme.bgCard;
    Color borderColor = AppTheme.borderSubtle;

    if (accent == 'red') {
      textColor = AppTheme.red;
      bgColor = AppTheme.redDim;
      borderColor = AppTheme.red.withValues(alpha: 0.2);
    } else if (accent == 'purple') {
      textColor = AppTheme.purple;
      bgColor = AppTheme.purpleDim;
      borderColor = AppTheme.purple.withValues(alpha: 0.2);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: borderColor),
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  color: textColor,
                )),
          ),
        ),
      ),
    );
  }

  Widget _buildSlashCommandMenu() {
    const commands = [
      ('/', '帮助'),
      ('/model', '切换模型'),
      ('/resume', '继续对话'),
      ('/clear', '清除上下文'),
      ('/usage', '查看消耗'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: PopupMenuButton<String>(
        onSelected: (cmd) => _sendRaw(cmd),
        tooltip: '斜杠命令',
        offset: const Offset(0, -200),
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: AppTheme.purpleDim,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.purple.withValues(alpha: 0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('/',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      color: AppTheme.purple)),
              Icon(Icons.arrow_drop_down, size: 16, color: AppTheme.purple),
            ],
          ),
        ),
        itemBuilder: (_) => commands
            .map((c) => PopupMenuItem(
                  value: c.$1,
                  child: Row(children: [
                    Text(c.$1,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace')),
                    const SizedBox(width: 12),
                    Text(c.$2,
                        style:
                            TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                  ]),
                ))
            .toList(),
      ),
    );
  }

  // ===== 输入操作 =====

  KeyEventResult _handleTerminalKeyEvent(FocusNode _, KeyEvent event) {
    if (!_isMacOS) return KeyEventResult.ignored;

    final key = event.logicalKey;
    final isMetaPressed = HardwareKeyboard.instance.isMetaPressed;
    final isAltPressed = HardwareKeyboard.instance.isAltPressed;
    final isControlPressed = HardwareKeyboard.instance.isControlPressed;
    final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
    bool matches({
      required LogicalKeyboardKey logicalKey,
      bool meta = false,
      bool alt = false,
      bool control = false,
      bool shift = false,
    }) {
      return key == logicalKey &&
          isMetaPressed == meta &&
          isAltPressed == alt &&
          isControlPressed == control &&
          isShiftPressed == shift;
    }

    if (isAltPressed ||
        isMetaPressed ||
        isControlPressed ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      unawaited(
        MacosKeyboardBridge.log(
          'flutter-key',
          'terminal onKeyEvent',
          <String, Object?>{
            'eventType': event.runtimeType.toString(),
            'logicalKey': key.keyLabel,
            'debugName': key.debugName,
            'meta': isMetaPressed,
            'alt': isAltPressed,
            'control': isControlPressed,
            'shift': HardwareKeyboard.instance.isShiftPressed,
            ..._keyboardDebugContext(),
          },
        ),
      );
    }

    // 任何按键退出 tmux copy-mode（Cmd+C 除外，先复制再退出）
    final tab = _currentTab;
    if (tab != null && tab.inTmuxCopyMode) {
      if (!(key == LogicalKeyboardKey.keyC && isMetaPressed)) {
        unawaited(_exitTmuxCopyModeForCurrentTab());
      }
    }

    // Cmd+C: 复制选中文本
    if (matches(logicalKey: LogicalKeyboardKey.keyC, meta: true)) {
      if (event is! KeyUpEvent) {
        unawaited(_copySelection());
      }
      return KeyEventResult.handled;
    }

    if (matches(logicalKey: LogicalKeyboardKey.keyV, meta: true)) {
      if (event is! KeyUpEvent) {
        unawaited(_pasteToTerminal());
      }
      return KeyEventResult.handled;
    }

    // Cmd+A: 全选文本（用固定坐标避免 anchor detach）
    if (matches(logicalKey: LogicalKeyboardKey.keyA, meta: true)) {
      if (event is! KeyUpEvent) {
        final tab = _currentTab;
        final terminal = tab?.terminal;
        final controller = tab?.controller;
        if (terminal != null && controller != null) {
          controller.setSelectionOffsets(
            CellOffset(0, terminal.buffer.height - terminal.viewHeight),
            CellOffset(terminal.viewWidth - 1, terminal.buffer.height - 1),
          );
        }
      }
      return KeyEventResult.handled;
    }

    if (matches(
      logicalKey: LogicalKeyboardKey.arrowLeft,
      alt: true,
      control: true,
    )) {
      if (event is! KeyUpEvent) {
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.left,
            source: 'flutter',
          ),
        );
      }
      return KeyEventResult.handled;
    }

    if (matches(
      logicalKey: LogicalKeyboardKey.arrowRight,
      alt: true,
      control: true,
    )) {
      if (event is! KeyUpEvent) {
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.right,
            source: 'flutter',
          ),
        );
      }
      return KeyEventResult.handled;
    }

    if (matches(logicalKey: LogicalKeyboardKey.arrowLeft, alt: true)) {
      if (event is! KeyUpEvent) {
        _switchTabByDelta(-1, source: 'flutter');
      }
      return KeyEventResult.handled;
    }

    if (matches(logicalKey: LogicalKeyboardKey.arrowRight, alt: true)) {
      if (event is! KeyUpEvent) {
        _switchTabByDelta(1, source: 'flutter');
      }
      return KeyEventResult.handled;
    }

    if (matches(logicalKey: LogicalKeyboardKey.arrowUp, alt: true)) {
      if (event is! KeyUpEvent) {
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.up,
            source: 'flutter',
          ),
        );
      }
      return KeyEventResult.handled;
    }

    if (matches(logicalKey: LogicalKeyboardKey.arrowDown, alt: true)) {
      if (event is! KeyUpEvent) {
        unawaited(
          _navigateCurrentTmuxPane(
            _TmuxPaneDirection.down,
            source: 'flutter',
          ),
        );
      }
      return KeyEventResult.handled;
    }

    if (matches(
        logicalKey: LogicalKeyboardKey.arrowLeft, meta: true, alt: true)) {
      if (event is! KeyUpEvent) {
        _switchTabByDelta(-1, source: 'flutter');
      }
      return KeyEventResult.handled;
    }

    if (matches(
        logicalKey: LogicalKeyboardKey.arrowRight, meta: true, alt: true)) {
      if (event is! KeyUpEvent) {
        _switchTabByDelta(1, source: 'flutter');
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  Future<_TmuxPaneSnapshot?> _readTmuxPaneSnapshot(
    _TabSession tab,
    SSHClient client,
  ) async {
    final target = _shellQuote('${tab.name}:');
    try {
      final result = await client.run(
        "tmux list-panes -t $target -F '#{pane_id}|#{pane_active}' 2>/dev/null",
      );
      final text = utf8.decode(result, allowMalformed: true).trim();
      if (text.isEmpty) {
        const snapshot =
            _TmuxPaneSnapshot(paneIds: <String>[], activePaneId: null);
        tab.lastKnownPaneCount = snapshot.paneCount;
        return snapshot;
      }

      final paneIds = <String>[];
      String? activePaneId;
      for (final rawLine in text.split('\n')) {
        final line = rawLine.trim();
        if (line.isEmpty) continue;
        final parts = line.split('|');
        if (parts.isEmpty) continue;
        final paneId = parts.first.trim();
        if (paneId.isEmpty) continue;
        paneIds.add(paneId);
        if (parts.length > 1 && parts[1].trim() == '1') {
          activePaneId = paneId;
        }
      }

      final snapshot = _TmuxPaneSnapshot(
        paneIds: paneIds,
        activePaneId: activePaneId,
      );
      tab.lastKnownPaneCount = snapshot.paneCount;
      return snapshot;
    } catch (e) {
      await MacosKeyboardBridge.log(
        'tmux',
        'read pane snapshot failed',
        <String, Object?>{
          'tabName': tab.name,
          'error': e.toString(),
          ..._keyboardDebugContext(),
        },
      );
      return null;
    }
  }

  Future<void> _exitTmuxCopyMode(_TabSession tab, String paneId) async {
    if (!tab.inTmuxCopyMode) return;
    final client = SshService.getClient(_connectionId);
    if (client == null) return;
    try {
      await client.run(
        "tmux send-keys -t ${_shellQuote(paneId)} -X cancel 2>/dev/null",
      );
    } catch (_) {}
    tab.inTmuxCopyMode = false;
    tab.copyModePaneId = null;
  }

  Future<void> _exitTmuxCopyModeForCurrentTab() async {
    final tab = _currentTab;
    if (tab == null || !tab.inTmuxCopyMode) return;
    // 优先使用缓存的 paneId，避免额外 SSH 调用
    final paneId =
        tab.copyModePaneId ?? (await _readActiveTmuxPaneState(tab))?.paneId;
    if (paneId != null && paneId.isNotEmpty) {
      await _exitTmuxCopyMode(tab, paneId);
    } else {
      tab.inTmuxCopyMode = false;
      tab.copyModePaneId = null;
    }
  }

  void _handleTerminalScroll(int index, PointerScrollEvent event) {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    if (!tab.isConnected) return;
    if (tab.type == SessionType.shell) return;

    final up = event.scrollDelta.dy < 0;

    // 向下滚：如果悬浮面板已打开，关闭它
    if (!up) {
      if (_isHistoryPanelOpen) {
        _closeHistoryPanel();
      }
      if (!tab.inTmuxCopyMode) return;
    }

    // 节流：如果已有待处理的滚动，跳过
    if (_scrollPending) return;
    _scrollPending = true;

    // 延迟执行，合并高频滚轮事件
    _scrollThrottleTimer?.cancel();
    _scrollThrottleTimer = Timer(const Duration(milliseconds: 50), () async {
      _scrollPending = false;
      if (!mounted || index >= _tabs.length) return;

      final client = SshService.getClient(_connectionId);
      if (client == null) return;

      final snapshot = await _readTmuxPaneSnapshot(tab, client);
      if (snapshot == null) return;

      // 仅单 pane 时拦截滚轮
      if (snapshot.paneCount != 1) return;

      if (up) {
        // 单 pane 滚轮上滚 → 直接打开历史浏览器（不进 tmux copy-mode）
        unawaited(_openHistoryViewer());
      } else if (tab.inTmuxCopyMode) {
        // 兼容：如果仍在 copy-mode（旧状态），退出它
        final paneId = snapshot.activePaneId ?? snapshot.paneIds.firstOrNull;
        if (paneId != null) {
          await _exitTmuxCopyMode(tab, paneId);
        }
      }
    });
  }

  SessionType _sessionTypeFromPaneCommand(String? command) {
    if (command == null || command.isEmpty) {
      return SessionType.shell;
    }
    final normalized = command.trim().toLowerCase();
    if (normalized.contains('claude')) {
      return SessionType.claude;
    }
    if (normalized.contains('codex')) {
      return SessionType.codex;
    }
    return SessionType.shell;
  }

  Future<_ActiveTmuxPaneState?> _readActiveTmuxPaneState(
      _TabSession tab) async {
    final client = SshService.getClient(_connectionId);
    if (client == null || !tab.isConnected) {
      return null;
    }
    final target = _shellQuote('${tab.name}:');
    try {
      final result = await client.run(
        "tmux display-message -p -t $target '#{pane_id}|#{pane_current_command}' 2>/dev/null",
      );
      final text = utf8.decode(result, allowMalformed: true).trim();
      if (text.isEmpty) {
        return null;
      }

      final parts = text.split('|');
      final paneId = parts.isNotEmpty ? parts.first.trim() : null;
      final command = parts.length > 1 ? parts[1].trim() : null;
      return _ActiveTmuxPaneState(
        paneId: paneId?.isEmpty == true ? null : paneId,
        currentCommand: command?.isEmpty == true ? null : command,
        sessionType: _sessionTypeFromPaneCommand(command),
      );
    } catch (e) {
      await MacosKeyboardBridge.log(
        'tmux',
        'read active pane state failed',
        <String, Object?>{
          'tabName': tab.name,
          'error': e.toString(),
          ..._keyboardDebugContext(),
        },
      );
      return null;
    }
  }

  bool _didActivePaneChange(
    _TmuxPaneSnapshot? before,
    _TmuxPaneSnapshot? after,
  ) {
    if (before == null || after == null) {
      return false;
    }
    final beforeId = before.activePaneId;
    final afterId = after.activePaneId;
    return beforeId != null && afterId != null && beforeId != afterId;
  }

  Future<void> _refreshTmuxClients(_TabSession tab, SSHClient client) async {
    final sessionTarget = _shellQuote(tab.name);
    try {
      final result = await client.run(
        "tmux list-clients -t $sessionTarget -F '#{client_tty}' 2>/dev/null",
      );
      final ttys = utf8
          .decode(result, allowMalformed: true)
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      if (ttys.isEmpty) {
        return;
      }
      final command = ttys
          .map((tty) => 'tmux refresh-client -S -t ${_shellQuote(tty)}')
          .join(' ; ');
      await client.run('$command >/dev/null 2>&1 || true');
      await MacosKeyboardBridge.log(
        'tmux',
        'refreshed tmux clients',
        <String, Object?>{
          'ttys': ttys,
          ..._keyboardDebugContext(),
        },
      );
    } catch (e) {
      await MacosKeyboardBridge.log(
        'tmux',
        'refresh tmux clients failed',
        <String, Object?>{
          'tabName': tab.name,
          'error': e.toString(),
          ..._keyboardDebugContext(),
        },
      );
    }
  }

  Future<void> _navigateCurrentTmuxPane(
    _TmuxPaneDirection direction, {
    String source = 'unknown',
  }) async {
    final tab = _currentTab;
    final client = SshService.getClient(_connectionId);
    if (tab == null || !tab.isConnected || client == null) {
      await MacosKeyboardBridge.log(
        'tmux',
        'skip pane navigation',
        <String, Object?>{
          'source': source,
          'direction': direction.name,
          ..._keyboardDebugContext(),
        },
      );
      return;
    }

    try {
      final beforeSnapshot = await _readTmuxPaneSnapshot(tab, client);
      await MacosKeyboardBridge.log(
        'tmux',
        'run pane navigation',
        <String, Object?>{
          'source': source,
          'direction': direction.name,
          'strategy': 'prefix-sequence-then-pane-id-fallback',
          'beforeSnapshot': beforeSnapshot?.toDebugMap(),
          ..._keyboardDebugContext(),
        },
      );

      if (beforeSnapshot != null && beforeSnapshot.paneCount <= 1) {
        await MacosKeyboardBridge.log(
          'tmux',
          'skip pane navigation because only one pane is present',
          <String, Object?>{
            'source': source,
            'direction': direction.name,
            'beforeSnapshot': beforeSnapshot.toDebugMap(),
            ..._keyboardDebugContext(),
          },
        );
        final now = DateTime.now();
        final canShowHint = _lastSinglePaneHintTime == null ||
            now.difference(_lastSinglePaneHintTime!) >
                const Duration(milliseconds: 1200);
        if (mounted && canShowHint) {
          _lastSinglePaneHintTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('当前 tmux 只有 1 个 pane，请先分割'),
              duration: Duration(seconds: 1),
            ),
          );
        }
        return;
      }

      final sessionId = tab.sessionId(widget.connection.id);
      SshService.sendInput(sessionId, '\x02${direction.terminalEscape}');
      await Future.delayed(const Duration(milliseconds: 90));

      final afterPrefixSnapshot = await _readTmuxPaneSnapshot(tab, client);
      if (_didActivePaneChange(beforeSnapshot, afterPrefixSnapshot)) {
        if (!mounted) return;
        await MacosKeyboardBridge.log(
          'tmux',
          'pane navigation succeeded',
          <String, Object?>{
            'source': source,
            'direction': direction.name,
            'strategy': 'prefix-sequence',
            'afterSnapshot': afterPrefixSnapshot?.toDebugMap(),
            ..._keyboardDebugContext(),
          },
        );
        if (_isHistoryPanelOpen) {
          await _refreshHistoryPanelContent(
            paneId: afterPrefixSnapshot?.activePaneId,
            title: _historyTitleFor(
              tab,
              paneId: afterPrefixSnapshot?.activePaneId,
            ),
          );
        }
        _focusCurrentTerminal(reason: 'pane-navigation:$source');
        return;
      }

      final activePaneId = beforeSnapshot?.activePaneId;
      if (activePaneId != null && activePaneId.isNotEmpty) {
        await client.run(
          "tmux select-pane ${direction.tmuxFlag} -t $activePaneId 2>/dev/null",
        );
        await _refreshTmuxClients(tab, client);
      }

      await Future.delayed(const Duration(milliseconds: 60));
      final afterFallbackSnapshot = await _readTmuxPaneSnapshot(tab, client);
      if (!mounted) return;
      if (_didActivePaneChange(beforeSnapshot, afterFallbackSnapshot)) {
        await MacosKeyboardBridge.log(
          'tmux',
          'pane navigation succeeded',
          <String, Object?>{
            'source': source,
            'direction': direction.name,
            'strategy': 'pane-id-fallback',
            'afterSnapshot': afterFallbackSnapshot?.toDebugMap(),
            ..._keyboardDebugContext(),
          },
        );
        if (_isHistoryPanelOpen) {
          await _refreshHistoryPanelContent(
            paneId: afterFallbackSnapshot?.activePaneId,
            title: _historyTitleFor(
              tab,
              paneId: afterFallbackSnapshot?.activePaneId,
            ),
          );
        }
        _focusCurrentTerminal(reason: 'pane-navigation:$source');
        return;
      }

      await MacosKeyboardBridge.log(
        'tmux',
        'pane navigation did not change active pane',
        <String, Object?>{
          'source': source,
          'direction': direction.name,
          'beforeSnapshot': beforeSnapshot?.toDebugMap(),
          'afterPrefixSnapshot': afterPrefixSnapshot?.toDebugMap(),
          'afterFallbackSnapshot': afterFallbackSnapshot?.toDebugMap(),
          ..._keyboardDebugContext(),
        },
      );
    } catch (e) {
      await MacosKeyboardBridge.log(
        'tmux',
        'pane navigation failed',
        <String, Object?>{
          'source': source,
          'direction': direction.name,
          'error': e.toString(),
          ..._keyboardDebugContext(),
        },
      );
    }
  }

  Future<void> _splitCurrentTmuxPane(_TmuxSplitDirection direction) async {
    final tab = _currentTab;
    final client = SshService.getClient(_connectionId);
    if (tab == null || !tab.isConnected || client == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('当前 tmux 会话未连接'),
            backgroundColor: AppTheme.orange,
          ),
        );
      }
      return;
    }

    final target = _shellQuote('${tab.name}:');
    try {
      await client.run(
        "tmux split-window ${direction.tmuxFlag} -t $target -c '#{pane_current_path}'",
      );
      unawaited(_refreshPaneCountForTab(_currentIndex));
      if (!mounted) return;
      _focusCurrentTerminal();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${direction.label}失败：$e'),
          backgroundColor: AppTheme.red,
        ),
      );
    }
  }

  /// 拦截危险信号（Ctrl+C 连按 / Ctrl+D），弹出确认框
  void _confirmDangerousInput(
      _TabSession tab, String sessionId, String signal, String label) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('确认 $label'),
        content: Text('连续 $label 会退出 ${tab.type.label}，确定发送？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.red),
            child: const Text('确定退出'),
          ),
        ],
      ),
    );
    if (confirmed == true && tab.isConnected) {
      SshService.sendInput(sessionId, signal);
    }
  }

  void _showBlockedClaudeExitHint() {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('不允许退出该 Claude 终端'),
        backgroundColor: AppTheme.orange,
        duration: Duration(seconds: 1),
      ),
    );
  }

  Future<void> _handleCtrlCInput(_TabSession tab, String sessionId) async {
    final paneState = await _readActiveTmuxPaneState(tab);
    final activeType = paneState?.sessionType ?? tab.type;
    final requiresConfirm = activeType != SessionType.shell;

    await MacosKeyboardBridge.log(
      'tmux',
      'handle Ctrl+C',
      <String, Object?>{
        'tabName': tab.name,
        'sessionId': sessionId,
        'requiresConfirm': requiresConfirm,
        'paneState': paneState?.toDebugMap(),
        ..._keyboardDebugContext(),
      },
    );

    if (activeType == SessionType.claude) {
      await MacosKeyboardBridge.log(
        'tmux',
        'block Ctrl+C in Claude pane',
        <String, Object?>{
          'tabName': tab.name,
          'sessionId': sessionId,
          'paneState': paneState?.toDebugMap(),
          ..._keyboardDebugContext(),
        },
      );
      _showBlockedClaudeExitHint();
      return;
    }

    if (!requiresConfirm) {
      tab._lastCtrlCTime = null;
      if (tab.isConnected) {
        SshService.sendInput(sessionId, '\x03');
      }
      return;
    }

    final now = DateTime.now();
    if (tab._lastCtrlCTime != null &&
        now.difference(tab._lastCtrlCTime!).inMilliseconds < 1500) {
      tab._lastCtrlCTime = null;
      if (!mounted) {
        return;
      }
      _confirmDangerousInput(tab, sessionId, '\x03', 'Ctrl+C');
      return;
    }

    tab._lastCtrlCTime = now;
    if (tab.isConnected) {
      SshService.sendInput(sessionId, '\x03');
    }
  }

  Future<void> _handleCtrlDInput(_TabSession tab, String sessionId) async {
    final paneState = await _readActiveTmuxPaneState(tab);
    final activeType = paneState?.sessionType ?? tab.type;
    final requiresConfirm = activeType != SessionType.shell;

    await MacosKeyboardBridge.log(
      'tmux',
      'handle Ctrl+D',
      <String, Object?>{
        'tabName': tab.name,
        'sessionId': sessionId,
        'requiresConfirm': requiresConfirm,
        'paneState': paneState?.toDebugMap(),
        ..._keyboardDebugContext(),
      },
    );

    if (activeType == SessionType.claude) {
      await MacosKeyboardBridge.log(
        'tmux',
        'block Ctrl+D in Claude pane',
        <String, Object?>{
          'tabName': tab.name,
          'sessionId': sessionId,
          'paneState': paneState?.toDebugMap(),
          ..._keyboardDebugContext(),
        },
      );
      _showBlockedClaudeExitHint();
      return;
    }

    if (!requiresConfirm) {
      await MacosKeyboardBridge.log(
        'tmux',
        'send Ctrl+D directly in shell pane',
        <String, Object?>{
          'tabName': tab.name,
          'sessionId': sessionId,
          'paneState': paneState?.toDebugMap(),
          ..._keyboardDebugContext(),
        },
      );
      if (tab.isConnected) {
        SshService.sendInput(sessionId, '\x04');
      }
      return;
    }

    if (!mounted) {
      return;
    }
    _confirmDangerousInput(tab, sessionId, '\x04', 'Ctrl+D');
  }

  void _sendRaw(String data) => SshService.sendInput(_currentSessionId, data);
  void _sendEsc(String seq) =>
      SshService.sendInput(_currentSessionId, '\x1b$seq');

  void _onSecondaryTapUp(
      TapUpDetails details, CellOffset cellOffset, int tabIndex) {
    final tab = _tabs.length > tabIndex ? _tabs[tabIndex] : null;
    final hasSelection = tab?.controller?.selection != null;
    final renderBox = context.findRenderObject() as RenderBox;
    final position = renderBox.localToGlobal(details.localPosition);

    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'copy',
          enabled: hasSelection,
          child: const Row(
            children: [
              Icon(Icons.copy, size: 18),
              SizedBox(width: 8),
              Text('复制'),
              Spacer(),
              Text('⌘C', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'paste',
          child: const Row(
            children: [
              Icon(Icons.paste, size: 18),
              SizedBox(width: 8),
              Text('粘贴'),
              Spacer(),
              Text('⌘V', style: TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'copy') {
        _copySelection();
      } else if (value == 'paste') {
        _pasteToTerminal();
      }
    });
  }

  Future<void> _pasteToTerminal() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      SshService.sendInput(_currentSessionId, text);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已粘贴'), duration: Duration(seconds: 1)),
        );
      }
    }
  }

  Future<void> _copySelection() async {
    final tab = _currentTab;
    final controller = tab?.controller;
    final terminal = tab?.terminal;
    if (controller == null || terminal == null) return;

    // 优先从当前选区读取
    String? text;
    var copySource = 'none';
    final selection = controller.selection;
    if (selection != null) {
      try {
        text = terminal.buffer.getText(selection);
        if (text.isNotEmpty) {
          copySource = 'live-selection';
          tab?.cachedSelectionText = text;
        }
      } catch (_) {}
    }

    // 选区可能因 tmux 刷新 detach，回退到缓存
    if ((text == null || text.isEmpty) &&
        tab != null &&
        tab.cachedSelectionText != null) {
      text = tab.cachedSelectionText;
      if (text != null && text.isNotEmpty) {
        copySource = 'cached-selection';
      }
    }

    await MacosKeyboardBridge.log(
      'clipboard',
      'copy terminal selection',
      <String, Object?>{
        'source': copySource,
        'hasLiveSelection': selection != null,
        'textLength': text?.length ?? 0,
        ..._keyboardDebugContext(),
      },
    );

    if (text != null && text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      tab?.cachedSelectionText = null; // 复制后清除缓存
      if (tab?.outputPaused == true) {
        tab?.resumeOutput();
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('请先用鼠标选中文本'), duration: Duration(seconds: 1)),
        );
      }
    }
  }

  void _bindSelectionCache(_TabSession tab) {
    final controller = tab.controller;
    if (controller == null || tab.selectionCacheBound) {
      return;
    }

    controller.addListener(() {
      final selection = controller.selection;
      final terminal = tab.terminal;
      if (selection == null || terminal == null) {
        return;
      }

      try {
        final text = terminal.buffer.getText(selection);
        if (text.isNotEmpty) {
          tab.cachedSelectionText = text;
        }
      } catch (_) {}
    });

    tab.selectionCacheBound = true;
  }

  // ===== 悬浮历史面板方法 =====

  String _historyTitleFor(_TabSession tab, {String? paneId}) {
    if (paneId == null || paneId.isEmpty) {
      return tab.name;
    }
    return '${tab.name} · $paneId';
  }

  /// 获取指定 pane（默认当前 active pane）的完整历史文本
  Future<_PaneHistoryContent?> _fetchCurrentPaneHistory({
    String? paneId,
  }) async {
    final tab = _currentTab;
    final client = SshService.getClient(_connectionId);
    if (tab == null || !tab.isConnected || client == null) return null;

    final targetPaneId = (paneId == null || paneId.isEmpty)
        ? (await _readActiveTmuxPaneState(tab))?.paneId
        : paneId;
    if (targetPaneId == null || targetPaneId.isEmpty) return null;

    try {
      final result = await client.run(
        "tmux capture-pane -J -p -t ${_shellQuote(targetPaneId)} -S -10000 2>/dev/null",
      );
      final text = utf8.decode(result, allowMalformed: true).trimRight();
      if (text.isEmpty) {
        return null;
      }
      return _PaneHistoryContent(
        paneId: targetPaneId,
        text: text,
      );
    } catch (_) {
      return null;
    }
  }

  /// 统一入口：根据设置选悬浮面板或模态对话框
  Future<void> _openHistoryViewer() async {
    if (_historyPanelAsPanel) {
      await _showFloatingHistoryPanel();
    } else {
      await _showPaneHistoryViewer();
    }
  }

  /// 打开或刷新悬浮历史面板
  Future<void> _showFloatingHistoryPanel() async {
    if (_historyFetchInProgress) return;
    _historyFetchInProgress = true;
    try {
      final history = await _fetchCurrentPaneHistory();
      final tab = _currentTab;
      if (history == null || tab == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('无法获取 pane 历史'),
              duration: Duration(seconds: 1),
            ),
          );
        }
        return;
      }

      _historyContent.value = history.text;
      _historyTitle.value = _historyTitleFor(tab, paneId: history.paneId);

      if (_historyPanelOverlay != null) {
        // 已打开，内容已通过 ValueNotifier 更新
        return;
      }

      if (!mounted) return;

      final overlay = Overlay.of(context);
      _historyPanelOverlay = OverlayEntry(
        builder: (_) => HistoryPanel(
          contentNotifier: _historyContent,
          titleNotifier: _historyTitle,
          fontSize: _fontSize,
          onClose: _closeHistoryPanel,
        ),
      );
      overlay.insert(_historyPanelOverlay!);
      setState(() {});
    } finally {
      _historyFetchInProgress = false;
    }
  }

  /// 刷新悬浮面板内容（tab/pane 切换后调用）
  Future<void> _refreshHistoryPanelContent({
    String? paneId,
    String? title,
  }) async {
    if (_historyPanelOverlay == null) return;
    if (_historyFetchInProgress) {
      _historyRefreshPending = true;
      _pendingHistoryPaneId = paneId;
      _pendingHistoryTitle = title;
      return;
    }
    _historyFetchInProgress = true;
    try {
      final history = await _fetchCurrentPaneHistory(paneId: paneId);
      final tab = _currentTab;
      if (history != null && tab != null) {
        _historyContent.value = history.text;
        _historyTitle.value =
            title ?? _historyTitleFor(tab, paneId: history.paneId);
      }
    } finally {
      _historyFetchInProgress = false;
      if (_historyRefreshPending && _historyPanelOverlay != null) {
        final nextPaneId = _pendingHistoryPaneId;
        final nextTitle = _pendingHistoryTitle;
        _historyRefreshPending = false;
        _pendingHistoryPaneId = null;
        _pendingHistoryTitle = null;
        unawaited(
          _refreshHistoryPanelContent(
            paneId: nextPaneId,
            title: nextTitle,
          ),
        );
      }
    }
  }

  /// 关闭悬浮历史面板
  void _closeHistoryPanel() {
    _historyPanelOverlay?.remove();
    _historyPanelOverlay = null;
    _historyRefreshPending = false;
    _pendingHistoryPaneId = null;
    _pendingHistoryTitle = null;
    if (mounted) setState(() {});
  }

  bool get _isHistoryPanelOpen => _historyPanelOverlay != null;

  /// Pane 历史浏览器：获取 tmux pane 完整历史，在可选择的覆盖层中显示
  bool _isPaneHistoryViewerOpen = false;

  Future<void> _showPaneHistoryViewer() async {
    if (_isPaneHistoryViewerOpen) {
      // 防止 flag 卡死：超过 30 秒强制重置
      return;
    }
    final tab = _currentTab;
    final client = SshService.getClient(_connectionId);
    if (tab == null || !tab.isConnected || client == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('当前会话未连接'), duration: Duration(seconds: 1)),
        );
      }
      return;
    }

    final paneState = await _readActiveTmuxPaneState(tab);
    final paneId = paneState?.paneId;
    if (paneId == null || paneId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('未找到当前 pane'), duration: Duration(seconds: 1)),
        );
      }
      return;
    }

    String content;
    try {
      final result = await client.run(
        "tmux capture-pane -J -p -t ${_shellQuote(paneId)} -S -10000 2>/dev/null",
      );
      content = utf8.decode(result, allowMalformed: true).trimRight();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('获取 pane 历史失败: $e'),
              duration: const Duration(seconds: 2)),
        );
      }
      return;
    }
    if (content.isEmpty || !mounted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('pane 历史为空'), duration: Duration(seconds: 1)),
        );
      }
      return;
    }

    if (!mounted) return;

    _isPaneHistoryViewerOpen = true;
    final scrollController = ScrollController();

    try {
      await showDialog(
        context: context,
        barrierColor: Colors.black87,
        builder: (ctx) {
          // 打开后自动滚到底部（最新内容）
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (scrollController.hasClients) {
              scrollController
                  .jumpTo(scrollController.position.maxScrollExtent);
            }
          });

          return KeyboardListener(
            focusNode: FocusNode()..requestFocus(),
            onKeyEvent: (event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                Navigator.of(ctx).pop();
              }
            },
            child: GestureDetector(
              onTap: () => Navigator.of(ctx).pop(),
              child: Dialog(
                insetPadding: const EdgeInsets.all(16),
                backgroundColor: const Color(0xFF1A1A2E),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
                child: GestureDetector(
                  onTap: () {}, // 防止点击内容区关闭
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                        decoration: const BoxDecoration(
                          color: Color(0xFF252545),
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(12)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.history,
                                size: 18, color: Colors.white70),
                            const SizedBox(width: 8),
                            Text(
                              'Pane 历史 — ${tab.name}',
                              style: const TextStyle(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w600),
                            ),
                            const Spacer(),
                            const Text(
                              '鼠标选中 → Cmd+C 复制 · Esc 关闭',
                              style: TextStyle(
                                  color: Colors.white38, fontSize: 12),
                            ),
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: () => Navigator.of(ctx).pop(),
                              child: const Icon(Icons.close,
                                  size: 18, color: Colors.white38),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Scrollbar(
                          controller: scrollController,
                          thumbVisibility: true,
                          child: SingleChildScrollView(
                            controller: scrollController,
                            padding: const EdgeInsets.all(16),
                            child: SelectableText(
                              content,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: _fontSize,
                                color: Colors.white,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    } finally {
      scrollController.dispose();
      _isPaneHistoryViewerOpen = false;
    }
  }
}
