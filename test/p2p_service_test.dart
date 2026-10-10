import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/services/p2p_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final config = <String, dynamic>{
    'allowRelayFallback': true,
  };
  SshConnection connection({bool p2p = true, Map<String, dynamic>? options}) =>
      SshConnection.create(
          name: 'Host',
          host: 'relay.example',
          port: 7001,
          username: 'user',
          useP2p: p2p,
          p2pOptions: options ?? config);

  tearDown(() {
    P2pService.startOverride = null;
    P2pService.endpoints.clear();
    P2pService.diagnostics.clear();
    P2pService.lastInterfaces = null;
  });
  test('concurrent requests reuse one P2P startup', () async {
    final c = connection();
    final pending = Completer<int>();
    var starts = 0;
    P2pService.startOverride = (_) { starts++; return pending.future; };
    final first = P2pService.resolve(c);
    final second = P2pService.resolve(c);
    expect(starts, 1);
    pending.complete(45678);
    expect(await first, same(await second));
  });

  test('upload timeout is not blocked by file cleanup', () async {
    final file = _StalledUploadFile();
    final task = P2pService.uploadAgentFile(file, Uint8List(1024),
        timeout: const Duration(milliseconds: 10),
        cleanupTimeout: const Duration(milliseconds: 10));
    await expectLater(task.timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>().having(
            (error) => error.message, 'message', contains('P2P 辅助程序上传超时'))));
    expect(file.closeCalls, 1);
  });

  test('batched upload preserves every byte and file offset', () async {
    final bytes = Uint8List.fromList(
        List<int>.generate(2 * 1024 * 1024 + 127, (index) => index % 251));
    final file = _RecordingUploadFile(bytes.length);
    await P2pService.uploadAgentFile(file, bytes);
    expect(file.contents, orderedEquals(bytes));
    expect(file.writeCalls, 33);
    expect(file.closeCalls, 1);
  });

  test('verified agent is reused on repeated connections without opening a file', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (_) async => ByteData.sublistView(bytes));
    rootBundle.evict('assets/p2p/agent-linux-amd64');
    try {
      final digest = sha256.convert(bytes).toString();
      final sftp = _CachedAgentSftp();
      final client = _CachedAgentClient(digest, sftp);
      final first = await P2pService.deployAgent(client);
      final second = await P2pService.deployAgent(client);
      expect(first, ('/home/test/.ssh_tool/p2p/agent-$digest', 22));
      expect(second, first);
      expect(sftp.openCalls, 0);
      expect(client.checkCalls, 2);
      expect(client.sftpCalls, 0);
      // A changed home hint must not make an unverified cached path usable.
      final moved = _CachedAgentClient(digest, sftp, homeHint: '/missing');
      expect(await P2pService.deployAgent(moved), first);
      expect(moved.sftpCalls, 1);
      expect(moved.checkCalls, 2);
      final legacy = _CachedAgentClient(digest, sftp, homeHint: '');
      expect(await P2pService.deployAgent(legacy), first);
      expect(legacy.sftpCalls, 1);
      expect(sftp.openCalls, 0);
    } finally {
      rootBundle.evict('assets/p2p/agent-linux-amd64');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
    }
  });

  test('ordinary SSH preserves address without starting a helper', () async {
    P2pService.startOverride = (_) async => throw StateError('unexpected');
    final endpoint = await P2pService.resolve(connection(p2p: false));
    expect(endpoint.host, 'relay.example');
    expect(endpoint.port, 7001);
    expect(endpoint.route, isNull);
  });
  test(
      'successful automatic tunnel uses local endpoint and records actual P2P route',
      () async {
    final c = connection();
    P2pService.startOverride = (input) async {
      expect(input['id'], c.id);
      expect(input['host'], 'relay.example');
      return 45678;
    };
    final endpoint = await P2pService.resolve(c);
    expect(endpoint.host, '127.0.0.1');
    expect(endpoint.port, 45678);
    expect(endpoint.route, 'P2P');
    expect(P2pService.endpoints[c.id], same(endpoint));
  });
  test('failed hole punching falls back to original SSH address with reason',
      () async {
    P2pService.startOverride = (_) async => throw Exception('打洞失败');
    final endpoint = await P2pService.resolve(connection());
    expect(endpoint.host, 'relay.example');
    expect(endpoint.port, 7001);
    expect(endpoint.route, '原连接');
    expect(endpoint.fallbackReason, '打洞失败');
  });
  test('strict P2P failure is surfaced without reporting connection', () async {
    final c = connection(options: {...config, 'allowRelayFallback': false});
    P2pService.startOverride = (_) async => throw Exception('协调连接失败');
    await expectLater(P2pService.resolve(c),
        throwsA(predicate((e) => e.toString().contains('协调连接失败；已关闭原连接回退'))));
    expect(P2pService.endpoints[c.id], isNull);
  });
  test('rejected SSH credentials are not turned into P2P fallback', () async {
    P2pService.startOverride = (_) async => throw SSHAuthFailError('denied');
    final c = connection();
    await expectLater(P2pService.resolve(c), throwsA(isA<SSHAuthFailError>()));
    expect(P2pService.endpoints[c.id], isNull);
  });
  test('automatic P2P requires no coordinator or XTCP fields', () async {
    P2pService.startOverride = (_) async => 45678;
    final endpoint = await P2pService.resolve(connection(options: {}));
    expect(endpoint.route, 'P2P');
  });
  test('P2P settings survive copy and Hive reopen', () async {
    final directory = await Directory.systemTemp.createTemp('p2p-storage-');
    Hive.init(directory.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(SshConnectionAdapter());
    }
    try {
      final c = connection();
      var box = await Hive.openBox<SshConnection>('frp-connections');
      await box.put(c.id, c.copyWith(name: 'Edited'));
      await box.close();
      box = await Hive.openBox<SshConnection>('frp-connections');
      final saved = box.get(c.id)!;
      expect(saved.name, 'Edited');
      expect(saved.useP2p, isTrue);
      expect(saved.p2pOptions, config);
      expect(saved.copyWith(useP2p: false).p2pOptions, config);
      await box.close();
    } finally {
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
  test('legacy saved connections default to ordinary SSH', () async {
    final directory = await Directory.systemTemp.createTemp('p2p-legacy-');
    Hive.init(directory.path);
    Hive.registerAdapter(_LegacyConnectionAdapter(), override: true);
    try {
      final c = connection(p2p: false);
      var box = await Hive.openBox<SshConnection>('legacy');
      await box.put(c.id, c);
      await box.close();
      Hive.registerAdapter(SshConnectionAdapter(), override: true);
      box = await Hive.openBox<SshConnection>('legacy');
      expect(box.get(c.id)!.useP2p, isFalse);
      expect(box.get(c.id)!.p2pOptions, isNull);
      expect(box.get(c.id)!.host, 'relay.example');
      await box.close();
    } finally {
      Hive.registerAdapter(SshConnectionAdapter(), override: true);
      await Hive.close();
      await directory.delete(recursive: true);
    }
  });
}

// Writes the previous on-disk format without the new P2P fields.
class _LegacyConnectionAdapter extends SshConnectionAdapter {
  @override
  void write(BinaryWriter writer, SshConnection obj) {
    final fields = [
      obj.id,
      obj.name,
      obj.host,
      obj.port,
      obj.username,
      obj.password,
      obj.privateKeyPath,
      obj.passphrase,
      obj.createdAt,
      obj.updatedAt,
      obj.terminalColor,
      obj.useTmux
    ];
    writer.writeByte(fields.length);
    for (var i = 0; i < fields.length; i++) {
      writer.writeByte(i);
      writer.write(fields[i]);
    }
  }
}

class _StalledUploadFile extends Fake implements SftpFile {
  int closeCalls = 0;
  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) => Completer<void>().future;
  @override
  Future<void> close() { closeCalls++; return Completer<void>().future; }
}

class _CachedAgentClient extends Fake implements SSHClient {
  final String digest;
  final _CachedAgentSftp fileClient;
  int checkCalls = 0;
  int sftpCalls = 0;
  final String homeHint;
  _CachedAgentClient(this.digest, this.fileClient, {this.homeHint = '/home/test'});
  @override
  Future<Uint8List> run(String command, {bool runInPty = false, bool stdout = true, bool stderr = true, Map<String, String>? environment}) async {
    if (command.startsWith('uname')) return Uint8List.fromList(utf8.encode('Linux\nx86_64\n100.1.1.1 12345 100.2.2.2 22\n$homeHint\n'));
    if (command.startsWith('test -x')) { checkCalls++; if (command.contains('/missing/')) return Uint8List.fromList(utf8.encode('wrong-digest  missing')); return Uint8List.fromList(utf8.encode('$digest  /home/test/.ssh_tool/p2p/agent-$digest')); }
    throw StateError('Unexpected deployment command');
  }
  @override
  Future<SftpClient> sftp() async { sftpCalls++; return fileClient; }
}

class _CachedAgentSftp extends Fake implements SftpClient {
  int openCalls = 0;
  @override
  Future<String> absolute(String path) async => '/home/test';
  @override
  Future<SftpFile> open(String path, {SftpFileOpenMode mode = SftpFileOpenMode.read, SftpFileAttrs? attrs}) async { openCalls++; throw StateError('Cached helper must not be uploaded'); }
  @override
  Future<void> close() async {}
}

class _RecordingUploadFile extends Fake implements SftpFile {
  final Uint8List contents;
  int writeCalls = 0;
  int closeCalls = 0;
  _RecordingUploadFile(int length) : contents = Uint8List(length);
  @override
  Future<void> writeBytes(Uint8List data, {int offset = 0}) async {
    writeCalls++;
    contents.setRange(offset, offset + data.length, data);
  }
  @override
  Future<void> close() async { closeCalls++; }
}
