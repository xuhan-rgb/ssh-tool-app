import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/ssh_connection.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

class CodexSetupStatus {
  final String system, codexPath, version, detail, authPath;
  final bool pythonAvailable, tmuxAvailable, loggedIn, compatible, prepared;
  final bool shortcutAvailable;

  const CodexSetupStatus(
      {required this.system,
      required this.codexPath,
      required this.version,
      required this.detail,
      required this.pythonAvailable,
      required this.tmuxAvailable,
      required this.loggedIn,
      required this.compatible,
      required this.prepared,
      this.authPath = '',
      this.shortcutAvailable = false});

  bool get ready => canPrepare && prepared;
  bool get canPrepare =>
      system == 'Linux' &&
      codexPath.isNotEmpty &&
      pythonAvailable &&
      tmuxAvailable &&
      loggedIn &&
      compatible;
  List<String> get missingDependencies =>
      [if (!pythonAvailable) 'python3', if (!tmuxAvailable) 'tmux'];

  factory CodexSetupStatus.parse(String output) {
    final fields = <String, String>{};
    for (final line in const LineSplitter().convert(output)) {
      final separator = line.indexOf('\t');
      if (separator < 0) continue;
      fields[line.substring(0, separator)] =
          utf8.decode(base64Decode(line.substring(separator + 1)));
    }
    if (!fields.containsKey('system') || !fields.containsKey('prepared')) {
      throw StateError('环境检测未返回完整结果');
    }
    return CodexSetupStatus(
        system: fields['system']!,
        codexPath: fields['codexPath'] ?? '',
        version: fields['version'] ?? '',
        detail: fields['detail'] ?? '',
        authPath: fields['authPath'] ?? '',
        pythonAvailable: fields['python'] == 'true',
        tmuxAvailable: fields['tmux'] == 'true',
        loggedIn: fields['loggedIn'] == 'true',
        compatible: fields['compatible'] == 'true',
        prepared: fields['prepared'] == 'true',
        shortcutAvailable: fields['shortcut'] == 'true');
  }
}

class CodexSetupService {
  @visibleForTesting
  static Future<String> Function(SshConnection, String)? runOverride;

  static String _quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
  static String _interactive(String command) =>
      'bash --noprofile --norc -ic ${_quote('if [ -r "\$HOME/.bashrc" ]; then . "\$HOME/.bashrc" >/dev/null; fi; $command')}';

  static Future<String> _run(SshConnection connection, String command) async {
    if (runOverride != null) return runOverride!(connection, command);
    final client = (await SshService.connectClient(connection)).client;
    if (client == null) throw StateError('SSH 连接已断开');
    final session = await client.execute(command);
    try {
      final values = await Future.wait([
        utf8.decoder.bind(session.stdout.cast<List<int>>()).join(),
        utf8.decoder.bind(session.stderr.cast<List<int>>()).join(),
      ]).timeout(const Duration(seconds: 90));
      if (session.exitCode != 0) {
        throw StateError(
            values[1].trim().isEmpty ? values[0].trim() : values[1].trim());
      }
      return values[0];
    } finally {
      session.close();
    }
  }

  static Future<CodexSetupStatus> inspect(SshConnection connection) async {
    final script = await rootBundle.loadString('assets/codex_environment.sh');
    return CodexSetupStatus.parse(
        await _run(connection, _interactive(script)));
  }

  static Future<CodexSetupStatus> prepare(SshConnection connection) async {
    final before = await inspect(connection);
    if (!before.canPrepare) throw StateError(before.detail);
    final commands = await _deploymentCommands();
    commands.add(
        'python3 "\$HOME/.ssh_tool/codex_runtime.py" prepare ${_quote(before.codexPath)}');
    final result = jsonDecode(await _run(
        connection, _interactive(commands.join(' && ')))) as Map;
    if (result['ok'] != true) throw StateError(result['error'] ?? '共享服务准备失败');
    final after = await inspect(connection);
    if (!after.ready) throw StateError('服务验证未通过：${after.detail}');
    final configured = StorageService.getCodexTerminalCommand(connection.id);
    if (configured == StorageService.defaultCodexTerminalCommand ||
        configured ==
            'codex --dangerously-bypass-approvals-and-sandbox -p yolo') {
      await StorageService.setCodexTerminalCommand(connection.id,
          'python3 "\$HOME/.ssh_tool/codex_runtime.py" terminal');
    }
    return after;
  }

  static Future<List<String>> _deploymentCommands() async {
    final commands = <String>['umask 077', 'mkdir -p "\$HOME/.ssh_tool"'];
    for (final name in [
      'codex_runtime.py',
      'codex_steer_message.py',
      'codex_chat_worker.py'
    ]) {
      final source = await rootBundle.loadString('assets/$name');
      final encoded = base64Encode(utf8.encode(source));
      // A unique staging path prevents concurrent prepares from truncating modules.
      commands.add('stage=\$(mktemp "\$HOME/.ssh_tool/$name.XXXXXX") && '
          'printf %s ${_quote(encoded)} | base64 -d > "\$stage" && '
          'chmod 600 "\$stage" && mv "\$stage" "\$HOME/.ssh_tool/$name"');
    }
    return commands;
  }

  static Future<void> configureTerminalShortcut(SshConnection connection) async {
    final status = await inspect(connection);
    if (!status.ready) throw StateError('请先完成环境准备');
    final result = jsonDecode(await _run(connection,
        _interactive('python3 "\$HOME/.ssh_tool/codex_runtime.py" shortcut'))) as Map;
    if (result['ok'] != true) throw StateError(result['error'] ?? '电脑命令配置失败');
  }

