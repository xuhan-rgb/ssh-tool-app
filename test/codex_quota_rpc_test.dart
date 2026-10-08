import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_quota_rpc.dart';

// A real byte stream stand-in for the already authenticated SSH forward.
class _Forward implements SSHForwardChannel {
  final Socket socket;
  bool destroyed = false;
  _Forward(this.socket);
  @override
  Stream<Uint8List> get stream => socket;
  @override
  StreamSink<List<int>> get sink => socket;
  @override
  Future<void> get done => socket.done;
  @override
  Future<void> close() => socket.close();
  @override
  void destroy() {
    destroyed = true;
    socket.destroy();
  }

  @override
  Future<void> flush() => socket.flush();
}

void main() {
  late HttpServer server;
  late List<WebSocket> sockets;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    sockets = [];
  });
  tearDown(() async {
    for (final socket in sockets) {
      unawaited(socket.close());
    }
    await server.close(force: true);
  });

  test(
      'forwarded byte stream initializes, skips notices, reads limits and closes',
      () async {
    final methods = <String>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final value = jsonDecode(raw as String) as Map;
        methods.add(value['method'] as String);
        if (value['method'] == 'initialize') {
          socket.add(jsonEncode({'id': value['id'], 'result': {}}));
        } else if (value['method'] == 'account/rateLimits/read') {
          socket.add(jsonEncode(
              {'method': 'account/rateLimits/updated', 'params': {}}));
          socket.add(jsonEncode({
            'id': value['id'],
            'result': {
              'rateLimits': {
                'primary': {'usedPercent': 25, 'windowDurationMins': 300}
              },
            }
          }));
        }
      });
    });
    final channel = _Forward(await Socket.connect('127.0.0.1', server.port));
    final result = await CodexQuotaRpc.readForwarded(channel);
    expect(result['rateLimits']['primary']['usedPercent'], 25);
    expect(methods, ['initialize', 'initialized', 'account/rateLimits/read']);
    expect(channel.destroyed, isTrue);
  });

  test('API errors do not expose raw account data or become zero quota',
      () async {
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((raw) {
        final value = jsonDecode(raw as String) as Map;
        socket.add(jsonEncode({
          'id': value['id'],
          'error': {'message': 'private account data'}
        }));
      });
    });
    await expectLater(
        CodexQuotaRpc.read(Uri.parse('ws://127.0.0.1:${server.port}/')),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            '当前 Codex 服务无法提供额度，请检查账号登录状态及账号类型')));
  });

  test('unresponsive server has a bounded query timeout', () async {
    server.listen((request) async {
      sockets.add(await WebSocketTransformer.upgrade(request));
    });
    await expectLater(
        CodexQuotaRpc.read(Uri.parse('ws://127.0.0.1:${server.port}/'),
            timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()));
  });
}
