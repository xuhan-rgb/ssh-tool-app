import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

/// Query the existing Codex socket over SSH forwarding. No remote commands.
class CodexQuotaRpc {
  static Future<Map<String, dynamic>> readRemote(SSHClient client) async {
    final sftp = await client.sftp();
    late String path;
    try {
      final home = await sftp.absolute('.');
      try {
        final file =
            await sftp.open('$home/.ssh_tool/codex_runtime/connection.json');
        try {
          final bytes = await file.readBytes(length: 16384);
          final config = jsonDecode(utf8.decode(bytes)) as Map;
          path = config['socketPath'] as String;
        } finally {
          await file.close();
        }
      } on SftpStatusError catch (error) {
        if (error.code != SftpStatusCode.noSuchFile) rethrow;
        path = '$home/.codex/app-server-control/app-server-control.sock';
      }
    } finally {
      sftp.close();
    }
    if (!path.startsWith('/')) throw StateError('Codex 服务地址无效');
    return readForwarded(await client.forwardLocalUnix(path));
  }

  static Future<Map<String, dynamic>> readForwarded(
      SSHForwardChannel channel) async {
    ServerSocket? server;
    Socket? local;
    StreamSubscription? accept;
    StreamSubscription? inbound;
    StreamSubscription? outbound;
    try {
      // Dart's WebSocket client handles framing through a temporary loopback bridge.
      // The bridge is bound only on the phone and removed when this read finishes.
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      accept = server.listen((socket) {
        if (local != null) {
          socket.destroy();
          return;
        }
        local = socket;
        inbound = socket.listen(channel.sink.add,
            onError: (Object _) => channel.destroy(), onDone: channel.destroy);
        outbound = channel.stream.listen(socket.add,
            onError: (Object _) => socket.destroy(), onDone: socket.destroy);
      });
      return await read(Uri.parse('ws://127.0.0.1:${server.port}/'));
    } finally {
      local?.destroy();
      channel.destroy();
      await inbound?.cancel();
      await outbound?.cancel();
      await accept?.cancel();
      await server?.close();
    }
  }

  /// Separated from SSH so the actual WebSocket/JSON-RPC exchange can be tested.
  static Future<Map<String, dynamic>> read(Uri url,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final http = HttpClient()..connectionTimeout = timeout;
    WebSocket? socket;
    StreamIterator<dynamic>? messages;
    final deadline = DateTime.now().add(timeout);
    Duration remaining() {
      final duration = deadline.difference(DateTime.now());
      if (duration <= Duration.zero) throw TimeoutException('额度查询超时');
      return duration;
    }

    try {
      socket = await WebSocket.connect(url.toString(), customClient: http)
          .timeout(remaining());
      messages = StreamIterator<dynamic>(socket);
      Future<Map<String, dynamic>> request(
          int id, String method, Map<String, dynamic> params) async {
        socket!.add(jsonEncode({'id': id, 'method': method, 'params': params}));
        while (await messages!.moveNext().timeout(remaining())) {
          final value = jsonDecode(messages.current as String) as Map;
          if (value['id'] != id) continue;
          if (value['error'] != null) {
            throw StateError('当前 Codex 服务无法提供额度，请检查账号登录状态及账号类型');
          }
          return Map<String, dynamic>.from(value['result'] as Map);
        }
        throw StateError('Codex 额度连接已关闭');
      }

      await request(1, 'initialize', {
        'clientInfo': {'name': 'ssh_tool_status', 'version': '1'},
      });
      socket.add(jsonEncode({'method': 'initialized', 'params': {}}));
      return await request(2, 'account/rateLimits/read', {});
    } finally {
      await messages?.cancel();
      unawaited(socket?.close());
      http.close(force: true);
    }
  }
}
