import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/ssh_connection.dart';
import 'services/storage_service.dart';
import 'services/notification_service.dart';
import 'services/ssh_service.dart';
import 'services/background_service.dart';
import 'services/codex_chat_service.dart';
import 'screens/home_screen.dart';
import 'screens/codex_notification_history_screen.dart';
import 'screens/tmux_workspace_screen.dart';
import 'theme/app_theme.dart';

/// 单实例锁：通过监听固定端口实现，同一时间只能有一个 app 实例运行
/// 返回 true 表示获得锁（可以启动），false 表示已有实例在运行
Future<bool> _acquireSingleInstanceLock() async {
  try {
    // 绑定固定端口，第二个实例会绑定失败
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 23847);
    return true;
  } catch (_) {
    // 尝试连接该端口，确认是否真有另一个实例
    try {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, 23847,
          timeout: const Duration(seconds: 1));
      socket.destroy();
      return false; // 确实有另一个实例在运行
    } catch (_) {
      // 无法连接 — 可能是权限/沙盒问题，允许启动
      return true;
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 单实例检查（仅 macOS/桌面端）
  if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
    final isFirstInstance = await _acquireSingleInstanceLock();
    if (!isFirstInstance) {
      // 已有实例在运行，直接退出
      exit(0);
    }
  }

  // 状态栏透明，与深色主题融合
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppTheme.bgDeep,
    systemNavigationBarIconBrightness: Brightness.light,
  ));

  try {
    // 初始化Hive数据库
    await StorageService.init();
    AppTheme.select(StorageService.getColorScheme());

    // 初始化通知服务
    await NotificationService.init();
    // 初始化后台服务
    await BackgroundService.init();

    runApp(const MyApp());
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'ssh_tool_app startup',
      ),
    );
    runApp(StartupErrorApp(message: _buildStartupErrorMessage(error)));
  }
}

String _buildStartupErrorMessage(Object error) {
  if (error is StorageInitializationException) {
    return error.message;
  }
  return '应用启动失败：$error';
}

