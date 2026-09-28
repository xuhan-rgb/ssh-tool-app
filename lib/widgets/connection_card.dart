import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/ssh_connection.dart';
import '../theme/app_theme.dart';

enum _ConnectionCardAction { connect, disconnect, edit, delete }

class ConnectionCard extends StatelessWidget {
  final SshConnection connection;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onDisconnect;

  const ConnectionCard({
    super.key,
    required this.connection,
    this.isActive = false,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    this.onDisconnect,
  });

  /// 左侧竖条颜色：SSH 已连接=绿, 默认=紫暗
  Color get _accentColor {
    if (isActive) return AppTheme.green;
    return AppTheme.purple.withValues(alpha: 0.4);
  }

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MM-dd HH:mm');

    return Card(
      child: InkWell(
        onTap: onTap,
        onLongPress: () => _showOptions(context),
        onSecondaryTapDown: (details) =>
            _showContextMenu(context, details.globalPosition),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border(
              left: BorderSide(color: _accentColor, width: 3),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          child: Row(
            children: [
              // 图标
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: isActive ? AppTheme.greenDim : AppTheme.bgHover,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.computer,
                  size: 20,
                  color: isActive ? AppTheme.green : AppTheme.textMuted,
                ),
              ),
              const SizedBox(width: 14),
              // 信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 名称行 + 徽章
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            connection.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isActive) ...[
                          const SizedBox(width: 6),
                          _badge('● 已连接', AppTheme.green, AppTheme.greenDim),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    // 主机
                    Text(
                      connection.connectionString,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        color: AppTheme.textMuted,
                      ),
                    ),
                    const SizedBox(height: 3),
                    // 底部信息行
                    Row(
                      children: [
                        Icon(
                          connection.usePrivateKey
                              ? Icons.vpn_key
                              : Icons.password,
                          size: 12,
                          color: AppTheme.textMuted,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          connection.usePrivateKey ? '密钥' : '密码',
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textMuted),
                        ),
                        const SizedBox(width: 10),
                        Icon(Icons.access_time,
                            size: 12, color: AppTheme.textMuted),
                        const SizedBox(width: 3),
                        Text(
                          dateFormat.format(connection.updatedAt),
                          style: TextStyle(
                              fontSize: 11, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PopupMenuButton<_ConnectionCardAction>(
                    tooltip: '更多操作',
                    icon: Icon(Icons.more_vert,
                        size: 20, color: AppTheme.textMuted),
                    onSelected: _handleAction,
                    itemBuilder: (context) => _buildMenuItems(),
                  ),
                  Icon(Icons.chevron_right,
                      size: 20, color: AppTheme.textMuted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<PopupMenuEntry<_ConnectionCardAction>> _buildMenuItems() {
    final items = <PopupMenuEntry<_ConnectionCardAction>>[
      PopupMenuItem(
        value: _ConnectionCardAction.connect,
        child: Row(
          children: [
            const Icon(Icons.terminal, size: 18),
            const SizedBox(width: 10),
            Text(isActive ? '打开终端' : '连接'),
          ],
        ),
      ),
    ];

    if (isActive && onDisconnect != null) {
      items.add(
        PopupMenuItem(
          value: _ConnectionCardAction.disconnect,
          child: Row(
            children: [
              Icon(Icons.link_off, size: 18, color: AppTheme.orange),
              const SizedBox(width: 10),
              Text('断开连接', style: TextStyle(color: AppTheme.orange)),
            ],
          ),
        ),
      );
    }

    items.addAll([
      const PopupMenuDivider(),
      const PopupMenuItem(
        value: _ConnectionCardAction.edit,
        child: Row(
          children: [
            Icon(Icons.edit, size: 18),
            SizedBox(width: 10),
            Text('编辑'),
          ],
        ),
      ),
      PopupMenuItem(
        value: _ConnectionCardAction.delete,
        child: Row(
          children: [
            Icon(Icons.delete, size: 18, color: AppTheme.red),
            const SizedBox(width: 10),
            Text('删除', style: TextStyle(color: AppTheme.red)),
          ],
        ),
      ),
    ]);

    return items;
  }

  Widget _badge(String text, Color color, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
          color: color,
        ),
      ),
    );
  }

  void _handleAction(_ConnectionCardAction action) {
    switch (action) {
      case _ConnectionCardAction.connect:
        onTap();
        break;
      case _ConnectionCardAction.disconnect:
        onDisconnect?.call();
        break;
      case _ConnectionCardAction.edit:
        onEdit();
        break;
      case _ConnectionCardAction.delete:
        onDelete();
        break;
    }
  }

  void _showOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.terminal),
              title: Text(isActive ? '打开终端' : '连接'),
              onTap: () {
                Navigator.pop(context);
                _handleAction(_ConnectionCardAction.connect);
              },
            ),
            if (isActive && onDisconnect != null)
              ListTile(
                leading: Icon(Icons.link_off, color: AppTheme.orange),
                title: Text('断开连接', style: TextStyle(color: AppTheme.orange)),
                onTap: () {
                  Navigator.pop(context);
                  _handleAction(_ConnectionCardAction.disconnect);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑'),
              onTap: () {
                Navigator.pop(context);
                _handleAction(_ConnectionCardAction.edit);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete, color: AppTheme.red),
              title: Text('删除', style: TextStyle(color: AppTheme.red)),
              onTap: () {
                Navigator.pop(context);
                _handleAction(_ConnectionCardAction.delete);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showContextMenu(
      BuildContext context, Offset globalPosition) async {
    final action = await showMenu<_ConnectionCardAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: _buildMenuItems(),
    );

    if (action != null) {
      _handleAction(action);
    }
  }
}
