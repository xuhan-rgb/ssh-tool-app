import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Runs a Python script remotely, caching its content by SHA-256 in the
/// remote user's `~/.cache/ssh_tool/reader_scripts` directory.
///
/// [execute] runs one shell command over the existing SSH connection and
/// returns its stdout, including the `__SSH_TOOL_EXIT__` status marker.
class RemotePythonScript {
  static const _missingMarker = '__SSH_TOOL_SCRIPT_MISSING_7F3A91D2__';

  /// Runs [script] with [args] and returns the raw output from [execute].
  ///
  /// The script is sent only when its content-addressed file is missing.
  static Future<String> run({
    required String script,
    required List<String> args,
    required Future<String> Function(String command) execute,
  }) async {
    final digest = sha256.convert(utf8.encode(script)).toString();
    const pathVariable = '__ssh_tool_script_path';
    final invocation = _invocation('\$$pathVariable', args);
    final probe =
        '$pathVariable="\$HOME/.cache/ssh_tool/reader_scripts/$digest.py"; if [ -f "\$$pathVariable" ]; then $invocation; else printf %s ${_quote(_missingMarker)}; fi';
    final firstOutput = await execute(_withExitMarker(probe));
    if (firstOutput.trimRight() != '$_missingMarker\n__SSH_TOOL_EXIT__0') {
      return firstOutput;
    }

    final encoded = base64Encode(utf8.encode(script));
    final deployment =
        'umask 077; $pathVariable="\$HOME/.cache/ssh_tool/reader_scripts/$digest.py"; __ssh_tool_script_dir="\$HOME/.cache/ssh_tool/reader_scripts"; mkdir -p "\$__ssh_tool_script_dir" && __ssh_tool_script_temp="\$$pathVariable.tmp.\$\$" && printf %s ${_quote(encoded)} | base64 -d > "\$__ssh_tool_script_temp" && chmod 600 "\$__ssh_tool_script_temp" && mv "\$__ssh_tool_script_temp" "\$$pathVariable" && $invocation';
    return execute(_withExitMarker(deployment));
  }

  static String _invocation(String path, List<String> args) {
    return ['python3', '"$path"', ...args.map(_quote)].join(' ');
  }

  static String _withExitMarker(String command) =>
      '{ $command; } 2>&1; __ssh_tool_script_status=\$?; printf "\\n__SSH_TOOL_EXIT__%s\\n" "\$__ssh_tool_script_status"';

  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
}