bool shouldPollLocally(
    TargetPlatform platform, bool isForeground, bool hasActiveSessions) {
  return hasActiveSessions &&
      (isForeground || platform == TargetPlatform.macOS);
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  // 全局导航 key，用于通知点击后导航
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // 待跳转状态（通知点击时兜底）
  static String? pendingSessionName;
  static SshConnection? pendingConnection;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  Timer? _foregroundPollTimer;
  bool _isForegroundPolling = false;
  final Map<String, String> _lastNotifiedActivity = {};
  final Set<String> _primedConnections = {};

  int _activityPriority(String activity) {
    switch (activity) {
      case 'asking':
        return 0;
      case 'finished':
        return 1;
      default:
        return 2;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 设置通知点击回调
    NotificationService.onNotificationTap = _onNotificationTap;
    NotificationService.onCodexTap = _onCodexTap;
    CodexChatService.activeJobsNotifier.addListener(_onActiveSessionsChanged);
    final initial = NotificationService.takePendingCodexLaunch();
    if (initial != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onCodexTap(initial);
      });
    }

    // 活跃会话变化时，前台轮询状态并发通知
    SshService.activeSessionsNotifier.addListener(_onActiveSessionsChanged);
    _syncForegroundPollingState();
    unawaited(_syncBackgroundMonitoringState()
        .then((_) => NotificationService.syncForegroundNotifications()));
  }

  void _onActiveSessionsChanged() {
    _syncForegroundPollingState();
    unawaited(_syncBackgroundMonitoringState());
  }

  void _syncForegroundPollingState() {
    final activeIds = _activeConnectionIds();
    final hasActiveSessions = activeIds.isNotEmpty;
    _primedConnections.removeWhere((id) => !activeIds.contains(id));
    final shouldForegroundPoll = shouldPollLocally(defaultTargetPlatform,
        NotificationService.isAppInForeground, hasActiveSessions);
    if (shouldForegroundPoll) {
      _startForegroundPoller();
    } else {
      _stopForegroundPoller();
      if (!hasActiveSessions) {
        _lastNotifiedActivity.clear();
        _primedConnections.clear();
      }
    }
  }

  Future<void> _syncBackgroundMonitoringState() async {
    final activeIds = _activeConnectionIds();
    final shouldRunInBackground =
        !NotificationService.isAppInForeground && activeIds.isNotEmpty;

    if (shouldRunInBackground) {
      final connections = StorageService.getAllConnections()
          .where((c) => activeIds.contains(c.id))
          .toList();
      final started = await BackgroundService.start();
      if (started) {
        BackgroundService.updateConnections(
          connections,
          codexJobs: CodexChatService.activeJobsNotifier.value,
        );
      }
      return;
    }

    await BackgroundService.stop();
  }

  void _startForegroundPoller() {
    _foregroundPollTimer ??=
        Timer.periodic(const Duration(seconds: 5), (_) => _pollAndNotify());
    _pollAndNotify();
  }

  void _stopForegroundPoller() {
    _foregroundPollTimer?.cancel();
    _foregroundPollTimer = null;
  }

  Set<String> _activeConnectionIds() {
    return {
      ...CodexChatService.activeJobsNotifier.value.keys,
      ...SshService.activeSessionsNotifier.value
          .map((id) => id.split(':').first)
    };
  }

  Future<void> _pollAndNotify() async {
    if (_isForegroundPolling) return;
    if (!shouldPollLocally(defaultTargetPlatform,
        NotificationService.isAppInForeground, _activeConnectionIds().isNotEmpty)) {
      return;
    }

    // 在会话页由 TmuxWorkspaceScreen 自己处理，避免重复通知
    if (NotificationService.activeConnectionId != null) return;

    final connectionIds = _activeConnectionIds();
    if (connectionIds.isEmpty) return;

    _isForegroundPolling = true;
    try {
      for (final connectionId in connectionIds) {
        await _pollOneConnection(connectionId);
      }
    } finally {
      _isForegroundPolling = false;
    }
  }

  Future<void> _pollOneConnection(String connectionId) async {
    final client = SshService.getClient(connectionId);
    if (client == null) return;

    try {
      final result = await client
          .run('cat ~/.ssh_tool/state.json 2>/dev/null || echo "{}"');
      final stateJson = utf8.decode(result, allowMalformed: true);
      final state = json.decode(stateJson) as Map<String, dynamic>;
      final sessions = state['sessions'] as Map<String, dynamic>? ?? {};
      final seenKeys = <String>{};
      final isPriming = !_primedConnections.contains(connectionId);
      final sortedEntries = sessions.entries.toList()
        ..sort((a, b) {
          final aMap = a.value is Map
              ? Map<String, dynamic>.from(a.value as Map)
              : const <String, dynamic>{};
          final bMap = b.value is Map
              ? Map<String, dynamic>.from(b.value as Map)
              : const <String, dynamic>{};
          final aActivity = (aMap['activity'] as String? ?? 'idle').trim();
          final bActivity = (bMap['activity'] as String? ?? 'idle').trim();
          final byPriority = _activityPriority(aActivity).compareTo(
            _activityPriority(bActivity),
          );
          if (byPriority != 0) return byPriority;
          return a.key.compareTo(b.key);
        });

      for (final entry in sortedEntries) {
        if (entry.value is! Map) continue;
        final sessionName = entry.key;
        final info = Map<String, dynamic>.from(entry.value as Map);
        final activity = (info['activity'] as String? ?? 'idle').trim();
        final sessionKey = '$connectionId:$sessionName';
        seenKeys.add(sessionKey);

        if (activity == 'finished') {
          // 首次接管该连接时，不补发历史 finished，避免切后台后弹旧通知。
          if (isPriming && activity == 'finished') {
            _lastNotifiedActivity[sessionKey] = activity;
            continue;
          }
          final last = _lastNotifiedActivity[sessionKey];
          if (last != activity) {
            await NotificationService.showClaudeFinished(
              connectionId,
              sessionName,
            );
            _lastNotifiedActivity[sessionKey] = activity;
          }
        } else {
          _lastNotifiedActivity.remove(sessionKey);
        }
      }
      _primedConnections.add(connectionId);

      _lastNotifiedActivity.removeWhere(
        (key, _) => key.startsWith('$connectionId:') && !seenKeys.contains(key),
      );
    } catch (_) {
      // 忽略轮询错误，下次继续
    }
  }

  void _onNotificationTap(String connectionId, String sessionName) {
    // 已在对应连接的 tmux 页面时，由页面内监听器直接切 tab
    if (NotificationService.activeConnectionId == connectionId) {
      return;
    }

    // 从存储中找到对应的连接
    final connections = StorageService.getAllConnections();
    SshConnection? targetConnection;

    // 优先用 ID 查找
    for (final conn in connections) {
      if (conn.id == connectionId) {
        targetConnection = conn;
        break;
      }
    }

    // 记录通知目标，供页面初始化时切换对应会话
    MyApp.pendingSessionName = sessionName;

    // 如果找不到，用最近的连接
    targetConnection ??= MyApp.pendingConnection;

    if (targetConnection == null) return;
    final SshConnection connection = targetConnection;

    MyApp.pendingConnection = connection;
    // 导航到 tmux workspace
    MyApp.navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (_) => TmuxWorkspaceScreen(
          connection: connection,
          initialSessionName: sessionName,
        ),
      ),
    );
  }

  Future<void> _onCodexTap(CodexCompletionTarget target) async {
    await NotificationService.recordCodexFinished(
      target.connectionId,
      target.threadId,
      target.jobId ?? 'legacy:${target.threadId}',
    );
    if (StorageService.getConnection(target.connectionId) == null) return;
    MyApp.navigatorKey.currentState?.push(MaterialPageRoute(
      builder: (_) => CodexNotificationHistoryScreen(initialTarget: target),
    ));
  }

  @override
  void dispose() {
    _stopForegroundPoller();
    unawaited(BackgroundService.stop());
    SshService.activeSessionsNotifier.removeListener(_onActiveSessionsChanged);
    CodexChatService.activeJobsNotifier
        .removeListener(_onActiveSessionsChanged);
    NotificationService.onCodexTap = null;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService.isAppInForeground = state == AppLifecycleState.resumed;
    _syncForegroundPollingState();
    final sync = _syncBackgroundMonitoringState();
    if (NotificationService.isAppInForeground) {
      unawaited(
          sync.then((_) => NotificationService.syncForegroundNotifications()));
    } else {
      unawaited(sync);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AppTheme.selectedScheme,
      builder: (context, _, __) => MaterialApp(
        navigatorKey: MyApp.navigatorKey,
        title: 'SSH终端工具',
        theme: AppTheme.darkTheme,
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SSH终端工具',
      theme: AppTheme.darkTheme,
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: AppTheme.orange, size: 24),
                          SizedBox(width: 10),
                          Text(
                            '启动失败',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      SelectableText(
                        message,
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '处理方式：关闭已打开的 ssh_tool_app 窗口，再重新运行当前 .app。',
                        style: TextStyle(color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
