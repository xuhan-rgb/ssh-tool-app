import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../models/ssh_connection.dart';
import '../services/codex_setup_service.dart';
import '../theme/app_theme.dart';
import 'terminal_screen.dart';

class CodexSetupScreen extends StatefulWidget {
  final SshConnection connection;
  final Future<CodexSetupStatus> Function(SshConnection)? inspect;
  final Future<CodexSetupStatus> Function(SshConnection)? prepare;
  final Future<String> Function(SshConnection)? installCommand;
  final Stream<String> Function(SshConnection)? login;
  final Future<String> Function(SshConnection)? updateCommand;

  const CodexSetupScreen({
    super.key,
    required this.connection,
    this.inspect,
    this.prepare,
    this.installCommand,
    this.login,
    this.updateCommand,
  });

  @override
  State<CodexSetupScreen> createState() => _CodexSetupScreenState();
}

class _CodexSetupScreenState extends State<CodexSetupScreen> {
  CodexSetupStatus? _status;
  bool _checking = true;
  bool _preparing = false;
  bool _commandInProgress = false;
  String? _error;
  StreamSubscription<String>? _loginSubscription;
  Completer<void>? _loginFinished;
  int _loginRun = 0;
  bool _loggingIn = false;
  bool _loginFailed = false;
  String _loginOutput = '';
  String? _authorizationUrl;
  String? _deviceCode;
  static const _browserChannel = MethodChannel('ssh_tool_app/browser');

  bool get _busy =>
      _checking ||
      _preparing ||
      _commandInProgress ||
      _loggingIn;

