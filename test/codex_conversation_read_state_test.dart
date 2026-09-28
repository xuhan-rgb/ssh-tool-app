import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/codex_completion_notice.dart';
import 'package:ssh_tool_app/services/notification_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory storage;
  setUpAll(() async {
    storage = (await TestWidgetsFlutterBinding.ensureInitialized()
        .runAsync(() => Directory.systemTemp.createTemp('codex-read-state-')))!;
    Hive.init(storage.path);
    await Hive.openBox('settings');
  });
  tearDownAll(() async {
    await Hive.close();
    await TestWidgetsFlutterBinding.ensureInitialized()
        .runAsync(() => storage.delete(recursive: true));
  });

  test('view timestamps are isolated, persistent, and monotonic', () async {
    final settings = Hive.box('settings');
    await settings.clear();
    final first = DateTime.utc(2025, 4, 1, 10);
    final later = first.add(const Duration(minutes: 5));
    await StorageService.markCodexConversationViewed('server-a', 'thread-1',
        viewedAt: first);
    await StorageService.markCodexConversationViewed('server-b', 'thread-1',
        viewedAt: later);
    expect(StorageService.getCodexConversationViewedAt('server-a', 'thread-1'),
        first);
    expect(StorageService.getCodexConversationViewedAt('server-b', 'thread-1'),
        later);
    expect(StorageService.getCodexConversationViewedAt('server-a', 'missing'),
        isNull);

    await StorageService.markCodexConversationViewed('server-a', 'thread-1',
        viewedAt: first.subtract(const Duration(seconds: 1)));
    expect(StorageService.getCodexConversationViewedAt('server-a', 'thread-1'),
        first);

    await Hive.close();
    await Hive.openBox('settings');
    expect(StorageService.getCodexConversationViewedAt('server-a', 'thread-1'),
        first);
    await Hive.box('settings').clear();
  });

  test('viewing without a notification persists and advances history revision',
      () async {
    await Hive.box('settings').clear();
    final before = NotificationService.historyRevision.value;
    final viewedAt = DateTime.utc(2025, 4, 2);
    await NotificationService.markCodexConversationViewed(
        'server-a', 'empty-thread',
        viewedAt: viewedAt);
    expect(
        StorageService.getCodexConversationViewedAt('server-a', 'empty-thread'),
        viewedAt);
    expect(NotificationService.historyRevision.value, greaterThan(before));
    await Hive.box('settings').clear();
  });

  test('viewing one conversation still marks only its notices read', () async {
    await Hive.box('settings').clear();
    final completedAt = DateTime.now();
    await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
      id: 'server-a:job-1',
      connectionId: 'server-a',
      threadId: 'thread-1',
      completedAt: completedAt,
    ));
    await StorageService.saveCodexCompletionNotice(CodexCompletionNotice(
      id: 'server-a:job-2',
      connectionId: 'server-a',
      threadId: 'thread-2',
      completedAt: completedAt,
    ));

    await NotificationService.markCodexConversationViewed(
        'server-a', 'thread-1');
    final notices = StorageService.getCodexCompletionNotices();
    expect(notices.firstWhere((notice) => notice.threadId == 'thread-1').read,
        isTrue);
    expect(notices.firstWhere((notice) => notice.threadId == 'thread-2').read,
        isFalse);
    await Hive.box('settings').clear();
  });
}
