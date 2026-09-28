import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

Future<ProcessResult> runPythonScript(
  String script,
  List<String> args, {
  required Map<String, String> environment,
}) async {
  final process = await Process.start(
    '/usr/bin/python3',
    ['-', ...args],
    runInShell: false,
    environment: environment,
    includeParentEnvironment: false,
  );
  process.stdin.write(script);
  await process.stdin.close();
  final stdout = await process.stdout.transform(utf8.decoder).join();
  final stderr = await process.stderr.transform(utf8.decoder).join();
  return ProcessResult(process.pid, await process.exitCode, stdout, stderr);
}

void main() {
  test('queues the exact thread and message through the remote script',
      () async {
    const conversationId = 'thread-123';
    const message = '中文 “引号”\nsecond line\nquote \' and "';
    String? capturedScript;
    List<String>? capturedArgs;
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      capturedScript = script;
      capturedArgs = args;
      return '';
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    await CodexSessionService.queueMessage(
        'connection', conversationId, message);

    expect(capturedArgs, [conversationId, message]);
    expect(capturedScript, contains('subprocess.run'));
    expect(capturedScript, isNot(contains('shell=True')));

    final temp = await Directory.systemTemp.createTemp('codex-queue-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    final bin = Directory('${home.path}/.local/bin')
      ..createSync(recursive: true);
    final pathBin = Directory('${temp.path}/path-bin')..createSync();
    final oldCodex = File('${pathBin.path}/codex');
    await oldCodex.writeAsString(
      '#!/bin/sh\necho old-codex > "\$ARGV_PATH"\n',
    );
    await Process.run('chmod', ['+x', oldCodex.path]);
    final argvPath = '${temp.path}/argv';
    final codex = File('${bin.path}/codex');
    await codex.writeAsString(
      '#!/bin/sh\n'
      'if [ "\$1" = queue ] && [ "\$2" = --help ]; then\n'
      '  echo "Usage: codex queue --thread ID --message TEXT"\n'
      '  exit 0\n'
      'fi\n'
      'printf \'%s\\0\' "\$@" > "\$ARGV_PATH"\n',
    );
    await Process.run('chmod', ['+x', codex.path]);

    final result = await runPythonScript(
      capturedScript!,
      capturedArgs!,
      environment: {
        ...Platform.environment,
        'HOME': home.path,
        'PATH': pathBin.path,
        'ARGV_PATH': argvPath
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      File(argvPath).readAsBytesSync(),
      [
        ...['queue', '--thread', conversationId, '--message', message]
            .expand((arg) => [...utf8.encode(arg), 0]),
      ],
    );
  });

  test('skips unsupported local CLI and uses supported nvm CLI', () async {
    const conversationId = 'thread-compat';
    const message = 'hello from nvm';
    String? capturedScript;
    List<String>? capturedArgs;
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      capturedScript = script;
      capturedArgs = args;
      return '';
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    await CodexSessionService.queueMessage(
        'connection', conversationId, message);

    final temp = await Directory.systemTemp.createTemp('codex-queue-compat-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    final localBin = Directory('${home.path}/.local/bin')
      ..createSync(recursive: true);
    final nvmBin = Directory('${home.path}/.nvm/versions/node/v99/bin')
      ..createSync(recursive: true);
    final argvPath = '${temp.path}/nvm-argv';
    final localCodex = File('${localBin.path}/codex');
    await localCodex.writeAsString(
      '#!/bin/sh\n'
      'if [ "\$1" = queue ] && [ "\$2" = --help ]; then\n'
      '  echo "Codex CLI 0.136.0\nUsage: codex [options] [prompt]"\n'
      '  exit 0\n'
      'fi\n'
      'echo local-sent >> "\$ARGV_PATH"\n',
    );
    await Process.run('chmod', ['+x', localCodex.path]);
    final nvmCodex = File('${nvmBin.path}/codex');
    await nvmCodex.writeAsString(
      '#!/usr/bin/env node\n',
    );
    await Process.run('chmod', ['+x', nvmCodex.path]);
    final node = File('${nvmBin.path}/node');
    await node.writeAsString(
      '#!/bin/sh\n'
      'case "\$PATH" in ${nvmBin.path}:*) ;; *) echo "nvm bin is not first in PATH" >&2; exit 127;; esac\n'
      'shift\n'
      'if [ "\$1" = queue ] && [ "\$2" = --help ]; then\n'
      '  echo "Usage: codex queue --thread ID --message TEXT"\n'
      '  exit 0\n'
      'fi\n'
      'printf \'%s\\0\' "\$@" > "\$ARGV_PATH"\n',
    );
    await Process.run('chmod', ['+x', node.path]);

    final result = await runPythonScript(
      capturedScript!,
      capturedArgs!,
      environment: {
        ...Platform.environment,
        'HOME': home.path,
        'PATH': '/usr/bin:/bin',
        'ARGV_PATH': argvPath,
      },
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      File(argvPath).readAsBytesSync(),
      [
        ...['queue', '--thread', conversationId, '--message', message]
            .expand((arg) => [...utf8.encode(arg), 0]),
      ],
    );
  });

  test('does not send when no CLI supports queue options', () async {
    final temp =
        await Directory.systemTemp.createTemp('codex-queue-unsupported-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    final bin = Directory('${home.path}/.local/bin')
      ..createSync(recursive: true);
    final argvPath = '${temp.path}/argv';
    final codex = File('${bin.path}/codex');
    await codex.writeAsString(
      '#!/bin/sh\n'
      'echo "Codex CLI 0.136.0\nUsage: codex [options] [prompt]"\n'
      'exit 0\n',
    );
    await Process.run('chmod', ['+x', codex.path]);
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      final result = await runPythonScript(
        script,
        args,
        environment: {
          ...Platform.environment,
          'HOME': home.path,
          'PATH': temp.path,
          'ARGV_PATH': argvPath,
        },
      );
      if (result.exitCode != 0) throw StateError(result.stderr.trim());
      return result.stdout;
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    await expectLater(
      CodexSessionService.queueMessage('connection', 'thread', 'hello'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        allOf(contains('queue'), contains('不支持')),
      )),
    );
    expect(File(argvPath).existsSync(), isFalse);
  });

  test('does not retry a real send failure with another CLI', () async {
    final temp =
        await Directory.systemTemp.createTemp('codex-queue-send-failure-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    final localBin = Directory('${home.path}/.local/bin')
      ..createSync(recursive: true);
    final nvmBin = Directory('${home.path}/.nvm/versions/node/v99/bin')
      ..createSync(recursive: true);
    final nvmSendPath = '${temp.path}/nvm-sent';
    final supportedHelp =
        'echo "Usage: codex queue --thread ID --message TEXT"; exit 0';
    final localCodex = File('${localBin.path}/codex');
    await localCodex.writeAsString(
      '#!/bin/sh\n'
      'if [ "\$2" = --help ]; then $supportedHelp; fi\n'
      'echo "local send failed" >&2; exit 9\n',
    );
    await Process.run('chmod', ['+x', localCodex.path]);
    final nvmCodex = File('${nvmBin.path}/codex');
    await nvmCodex.writeAsString(
      '#!/usr/bin/env node\n',
    );
    await Process.run('chmod', ['+x', nvmCodex.path]);
    final node = File('${nvmBin.path}/node');
    await node.writeAsString(
      '#!/bin/sh\n'
      'case "\$PATH" in ${nvmBin.path}:*) ;; *) echo "nvm bin is not first in PATH" >&2; exit 127;; esac\n'
      'shift\n'
      'if [ "\$2" = --help ]; then $supportedHelp; fi\n'
      'echo sent >> "\$NVM_SEND_PATH"\n',
    );
    await Process.run('chmod', ['+x', node.path]);
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      final result = await runPythonScript(
        script,
        args,
        environment: {
          ...Platform.environment,
          'HOME': home.path,
          'PATH': '/usr/bin:/bin',
          'NVM_SEND_PATH': nvmSendPath,
        },
      );
      if (result.exitCode != 0) throw StateError(result.stderr.trim());
      return result.stdout;
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    await expectLater(
      CodexSessionService.queueMessage('connection', 'thread', 'hello'),
      throwsA(isA<StateError>().having(
        (e) => e.message,
        'message',
        contains('local send failed'),
      )),
    );
    expect(File(nvmSendPath).existsSync(), isFalse);
  });

  test('reports CLI failure and missing CLI', () async {
    final temp = await Directory.systemTemp.createTemp('codex-queue-errors-');
    addTearDown(() => temp.delete(recursive: true));
    final home = Directory('${temp.path}/home')..createSync();
    final bin = Directory('${home.path}/.local/bin')
      ..createSync(recursive: true);
    final codex = File('${bin.path}/codex');
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, script, args) async {
      final failed = await runPythonScript(
        script,
        args,
        environment: {
          ...Platform.environment,
          'HOME': home.path,
          'PATH': temp.path,
        },
      );
      if (failed.exitCode != 0) throw StateError('${failed.stderr}'.trim());
      return '${failed.stdout}';
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    await codex.writeAsString(
      '#!/bin/sh\n'
      'if [ "\$1" = queue ] && [ "\$2" = --help ]; then\n'
      '  echo "Usage: codex queue --thread ID --message TEXT"\n'
      '  exit 0\n'
      'fi\n'
      'echo "queue rejected" >&2\nexit 7\n',
    );
    await Process.run('chmod', ['+x', codex.path]);
    await expectLater(
      CodexSessionService.queueMessage('connection', 'thread', 'hello'),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('queue rejected'))),
    );

    await codex.delete();
    await expectLater(
      CodexSessionService.queueMessage('connection', 'thread', 'hello'),
      throwsA(isA<StateError>()
          .having((e) => e.message, 'message', contains('未找到 Codex CLI'))),
    );
  });

  test('rejects empty conversation IDs and messages without running remotely',
      () async {
    var called = false;
    final previous = CodexSessionService.runPythonOverride;
    CodexSessionService.runPythonOverride = (_, __, ___) async {
      called = true;
      return '';
    };
    addTearDown(() => CodexSessionService.runPythonOverride = previous);

    await expectLater(
        CodexSessionService.queueMessage('c', ' ', 'x'), throwsArgumentError);
    await expectLater(
        CodexSessionService.queueMessage('c', 'id', ''), throwsArgumentError);
    expect(called, isFalse);
  });
}
