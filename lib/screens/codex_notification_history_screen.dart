import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/codex_completion_notice.dart';
import '../models/ssh_connection.dart';
import '../services/codex_session_service.dart';
import '../services/notification_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import 'codex_chat_screen.dart';

class CodexServerNotificationButton extends StatelessWidget {
  const CodexServerNotificationButton({super.key, required this.connectionId});

  final String connectionId;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: NotificationService.historyRevision,
        builder: (context, _, __) {
          final unread = StorageService.getCodexCompletionNotices()
              .where((notice) =>
                  notice.connectionId == connectionId && !notice.read)
              .length;
          return IconButton(
            tooltip: '本服务器通知历史',
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 99 ? '99+' : '$unread'),
              child: const Icon(Icons.notifications_none),
            ),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) =>
                  CodexNotificationHistoryScreen(connectionId: connectionId),
            )),
          );
        },
      );
}

class CodexNotificationHistoryScreen extends StatefulWidget {
  final String? connectionId;
  final CodexCompletionTarget? initialTarget;
  final Widget Function(SshConnection connection, String threadId)?
      conversationBuilder;

  const CodexNotificationHistoryScreen({
    super.key,
    this.connectionId,
    this.initialTarget,
    this.conversationBuilder,
  });

  @override
  State<CodexNotificationHistoryScreen> createState() =>
      _CodexNotificationHistoryScreenState();
}

class _CodexNotificationHistoryScreenState
    extends State<CodexNotificationHistoryScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.initialTarget != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final target = widget.initialTarget!;
        final notices = StorageService.getCodexCompletionNotices();
        for (final notice in notices) {
          if (notice.connectionId == target.connectionId &&
              notice.threadId == target.threadId &&
              (target.jobId == null ||
                  notice.id == '${target.connectionId}:${target.jobId}')) {
            unawaited(_open(notice));
            return;
          }
        }
      });
    }
  }

  Future<void> _open(CodexCompletionNotice notice) async {
    final connection = StorageService.getConnection(notice.connectionId);
    if (connection == null) return;
    unawaited(NotificationService.markCodexConversationViewed(
        notice.connectionId, notice.threadId));
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) =>
          widget.conversationBuilder?.call(connection, notice.threadId) ??
          CodexNotificationConversationScreen(
            connection: connection,
            threadId: notice.threadId,
          ),
    ));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('通知历史')),
        body: ValueListenableBuilder<int>(
          valueListenable: NotificationService.historyRevision,
          builder: (context, _, __) {
            final notices = StorageService.getCodexCompletionNotices()
                .where((notice) =>
                    widget.connectionId == null ||
                    notice.connectionId == widget.connectionId)
                .toList();
            if (notices.isEmpty) {
              return Center(
                child: Text('还没有完成通知',
                    style: TextStyle(color: AppTheme.textMuted)),
              );
            }
            return ListView.builder(
              itemCount: notices.length,
              itemBuilder: (context, index) {
                final notice = notices[index];
                final connection =
                    StorageService.getConnection(notice.connectionId);
                final shortId = notice.threadId.length > 8
                    ? notice.threadId.substring(0, 8)
                    : notice.threadId;
                return ListTile(
                  key: ValueKey('notice-${notice.id}'),
                  leading: Icon(
                    notice.read
                        ? Icons.notifications_none
                        : Icons.notifications_active,
                    color: notice.read ? AppTheme.textMuted : AppTheme.blue,
                  ),
                  title: Text(notice.notificationTitle,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(widget.connectionId == null
                      ? '${connection?.name ?? '已删除的连接'} · $shortId\n'
                          '${DateFormat('MM-dd HH:mm').format(notice.completedAt.toLocal())}'
                      : '$shortId · '
                          '${DateFormat('MM-dd HH:mm').format(notice.completedAt.toLocal())}'),
                  isThreeLine: widget.connectionId == null,
                  onTap: () => unawaited(_open(notice)),
                );
              },
            );
          },
        ),
      );
}

class CodexNotificationConversationScreen extends StatefulWidget {
  const CodexNotificationConversationScreen(
      {super.key, required this.connection, required this.threadId});
  final SshConnection connection;
  final String threadId;

  @override
  State<CodexNotificationConversationScreen> createState() =>
      _CodexNotificationConversationScreenState();
}

class _CodexNotificationConversationScreenState
    extends State<CodexNotificationConversationScreen> {
  late final Future<CodexConversation?> _conversation = _load();

  Future<CodexConversation?> _load() async {
    await SshService.connectClient(widget.connection);
    return CodexSessionService.findById(widget.connection.id, widget.threadId);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CodexConversation?>(
        future: _conversation,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Scaffold(
                appBar: AppBar(title: const Text('Codex 对话')),
                body: Center(child: Text('打开对话失败：${snapshot.error}')));
          }
          if (snapshot.connectionState != ConnectionState.done) {
            return Scaffold(
                appBar: AppBar(title: const Text('Codex 对话')),
                body: const Center(child: CircularProgressIndicator()));
          }
          if (snapshot.data == null) {
            return Scaffold(
              appBar: AppBar(title: const Text('Codex 对话')),
              body: const Center(child: Text('远端没有找到这条对话')),
            );
          }
          final conversation = snapshot.data!;
          return CodexChatScreen(
            connection: widget.connection,
            workDir: conversation.cwd,
            conversation: conversation,
          );
        },
      );
}
