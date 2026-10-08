import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../main.dart';
import '../models/ssh_connection.dart';
import '../services/ssh_service.dart';
import '../services/codex_preload_service.dart';
import '../services/codex_setup_service.dart';
import '../services/storage_service.dart';
import '../services/notification_service.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_card.dart';
import 'connection_form_screen.dart';
import 'claude_conversation_picker_screen.dart';
import 'tmux_workspace_screen.dart';
import 'codex_notification_history_screen.dart';
import 'codex_setup_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final CodexPreloadService _preloader = CodexPreloadService();
  Timer? _preloadTimer;
  bool _preloadInProgress = false;
  late String _assistant;

  @override
  void initState() {
    super.initState();
    _assistant = StorageService.getHomeAssistant();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _preloadIfVisible());
    _preloadTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _preloadIfVisible(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _preloadIfVisible();
  }

  Future<void> _preloadIfVisible() async {
    if (!mounted ||
        _assistant != 'codex' ||
        _preloadInProgress ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        (ModalRoute.of(context)?.isCurrent == false)) {
      return;
    }
    _preloadInProgress = true;
    try {
      final box = Hive.box<SshConnection>('connections');
      await _preloader.preloadConnections(box.values.toList());
    } catch (_) {
      // Background preload failures should not interrupt the home screen.
    } finally {
      _preloadInProgress = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _preloadTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('>_ SSH 终端'),
        actions: [
          if (_assistant == 'codex') ValueListenableBuilder<int>(
            valueListenable: NotificationService.historyRevision,
            builder: (context, _, __) {
              final unread = StorageService.getCodexCompletionNotices()
                  .where((notice) => !notice.read)
                  .length;
              return IconButton(
                tooltip: '通知历史',
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text(unread > 99 ? '99+' : '$unread'),
                  child: const Icon(Icons.notifications_none),
                ),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const CodexNotificationHistoryScreen(),
                )),
              );
            },
          ),
          PopupMenuButton<String>(
            tooltip: '配色方案',
            icon: const Icon(Icons.palette_outlined),
            onSelected: (scheme) async {
              AppTheme.select(scheme);
              await StorageService.setColorScheme(scheme);
            },
            itemBuilder: (_) => [
              for (final entry in AppTheme.schemes.entries)
                CheckedPopupMenuItem<String>(
                  value: entry.key,
                  checked: AppTheme.selectedScheme.value == entry.key,
                  child: Text(entry.value),
                ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 20),
            onPressed: () => _showAbout(context),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: SizedBox(width: double.infinity, child: SegmentedButton<String>(
            key: const ValueKey('home-assistant-mode'),
            segments: const [
              ButtonSegment(value: 'codex', label: Text('Codex'), icon: Icon(Icons.code)),
              ButtonSegment(value: 'claude', label: Text('Claude'), icon: Icon(Icons.auto_awesome)),
            ],
            selected: {_assistant},
            onSelectionChanged: (selection) async {
              setState(() => _assistant = selection.single);
              await StorageService.setHomeAssistant(_assistant);
              if (mounted) unawaited(_preloadIfVisible());
            },
          )),
        ),
        Expanded(child: ValueListenableBuilder<Set<String>>(
        valueListenable: SshService.activeSessionsNotifier,
        builder: (context, activeSessions, _) {
          return ValueListenableBuilder(
            valueListenable: Hive.box<SshConnection>('connections').listenable(),
            builder: (context, Box<SshConnection> box, _) {
              if (box.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.terminal, size: 56, color: AppTheme.textMuted.withValues(alpha: 0.4)),
                      const SizedBox(height: 16),
                      Text(
                        '还没有 SSH 连接',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '点击下方按钮添加第一个连接',
                        style: TextStyle(fontSize: 13, color: AppTheme.textMuted),
                      ),
                    ],
                  ),
                );
              }

              final connections = box.values.toList()
                ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

              return ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: connections.length,
                itemBuilder: (context, index) {
                  final connection = connections[index];
                  final isActive = activeSessions.any((sid) =>
                      sid == connection.id || sid.startsWith('${connection.id}:'));
                  return ConnectionCard(
                    connection: connection,
                    isActive: isActive,
                    onTap: () => _connectToServer(context, connection),
                    onEdit: () => _editConnection(context, connection),
                    onDelete: () => _deleteConnection(context, connection),
                    onCodexSetup: _assistant == 'codex'
                        ? () => _openCodexSetup(context, connection)
                        : null,
                    onDisconnect: isActive
                        ? () => _disconnectSession(context, connection)
                        : null,
                  );
                },
              );
            },
          );
        },
      )),
      ]),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            colors: [AppTheme.cyan, Color(0xFF2196F3)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [
            BoxShadow(
              color: AppTheme.cyan.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _addConnection(context),
            borderRadius: BorderRadius.circular(28),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('新建连接', style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _addConnection(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => const ConnectionFormScreen(),
      ),
    );
  }

  void _editConnection(BuildContext context, SshConnection connection) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ConnectionFormScreen(connection: connection),
      ),
    );
  }

  Future<void> _connectToServer(BuildContext context, SshConnection connection) async {
    // 设置待跳转连接，供通知点击回调使用
    MyApp.pendingConnection = connection;
    MyApp.pendingSessionName = null;

    if (_assistant == 'claude') {
      Navigator.push(
        context,
        MaterialPageRoute(
          settings: const RouteSettings(name: '/assistant/claude'),
          builder: (_) => ClaudeConversationPickerScreen(connection: connection),
        ),
      );
      return;
    }

    CodexSetupStatus setup;
    try {
      setup = await CodexSetupService.inspect(connection);
    } catch (e) {
      if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('无法检测 Codex 环境：$e'),
            action: SnackBarAction(
              label: '检查环境',
              onPressed: () => _openCodexSetup(context, connection),
            ),
          ),
        );
      }
      return;
    }
    if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) return;
    if (!setup.ready) {
      await _openCodexSetup(context, connection);
      if (!context.mounted || ModalRoute.of(context)?.isCurrent != true) return;
      try {
        setup = await CodexSetupService.inspect(connection);
      } catch (e) {
        if (context.mounted && ModalRoute.of(context)?.isCurrent == true) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('无法检测 Codex 环境：$e'),
              action: SnackBarAction(
                label: '检查环境',
                onPressed: () => _openCodexSetup(context, connection),
              ),
            ),
          );
        }
        return;
      }
      if (!context.mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          !setup.ready) {
        return;
      }
    }
    _openCodexPicker(context, connection);
  }

  void _openCodexPicker(BuildContext context, SshConnection connection) {
    ScaffoldMessenger.of(context).clearSnackBars();
    Navigator.push(
      context,
      MaterialPageRoute(
        settings: const RouteSettings(name: '/assistant/codex'),
        builder: (_) => CodexConversationPickerScreen(connection: connection),
      ),
    );
  }

  Future<void> _openCodexSetup(BuildContext context, SshConnection connection) async {
    ScaffoldMessenger.of(context).clearSnackBars();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => CodexSetupScreen(connection: connection)),
    );
  }

  Future<void> _disconnectSession(BuildContext context, SshConnection connection) async {
    final allActive = SshService.activeSessionsNotifier.value;
    final toDisconnect = allActive.where((sid) =>
        sid == connection.id || sid.startsWith('${connection.id}:')).toList();
    for (final sid in toDisconnect) {
      await SshService.disconnect(sid);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已断开 ${connection.name} (${toDisconnect.length}个会话)')),
      );
    }
  }

  Future<void> _deleteConnection(BuildContext context, SshConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除连接 "${connection.name}" 吗？\n这将同时删除所有命令历史。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      await StorageService.deleteConnection(connection.id);
      NotificationService.historyRevision.value++;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('连接已删除')),
        );
      }
    }
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'SSH终端工具',
      applicationVersion: '1.0.0',
      applicationIcon: Icon(Icons.terminal, size: 48, color: AppTheme.cyan),
      children: const [
        Text('终端风格的 SSH 客户端'),
        SizedBox(height: 8),
        Text('• 多会话 tmux 工作区'),
        Text('• Claude / Codex 会话类型'),
        Text('• 命令历史记录'),
      ],
    );
  }
}
