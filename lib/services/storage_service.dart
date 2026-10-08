import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import '../models/ssh_connection.dart';
import '../models/command_record.dart';
import '../models/codex_completion_notice.dart';
import 'codex_session_service.dart';
import 'claude_session_service.dart';

class StorageInitializationException implements Exception {
  const StorageInitializationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class StorageService {
  static const String _connectionsBoxName = 'connections';
  static const String _commandHistoryBoxName = 'command_history';
  static const String _settingsBoxName = 'settings';
  static const String _storageFolderName = 'ssh_tool_app';
  static const String _storageSubFolderName = 'hive';
  static const List<String> _boxNames = <String>[
    _connectionsBoxName,
    _commandHistoryBoxName,
    _settingsBoxName,
  ];
  static String? _dataDirectory;

  static String? get dataDirectory => _dataDirectory;

  // 初始化Hive
  static Future<void> init() async {
    try {
      final hivePath = await _prepareHiveDirectory();
      Hive.init(hivePath);

      // 注册适配器
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(SshConnectionAdapter());
      }
      if (!Hive.isAdapterRegistered(1)) {
        Hive.registerAdapter(CommandRecordAdapter());
      }

      // 打开boxes
      await _openBoxIfNeeded<SshConnection>(_connectionsBoxName);
      await _openBoxIfNeeded<CommandRecord>(_commandHistoryBoxName);
      await _openBoxIfNeeded(_settingsBoxName);
    } on FileSystemException catch (e) {
      await Hive.close();
      final isLockConflict = e.osError?.errorCode == 35;
      final reason = isLockConflict
          ? '本地数据被另一个 ssh_tool_app 进程占用，请先关闭已有窗口后重试。'
          : '本地数据目录不可用：${e.message}';
      throw StorageInitializationException(
        '$reason\n数据目录：${_dataDirectory ?? "未知"}',
      );
    } catch (e) {
      await Hive.close();
      throw StorageInitializationException(
        '初始化本地存储失败：$e\n数据目录：${_dataDirectory ?? "未知"}',
      );
    }
  }

  static Future<String> _prepareHiveDirectory() async {
    final appSupportDir = await getApplicationSupportDirectory();
    final hiveDir = Directory(
      '${appSupportDir.path}${Platform.pathSeparator}$_storageFolderName${Platform.pathSeparator}$_storageSubFolderName',
    );
    if (!await hiveDir.exists()) {
      await hiveDir.create(recursive: true);
    }
    _dataDirectory = hiveDir.path;
    await _migrateLegacyDataIfNeeded(hiveDir.path);
    return hiveDir.path;
  }

  static Future<void> _migrateLegacyDataIfNeeded(String hivePath) async {
    final legacyDir = await getApplicationDocumentsDirectory();
    if (legacyDir.path == hivePath) {
      return;
    }

    for (final boxName in _boxNames) {
      final legacyFile = File(
        '${legacyDir.path}${Platform.pathSeparator}$boxName.hive',
      );
      final targetFile = File(
        '$hivePath${Platform.pathSeparator}$boxName.hive',
      );
      if (await legacyFile.exists() && !await targetFile.exists()) {
        await legacyFile.copy(targetFile.path);
      }
    }
  }

  static Future<void> _openBoxIfNeeded<E>(String boxName) async {
    if (Hive.isBoxOpen(boxName)) {
      return;
    }
    await Hive.openBox<E>(boxName);
  }

  // ===== SSH连接管理 =====

  static Box<SshConnection> get _connectionsBox =>
      Hive.box<SshConnection>(_connectionsBoxName);

  // 保存连接配置
  static Future<void> saveConnection(SshConnection connection) async {
    await _connectionsBox.put(connection.id, connection);
    CodexSessionService.clearCache(connection.id);
    ClaudeSessionService.clearCache(connection.id);
  }

