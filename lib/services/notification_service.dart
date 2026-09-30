import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../models/codex_completion_notice.dart';
import 'storage_service.dart';

class NotificationRouteTarget {
  final String connectionId;
  final String sessionName;

  const NotificationRouteTarget({
    required this.connectionId,
    required this.sessionName,
  });
}

class CodexCompletionTarget {
  final String connectionId;
  final String threadId;
  final String? jobId;

  const CodexCompletionTarget(this.connectionId, this.threadId, [this.jobId]);
}

/// Claude 终端通知服务
///
/// 当 Claude 需要用户关注时（提问、完成）发送通知。
/// 支持 Android 和 macOS。
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool get _isSupportedPlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static final ValueNotifier<int> historyRevision = ValueNotifier<int>(0);
  static Future<void> _noticeWrite = Future.value();
  static final Set<String> _failedCodexAlerts = {};

  /// 通知点击回调 — 外部设置，用于跳转到对应 Tab
  /// payload 格式: "connectionId:sessionName"
  static void Function(String connectionId, String sessionName)?
      onNotificationTap;
  static void Function(CodexCompletionTarget target)? onCodexTap;

  static final ValueNotifier<NotificationRouteTarget?> routeTargetNotifier =
      ValueNotifier<NotificationRouteTarget?>(null);

  /// 当前是否在前台（由 App 生命周期更新）
  static bool isAppInForeground = true;

  /// 当前正在查看的会话名（前台 + 当前 Tab 时不发通知）
  static String? activeSessionName;

  /// 当前活跃的连接 ID（在 tmux_workspace_screen 中设置）
  static String? activeConnectionId;

  static const String _channelId = 'claude_activity';
  static const String _channelName = 'Claude 活动';
  static const String _channelDesc = 'Claude Code 状态变化通知';
  static const String codexPayloadPrefix = 'codex|';

  static CodexCompletionTarget? parseCodexPayload(String? payload) {
    if (payload == null || !payload.startsWith(codexPayloadPrefix)) {
      return null;
    }
    final parts = payload.split('|');
    if ((parts.length != 3 && parts.length != 4) ||
        parts[1].isEmpty ||
        parts[2].isEmpty ||
        (parts.length == 4 && parts[3].isEmpty)) {
      return null;
    }
    return CodexCompletionTarget(
        parts[1], parts[2], parts.length == 4 ? parts[3] : null);
  }

  static int _notificationId(String connectionId, String sessionName) {
    return '$connectionId:$sessionName'.hashCode;
  }

  static NotificationRouteTarget? _parsePayload(String payload) {
    final idx = payload.indexOf(':');
    if (idx > 0 && idx < payload.length - 1) {
      return NotificationRouteTarget(
        connectionId: payload.substring(0, idx),
        sessionName: payload.substring(idx + 1),
      );
    }
    if (activeConnectionId != null && payload.isNotEmpty) {
      return NotificationRouteTarget(
        connectionId: activeConnectionId!,
        sessionName: payload,
      );
    }
    return null;
  }

  /// 初始化通知插件
  static Future<void> init() async {
    if (!_isSupportedPlatform) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      macOS: darwinSettings,
    );

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onTap,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    final initial = parseCodexPayload(launch?.notificationResponse?.payload);
    if (launch?.didNotificationLaunchApp == true && initial != null) {
      _pendingCodexLaunch = initial;
    }

    // Android: 创建高优先级通知渠道
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDesc,
            importance: Importance.high,
          ));
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }

    // macOS: 请求通知权限
    if (Platform.isMacOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  static void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null) return;
    final codex = parseCodexPayload(payload);
    if (codex != null) {
      onCodexTap?.call(codex);
      return;
    }
    final target = _parsePayload(payload);
    if (target == null) return;

    routeTargetNotifier.value = target;

    if (onNotificationTap != null) {
      onNotificationTap!(target.connectionId, target.sessionName);
    }
  }

  static CodexCompletionTarget? _pendingCodexLaunch;

  static CodexCompletionTarget? takePendingCodexLaunch() {
    final target = _pendingCodexLaunch;
    _pendingCodexLaunch = null;
    return target;
  }

  static Future<void> showCodexFinished(
      String connectionId, String threadId, String jobId,
      {String? title}) async {
    final isNew = await _recordCodexFinished(
        connectionId, threadId, jobId, title: title);
    final id = '$connectionId:$jobId';
    final retry = _failedCodexAlerts.remove(id);
    if (!isNew && !retry) return;
    if (!_isSupportedPlatform) return;
    try {
      await _plugin.show(
        'codex:$connectionId:$jobId'.hashCode,
        '${CodexCompletionNotice.formatTitle(threadId, title)} · 已完成',
        '点击查看回复',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'claude_activity',
            'Claude 活动',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            onlyAlertOnce: true,
          ),
          macOS: DarwinNotificationDetails(),
        ),
        payload: '$codexPayloadPrefix$connectionId|$threadId|$jobId',
      );
    } catch (_) {
      _failedCodexAlerts.add(id);
      rethrow;
    }
  }

  static Future<void> recordCodexFinished(
      String connectionId, String threadId, String jobId, {String? title}) async {
    await _recordCodexFinished(connectionId, threadId, jobId, title: title);
  }

  static Future<bool> _recordCodexFinished(
      String connectionId, String threadId, String jobId, {String? title}) {
    final write = _noticeWrite.catchError((_) {}).then((_) async {
      final id = '$connectionId:$jobId';
      final exists = StorageService.getCodexCompletionNotices()
          .any((notice) => notice.id == id);
      await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
        id: id,
        connectionId: connectionId,
        threadId: threadId,
        title: title,
        completedAt: DateTime.now(),
      ));
      historyRevision.value++;
      return !exists;
    });
    _noticeWrite = write.then((_) {});
    return write;
  }

  static Future<void> markCodexRead(String id) async {
    await StorageService.markCodexCompletionNoticeRead(id);
    historyRevision.value++;
  }

  static Future<void> markCodexConversationViewed(
      String connectionId, String threadId,
      {DateTime? viewedAt}) async {
    if (connectionId.isEmpty) return;
    await StorageService.markCodexConversationViewed(
        connectionId, threadId,
        viewedAt: viewedAt);
    List<ActiveNotification> active = const [];
    if (_isSupportedPlatform) {
      try {
        active = await _plugin.getActiveNotifications();
      } catch (_) {
        // 即使系统通知不可读取，也要清除应用内的未读状态。
      }
    }
    for (final notification in active) {
      final target = parseCodexPayload(notification.payload);
      if (target?.connectionId != connectionId ||
          target?.threadId != threadId) {
        continue;
      }
      await recordCodexFinished(
          connectionId, threadId, target?.jobId ?? 'legacy:$threadId',
          title: _titleFromNotification(notification.title));
    }
    await _noticeWrite;
    for (final notice in StorageService.getCodexCompletionNotices()) {
      if (notice.connectionId == connectionId &&
          notice.threadId == threadId &&
          !notice.read) {
        await StorageService.markCodexCompletionNoticeRead(notice.id);
        historyRevision.value++;
      }
    }
    for (final notification in active) {
      final target = parseCodexPayload(notification.payload);
      if (target?.connectionId == connectionId &&
          target?.threadId == threadId &&
          notification.id != null) {
        await _plugin.cancel(notification.id!);
      }
    }
    historyRevision.value++;
  }

  static Future<void> syncForegroundNotifications() async {
    if (!_isSupportedPlatform || !isAppInForeground) return;
    final List<ActiveNotification> active;
    try {
      active = await _plugin.getActiveNotifications();
    } catch (_) {
      return;
    }
    for (final notification in active) {
      final target = parseCodexPayload(notification.payload);
      if (target == null) continue;
      await recordCodexFinished(
        target.connectionId,
        target.threadId,
        target.jobId ?? 'legacy:${target.threadId}',
        title: _titleFromNotification(notification.title),
      );
    }
  }

  static String? _titleFromNotification(String? title) {
    const suffix = ' · 已完成';
    if (title == null || !title.endsWith(suffix)) return null;
    return title.substring(0, title.length - suffix.length).trim();
  }

  /// Claude 完成了回答（finished 状态）
  static Future<void> showClaudeFinished(
      String connectionId, String sessionName) async {
    if (!_isSupportedPlatform) return;
    if (_shouldSuppress(connectionId, sessionName)) return;

    await _plugin.show(
      _notificationId(connectionId, sessionName),
      '$sessionName — Claude 完成了',
      '点击查看结果',
      NotificationDetails(
        android: const AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          onlyAlertOnce: true,
          color: Color(0xFF3FB950),
        ),
        macOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: '$connectionId:$sessionName',
    );
  }

  /// 取消某会话的通知（用户已切到该 Tab 时）
  static Future<void> cancelForSession(
    String sessionName, {
    String? connectionId,
  }) async {
    if (!_isSupportedPlatform) return;
    if (connectionId != null) {
      await _plugin.cancel(_notificationId(connectionId, sessionName));
      return;
    }
    await _plugin.cancel(sessionName.hashCode);
  }

  /// 是否应该抑制通知
  static bool _shouldSuppress(String connectionId, String sessionName) {
    if (isAppInForeground && activeSessionName == sessionName) return true;
    if (activeConnectionId != null && activeConnectionId != connectionId) {
      return true;
    }
    return false;
  }
}
