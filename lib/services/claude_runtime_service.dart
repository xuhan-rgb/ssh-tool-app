import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'ssh_service.dart';

class ClaudeRuntimeSession {
  final String sessionId;
  final String tmuxSession;
  final String workDir;
  final String status;
  final bool isAlive;
  final String? model;
  final String? effort;
  final DateTime? updatedAt;

  ClaudeRuntimeSession.fromJson(Map<String, dynamic> data)
      : sessionId = data['sessionId'] as String,
        tmuxSession = data['tmuxSession'] as String,
        workDir = data['workDir'] as String? ?? '~',
        status = data['status'] as String? ?? 'unknown',
        isAlive = data['alive'] == true,
        model = data['model'] as String?,
        effort = data['effort'] as String?,
        updatedAt = data['updatedAt'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (data['updatedAt'] * 1000).toInt())
            : null;
}

class ClaudeMessageReceipt {
  final String id;
  final String text;
  final String status;
  final String? error;
  final DateTime timestamp;

  ClaudeMessageReceipt.fromJson(Map<String, dynamic> data)
      : id = data['id'] as String,
        text = data['text'] as String,
        status = data['status'] as String,
        error = data['error'] as String?,
        timestamp = DateTime.fromMillisecondsSinceEpoch(
            ((data['createdAt'] as num) * 1000).toInt());

  String get label => switch (status) {
        'queued' => '已排队 · 等待 Claude 空闲',
        'dispatching' => '已提交终端 · 等待 Claude 确认',
        'accepted' => 'Claude 已收到',
        'cancelled' => '已移出队列 · 不再发送',
        'failed' => error ?? '发送失败',
        'uncertain' => error ?? '接收状态不确定，请检查终端',
        _ => status,
      };
}

class ClaudeRuntimeStatus {
  final ClaudeRuntimeSession? session;
  final List<ClaudeMessageReceipt> messages;

  ClaudeRuntimeStatus.fromJson(Map<String, dynamic> data)
      : session = data['session'] == null
            ? null
            : ClaudeRuntimeSession.fromJson(
                Map<String, dynamic>.from(data['session'])),
        messages = (data['messages'] as List? ?? [])
            .map((item) =>
                ClaudeMessageReceipt.fromJson(Map<String, dynamic>.from(item)))
            .toList();
}

class ClaudeRuntimeService {
  static final Map<String, Object> _installedClients = {};
  @visibleForTesting
  static Future<dynamic> Function(
          String connectionId, String action, Map<String, dynamic> payload)?
      requestOverride;

  static Future<ClaudeRuntimeSession> ensureSession(String connectionId,
          {required String sessionId,
          required String workDir,
          bool resume = true,
          String? model,
          String? effort}) async =>
      ClaudeRuntimeSession.fromJson(
          Map<String, dynamic>.from(await _request(connectionId, 'ensure', {
        'sessionId': sessionId,
        'workDir': workDir,
        'resume': resume,
        'model': model,
        'effort': effort,
      })));

  static Future<Map<String, ClaudeRuntimeSession>> listSessions(
      String connectionId) async {
    final list = await _request(connectionId, 'list', {}) as List;
    return {
      for (final item in list)
        (item['sessionId'] as String):
            ClaudeRuntimeSession.fromJson(Map<String, dynamic>.from(item))
    };
  }

  static Future<ClaudeRuntimeStatus> status(
          String connectionId, String sessionId) async =>
      ClaudeRuntimeStatus.fromJson(Map<String, dynamic>.from(
          await _request(connectionId, 'status', {'sessionId': sessionId})));

  static Future<void> send(String connectionId, String sessionId, String text,
      {required String messageId}) async {
    await _request(connectionId, 'send', {
      'sessionId': sessionId,
      'messageId': messageId,
      'text': text,
    });
  }

  static Future<void> cancel(
      String connectionId, String sessionId, String messageId) async {
    await _request(connectionId, 'cancel',
        {'sessionId': sessionId, 'messageId': messageId});
  }

  static String newMessageId() => const Uuid().v4();

  static Future<dynamic> _request(
      String connectionId, String action, Map<String, dynamic> payload) async {
    final override = requestOverride;
    if (override != null) return override(connectionId, action, payload);
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');
    final body = base64Encode(utf8.encode(jsonEncode(payload)));
    var deploy = '';
    if (!identical(_installedClients[connectionId], client)) {
      final script = await rootBundle.loadString('assets/claude_runtime.py');
      final encoded = base64Encode(utf8.encode(script));
      deploy = 'umask 077; mkdir -p ~/.ssh_tool/claude_runtime; '
          'tmp=~/.ssh_tool/claude_runtime/worker.\$\$.tmp; '
          'printf %s $encoded | base64 -d > "\$tmp" && '
          'mv "\$tmp" ~/.ssh_tool/claude_runtime/worker.py && ';
    }
    final command = '$deploy'
        'printf %s $body | base64 -d | python3 ~/.ssh_tool/claude_runtime/worker.py $action';
    final output = utf8.decode(
        await client
            .run('$command 2>&1; printf "\\n__CLAUDE_EXIT__%s\\n" "\$?"'),
        allowMalformed: true);
    final marker = RegExp(r'__CLAUDE_EXIT__(\d+)\s*$').firstMatch(output);
    if (marker == null) throw StateError('Claude 操作未返回状态，请刷新后检查');
    final result = output.substring(0, marker.start).trim();
    if (marker.group(1) != '0') throw StateError(result);
    _installedClients[connectionId] = client;
    return jsonDecode(result);
  }
}
