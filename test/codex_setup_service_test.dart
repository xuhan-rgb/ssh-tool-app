import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/services/codex_setup_service.dart';
import 'package:ssh_tool_app/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final connection =
      SshConnection.create(name: 'test', host: 'localhost', username: 'user');
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('codex-setup-service');
    Hive.init(directory.path);
    await Hive.openBox('settings');
  });
  tearDown(() => CodexSetupService.runOverride = null);
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  String status(
          {bool prepared = false,
          bool python = true,
          bool tmux = true,
          bool loggedIn = true,
          bool compatible = true,
          bool shortcut = false}) =>
      <String, String>{
        'system': 'Linux',
        'codexPath': '/opt/node/bin/codex',
        'version': 'codex-test',
        'detail': 'check',
        'python': '$python',
        'tmux': '$tmux',
        'loggedIn': '$loggedIn',
        'compatible': '$compatible',
        'prepared': '$prepared',
        'shortcut': '$shortcut',
      }
          .entries
          .map((e) => '${e.key}\t${base64Encode(utf8.encode(e.value))}')
          .join('\n');

  test('login streams both channels before exit and decodes split UTF8', () async {
    final stdout = StreamController<List<int>>();
    final stderr = StreamController<List<int>>();
    final exit = Completer<int?>();
    var closed = 0;
    final chunks = <String>[];
    final done = Completer<void>();
    CodexSetupService.loginOutput(
      stdout: stdout.stream,
      stderr: stderr.stream,
      exit: exit.future,
      close: () => closed++,
    ).listen(chunks.add, onError: done.completeError, onDone: done.complete);
    final bytes = utf8.encode('授权');
    stdout.add(bytes.sublist(0, 2));
    stdout.add(bytes.sublist(2));
    stderr.add(utf8.encode('https://auth.openai.com/codex/device'));
    await Future<void>.delayed(Duration.zero);
    expect(chunks.join(), contains('授权'));
    expect(chunks.join(), contains('https://auth.openai.com/codex/device'));
    expect(done.isCompleted, isFalse);
    await stdout.close();
    await stderr.close();
    exit.complete(0);
    await done.future;
    expect(closed, 1);
  });

  test('login failure reports stderr and closes its process', () async {
    var closed = 0;
    await expectLater(
      CodexSetupService.loginOutput(
        stdout: const Stream.empty(),
        stderr: Stream.value(utf8.encode('error sending request')),
        exit: Future.value(1),
        close: () => closed++,
      ),
      emitsInOrder([
        'error sending request',
        emitsError(isA<StateError>().having(
            (e) => e.toString(), 'message', contains('error sending request'))),
        emitsDone,
      ]),
    );
    expect(closed, 1);
  });

  test('cancel login closes only the login process without waiting for exit', () async {
    final stdout = StreamController<List<int>>();
    final stderr = StreamController<List<int>>();
    var closed = 0;
    final subscription = CodexSetupService.loginOutput(
      stdout: stdout.stream,
      stderr: stderr.stream,
      exit: Completer<int?>().future,
      close: () => closed++,
    ).listen((_) {});
    await subscription.cancel();
    expect(closed, 1);
    await stdout.close();
    await stderr.close();
  });

  test('login timeout terminates the pending process and reports retry', () async {
    var closed = 0;
    await expectLater(
      CodexSetupService.loginOutput(
        stdout: const Stream.empty(),
        stderr: const Stream.empty(),
        exit: Completer<int?>().future,
        close: () => closed++,
        timeout: const Duration(milliseconds: 5),
      ),
      emitsError(isA<TimeoutException>()),
    );
    expect(closed, 1);
  });

  test('inspection and preparation run through interactive bash', () async {
    var checks = 0;
    CodexSetupService.runOverride = (_, command) async {
      expect(command, startsWith('bash --noprofile --norc -ic '));
      if (command.contains('codex_runtime.py') && command.contains(' prepare ')) {
        expect(command, contains('prepare'));
        expect(command, contains('/opt/node/bin/codex'));
        return '{"ok":true}';
      }
      return status(prepared: checks++ > 0);
    };
    await CodexSetupService.prepare(connection);
  });

  test('login command uses interactive bash and injects no proxy settings', () async {
    CodexSetupService.runOverride = (_, command) async => status();
    final command = await CodexSetupService.loginCommand(connection);
    expect(command, startsWith('bash --noprofile --norc -ic '));
    expect(command, contains('/opt/node/bin'));
    expect(command, contains('\$PATH'));
    expect(command, contains('/opt/node/bin/codex'));
    expect(command, contains('login --device-auth'));
    expect(command, isNot(contains('HTTP_PROXY')));
    expect(command, isNot(contains('HTTPS_PROXY')));
    expect(command, contains('.bashrc'));
    expect(command, contains('>/dev/null'));
  });

  test('status distinguishes dependency readiness from service preparation',
      () {
    expect(CodexSetupStatus.parse(status()).canPrepare, isTrue);
    expect(CodexSetupStatus.parse(status()).ready, isFalse);
    expect(CodexSetupStatus.parse(status(prepared: true)).ready, isTrue);
    expect(CodexSetupStatus.parse(status(prepared: true)).shortcutAvailable, isFalse);
    expect(
        CodexSetupStatus.parse(status(python: false, tmux: false))
            .missingDependencies,
        ['python3', 'tmux']);
    expect(CodexSetupStatus.parse(status(loggedIn: false)).canPrepare, isFalse);
    expect(() => CodexSetupStatus.parse('incomplete'), throwsStateError);
  });

  test(
      'prepare deploys owned scripts and uses verified status before saving command',
      () async {
    var checks = 0;
    CodexSetupService.runOverride = (_, command) async {
      if (command.startsWith('bash --noprofile --norc -ic') &&
          !command.contains(' prepare ')) {
        return status(prepared: checks++ > 0);
      }
      expect(command, contains('codex_runtime.py'));
      expect(command, contains('mktemp'));
      expect(command, contains('prepare'));
      expect(command, contains('/opt/node/bin/codex'));
      expect(command, isNot(contains('sudo')));
      return '{"ok":true}';
    };
    final ready = await CodexSetupService.prepare(connection);
    expect(ready.ready, isTrue);
    expect(StorageService.getCodexTerminalCommand(connection.id),
        'python3 "\$HOME/.ssh_tool/codex_runtime.py" terminal');
  });

  test('shortcut configuration is a separate explicit operation', () async {
    final commands = <String>[];
    CodexSetupService.runOverride = (_, command) async {
      commands.add(command);
      return commands.length == 3 ? '{"ok":true}' : status(prepared: true);
    };
    final ready = await CodexSetupService.inspect(connection);
    expect(ready.ready, isTrue);
    expect(ready.shortcutAvailable, isFalse);
    expect(commands.length, 1);
    await CodexSetupService.configureTerminalShortcut(connection);
    expect(commands.last, startsWith('bash --noprofile --norc -ic '));
    expect(commands.last, contains('codex_runtime.py'));
    expect(commands.last, contains('shortcut'));
  });

  test('shortcut configuration requires the shared service to be ready', () async {
    var calls = 0;
    CodexSetupService.runOverride = (_, command) async {
      calls++;
      return status();
    };
    await expectLater(CodexSetupService.configureTerminalShortcut(connection), throwsStateError);
    expect(calls, 1);
  });

  test('prepare does not overwrite an explicit custom terminal command',
      () async {
    await StorageService.setCodexTerminalCommand(connection.id, 'codex-yolo');
    var checks = 0;
    CodexSetupService.runOverride = (_, command) async =>
        command.startsWith('bash --noprofile --norc -ic') &&
            !command.contains(' prepare ')
            ? status(prepared: checks++ > 0)
            : '{"ok":true}';
    await CodexSetupService.prepare(connection);
    expect(StorageService.getCodexTerminalCommand(connection.id), 'codex-yolo');
  });

  test('missing prerequisites prevent mutation', () async {
    var calls = 0;
    CodexSetupService.runOverride = (_, command) async {
      calls++;
      return status(loggedIn: false);
    };
    await expectLater(CodexSetupService.prepare(connection), throwsStateError);
    expect(calls, 1);
  });

  test('install command includes only missing packages and is not executed',
      () async {
    var calls = 0;
    CodexSetupService.runOverride = (_, command) async {
      calls++;
      return command.startsWith('bash --noprofile --norc -ic')
          ? status(tmux: false)
          : 'apt-get';
    };
    final command = await CodexSetupService.installationCommand(connection);
    expect(command, contains('install -y tmux'));
    expect(command, isNot(contains('install -y python3')));
    expect(command, contains('sudo'));
    expect(calls, 2);
  });

  test(
      'login uses the detected executable, without installing account wrappers',
      () async {
    CodexSetupService.runOverride =
        (_, command) async => status(loggedIn: false);
    final command = await CodexSetupService.loginCommand(connection);
    expect(command, contains('/opt/node/bin/codex'));
    expect(command, contains('login --device-auth'));
    expect(command, isNot(contains('codex-auth')));
  });
}
