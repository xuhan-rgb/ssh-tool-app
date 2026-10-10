import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/ssh_connection.dart';

class SshEndpoint {
  final String host;
  final int port;
  final String? route;
  final String? fallbackReason;
  final SSHClient? authenticatedClient;
  const SshEndpoint(this.host, this.port,
      {this.route, this.fallbackReason, this.authenticatedClient});
}

class _P2pLease {
  final SSHClient client;
  final SSHSession command;
  _P2pLease(this.client, this.command);
  void close() {
    command.close();
    client.close();
  }
}

/// SSH is the authenticated signaling channel. The dedicated remote process
/// belongs to this app and never reads or changes an existing frp installation.
class P2pService {
  static final Map<String, SshEndpoint> endpoints = {};
  static List<Map<String, dynamic>>? lastInterfaces;
  static final Map<String, Map<String, dynamic>> diagnostics = {};
  static const _platform = MethodChannel('ssh_tool_app/p2p');
  static final Map<String, String> _keys = {};
  static final Map<String, _P2pLease> _leases = {};
  @visibleForTesting
  static Future<int> Function(Map<String, dynamic>)? startOverride;

  static Future<SshEndpoint> resolve(SshConnection connection) => resolveConfig(
        connection.id,
        connection.host,
        connection.port,
        username: connection.username,
        password: connection.password ?? '',
        useP2p: connection.useP2p,
        options: connection.p2pOptions,
      );

  static Future<SshEndpoint> resolveConfig(
    String id,
    String host,
    int port, {
    required String username,
    required String password,
    required bool useP2p,
    Map<String, dynamic>? options,
    List<Map<String, dynamic>>? networkInterfaces,
  }) async {
    if (!useP2p) {
      final endpoint = SshEndpoint(host, port);
      endpoints[id] = endpoint;
      return endpoint;
    }
    diagnostics[id] = {'stage': 'starting'};
    final key = '$id-${sha256.convert(utf8.encode('$host:$port:$username'))}';
    _keys[id] = key;
    SSHClient? bootstrap;
    SSHSession? command;
    var bootstrapStarted = false;
    var bootstrapAuthenticated = false;
    try {
      final override = startOverride;
      int localPort;
      if (override != null) {
        localPort = await override({'id': id, 'host': host, 'port': port});
      } else {
        final cached = await _call('P2pLookup', key);
        if (cached['port'] is int) {
          localPort = cached['port'] as int;
        } else {
          _leases.remove(key)?.close();
          diagnostics[id]!['stage'] = 'ssh_auth';
          bootstrapStarted = true;
          final socket = await SSHSocket.connect(host, port,
              timeout: const Duration(seconds: 20));
          bootstrap = SSHClient(socket,
              username: username, onPasswordRequest: () => password);
          // Credential rejection must be reported immediately, not interpreted
          // as a hole-punching failure or retried via fallback.
          await bootstrap.authenticated.timeout(const Duration(seconds: 20));
          bootstrapAuthenticated = true;
          diagnostics[id]!['stage'] = 'deploy_agent';
          final agent = await _deployAgent(bootstrap);
          diagnostics[id]!['stage'] = 'phone_interfaces';
          final interfaces = networkInterfaces ?? await _collectInterfaces();
          lastInterfaces = interfaces;
          final offer = await _call(
              'P2pOffer', jsonEncode({'id': key, 'interfaces': interfaces}));
          diagnostics[id]!['phoneCandidates'] = _candidateCounts(offer['offer'] as Map);
          diagnostics[id]!['phoneAddresses'] = _candidateAddresses(offer['offer'] as Map);
          diagnostics[id]!['stage'] = 'remote_answer';
          command = await bootstrap.execute(_quote(agent.$1));
          command.stderr.listen((_) {});
          final response = command.stdout
              .cast<List<int>>()
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first;
          command.stdin.add(utf8.encode(
              '${jsonEncode({'offer': offer['offer'], 'port': agent.$2})}\n'));
          final answer =
              jsonDecode(await response.timeout(const Duration(seconds: 8)))
                  as Map;
          if (answer['error'] != null) throw Exception(answer['error']);
          diagnostics[id]!['computerCandidates'] = _candidateCounts(answer['answer'] as Map);
          diagnostics[id]!['computerAddresses'] = _candidateAddresses(answer['answer'] as Map);
          diagnostics[id]!['stage'] = 'ice_connect';
          final connected = await _call(
              'P2pAnswer', jsonEncode({'id': key, 'answer': answer['answer']}));
          diagnostics[id]!['candidatePair'] = connected['candidatePair'];
          localPort = connected['port'] as int;
          await _probe(localPort);
          final lease = _P2pLease(bootstrap, command);
          _leases[key] = lease;
          command.done.then((_) {
            if (identical(_leases[key], lease)) {
              _leases.remove(key);
              lease.client.close();
              unawaited(
                  _call('P2pStop', key).catchError((_) => <String, dynamic>{}));
            }
          });
          bootstrap = null;
          command = null;
        }
      }
      diagnostics[id]!['stage'] = 'connected';
      final endpoint = SshEndpoint('127.0.0.1', localPort, route: 'P2P');
      endpoints[id] = endpoint;
      return endpoint;
    } on SSHAuthFailError {
      bootstrap?.close();
      rethrow;
    } on SSHAuthAbortError {
      bootstrap?.close();
      rethrow;
    } catch (e) {
      if (bootstrapStarted && !bootstrapAuthenticated) {
        bootstrap?.close();
        rethrow;
      }
      command?.close();
      if (startOverride == null) {
        await _call('P2pStop', key).catchError((_) => <String, dynamic>{});
      }
      diagnostics[id]!['error'] = e.toString();
      final reason = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
      if (options?['allowRelayFallback'] == false) {
        bootstrap?.close();
        throw Exception('$reason；已关闭原连接回退');
      }
      final endpoint = SshEndpoint(host, port,
          route: '原连接', fallbackReason: reason, authenticatedClient: bootstrap);
      endpoints[id] = endpoint;
      return endpoint;
    }
  }

