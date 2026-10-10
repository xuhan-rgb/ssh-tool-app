import 'dart:io';
import 'dart:async';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/services/p2p_service.dart';

void main() {
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
  test('identical concurrent requests share a single P2P startup', () async {
    final c = connection();
    final pending = Completer<int>();
    var starts = 0;
    P2pService.startOverride = (_) { starts++; return pending.future; };
    final first = P2pService.resolve(c);
    final second = P2pService.resolve(c);
    pending.complete(45678);
    final endpoints = await Future.wait([first, second]);
    expect(starts, 1);
    expect(endpoints.first, same(endpoints.last));
  });

  test('failed startup does not prevent a later retry', () async {
    final c = connection(options: {'allowRelayFallback': false});
    var starts = 0;
    P2pService.startOverride = (_) async {
      if (++starts == 1) throw Exception('test failure');
      return 45678;
    };
    await expectLater(P2pService.resolve(c), throwsException);
    expect((await P2pService.resolve(c)).route, 'P2P');
    expect(starts, 2);
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
