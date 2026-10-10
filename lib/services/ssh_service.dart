import 'p2p_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dartssh2/dartssh2.dart';
import '../models/ssh_connection.dart';
import '../models/command_record.dart';
import 'storage_service.dart';

/// 去除ANSI转义序列（终端颜色、光标控制等）
final RegExp _ansiEscapeRegex = RegExp(
  r'\x1B'          // ESC字符
  r'(?:'
    r'\[[0-9;]*[A-Za-z]'   // CSI序列: ESC[...m (颜色)、ESC[...H (光标) 等
    r'|'
    r'\].*?\x07'           // OSC序列: ESC]...BEL (窗口标题等)
    r'|'
    r'\].*?\x1B\\'         // OSC序列: ESC]...ESC\ (另一种终止符)
    r'|'
    r'[()][AB012]'         // 字符集切换: ESC(B 等
    r'|'
    r'[>=]'                // 键盘模式: ESC> ESC=
  r')',
);

String stripAnsiEscapes(String text) {
  return text.replaceAll(_ansiEscapeRegex, '');
}

/// UTF-8流式解码器，处理跨数据包的不完整多字节字符
class Utf8StreamDecoder {
  final List<int> _pendingBytes = [];

  String decode(Uint8List data) {
    // 将待处理的字节和新数据合并
    if (_pendingBytes.isNotEmpty) {
      _pendingBytes.addAll(data);
      data = Uint8List.fromList(_pendingBytes);
      _pendingBytes.clear();
    }

    // 从末尾检查是否有不完整的UTF-8多字节序列
    int truncateAt = data.length;
    if (data.isNotEmpty) {
      // 从最后往前找，最多检查3个字节（UTF-8最长4字节）
      for (int i = 1; i <= 3 && i <= data.length; i++) {
        final byte = data[data.length - i];
        if ((byte & 0xC0) == 0xC0) {
          // 这是一个多字节序列的起始字节
          int expectedLen;
          if ((byte & 0xE0) == 0xC0) expectedLen = 2;
          else if ((byte & 0xF0) == 0xE0) expectedLen = 3;
          else if ((byte & 0xF8) == 0xF0) expectedLen = 4;
          else break; // 无效字节，不处理

          // 检查从该起始字节到末尾是否有足够的字节
          final available = i;
          if (available < expectedLen) {
            // 不完整，截断并保留到下次
            truncateAt = data.length - i;
            _pendingBytes.addAll(data.sublist(truncateAt));
          }
          break;
        } else if ((byte & 0x80) == 0) {
          // ASCII字节，序列完整
          break;
        }
        // 否则是 continuation byte (10xxxxxx)，继续往前找
      }
    }

    if (truncateAt == 0) return '';
    final decoded = utf8.decode(data.sublist(0, truncateAt), allowMalformed: true);
    // 去除ANSI转义序列
    return stripAnsiEscapes(decoded);
  }
}

class TerminalSession {
  final String connectionId;
  SSHClient? client;
  SSHSession? shell;
  final List<CommandRecord> history = [];
  bool isConnected = false;
  final StreamController<String> outputController = StreamController<String>.broadcast();
  // 原始字节流，供xterm终端模拟器使用（不做任何解码/过滤）
  final StreamController<Uint8List> rawOutputController = StreamController<Uint8List>.broadcast();
  StreamSubscription? _stdoutSubscription;
  StreamSubscription? _stderrSubscription;
  final Utf8StreamDecoder _stdoutDecoder = Utf8StreamDecoder();
  final Utf8StreamDecoder _stderrDecoder = Utf8StreamDecoder();

  // 输出缓冲：在终端页面未打开时缓存输出，重新打开时回放
  final List<Uint8List> outputBuffer = [];
  int _bufferBytes = 0;
  static const int _maxBufferBytes = 256 * 1024; // 256KB

  // tmux 会话元信息（创建时记录）
  String? tmuxName;
  String? workDir;

  TerminalSession(this.connectionId);

  Stream<String> get outputStream => outputController.stream;
  Stream<Uint8List> get rawOutputStream => rawOutputController.stream;

  void addToBuffer(Uint8List data) {
    outputBuffer.add(data);
    _bufferBytes += data.length;
    _trimBuffer();
  }

  void _trimBuffer() {
    while (_bufferBytes > _maxBufferBytes && outputBuffer.isNotEmpty) {
      _bufferBytes -= outputBuffer.removeAt(0).length;
    }
  }

  void dispose() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    outputController.close();
    rawOutputController.close();
    shell?.close();
  }
}