  static String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static Future<(String, int)> _deployAgent(SSHClient client) async {
    final platform = utf8
        .decode(await client
            .run('uname -s; uname -m; printf \'%s\\n\' "\$SSH_CONNECTION"'))
        .trim()
        .split('\n');
    if (platform.length < 2 || platform[0].trim() != 'Linux') {
      throw Exception('自动 P2P 当前支持 Linux 电脑，已保留原 SSH 连接');
    }
    final remotePort = platform.length > 2
        ? int.tryParse(platform[2].trim().split(RegExp(r'\s+')).last)
        : null;
    if (remotePort == null || remotePort < 1 || remotePort > 65535) {
      throw Exception('无法识别电脑端 SSH 监听端口');
    }
    final arch = switch (platform[1].trim()) {
      'x86_64' => 'amd64',
      'aarch64' || 'arm64' => 'arm64',
      _ => throw Exception('电脑架构暂不支持自动 P2P'),
    };
    final asset = await rootBundle.load('assets/p2p/agent-linux-$arch');
    final bytes =
        asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes);
    final digest = sha256.convert(bytes).toString();
    final sftp = await client.sftp();
    String? stage;
    try {
      final home = await sftp.absolute('.');
      final directory = '$home/.ssh_tool/p2p';
      final target = '$directory/agent-$digest';
      final check = utf8
          .decode(await client
              .run('test -x ${_quote(target)} && sha256sum ${_quote(target)}'))
          .trim();
      if (check.startsWith('$digest ')) return (target, remotePort);
      await client.run(
          'umask 077; mkdir -p ${_quote(directory)}; chmod 700 ${_quote(directory)}');
      stage = '$target.part-${DateTime.now().microsecondsSinceEpoch}';
      final file = await sftp.open(stage,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate);
      try {
        await file.writeBytes(bytes).timeout(const Duration(seconds: 90));
      } finally {
        await file.close();
      }
      final installed = utf8.decode(await client.run(
          'test "\$(sha256sum ${_quote(stage)} | cut -d " " -f 1)" = ${_quote(digest)} && '
          'chmod 700 ${_quote(stage)} && mv ${_quote(stage)} ${_quote(target)} && printf ready'));
      if (installed != 'ready') throw Exception('P2P 辅助程序上传校验失败');
      stage = null;
      return (target, remotePort);
    } finally {
      if (stage != null) {
        await sftp.remove(stage).catchError((_) {});
      }
      sftp.close();
    }
  }

  static Map<String, int> _candidateCounts(Map description) {
    final counts = <String, int>{};
    for (final line in (description['sdp'] as String? ?? '').split('\n')) {
      if (!line.startsWith('a=candidate:')) continue;
      final fields = line.trim().split(RegExp(r'\s+'));
      final typeIndex = fields.indexOf('typ');
      if (typeIndex >= 0 && typeIndex + 1 < fields.length) {
        final type = fields[typeIndex + 1];
        counts[type] = (counts[type] ?? 0) + 1;
      }
    }
    return counts;
  }

  static String _candidateAddresses(Map description) =>
      (description['sdp'] as String? ?? '')
          .split('\n')
          .where((line) => line.startsWith('a=candidate:'))
          .map((line) => line.trim().split(RegExp(r'\s+')).skip(4).take(4).join(' '))
          .toSet()
          .join('; ');

  static Future<List<Map<String, dynamic>>> _collectInterfaces() async {
    final interfaces =
        await _platform.invokeListMethod<dynamic>('networkInterfaces');
    if (interfaces == null || interfaces.isEmpty) {
      throw Exception('手机未获取到可用网络地址');
    }
    return interfaces
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
  }

  static Future<void> _probe(int port) async {
    final socket = await Socket.connect('127.0.0.1', port,
        timeout: const Duration(seconds: 5));
    try {
      final banner = await socket.first.timeout(const Duration(seconds: 5));
      if (!utf8.decode(banner, allowMalformed: true).startsWith('SSH-')) {
        throw Exception('P2P 已协商，但电脑 SSH 服务未响应');
      }
    } finally {
      socket.destroy();
    }
  }

  static Future<void> stop(String id) async {
    endpoints.remove(id);
    final key = _keys.remove(id);
    if (key == null) return;
    _leases.remove(key)?.close();
    await _call('P2pStop', key).catchError((_) => <String, dynamic>{});
  }

  static Future<Map<String, dynamic>> _call(String method, String input) =>
      Isolate.run(() => _native(method, input));

  static Map<String, dynamic> _native(String method, String value) {
    if (!Platform.isAndroid) throw Exception('自动 P2P 当前仅支持 Android 手机');
    final library = DynamicLibrary.open('libsshp2p.so');
    final call = library.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)>(method);
    final free = library.lookupFunction<Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)>('P2pFree');
    final input = value.toNativeUtf8();
    Pointer<Utf8>? output;
    try {
      output = call(input);
      final result = jsonDecode(output.toDartString()) as Map<String, dynamic>;
      if (result['error'] != null) throw Exception(result['error']);
      return result;
    } finally {
      malloc.free(input);
      if (output != null) free(output);
    }
  }
}
