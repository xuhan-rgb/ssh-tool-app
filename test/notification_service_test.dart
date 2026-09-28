import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:ssh_tool_app/services/notification_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';
import 'package:ssh_tool_app/models/codex_completion_notice.dart';
import 'package:hive/hive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory storage;
  setUpAll(() async {
    storage = await Directory.systemTemp.createTemp('codex-notices-');
    Hive.init(storage.path);
    await Hive.openBox('settings');
  });
  tearDownAll(() async {
    await Hive.close();
    await storage.delete(recursive: true);
  });

  test('notification history expires read notices after 24 hours', () async {
    await Hive.box('settings').delete('codex_completion_notices');
    final now = DateTime.utc(2025, 1, 2, 12);
    await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
      id: 'boundary-read',
      connectionId: 'retention',
      threadId: 'thread-boundary',
      completedAt: now.subtract(const Duration(hours: 24)),
      read: true,
    ), now: now);
    await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
      id: 'expired-read',
      connectionId: 'retention',
      threadId: 'thread-read',
      completedAt: now.subtract(const Duration(hours: 24, seconds: 1)),
      read: true,
    ), now: now);
    await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
      id: 'old-unread',
      connectionId: 'retention',
      threadId: 'thread-unread',
      completedAt: now.subtract(const Duration(days: 30)),
    ), now: now);

    var notices = StorageService.getCodexCompletionNotices(now: now);
    expect(notices.map((notice) => notice.id), contains('boundary-read'));
    expect(notices.map((notice) => notice.id), contains('old-unread'));
    expect(
        notices.map((notice) => notice.id), isNot(contains('expired-read')));

    await StorageService.markCodexCompletionNoticeRead('old-unread', now: now);
    notices = StorageService.getCodexCompletionNotices(now: now);
    expect(notices.map((notice) => notice.id), isNot(contains('old-unread')));

    await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
      id: 'read-expires-on-read',
      connectionId: 'retention',
      threadId: 'thread-read-expires',
      completedAt: now.subtract(const Duration(hours: 23)),
      read: true,
    ), now: now);
    await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
      id: 'unread-survives-read',
      connectionId: 'retention',
      threadId: 'thread-unread-survives',
      completedAt: now.subtract(const Duration(days: 30)),
    ), now: now);
    final later = now.add(const Duration(hours: 2));
    notices = StorageService.getCodexCompletionNotices(now: later);
    expect(notices.map((notice) => notice.id),
        isNot(contains('read-expires-on-read')));
    expect(notices.map((notice) => notice.id), contains('unread-survives-read'));
    await Hive.box('settings').flush();
    final persisted = jsonDecode(Hive.box('settings')
        .get('codex_completion_notices') as String) as List;
    expect(
        persisted.map((item) => (item as Map)['id']),
        isNot(contains('read-expires-on-read')));
    expect(persisted.map((item) => (item as Map)['id']),
        contains('unread-survives-read'));

    for (var i = 0; i < 101; i++) {
      await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
        id: 'unread-$i',
        connectionId: 'retention',
        threadId: 'thread-$i',
        completedAt: now,
      ), now: now);
    }
    notices = StorageService.getCodexCompletionNotices(now: now);
    expect(
        notices.where((notice) => notice.id.startsWith('unread-')).length, 102);
    await StorageService.markCodexCompletionNoticeRead('unread-0', now: now);
    notices = StorageService.getCodexCompletionNotices(now: now);
    expect(notices.map((notice) => notice.id), contains('unread-0'));
    await Hive.box('settings').delete('codex_completion_notices');
  });

  test('Codex completion alerts for an unread conversation in foreground',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'initialize') return true;
      return null;
    });
    try {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      await FlutterLocalNotificationsPlugin().initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      NotificationService.isAppInForeground = false;
      await NotificationService.showCodexFinished(
          'connection-1', 'thread-123', 'job-1',
          title: '修复工作台环境安装提示');
      expect(calls.map((call) => call.method), contains('show'));
      expect(StorageService.getCodexCompletionNotices().first.threadId,
          'thread-123');
      expect(StorageService.getCodexCompletionNotices().first.title,
          '修复工作台环境安装提示');
      calls.clear();
      NotificationService.isAppInForeground = true;
      await NotificationService.showCodexFinished(
          'connection-1', 'thread-456', 'job-2');
      expect(calls.map((call) => call.method), contains('show'));
      expect(StorageService.getCodexCompletionNotices().length, 2);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('Codex completion notification routes to the exact conversation', () {
    final target = NotificationService.parseCodexPayload(
      'codex|connection-1|thread-123',
    );
    expect(target?.connectionId, 'connection-1');
    expect(target?.threadId, 'thread-123');
    expect(
        NotificationService.parseCodexPayload(
                'codex|connection-1|thread-123|job-1')
            ?.jobId,
        'job-1');
    expect(NotificationService.parseCodexPayload('connection-1:tmux'), isNull);
    expect(
        NotificationService.parseCodexPayload('codex|connection-1|'), isNull);
  });

  test('viewing one conversation cancels only its completion notification',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getActiveNotifications') {
        return [
          {'id': 101, 'payload': 'codex|view-conn|view-thread|job-a'},
          {'id': 102, 'payload': 'codex|view-conn|other-thread|job-b'},
        ];
      }
      return null;
    });
    try {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      await NotificationService.recordCodexFinished(
          'view-conn', 'view-thread', 'job-a', title: '修复工作台');
      await NotificationService.recordCodexFinished(
          'view-conn', 'other-thread', 'job-b');
      await NotificationService.markCodexConversationViewed(
          'view-conn', 'view-thread');
      final notices = StorageService.getCodexCompletionNotices();
      expect(notices.firstWhere((notice) => notice.threadId == 'view-thread').read,
          isTrue);
      expect(notices.firstWhere((notice) => notice.threadId == 'other-thread').read,
          isFalse);
      expect(calls.where((call) => call.method == 'cancel').length, 1);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('opening app imports Codex notifications without clearing unread ones',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final calls = <MethodCall>[];
    const channel = MethodChannel('dexterous.com/flutter/local_notifications');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'getActiveNotifications') {
        return [
          {
            'id': 91,
            'payload': 'codex|connection-2|thread-789|job-3',
          },
          {
            'id': 92,
            'payload': 'codex|connection-2|thread-999|job-4',
          },
        ];
      }
      return null;
    });
    try {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      NotificationService.isAppInForeground = true;
      await NotificationService.syncForegroundNotifications();
      expect(
          StorageService.getCodexCompletionNotices().map((item) => item.id),
          contains('connection-2:job-3'));
      expect(calls.map((call) => call.method), isNot(contains('cancel')));
      await NotificationService.markCodexConversationViewed(
          'connection-2', 'thread-789');
      final notices = StorageService.getCodexCompletionNotices();
      expect(notices.firstWhere((item) => item.threadId == 'thread-789').read,
          isTrue);
      expect(notices.firstWhere((item) => item.threadId == 'thread-999').read,
          isFalse);
      final cancelled = calls
          .where((call) => call.method == 'cancel')
          .map((call) => (call.arguments as Map)['id'])
          .toList();
      expect(cancelled, [91]);
    } finally {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
