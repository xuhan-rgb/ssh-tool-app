import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/ssh_connection.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class ConnectionFormScreen extends StatefulWidget {
  final SshConnection? connection;

  const ConnectionFormScreen({super.key, this.connection});

  @override
  State<ConnectionFormScreen> createState() => _ConnectionFormScreenState();
}

class _ConnectionFormScreenState extends State<ConnectionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _usernameController;
  late TextEditingController _passwordController;
  late TextEditingController _claudeEnvController;
  late TextEditingController _codexTerminalCommandController;

  bool _usePrivateKey = false;
  bool _obscurePassword = true;
  bool get _showClaudeEnvConfig =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void initState() {
    super.initState();
    final conn = widget.connection;
    _nameController = TextEditingController(text: conn?.name ?? '');
    _hostController = TextEditingController(text: conn?.host ?? '');
    _portController = TextEditingController(text: conn?.port.toString() ?? '22');
    _usernameController = TextEditingController(text: conn?.username ?? '');
    _passwordController = TextEditingController(text: conn?.password ?? '');
    _claudeEnvController = TextEditingController(
      text: conn == null ? '' : StorageService.getClaudeEnvText(conn.id),
    );
    _codexTerminalCommandController = TextEditingController(
      text: conn == null ? '' : StorageService.getCodexTerminalCommand(conn.id),
    );
    _usePrivateKey = conn?.usePrivateKey ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _claudeEnvController.dispose();
    _codexTerminalCommandController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.connection != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? '编辑连接' : '新建连接'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '连接名称',
                hintText: '例如: 我的服务器',
                prefixIcon: Icon(Icons.label),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) return '请输入连接名称';
                return null;
              },
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _hostController,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '主机地址',
                hintText: '例如: 192.168.1.100',
                prefixIcon: Icon(Icons.dns),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) return '请输入主机地址';
                return null;
              },
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _portController,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '端口',
                hintText: '默认: 22',
                prefixIcon: Icon(Icons.numbers),
              ),
              keyboardType: TextInputType.number,
              validator: (value) {
                if (value == null || value.isEmpty) return '请输入端口';
                final port = int.tryParse(value);
                if (port == null || port < 1 || port > 65535) return '端口必须在1-65535之间';
                return null;
              },
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _usernameController,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: '用户名',
                hintText: '例如: root',
                prefixIcon: Icon(Icons.person),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) return '请输入用户名';
                return null;
              },
            ),
            const SizedBox(height: 16),

            // 认证方式
            Card(
              child: SwitchListTile(
                title: const Text('使用SSH密钥认证'),
                subtitle: Text(
                  _usePrivateKey ? '将使用密钥文件认证' : '将使用密码认证',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                ),
                value: _usePrivateKey,
                onChanged: (value) => setState(() => _usePrivateKey = value),
              ),
            ),
            const SizedBox(height: 8),

            const SizedBox(height: 16),

            // 密码
            if (!_usePrivateKey) ...[
              TextFormField(
                controller: _passwordController,
                decoration: InputDecoration(
                  labelText: '密码',
                  hintText: '输入SSH密码',
                  prefixIcon: const Icon(Icons.lock),
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off, color: AppTheme.textMuted),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                obscureText: _obscurePassword,
                validator: (value) {
                  if (!_usePrivateKey && (value == null || value.isEmpty)) return '请输入密码';
                  return null;
                },
              ),
            ],

            // SSH密钥提示
            if (_usePrivateKey) ...[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.orangeDim,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.orange.withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info, color: AppTheme.orange, size: 20),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'SSH密钥认证功能将在后续版本中实现。\n当前版本请使用密码认证。',
                        style: TextStyle(color: AppTheme.orange, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            TextFormField(
              controller: _codexTerminalCommandController,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                labelText: 'Codex 终端启动命令',
                hintText: '例如：codex 或 /完整路径/codex',
                prefixIcon: Icon(Icons.terminal),
              ),
              validator: (value) {
                if (value != null &&
                    (value.contains('\n') || value.contains('\r'))) {
                  return '请输入单行启动命令';
                }
                return null;
              },
            ),
            const SizedBox(height: 6),
            Text(
              '仅用于 Codex 终端；恢复或 Fork 会自动追加参数。留空使用原有默认命令。',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),

            if (_showClaudeEnvConfig) ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _claudeEnvController,
                style: const TextStyle(fontFamily: 'monospace'),
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'Claude 环境变量（仅 macOS）',
                  hintText: '每行一个 KEY=VALUE\\n例如:\\nHTTP_PROXY=http://127.0.0.1:7890\\nANTHROPIC_BASE_URL=https://xxx',
                  prefixIcon: Icon(Icons.tune),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '创建 Claude 会话时会先 export 这些变量，再执行 claude。',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
              ),
            ],

            const SizedBox(height: 24),

            // 保存按钮
            Container(
              height: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  colors: [AppTheme.cyan, Color(0xFF2196F3)],
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _saveConnection,
                  borderRadius: BorderRadius.circular(10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.save, color: Colors.white, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        isEditing ? '保存修改' : '创建连接',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveConnection() async {
    if (!_formKey.currentState!.validate()) return;

    if (_usePrivateKey) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('SSH密钥认证功能即将推出，请暂时使用密码认证'),
          backgroundColor: AppTheme.orange,
        ),
      );
      return;
    }

    final name = _nameController.text.trim();
    final host = _hostController.text.trim();
    final port = int.parse(_portController.text.trim());
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    final claudeEnvText = _claudeEnvController.text;

    try {
      late final String connectionId;
      if (widget.connection != null) {
        final updated = widget.connection!.copyWith(
          name: name,
          host: host,
          port: port,
          username: username,
          password: password,
          useTmux: true,
        );
        await StorageService.updateConnection(updated);
        connectionId = updated.id;
      } else {
        final connection = SshConnection.create(
          name: name,
          host: host,
          port: port,
          username: username,
          password: password,
          useTmux: true,
        );
        await StorageService.saveConnection(connection);
        connectionId = connection.id;
      }

      await StorageService.setCodexTerminalCommand(
        connectionId, _codexTerminalCommandController.text,
      );
      if (_showClaudeEnvConfig) {
        await StorageService.setClaudeEnvText(connectionId, claudeEnvText);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(widget.connection != null ? '连接已更新' : '连接已创建')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败: $e'),
          backgroundColor: AppTheme.red,
        ),
      );
    }
  }
}