  static Future<String> installationCommand(SshConnection connection) async {
    final status = await inspect(connection);
    if (status.system != 'Linux') throw StateError('首版自动安装仅支持 Linux');
    if (status.missingDependencies.isEmpty) throw StateError('没有缺失的依赖');
    final manager = (await _run(
            connection,
            'for pm in apt-get dnf yum pacman zypper apk; do '
            'if command -v "\$pm" >/dev/null 2>&1; then printf %s "\$pm"; exit 0; fi; done; '
            'printf %s "未找到支持的包管理器" >&2; exit 1'))
        .trim();
    final packages = status.missingDependencies.join(' ');
    final install = switch (manager) {
      'apt-get' => 'apt-get update && apt-get install -y $packages',
      'dnf' => 'dnf install -y $packages',
      'yum' => 'yum install -y $packages',
      'pacman' => 'pacman -S --needed --noconfirm $packages',
      'zypper' => 'zypper --non-interactive install $packages',
      'apk' => 'apk add $packages',
      _ => throw StateError('不支持的包管理器：$manager'),
    };
    return 'if [ "\$(id -u)" -eq 0 ]; then sh -c ${_quote(install)}; '
        'else sudo sh -c ${_quote(install)}; fi';
  }

  static Future<String> loginCommand(SshConnection connection) async {
    final status = await inspect(connection);
    if (status.codexPath.isEmpty) throw StateError('未找到 Codex');
    final directory =
        status.codexPath.substring(0, status.codexPath.lastIndexOf('/'));
    final command = status.authPath.isEmpty
        ? '${_quote(status.codexPath)} login --device-auth'
        : 'CODEX_AUTH_CODEX_BIN=${_quote(status.codexPath)} '
            '${_quote(status.authPath)} run -- login --device-auth';
    return _interactive('PATH=${_quote(directory)}:"\$PATH" $command');
  }

  /// Streams only the user-requested login process; cancellation leaves shared
  /// SSH connections and Codex conversations running.
  static Stream<String> login(SshConnection connection) {
    late StreamController<String> controller;
    StreamSubscription<String>? output;
    SSHSession? session;
    var cancelled = false;
    controller = StreamController<String>(
      onListen: () async {
        try {
          final command = await loginCommand(connection);
          if (cancelled) return;
          final client = (await SshService.connectClient(connection)).client;
          if (client == null) throw StateError('SSH 连接已断开');
          if (cancelled) return;
          session = await client.execute(
              'exec env NO_COLOR=1 TERM=dumb $command');
          if (cancelled) {
            session!.kill(SSHSignal.TERM);
            session!.close();
            return;
          }
          output = loginOutput(
            stdout: session!.stdout.cast<List<int>>(),
            stderr: session!.stderr.cast<List<int>>(),
            exit: session!.done.then((_) => session!.exitCode),
            close: () {
              if (session!.exitCode == null) session!.kill(SSHSignal.TERM);
              session!.close();
            },
          ).listen(controller.add, onError: controller.addError,
              onDone: controller.close);
        } catch (e, stack) {
          if (!cancelled) {
            controller.addError(e, stack);
            await controller.close();
          }
        }
      },
      onCancel: () async {
        cancelled = true;
        await output?.cancel();
      },
    );
    return controller.stream;
  }

  @visibleForTesting
  static Stream<String> loginOutput({
    required Stream<List<int>> stdout,
    required Stream<List<int>> stderr,
    required Future<int?> exit,
    required void Function() close,
    Duration timeout = const Duration(minutes: 15),
  }) {
    late StreamController<String> controller;
    final subscriptions = <StreamSubscription<String>>[];
    final drained = <Future<void>>[];
    Timer? timer;
    var stopped = false;
    var details = '';
    Future<void> cleanup() async {
      if (stopped) return;
      stopped = true;
      timer?.cancel();
      close();
      await Future.wait(subscriptions.map((s) => s.cancel()));
    }
    void fail(Object error, [StackTrace? stack]) {
      if (stopped || controller.isClosed) return;
      controller.addError(error, stack);
      unawaited(cleanup());
      unawaited(controller.close());
    }
    controller = StreamController<String>(
      onListen: () {
        for (final source in [stdout, stderr]) {
          final done = Completer<void>();
          drained.add(done.future);
          subscriptions.add(utf8.decoder.bind(source).listen((chunk) {
            if (stopped) return;
            details += chunk;
            if (details.length > 12000) {
              details = details.substring(details.length - 12000);
            }
            controller.add(chunk);
          }, onError: fail, onDone: done.complete));
        }
        timer = Timer(timeout, () => fail(TimeoutException(
            '登录等待超时，请重试；远程电脑需要能够访问官方登录服务。')));
        () async {
          try {
            final code = await exit;
            await Future.wait(drained);
            if (stopped) return;
            if (code != 0) {
              fail(StateError(details.trim().isEmpty
                  ? '登录命令退出，状态码：$code'
                  : details.trim()));
              return;
            }
            await cleanup();
            await controller.close();
          } catch (e, stack) {
            fail(e, stack);
          }
        }();
      },
      onCancel: cleanup,
    );
    return controller.stream;
  }

  static Future<String> updateCommand(SshConnection connection) async {
    final status = await inspect(connection);
    if (status.codexPath.isEmpty) throw StateError('未找到 Codex');
    final directory =
        status.codexPath.substring(0, status.codexPath.lastIndexOf('/'));
    return 'PATH=${_quote(directory)}:"\$PATH"; export PATH; '
        'if command -v npm >/dev/null 2>&1; then npm install -g @openai/codex@latest; '
        'else printf "%s\\n" "未找到 npm，请按官方 Codex 安装方式更新后重新检测。"; exit 1; fi';
  }
}
