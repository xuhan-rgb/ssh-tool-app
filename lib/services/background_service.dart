import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/ssh_connection.dart';
import '../models/codex_completion_notice.dart';

/// 后台服务：保持 SSH 连接和轮询 alive
@pragma('vm:entry-point')
class BackgroundService {
  static bool get _isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static const String _channelId = 'claude_activity';
  static const String _channelName = 'Claude 活动';
  static const String _channelDesc = 'Claude Code 状态变化通知';

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static final Map<String, String> _lastNotifiedActivity = {};
  static final Map<String, SSHClient> _clients = {};
  static final Map<String, Map<String, dynamic>> _connectionConfigs = {};
  static final Map<String, Set<String>> _codexJobs = {};
  static final Set<String> _notifiedCodexJobs = {};
  static final Set<String> _primedConnections = {};

  static int _activityPriority(String activity) {
    switch (activity) {
      case 'asking':
        return 0;
      case 'finished':
        return 1;
      default:
        return 2;
    }
  }

  static int _notificationId(String connectionId, String sessionName) {
    return '$connectionId:$sessionName'.hashCode;
  }

  /// 初始化后台服务
  static Future<void> init() async {
    if (!_isSupportedPlatform) return;
    final service = FlutterBackgroundService();

    // 不在这里 initialize 通知插件，避免覆盖主 isolate 的点击回调。
    // 通知点击回调由 NotificationService.init() 统一注册。

    // 创建通知渠道
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description: _channelDesc,
          importance: Importance.high,
        ));

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'SSH终端',
        initialNotificationContent: '正在后台监控 Claude 状态',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  /// 启动后台服务
  static Future<bool> start() async {
    if (!_isSupportedPlatform) return false;
    final service = FlutterBackgroundService();
    if (await service.isRunning()) return true;
    return await service.startService();
  }

  /// 停止后台服务
  static Future<void> stop() async {
    if (!_isSupportedPlatform) return;
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) return;
    service.invoke('stop');
  }

  /// 后台服务是否在运行
  static Future<bool> isRunning() async {
    if (!_isSupportedPlatform) return false;
    return FlutterBackgroundService().isRunning();
  }

  /// 下发需要监控的连接配置给后台 isolate
  static void updateConnections(List<SshConnection> connections,
      {Map<String, Set<String>> codexJobs = const {}}) {
    if (!_isSupportedPlatform) return;
    final payload = connections
        .map((c) => {
              'id': c.id,
              'host': c.host,
              'port': c.port,
              'username': c.username,
              'password': c.password,
            })
        .toList();
    FlutterBackgroundService().invoke('setConnections', {
      'connections': payload,
      'codexJobs': codexJobs.map((id, jobs) => MapEntry(id, jobs.toList())),
    });
  }

  /// 后台服务入口
  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    final notificationPlugin = FlutterLocalNotificationsPlugin();
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await notificationPlugin.initialize(initSettings);

    // 接收前台下发的连接列表
    service.on('setConnections').listen((event) async {
      final list = event?['connections'] as List<dynamic>? ?? const [];
      final nextIds = <String>{};
      final nextConfigs = <String, Map<String, dynamic>>{};
      for (final item in list) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final id = (map['id'] as String?)?.trim() ?? '';
        if (id.isEmpty) continue;
        nextIds.add(id);
        nextConfigs[id] = map;
      }

      _connectionConfigs
        ..clear()
        ..addAll(nextConfigs);
      final jobs = event?['codexJobs'] as Map? ?? const {};
      _codexJobs
        ..clear()
        ..addAll(jobs.map((id, value) => MapEntry(
              id.toString(),
              (value as List).map((item) => item.toString()).toSet(),
            )));

      // 清理不再需要的连接
      final staleIds =
          _clients.keys.where((id) => !nextIds.contains(id)).toList();
      for (final id in staleIds) {
        _clients.remove(id)?.close();
        _primedConnections.remove(id);
        _lastNotifiedActivity.removeWhere((key, _) => key.startsWith('$id:'));
      }
    });

    // 响应停止命令
    service.on('stop').listen((event) {
      for (final client in _clients.values) {
        client.close();
      }
      _clients.clear();
      _connectionConfigs.clear();
      _codexJobs.clear();
      _notifiedCodexJobs.clear();
      _primedConnections.clear();
      _lastNotifiedActivity.clear();
      service.stopSelf();
    });

    // 主循环：每 5 秒检查一次状态
    Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          final connectionIds = _connectionConfigs.keys.toList();
          if (connectionIds.isEmpty) return;

          // 检查各连接内各会话状态
          for (final connId in connectionIds) {
            await _checkAndNotify(
              connId,
              _connectionConfigs[connId],
              notificationPlugin,
            );
          }
        }
      }
    });
  }

  /// 检查会话状态并发送通知
  static Future<void> _checkAndNotify(
    String connectionId,
    Map<String, dynamic>? config,
    FlutterLocalNotificationsPlugin plugin,
  ) async {
    try {
      final client = await _ensureClient(connectionId, config);
      if (client == null) return;

      for (final jobId in _codexJobs[connectionId] ?? const <String>{}) {
        if (_notifiedCodexJobs.contains('$connectionId:$jobId')) continue;
        final result = await client.run(
          'cat "\$HOME/.ssh_tool/chat_jobs/$jobId/state.json" 2>/dev/null || echo "{}"',
        );
        final job =
            jsonDecode(utf8.decode(result, allowMalformed: true)) as Map;
        if (job['status'] != 'completed') continue;
        final threadId = job['threadId'] as String?;
        if (threadId == null || threadId.isEmpty) continue;
        _notifiedCodexJobs.add('$connectionId:$jobId');
        await plugin.show(
          'codex:$connectionId:$jobId'.hashCode,
          '${CodexCompletionNotice.formatTitle(threadId, job['title'] as String?)} · 已完成',
          '点击查看回复',
          const NotificationDetails(
              android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            onlyAlertOnce: true,
          )),
          payload: 'codex|$connectionId|$threadId|$jobId',
        );
      }

      // 读取远程状态
      final result = await client.run(
        'cat ~/.ssh_tool/state.json 2>/dev/null || echo "{}"',
      );
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
        final name = entry.key;
        final info = Map<String, dynamic>.from(entry.value as Map);
        final activity = info['activity'] as String? ?? 'idle';
        final sessionKey = '$connectionId:$name';
        seenKeys.add(sessionKey);

        // asking/finished 只通知一次；状态变化后再允许下一次通知
        if (activity == 'finished') {
          // 首次接管该连接时，不补发历史 finished，避免切后台后弹旧通知。
          if (isPriming && activity == 'finished') {
            _lastNotifiedActivity[sessionKey] = activity;
            continue;
          }
          final last = _lastNotifiedActivity[sessionKey];
          if (last != activity) {
            await _showNotification(
              plugin,
              connectionId,
              name,
              activity,
              info['message'] as String? ?? '',
            );
            _lastNotifiedActivity[sessionKey] = activity;
          }
        } else {
          _lastNotifiedActivity.remove(sessionKey);
        }
      }
      _primedConnections.add(connectionId);

      // 清理已不存在的会话，避免缓存累积
      _lastNotifiedActivity.removeWhere(
        (key, _) => key.startsWith('$connectionId:') && !seenKeys.contains(key),
      );
    } catch (_) {
      // 当前 client 可能已失效，下次轮询重连
      _clients.remove(connectionId)?.close();
      // 忽略错误，继续轮询
    }
  }

  static Future<SSHClient?> _ensureClient(
    String connectionId,
    Map<String, dynamic>? config,
  ) async {
    if (config == null) return null;
    final cached = _clients[connectionId];
    if (cached != null) return cached;

    final host = (config['host'] as String?)?.trim();
    final username = (config['username'] as String?)?.trim();
    final port = (config['port'] as num?)?.toInt() ?? 22;
    final password = (config['password'] as String?) ?? '';
    if (host == null || host.isEmpty || username == null || username.isEmpty) {
      return null;
    }

    try {
      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 20),
      );
      final client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
      );
      await client.authenticated;
      _clients[connectionId] = client;
      return client;
    } catch (_) {
      return null;
    }
  }

  /// 显示通知
  static Future<void> _showNotification(
    FlutterLocalNotificationsPlugin plugin,
    String connectionId,
    String sessionName,
    String activity,
    String message,
  ) async {
    final title = '✅ $sessionName — Claude 完成了';

    final body = message.isNotEmpty
        ? (message.length > 120 ? '${message.substring(0, 120)}...' : message)
        : '点击查看结果';

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        onlyAlertOnce: true,
        category: AndroidNotificationCategory.message,
      ),
    );

    await plugin.show(
      _notificationId(connectionId, sessionName),
      title,
      body,
      details,
      payload: '$connectionId:$sessionName',
    );
  }
}
