import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/remote_python_script.dart';

void main() {
  late Directory home;
  final commands = <String>[];

  Future<String> execute(String command) async {
    commands.add(command);
    final result = await Process.run(
      'bash',
      ['-c', command],
      environment: {'HOME': home.path, 'PATH': Platform.environment['PATH']!},
    );
    return result.stdout as String;
  }

  setUp(() async {
    home = await Directory.systemTemp.createTemp('remote-python-script-');
    commands.clear();
  });

  tearDown(() async {
    await home.delete(recursive: true);
  });

  test('deploys once, then reuses the content-addressed script', () async {
    const script = 'import sys\nprint("hello", *sys.argv[1:])\n';
    final first = await RemotePythonScript.run(
      script: script,
      args: ['a b', "it's quoted"],
      execute: execute,
    );
    expect(first, contains("hello a b it's quoted"));
    expect(first, matches(r'__SSH_TOOL_EXIT__0\s*$'));
    expect(commands, hasLength(2));
    expect(commands.first, contains('__SSH_TOOL_SCRIPT_MISSING_7F3A91D2__'));
    expect(commands.last.length, greaterThan(commands.first.length));

    commands.clear();
    final second = await RemotePythonScript.run(
      script: script,
      args: ['again'],
      execute: execute,
    );
    expect(second, contains('hello again'));
    expect(commands, hasLength(1));
    expect(commands.single, isNot(contains(base64Encode(utf8.encode(script)))));
    expect(commands.single.length, lessThan(500));
  });

  test('reinstalls a missing version and gives changed scripts distinct paths',
      () async {
    const firstScript = 'print("first")\n';
    const secondScript = 'print("second")\n';
    await RemotePythonScript.run(
      script: firstScript,
      args: const [],
      execute: execute,
    );
    final cache = Directory('${home.path}/.cache/ssh_tool/reader_scripts');
    final cachedScript = cache.listSync().whereType<File>().single;
    await cachedScript.delete();

    commands.clear();
    final reinstalled = await RemotePythonScript.run(
      script: firstScript,
      args: const [],
      execute: execute,
    );
    expect(reinstalled, contains('first'));
    expect(commands, hasLength(2));

    commands.clear();
    final changed = await RemotePythonScript.run(
      script: secondScript,
      args: const [],
      execute: execute,
    );
    expect(changed, contains('second'));
    expect(commands, hasLength(2));
    expect(
        commands.last, isNot(contains(base64Encode(utf8.encode(firstScript)))));
  });

  test('preserves the Python failure exit marker', () async {
    final output = await RemotePythonScript.run(
      script: 'raise SystemExit(7)\n',
      args: const [],
      execute: execute,
    );
    expect(output, matches(r'__SSH_TOOL_EXIT__7\s*$'));
  });

  test('passes shell metacharacters as literal Python arguments', () async {
    final injected = '${home.path}/injected';
    final args = [
      'space ; \$(touch $injected)',
      '`touch $injected`',
      "quote' and\nnewline",
    ];
    final output = await RemotePythonScript.run(
      script: 'import json, sys\nprint(json.dumps(sys.argv[1:]))\n',
      args: args,
      execute: execute,
    );

    final jsonLine = output.split('\n').firstWhere(
          (line) => line.startsWith('['),
        );
    expect(jsonDecode(jsonLine), args);
    expect(await File(injected).exists(), isFalse);
    expect(output, matches(r'__SSH_TOOL_EXIT__0\s*$'));
  });

  test('captures deployment errors and reports their exit status', () async {
    final cacheRoot = Directory('${home.path}/.cache');
    await cacheRoot.create();
    await File('${cacheRoot.path}/ssh_tool').writeAsString('blocking file');

    final output = await RemotePythonScript.run(
      script: 'print("unreachable")\n',
      args: const [],
      execute: execute,
    );

    expect(output, contains('Not a directory'));
    expect(output, matches(r'__SSH_TOOL_EXIT__1\s*$'));
    expect(commands, hasLength(2));
  });
}
