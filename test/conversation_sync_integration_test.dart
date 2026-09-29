import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/claude_session_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/services/remote_python_script.dart';

void main() {
  for (final provider in ['codex', 'claude']) {
    test('$provider service merges actual cached Python responses', () async {
      final home = await Directory.systemTemp.createTemp('conversation-sync-');
      addTearDown(() async {
        CodexSessionService.runPythonOverride = null;
        ClaudeSessionService.runPythonOverride = null;
        CodexSessionService.clearCache();
        ClaudeSessionService.clearCache();
        await home.delete(recursive: true);
      });
      const id = 'integration-chat';
      final log = File(provider == 'codex'
          ? '${home.path}/.codex/sessions/2026/session-$id.jsonl'
          : '${home.path}/.claude/projects/project/$id.jsonl');
      await log.parent.create(recursive: true);
      String message(String text) => jsonEncode(provider == 'codex'
          ? {
              'type': 'response_item',
              'payload': {
                'type': 'message',
                'role': 'assistant',
                'content': [
                  {'text': text}
                ]
              }
            }
          : {
              'type': 'assistant',
              'message': {
                'role': 'assistant',
                'content': [
                  {'type': 'text', 'text': text}
                ]
              }
            });
      await log.writeAsString('${message('first')}\n');
      final responses = <Map<String, dynamic>>[];
      final commands = <String>[];
      Future<String> remote(
          String connection, String script, List<String> args) async {
        final output = await RemotePythonScript.run(
            script: script,
            args: args,
            execute: (command) async {
              commands.add(command);
              final result = await Process.run('sh', [
                '-c',
                command
              ], environment: {
                'HOME': home.path,
                'CODEX_HOME': '${home.path}/.codex',
              });
              expect(result.exitCode, 0, reason: '${result.stderr}');
              return result.stdout as String;
            });
        final marker =
            RegExp(r'__SSH_TOOL_EXIT__(\d+)\s*$').firstMatch(output)!;
        if (marker.group(1) != '0') throw StateError(output);
        final body = output.substring(0, marker.start).trim();
        responses.add(jsonDecode(body) as Map<String, dynamic>);
        return body;
      }

      CodexSessionService.runPythonOverride = remote;
      ClaudeSessionService.runPythonOverride = remote;
      final read = provider == 'codex'
          ? CodexSessionService.readConversation
          : ClaudeSessionService.readConversation;
      expect((await read('host', id)).map((row) => row.text), ['first']);
      expect(responses.last['type'], 'snapshot');
      expect(commands, hasLength(2)); // Probe + initial deployment.
      commands.clear();
      expect((await read('host', id)).map((row) => row.text), ['first']);
      expect(responses.last['type'], 'unchanged');
      expect(commands, hasLength(1));
      expect(commands.single.length, lessThan(1000));
      await log.writeAsString('${message('second')}\n', mode: FileMode.append);
      expect(
          (await read('host', id)).map((row) => row.text), ['first', 'second']);
      expect(responses.last['type'], 'delta');
      expect(responses.last['upserts'], hasLength(1));
      await Directory('${home.path}/.cache/ssh_tool').delete(recursive: true);
      expect(
          (await read('host', id)).map((row) => row.text), ['first', 'second']);
      expect(responses.last['type'], 'snapshot');
      await log.delete();
      await expectLater(read('host', id), throwsStateError);
    });
  }
}