  // 获取所有连接
  static List<SshConnection> getAllConnections() {
    return _connectionsBox.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  // 根据ID获取连接
  static SshConnection? getConnection(String id) {
    return _connectionsBox.get(id);
  }

  // 删除连接
  static Future<void> deleteConnection(String id) async {
    await _connectionsBox.delete(id);
    CodexSessionService.clearCache(id);
    ClaudeSessionService.clearCache(id);
    // 同时删除该连接的所有命令历史
    await clearHistory(id);
    // 清理连接相关设置
    await _settingsBox.delete(_tmuxKey(id));
    await _settingsBox.delete(_claudeEnvKey(id));
    await _settingsBox.delete(_codexTerminalCommandKey(id));
    for (final kind in [
      'favorite_dirs',
      'favorite_conversations',
      'filtered_dirs',
      'opened_conversations'
    ]) {
      await _settingsBox.delete(_codexListKey(kind, id));
    }
    final viewedPrefix = _codexConversationViewedPrefix(id);
    await _settingsBox.deleteAll(_settingsBox.keys
        .where((key) => key is String && (key.startsWith(viewedPrefix) || key.startsWith('codex_model_${id}_')))
        .toList());
    final notices = getCodexCompletionNotices()
        .where((notice) => notice.connectionId != id)
        .toList();
    await _writeCodexCompletionNotices(notices);
  }

  // 更新连接
  static Future<void> updateConnection(SshConnection connection) async {
    connection.updatedAt = DateTime.now();
    await _connectionsBox.put(connection.id, connection);
    CodexSessionService.clearCache(connection.id);
    ClaudeSessionService.clearCache(connection.id);
  }

  // ===== 命令历史管理 =====

  static Box<CommandRecord> get _commandHistoryBox =>
      Hive.box<CommandRecord>(_commandHistoryBoxName);

  // 保存命令记录
  static Future<void> saveCommandRecord(CommandRecord record) async {
    await _commandHistoryBox.put(record.id, record);
  }

  // 获取指定连接的命令历史
  static List<CommandRecord> getCommandHistory(String connectionId,
      {int limit = 50}) {
    final allRecords = _commandHistoryBox.values
        .where((record) => record.connectionId == connectionId)
        .toList()
      ..sort((a, b) => b.executedAt.compareTo(a.executedAt));

    return allRecords.take(limit).toList();
  }

  // 获取最近的命令（用于快速填充）
  static List<String> getRecentCommands(String connectionId, {int limit = 10}) {
    final history = getCommandHistory(connectionId, limit: limit);
    final commands = history.map((record) => record.command).toSet().toList();
    return commands.take(limit).toList();
  }

  // 清除指定连接的命令历史
  static Future<void> clearHistory(String connectionId) async {
    final keysToDelete = _commandHistoryBox.values
        .where((record) => record.connectionId == connectionId)
        .map((record) => record.id)
        .toList();

    await _commandHistoryBox.deleteAll(keysToDelete);
  }

  // 清除所有历史记录（超过指定天数）
  static Future<void> clearOldHistory({int days = 30}) async {
    final cutoffDate = DateTime.now().subtract(Duration(days: days));
    final keysToDelete = _commandHistoryBox.values
        .where((record) => record.executedAt.isBefore(cutoffDate))
        .map((record) => record.id)
        .toList();

    await _commandHistoryBox.deleteAll(keysToDelete);
  }

  // ===== 统计信息 =====

  // 获取连接数
  static int get connectionCount => _connectionsBox.length;

  // 获取命令历史总数
  static int get commandHistoryCount => _commandHistoryBox.length;

  // 获取指定连接的命令数
  static int getCommandCount(String connectionId) {
    return _commandHistoryBox.values
        .where((record) => record.connectionId == connectionId)
        .length;
  }

  // ===== 全局设置 =====

  static Box get _settingsBox => Hive.box(_settingsBoxName);

  static String getHomeAssistant() {
    if (!Hive.isBoxOpen(_settingsBoxName)) return 'codex';
    return _settingsBox.get('home_assistant') == 'claude' ? 'claude' : 'codex';
  }

  static Future<void> setHomeAssistant(String value) =>
      _settingsBox.put('home_assistant', value);

  static String getCodexViewerLogLevel() {
    if (!Hive.isBoxOpen(_settingsBoxName)) return 'terminal';
    final value = _settingsBox.get('codex_viewer_log_level_v1');
    return const ['conversation', 'terminal', 'full'].contains(value)
        ? value as String : 'terminal';
  }

  static Future<void> setCodexViewerLogLevel(String value) async {
    if (Hive.isBoxOpen(_settingsBoxName)) {
      await _settingsBox.put('codex_viewer_log_level_v1', value);
    }
  }

  static const _codexCompletionNoticesKey = 'codex_completion_notices';

  static String _codexConversationViewedPrefix(String connectionId) =>
      'codex_conversation_viewed_${jsonEncode(connectionId)}:';

  static String _codexConversationViewedKey(
          String connectionId, String threadId) =>
      '${_codexConversationViewedPrefix(connectionId)}${jsonEncode(threadId)}';

  static DateTime? getCodexConversationViewedAt(
      String connectionId, String threadId) {
    final raw = _settingsBox.get(
        _codexConversationViewedKey(connectionId, threadId));
    if (raw is! String) return null;
    return DateTime.tryParse(raw);
  }

  static Future<void> markCodexConversationViewed(
      String connectionId, String threadId,
      {DateTime? viewedAt}) async {
    final timestamp = viewedAt ?? DateTime.now();
    final previous = getCodexConversationViewedAt(connectionId, threadId);
    if (previous != null && !timestamp.isAfter(previous)) return;
    await _settingsBox.put(
        _codexConversationViewedKey(connectionId, threadId),
        timestamp.toIso8601String());
  }

  static List<CodexCompletionNotice> getCodexCompletionNotices(
      {DateTime? now}) {
    final raw = _settingsBox.get(_codexCompletionNoticesKey);
    if (raw is! String) return [];
    try {
      final notices = (jsonDecode(raw) as List)
          .map((item) => CodexCompletionNotice.fromJson(
              Map<String, dynamic>.from(item as Map)))
          .toList();
      final retained =
          _retainedCodexCompletionNotices(notices, now ?? DateTime.now());
      if (retained.length != notices.length) {
        unawaited(_writeCodexCompletionNotices(retained));
      }
      return retained;
    } catch (_) {
      return [];
    }
  }

  static List<CodexCompletionNotice> _retainedCodexCompletionNotices(
      List<CodexCompletionNotice> notices, DateTime now) {
    final cutoff = now.subtract(const Duration(hours: 24));
    final unexpired = notices
        .where((notice) =>
            !notice.read || !notice.completedAt.isBefore(cutoff))
        .toList();
    return unexpired;
  }

  static Future<void> _writeCodexCompletionNotices(
      List<CodexCompletionNotice> notices) async {
    await _settingsBox.put(_codexCompletionNoticesKey,
        jsonEncode(notices.map((notice) => notice.toJson()).toList()));
  }

  static Future<void> saveCodexCompletionNotice(
      CodexCompletionNotice notice, {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    final notices = getCodexCompletionNotices(now: timestamp);
    final index = notices.indexWhere((item) => item.id == notice.id);
    if (index >= 0) {
      final existing = notices[index];
      if ((existing.title == null || existing.title!.trim().isEmpty) &&
          notice.title != null &&
          notice.title!.trim().isNotEmpty) {
        notices[index] = CodexCompletionNotice(
          id: existing.id,
          connectionId: existing.connectionId,
          threadId: existing.threadId,
          title: notice.title,
          completedAt: existing.completedAt,
          read: existing.read,
        );
        await _writeCodexCompletionNotices(notices);
      }
      return;
    }
    notices.insert(0, notice);
    await _writeCodexCompletionNotices(
        _retainedCodexCompletionNotices(notices, timestamp));
  }

  static Future<void> markCodexCompletionNoticeRead(String id,
      {DateTime? now}) async {
    final timestamp = now ?? DateTime.now();
    final notices = getCodexCompletionNotices(now: timestamp);
    final index = notices.indexWhere((item) => item.id == id);
    if (index < 0 || notices[index].read) return;
    notices[index] = notices[index].markRead();
    await _writeCodexCompletionNotices(
        _retainedCodexCompletionNotices(notices, timestamp));
  }

  static (String, String)? getCodexConversationModel(String connectionId, String threadId) {
    if (!Hive.isBoxOpen(_settingsBoxName)) return null;
    final value = _settingsBox.get('codex_model_${connectionId}_$threadId');
    if (value is! List || value.length != 2 || value.any((item) => item is! String)) return null;
    return (value[0] as String, value[1] as String);
  }

  static Future<void> setCodexConversationModel(String connectionId, String threadId,
      (String, String)? selection) async {
    final key = 'codex_model_${connectionId}_$threadId';
    if (selection == null) {
      await _settingsBox.delete(key);
    } else {
      await _settingsBox.put(key, [selection.$1, selection.$2]);
    }
  }

  static String _claudeEnvKey(String connectionId) =>
      'claude_env_$connectionId';

  static String _codexListKey(String kind, String connectionId) =>
      'codex_${kind}_$connectionId';

  static Set<String> _getCodexList(String kind, String connectionId) {
    final raw = _settingsBox.get(_codexListKey(kind, connectionId));
    if (raw is! String) return <String>{};
    try {
      return (jsonDecode(raw) as List).whereType<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  static Future<void> _setCodexList(
      String kind, String connectionId, Set<String> values) async {
    await _settingsBox.put(
      _codexListKey(kind, connectionId),
      jsonEncode(values.toList()),
    );
  }

  static Set<String> getFavoriteCodexDirectories(String connectionId) =>
      _getCodexList('favorite_dirs', connectionId);

  static Future<void> setFavoriteCodexDirectories(
          String connectionId, Set<String> paths) =>
      _setCodexList('favorite_dirs', connectionId, paths);

  static Set<String> getFavoriteCodexConversations(String connectionId) =>
      _getCodexList('favorite_conversations', connectionId);

  static Future<void> setFavoriteCodexConversations(
          String connectionId, Set<String> ids) =>
      _setCodexList('favorite_conversations', connectionId, ids);

  static Set<String> getOpenedCodexConversations(String connectionId) =>
      _getCodexList('opened_conversations', connectionId);

  static Future<void> setOpenedCodexConversations(
          String connectionId, Set<String> ids) =>
      _setCodexList('opened_conversations', connectionId, ids);

  static Future<void> addOpenedCodexConversation(
      String connectionId, String id) async {
    final ids = getOpenedCodexConversations(connectionId);
    if (ids.add(id)) await setOpenedCodexConversations(connectionId, ids);
  }

  static Set<String> getFilteredCodexDirectories(String connectionId) =>
      _getCodexList('filtered_dirs', connectionId);

  static Future<void> setFilteredCodexDirectories(
          String connectionId, Set<String> paths) =>
      _setCodexList('filtered_dirs', connectionId, paths);

  static double getTerminalFontSize() {
    return (_settingsBox.get('terminalFontSize', defaultValue: 14.0) as num)
        .toDouble();
  }

  static Future<void> setTerminalFontSize(double size) async {
    await _settingsBox.put('terminalFontSize', size);
  }

  static bool getCodexChatMode() {
    return _settingsBox.get('codexChatMode', defaultValue: true) as bool;
  }

  static Future<void> setCodexChatMode(bool enabled) async {
    await _settingsBox.put('codexChatMode', enabled);
  }

  static bool getCodexShowTokenUsage() =>
      _settingsBox.get('codexShowTokenUsage', defaultValue: false) as bool;

  static Future<void> setCodexShowTokenUsage(bool enabled) async {
    await _settingsBox.put('codexShowTokenUsage', enabled);
  }

  static bool getCodexShowMessageTime() =>
      _settingsBox.get('codexShowMessageTime', defaultValue: true) as bool;

  static Future<void> setCodexShowMessageTime(bool enabled) async {
    await _settingsBox.put('codexShowMessageTime', enabled);
  }

  static String getColorScheme() {
    return _settingsBox.get('colorScheme', defaultValue: 'dark') as String;
  }

  static Future<void> setColorScheme(String scheme) async {
    await _settingsBox.put('colorScheme', scheme);
  }

  /// 历史浏览器是否使用悬浮面板模式（true=悬浮面板，false=模态对话框）
  static bool getHistoryViewerAsPanel() {
    return _settingsBox.get('historyViewerAsPanel', defaultValue: true) as bool;
  }

  static Future<void> setHistoryViewerAsPanel(bool value) async {
    await _settingsBox.put('historyViewerAsPanel', value);
  }

  // ===== Codex 终端启动命令（按连接存储） =====

  static const defaultCodexTerminalCommand = 'codex';

  static String _codexTerminalCommandKey(String connectionId) =>
      'codex_terminal_command_$connectionId';

  static String getCodexTerminalCommand(String connectionId) {
    final command =
        (_settingsBox.get(_codexTerminalCommandKey(connectionId)) as String?)
            ?.trim();
    return command == null || command.isEmpty
        ? defaultCodexTerminalCommand
        : command;
  }

  static Future<void> setCodexTerminalCommand(
      String connectionId, String command) async {
    final normalized = command.trim();
    if (normalized.isEmpty) {
      await _settingsBox.delete(_codexTerminalCommandKey(connectionId));
    } else {
      await _settingsBox.put(_codexTerminalCommandKey(connectionId), normalized);
    }
  }

  // ===== Claude 环境变量（按连接存储） =====

  static String getClaudeEnvText(String connectionId) {
    return (_settingsBox.get(_claudeEnvKey(connectionId), defaultValue: '')
            as String)
        .trim();
  }

  static Future<void> setClaudeEnvText(String connectionId, String text) async {
    final normalized = text.trim();
    await _settingsBox.put(_claudeEnvKey(connectionId), normalized);
  }

  // ===== tmux 会话记录（仅手机端创建的） =====

  static String _tmuxKey(String connectionId) => 'tmux_sessions_$connectionId';

  /// 获取某连接的所有 app 创建的 tmux 会话记录
  static List<Map<String, String>> getTmuxSessions(String connectionId) {
    final raw = _settingsBox.get(_tmuxKey(connectionId));
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw as String) as List;
      return list.map((e) => Map<String, String>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  /// 保存一条 tmux 会话记录（同 name 则更新 workDir，保留 type）
  static Future<void> saveTmuxSession(
      String connectionId, String name, String workDir,
      {String type = 'shell'}) async {
    final sessions = getTmuxSessions(connectionId);
    final idx = sessions.indexWhere((s) => s['name'] == name);
    final record = {
      'name': name,
      'workDir': workDir,
      'type': idx >= 0 ? (sessions[idx]['type'] ?? type) : type,
      'createdAt': idx >= 0
          ? (sessions[idx]['createdAt'] ?? DateTime.now().toIso8601String())
          : DateTime.now().toIso8601String(),
    };
    if (idx >= 0) {
      sessions[idx] = record;
    } else {
      sessions.add(record);
    }
    await _settingsBox.put(_tmuxKey(connectionId), jsonEncode(sessions));
  }

  /// 删除一条 tmux 会话记录
  static Future<void> deleteTmuxSession(
      String connectionId, String name) async {
    final sessions = getTmuxSessions(connectionId);
    sessions.removeWhere((s) => s['name'] == name);
    await _settingsBox.put(_tmuxKey(connectionId), jsonEncode(sessions));
  }

  // ===== 清理和关闭 =====

  // 关闭所有boxes
  static Future<void> close() async {
    await _connectionsBox.close();
    await _commandHistoryBox.close();
  }

  // 清除所有数据（仅用于测试或重置）
  static Future<void> clearAll() async {
    CodexSessionService.clearCache();
    ClaudeSessionService.clearCache();
    await _connectionsBox.clear();
    await _commandHistoryBox.clear();
  }
}