  Future<CodexSetupStatus> get _inspect =>
      (widget.inspect ?? CodexSetupService.inspect)(widget.connection);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _checking = true;
      _error = null;
      _loginFailed = false;
    });
    try {
      final result = await _inspect;
      if (mounted) {
        setState(() {
          _status = result;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _prepare() async {
    setState(() {
      _preparing = true;
      _error = null;
    });
    try {
      final result = await (widget.prepare ?? CodexSetupService.prepare)(
        widget.connection,
      );
      if (mounted) setState(() => _status = result);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  String _cleanAnsi(String value) => value.replaceAll(
        RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1B\\))'),
        '',
      );

  Future<void> _login() async {
    final run = ++_loginRun;
    final finished = Completer<void>();
    _loginFinished = finished;
    setState(() {
      _loggingIn = true;
      _loginFailed = false;
      _loginOutput = '';
      _authorizationUrl = null;
      _deviceCode = null;
      _error = null;
    });
    try {
      _loginSubscription =
          (widget.login ?? CodexSetupService.login)(widget.connection).listen(
        (chunk) {
          if (!mounted || run != _loginRun) return;
          setState(() {
            final combined = _loginOutput + chunk;
            _loginOutput = combined.length > 16000
                ? combined.substring(combined.length - 16000)
                : combined;
            final clean = _cleanAnsi(_loginOutput);
            _authorizationUrl = RegExp(
              r'https://auth\.openai\.com/[^\s\]\)<>]*',
            ).firstMatch(clean)?.group(0)?.replaceAll(RegExp(r'[.,;]+$'), '');
            _deviceCode ??= RegExp(
              r'\b[A-Z0-9]{4}-[A-Z0-9]{4}\b',
            ).firstMatch(clean)?.group(0);
          });
        },
        onError: (Object e) {
          if (run != _loginRun) return;
          _loginFailed = true;
          if (!finished.isCompleted) finished.completeError(e);
        },
        onDone: () {
          if (run != _loginRun) return;
          if (!finished.isCompleted && !_loginFailed) finished.complete();
        },
        cancelOnError: true,
      );
      await finished.future;
      if (!mounted || run != _loginRun) return;
      final status = await _inspect;
      if (!mounted || run != _loginRun) return;
      setState(() {
        _status = status;
        if (!status.loggedIn) {
          _loginFailed = true;
          _error = '登录命令已结束，但尚未检测到登录状态。请确认授权网页已完成登录。';
        }
      });
    } catch (e) {
      if (mounted && run == _loginRun) setState(() => _error = e.toString());
    } finally {
      if (mounted && run == _loginRun) {
        setState(() => _loggingIn = false);
        _loginSubscription = null;
        _loginFinished = null;
      }
    }
  }

  Future<void> _openAuthorizationUrl() async {
    final url = _authorizationUrl;
    if (url == null || !url.startsWith('https://')) return;
    try {
      await _browserChannel.invokeMethod<void>('openUrl', {'url': url});
    } catch (e) {
      if (mounted) setState(() => _error = '无法打开授权网页：$e');
    }
  }

  Future<void> _cancelLogin() async {
    // Cancellation ends only the login stream; it does not close the SSH connection.
    ++_loginRun;
    final subscription = _loginSubscription;
    _loginSubscription = null;
    final finished = _loginFinished;
    _loginFinished = null;
    if (finished != null && !finished.isCompleted) finished.complete();
    if (mounted) setState(() => _loggingIn = false);
    await subscription?.cancel();
  }

  @override
  void dispose() {
    ++_loginRun;
    final finished = _loginFinished;
    if (finished != null && !finished.isCompleted) finished.complete();
    _loginSubscription?.cancel();
    super.dispose();
  }

  Future<void> _runReviewedCommand(
    String title,
    Future<String> Function(SshConnection) command,
  ) async {
    setState(() => _commandInProgress = true);
    try {
      final value = await command(widget.connection);
      if (!mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SelectableText(value),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('在终端中打开'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
      final sessionId =
          '${widget.connection.id}:codex-setup-${DateTime.now().microsecondsSinceEpoch}';
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TerminalScreen(
            connection: widget.connection,
            initialCommand: value,
            terminalSessionId: sessionId,
          ),
        ),
      );
      if (mounted) await _refresh();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _commandInProgress = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      appBar: AppBar(title: const Text('Codex 环境设置')),
      body: _checking && status == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status?.ready == true ? '环境已就绪' : '准备 Linux Codex 环境',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          status?.detail ?? '默认使用 Codex 文本聊天。此页面不会自动安装、登录或更新。',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                        if (status != null)
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text('检测详情'),
                            children: [
                              _check(
                                'Linux 系统',
                                status.system.toLowerCase().contains('linux'),
                                status.system,
                              ),
                              _check(
                                'Codex CLI',
                                status.codexPath.isNotEmpty,
                                status.codexPath.isEmpty
                                    ? '未找到'
                                    : status.codexPath,
                              ),
                              _check(
                                'Codex 版本兼容',
                                status.compatible,
                                status.version,
                              ),
                              _check(
                                'Codex 已登录',
                                status.loggedIn,
                                status.loggedIn ? '已登录' : '未登录',
                              ),
                              _check(
                                'Python 3',
                                status.pythonAvailable,
                                status.pythonAvailable ? '可用' : '缺失',
                              ),
                              _check(
                                'tmux',
                                status.tmuxAvailable,
                                status.tmuxAvailable ? '可用' : '缺失',
                              ),
                              ListTile(
                                title: const Text('详情'),
                                subtitle: SelectableText(status.detail),
                              ),
                            ],
                          ),
                        if (_error != null && !_loginFailed)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              _error!,
                              style: TextStyle(color: AppTheme.red),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (status != null && !status.ready) ...[
                  if (status.missingDependencies.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: _busy
                          ? null
                          : () => _runReviewedCommand(
                                '安装缺失依赖',
                                widget.installCommand ??
                                    CodexSetupService.installationCommand,
                              ),
                      icon: const Icon(Icons.download),
                      label: const Text('安装缺失依赖'),
                    ),
                  if (!status.loggedIn && status.codexPath.isNotEmpty) ...[
                    FilledButton.tonalIcon(
                      onPressed: _busy ? null : _login,
                      icon: _loggingIn
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: Text(_loggingIn ? '等待 Codex 授权…' : '登录 Codex'),
                    ),
                    if (_loggingIn)
                      TextButton.icon(
                        onPressed: _cancelLogin,
                        icon: const Icon(Icons.close),
                        label: const Text('取消登录'),
                      ),
                    if (_authorizationUrl != null)
                      SelectableText('授权网址：\n$_authorizationUrl'),
                    if (_deviceCode != null)
                      Row(
                        children: [
                          Expanded(child: SelectableText('设备代码：$_deviceCode')),
                          IconButton(
                            tooltip: '复制设备代码',
                            onPressed: () => Clipboard.setData(
                              ClipboardData(text: _deviceCode!),
                            ),
                            icon: const Icon(Icons.copy),
                          ),
                        ],
                      ),
                    if (_authorizationUrl != null)
                      OutlinedButton.icon(
                        onPressed: _openAuthorizationUrl,
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('打开授权网页'),
                      ),
                    if (_loginOutput.isNotEmpty)
                      ExpansionTile(
                        title: const Text('登录输出'),
                        children: [Text(_cleanAnsi(_loginOutput))],
                      ),
                    if (_error != null && _loginFailed)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('登录失败。请检查远端电脑网络配置（包括代理）和可用地区。'),
                          ExpansionTile(
                            title: const Text('错误详情'),
                            children: [SelectableText(_error!)],
                          ),
                        ],
                      ),
                  ],
                  if (!status.compatible && status.codexPath.isNotEmpty)
                    FilledButton.tonalIcon(
                      onPressed: _busy
                          ? null
                          : () => _runReviewedCommand(
                                '更新 Codex',
                                widget.updateCommand ??
                                    CodexSetupService.updateCommand,
                              ),
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text('更新 Codex'),
                    ),
                  if (status.canPrepare)
                    FilledButton.icon(
                      onPressed: _busy ? null : _prepare,
                      icon: _preparing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.rocket_launch),
                      label: const Text('一键准备'),
                    ),
                ],
                if (status != null)
                  const ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('电脑端启动'),
                    children: [
                      ListTile(
                        title: Text('在项目目录启动'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText('cd /你的项目目录'),
                            SelectableText('codex'),
                          ],
                        ),
                      ),
                      ListTile(
                        title: Text('继续已有对话'),
                        subtitle: SelectableText('codex resume <对话 ID>'),
                      ),
                      ListTile(
                        subtitle: Text('手机选择同一个对话即可继续聊天。'),
                      ),
                    ],
                  ),
                if (status?.ready == true)
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('完成准备'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重新检测'),
                ),
              ],
            ),
    );
  }

  Widget _check(String title, bool passed, String detail) => ListTile(
        dense: true,
        leading: Icon(
          passed ? Icons.check_circle : Icons.cancel,
          color: passed ? AppTheme.green : AppTheme.orange,
        ),
        title: Text(title),
        subtitle: Text(detail),
      );
}
