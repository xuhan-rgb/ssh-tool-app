import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ssh_service.dart';

/// One foreground subscription, independent of the lifetime of a chat turn.
class CodexUserInputService extends ChangeNotifier {
  final String connectionId;
  final String threadId;
  final Map<String, Map<String, dynamic>> _pending = {};
  final Map<String, Completer<void>> _submissions = {};
  final Map<String, Timer> _timeouts = {};
  void Function()? _close;
  void Function(List<int>)? _write;
  Timer? _retry;
  bool _disposed = false;
  String? error;

  CodexUserInputService(this.connectionId, this.threadId) {
    unawaited(_connect());
  }

  List<Map<String, dynamic>> get pending => _pending.values.toList();
  static String requestKey(dynamic id) => jsonEncode(id);

  Future<void> _connect() async {
    try {
      final client = SshService.getClient(connectionId);
      if (client == null) return;
      final transport =
          await rootBundle.loadString('assets/codex_steer_message.py');
      final helper = await rootBundle.loadString('assets/codex_user_input.py');
      final source = '${transport.split('\ndef steer(').first}\n'
          '${helper.replaceFirst('from codex_steer_message import RpcConnection, control_socket_path', '')}';
      final encoded = base64Encode(utf8.encode(source));
      String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
      final session = await client.execute(
        'python3 -u -c ${quote("import base64; exec(base64.b64decode('$encoded'))")} ${quote(threadId)}',
      );
      if (_disposed) {
        session.close();
        return;
      }
      _close = session.close;
      _write = (bytes) => session.stdin.add(Uint8List.fromList(bytes));
      // Drain stderr so a closed remote process cannot block the SSH stream.
      final stderr = session.stderr.listen((_) {});
      try {
        await for (final line in session.stdout
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (_disposed) break;
          final event = jsonDecode(line) as Map<String, dynamic>;
          if (event['type'] == 'pending') {
            final request = Map<String, dynamic>.from(event['request'] as Map);
            _pending[requestKey(request['id'])] = request;
            error = null;
          } else if (event['type'] == 'resolved') {
            final key = requestKey(event['id']);
            _pending.remove(key);
            _timeouts.remove(key)?.cancel();
            _submissions.remove(key)?.complete();
          } else if (event['type'] == 'error') {
            final key = requestKey(event['id']);
            _timeouts.remove(key)?.cancel();
            _submissions
                .remove(key)
                ?.completeError(StateError(event['error'].toString()));
          } else if (event['type'] == 'connectionError') {
            throw StateError(event['error'].toString());
          } else if (event['type'] == 'ready') {
            final replayed =
                (event['pendingIds'] as List).map(requestKey).toSet();
            _pending.removeWhere((key, _) => !replayed.contains(key));
            error = null;
          }
          notifyListeners();
        }
        if (!_disposed) throw StateError('问题同步连接已断开');
      } finally {
        await stderr.cancel();
        session.close();
      }
    } catch (failure) {
      if (!_disposed) {
        error = failure.toString();
        // Retain the draft on transport failure; replay confirms pending questions.
        for (final value in _submissions.values) {
          value.completeError(StateError('连接中断，答案是否提交尚未确认；重连后可重试'));
        }
        _submissions.clear();
        for (final timer in _timeouts.values) {
          timer.cancel();
        }
        _timeouts.clear();
        notifyListeners();
      }
    } finally {
      _write = null;
      _close = null;
      if (!_disposed) {
        _retry = Timer(const Duration(seconds: 3), () => unawaited(_connect()));
      }
    }
  }

  Future<void> submit(
      Map<String, dynamic> request, Map<String, List<String>> answers) {
    final write = _write;
    if (write == null) return Future.error(StateError('问题同步正在重连，请稍后重试'));
    final key = requestKey(request['id']);
    if (!_pending.containsKey(key)) {
      return Future.error(StateError('问题已经回答或取消'));
    }
    if (_submissions.containsKey(key)) {
      return Future.error(StateError('正在等待远程确认'));
    }
    final completion = Completer<void>();
    _submissions[key] = completion;
    _timeouts[key] = Timer(const Duration(seconds: 15), () {
      _timeouts.remove(key);
      _submissions
          .remove(key)
          ?.completeError(StateError('远程尚未确认，正在重新同步；不会自动重复提交'));
      _close?.call();
    });
    try {
      write(utf8.encode(
          '${jsonEncode({'id': request['id'], 'answers': answers})}\n'));
    } catch (failure) {
      _timeouts.remove(key)?.cancel();
      _submissions.remove(key)?.completeError(failure);
    }
    return completion.future;
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _close?.call();
    for (final timer in _timeouts.values) {
      timer.cancel();
    }
    for (final value in _submissions.values) {
      value.completeError(StateError('对话已关闭'));
    }
    super.dispose();
  }
}