class SshService {
  static String connectionErrorMessage(Object error) {
    if (error is SSHAuthFailError) {
      return '认证失败：用户名或密码错误，请检查后重试';
    }
    if (error is TimeoutException) {
      return '连接超时：请检查电脑是否在线以及网络是否可达';
    }
    if (error is SocketException) {
      return '网络连接失败：请检查电脑地址、端口和网络连接';
    }
    if (error is SSHAuthAbortError) {
      return '认证中断：连接被关闭或超时，请重试';
    }
    final message = error.toString().replaceFirst(RegExp(r'^Exception: '), '');
    return message;
  }

  static final Map<String, TerminalSession> _activeSessions = {};
  static final Map<String, Future<TerminalSession>> _clientConnections = {};

  @visibleForTesting
  static Future<TerminalSession> Function(SshConnection)? connectClientOverride;

  /// 活跃连接ID集合，供首页监听状态变化
  static final ValueNotifier<Set<String>> activeSessionsNotifier =
      ValueNotifier<Set<String>>({});

  static void _notifyActiveSessionsChanged() {
    activeSessionsNotifier.value = _activeSessions.keys
        .where((id) => _activeSessions[id]?.isConnected == true)
        .toSet();
  }

  /// 仅建立 SSH 认证连接（不开 shell），用于管理操作（同步状态、执行一次性命令等）
  /// 返回的 TerminalSession 没有 shell，只能通过 client.run() 执行命令
  static Future<TerminalSession> connectClient(SshConnection config) {
    final id = config.id;
    final active = _activeSessions[id];
    if (active != null &&
        active.isConnected &&
        active.client?.isClosed == false) {
      return Future.value(active);
    }
    final existing = _clientConnections[id];
    if (existing != null) return existing;
    late final Future<TerminalSession> request;
    request = _connectClientImpl(config).whenComplete(() {
      if (identical(_clientConnections[id], request)) {
        _clientConnections.remove(id);
      }
    });
    _clientConnections[id] = request;
    return request;
  }

  static Future<TerminalSession> _connectClientImpl(SshConnection config) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _connectClientAttempt(config);
      } on SSHAuthAbortError {
        if (attempt >= 2) {
          throw Exception('认证中断: 连接被服务器关闭');
        }
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
  }

  static Future<TerminalSession> _connectClientAttempt(SshConnection config) async {
    final override = connectClientOverride;
    if (override != null) return override(config);
    final id = config.id;
    // 如果已有活跃连接，直接返回
    if (_activeSessions.containsKey(id) &&
        _activeSessions[id]!.isConnected &&
        _activeSessions[id]!.client?.isClosed == false) {
      return _activeSessions[id]!;
    }

    // 如果有残留的断开会话，清理掉
    if (_activeSessions.containsKey(id)) {
      await disconnect(id);
    }

    SSHClient? client;
    try {
      final session = TerminalSession(id);

      final endpoint = await P2pService.resolve(config);
      client = endpoint.authenticatedClient ?? SSHClient(
        await SSHSocket.connect(endpoint.host, endpoint.port,
            timeout: const Duration(seconds: 30)),
        username: config.username,
        onPasswordRequest: () => config.password ?? '',
      );

      P2pService.reportProgress(id, endpoint.route == 'P2P'
          ? 'P2P 通道已建立，正在验证 SSH 会话…'
          : '正在验证 SSH 会话…');
      // 等待认证完成
      await client.authenticated.timeout(const Duration(seconds: 30));

      session.client = client;
      session.isConnected = true;
      _activeSessions[id] = session;
      _notifyActiveSessionsChanged();
      return session;
    } on SocketException {
      throw Exception('网络连接失败: 无法连接到 ${config.host}:${config.port}');
    } on TimeoutException {
      throw Exception('连接超时: 请检查网络或服务器是否可达');
    } on SSHAuthFailError {
      throw Exception('认证失败：用户名或密码错误，请检查后重试');
    } on SSHAuthAbortError {
      rethrow;
    } catch (e) {
      throw Exception('连接失败: $e');
    } finally {
      if (!identical(_activeSessions[id]?.client, client)) client?.close();
    }
  }

  // 连接到SSH服务器，sessionId 可自定义（用于同一连接的多个 tmux 会话）
  static Future<TerminalSession> connect(SshConnection config, {String? sessionId}) async {
    final id = sessionId ?? config.id;
    try {
      // 如果已有活跃连接，直接返回
      if (_activeSessions.containsKey(id) &&
          _activeSessions[id]!.isConnected &&
          _activeSessions[id]!.client?.isClosed == false) {
        return _activeSessions[id]!;
      }

      // 如果有残留的断开会话，清理掉
      if (_activeSessions.containsKey(id)) {
        await disconnect(id);
      }

      // 创建会话
      final session = TerminalSession(id);

      // 建立SSH连接（30秒超时）
      final endpoint = await P2pService.resolve(config);
      final client = endpoint.authenticatedClient ?? SSHClient(
        await SSHSocket.connect(endpoint.host, endpoint.port,
            timeout: const Duration(seconds: 30)),
        username: config.username,
        onPasswordRequest: () => config.password ?? '',
        // TODO: 添加私钥认证支持
        // identities: config.usePrivateKey ? [...] : null,
      );

      session.client = client;

      // 创建交互式shell会话
      final shell = await client.shell(
        pty: SSHPtyConfig(
          width: 80,
          height: 24,
        ),
      );

      session.shell = shell;
      session.isConnected = true;
      _activeSessions[id] = session;

      // 监听stdout输出
      session._stdoutSubscription = shell.stdout.listen(
        (data) {
          // 缓存原始输出，供重新打开终端时回放
          session.addToBuffer(data);
          // 原始字节推送给xterm终端模拟器
          session.rawOutputController.add(data);
          // 解码后的文本推送给旧的outputController（兼容）
          final text = session._stdoutDecoder.decode(data);
          if (text.isNotEmpty) {
            session.outputController.add(text);
          }
        },
        onError: (error) {
          session.outputController.add('\n[错误]: $error\n');
        },
        onDone: () {
          session.isConnected = false;
          session.outputController.add('\n[连接已断开]\n');
          _notifyActiveSessionsChanged();
        },
      );

      // 监听stderr输出
      session._stderrSubscription = shell.stderr.listen(
        (data) {
          // 缓存原始输出
          session.addToBuffer(data);
          // 原始字节推送给xterm终端模拟器
          session.rawOutputController.add(data);
          // 解码后的文本推送给旧的outputController（兼容）
          final text = session._stderrDecoder.decode(data);
          if (text.isNotEmpty) {
            session.outputController.add(text);
          }
        },
        onError: (error) {
          session.outputController.add('\n[错误]: $error\n');
        },
      );

      // 发送欢迎消息
      session.outputController.add('成功连接到 ${config.connectionString}\n');
      session.outputController.add('交互式终端已启动，输入命令并回车执行\n\n');

      _notifyActiveSessionsChanged();
      return session;
    } on SocketException {
      throw Exception('网络连接失败: 无法连接到 ${config.host}:${config.port}');
    } on TimeoutException {
      throw Exception('连接超时: 请检查网络或服务器是否可达');
    } on SSHAuthFailError {
      throw Exception('认证失败: 用户名或密码错误');
    } on SSHAuthAbortError {
      throw Exception('认证中断: 连接被服务器关闭');
    } catch (e) {
      throw Exception('连接失败: $e');
    }
  }

  // 断开连接
  static Future<void> disconnect(String connectionId) async {
    final session = _activeSessions[connectionId];
    if (session != null) {
      session.client?.close();
      session.isConnected = false;
      session.dispose();
      _activeSessions.remove(connectionId);
      final baseId = connectionId.split(':').first;
      if (!_activeSessions.keys.any((id) => id == baseId || id.startsWith('$baseId:'))) {
        await P2pService.stop(baseId);
      }
      _notifyActiveSessionsChanged();
    }
  }

  // 发送命令到交互式shell
  static Future<void> sendCommand(String connectionId, String command) async {
    final session = _activeSessions[connectionId];
    if (session == null || !session.isConnected) {
      throw Exception('会话未连接');
    }

    if (session.shell == null) {
      throw Exception('Shell会话未初始化');
    }

    try {
      // 向shell的stdin写入命令（加上换行符）
      session.shell!.stdin.add(utf8.encode('$command\n'));

      // 保存命令到历史记录（仅保存命令，输出会实时显示）
      final record = CommandRecord.create(
        connectionId: connectionId,
        command: command,
        output: '', // 交互式模式下不保存输出，因为是实时流式的
        exitCode: 0,
      );

      session.history.add(record);
      await StorageService.saveCommandRecord(record);
    } catch (e) {
      session.outputController.add('\n[错误]: 发送命令失败: $e\n');
      throw Exception('发送命令失败: $e');
    }
  }

  // 发送原始输入（用于特殊控制字符）
  static void sendInput(String connectionId, String input) {
    final session = _activeSessions[connectionId];
    if (session?.shell != null) {
      session!.shell!.stdin.add(utf8.encode(input));
    }
  }

  // 发送Ctrl+C中断信号
  static void sendInterrupt(String connectionId) {
    sendInput(connectionId, '\x03'); // Ctrl+C
  }

  // 调整终端大小，并在 tmux 会话中强制完整重绘
  static void resizePty(String connectionId, int width, int height) {
    final session = _activeSessions[connectionId];
    if (session?.shell != null) {
      session!.shell!.resizeTerminal(width, height);

      // 如果是 tmux 会话，通过独立 exec 通道强制 refresh，避免 reflow 乱码
      if (session.tmuxName != null && session.client != null) {
        session.client!
            .run('tmux refresh-client -t ${session.tmuxName} 2>/dev/null')
            .catchError((_) => Uint8List(0));
      }
    }
  }

  /// 强制 tmux 重绘：先 resize 到不同尺寸再 resize 回来，确保 SIGWINCH 触发
  /// 用于重连/切换 tab 时让 tmux 重新发送完整屏幕内容
  static void forceRedraw(String connectionId, int width, int height) {
    final session = _activeSessions[connectionId];
    if (session?.shell == null) return;

    // 先缩小 1 列触发一次 SIGWINCH
    session!.shell!.resizeTerminal(width - 1, height);

    // 50ms 后恢复真实尺寸，再次触发 SIGWINCH，tmux 按正确尺寸完整重绘
    Future.delayed(const Duration(milliseconds: 50), () {
      session.shell?.resizeTerminal(width, height);
      // 额外 refresh 确保完整重绘
      if (session.tmuxName != null && session.client != null) {
        session.client!
            .run('tmux refresh-client -t ${session.tmuxName} 2>/dev/null')
            .catchError((_) => Uint8List(0));
      }
    });
  }

  // 发送Ctrl+D结束信号
  static void sendEOF(String connectionId) {
    sendInput(connectionId, '\x04'); // Ctrl+D
  }

  // 获取会话
  static TerminalSession? getSession(String connectionId) {
    return _activeSessions[connectionId];
  }

  /// 获取任意属于该连接的已连接 SSHClient（用于执行一次性命令）
  static SSHClient? getClient(String connectionId) {
    // 先看主连接
    final main = _activeSessions[connectionId];
    if (main != null &&
        main.isConnected &&
        main.client != null &&
        !main.client!.isClosed) {
      return main.client!;
    }
    // 再看子会话
    for (final entry in _activeSessions.entries) {
      if (entry.key.startsWith('$connectionId:') &&
          entry.value.isConnected &&
          entry.value.client != null &&
          !entry.value.client!.isClosed) {
        return entry.value.client!;
      }
    }
    return null;
  }

  /// 通过现有 SSH 连接的 keepalive 请求测量往返延迟，不创建新连接。
  static Future<int?> measureLatency(String connectionId) async {
    final client = getClient(connectionId);
    if (client == null) return null;
    final stopwatch = Stopwatch()..start();
    try {
      await client.ping().timeout(const Duration(seconds: 5));
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  // 检查连接状态
  static bool isConnected(String connectionId) {
    final session = _activeSessions[connectionId];
    return session != null && session.isConnected;
  }

  // 获取所有活跃会话
  static List<String> getActiveSessions() {
    return _activeSessions.keys.toList();
  }

  // 断开所有连接
  static Future<void> disconnectAll() async {
    final connectionIds = _activeSessions.keys.toList();
    for (final id in connectionIds) {
      await disconnect(id);
    }
  }

  // 获取会话历史
  static List<CommandRecord> getSessionHistory(String connectionId) {
    final session = _activeSessions[connectionId];
    return session?.history ?? [];
  }

  /// 获取指定连接的所有活跃 tmux 会话
  /// 返回 [{sessionId, tmuxName, workDir}]
  static List<TerminalSession> getTmuxSessions(String connectionId) {
    return _activeSessions.entries
        .where((e) =>
            e.key.startsWith('$connectionId:') &&
            e.value.isConnected &&
            e.value.tmuxName != null)
        .map((e) => e.value)
        .toList();
  }

  /// 通过任意已连接的会话执行一次性命令，获取 tmux 各会话的当前工作目录
  /// 返回 {tmuxName: currentPath}
  static Future<Map<String, String>> queryTmuxWorkDirs(String connectionId) async {
    // 找一个属于该连接的已连接会话，借用其 client 执行命令
    final session = _activeSessions.entries
        .where((e) =>
            (e.key == connectionId || e.key.startsWith('$connectionId:')) &&
            e.value.isConnected &&
            e.value.client != null)
        .map((e) => e.value)
        .firstOrNull;
    if (session == null) return {};

    try {
      final result = await session.client!.run(
        "tmux list-sessions -F '#{session_name}' 2>/dev/null | while read s; do "
        "echo \"\$s:\$(tmux display-message -p -t \"\$s\" '#{pane_current_path}' 2>/dev/null)\"; "
        "done",
      );
      final output = utf8.decode(result, allowMalformed: true);
      final Map<String, String> dirs = {};
      for (final line in output.trim().split('\n')) {
        final idx = line.indexOf(':');
        if (idx > 0 && idx < line.length - 1) {
          final name = line.substring(0, idx).trim();
          final path = line.substring(idx + 1).trim();
          if (name.isNotEmpty && path.isNotEmpty) {
            dirs[name] = path;
          }
        }
      }
      return dirs;
    } catch (_) {
      return {};
    }
  }
}
