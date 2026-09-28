import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/models/ssh_connection.dart';
import 'package:ssh_tool_app/services/codex_preload_service.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  final connection = SshConnection(
    id: 'host',
    name: 'host',
    host: 'localhost',
    username: 'user',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );
  CodexConversation conversation(String id, {bool running = false}) =>
      CodexConversation(
        id: id,
        cwd: '/',
        updatedAt: DateTime(2026),
        title: id,
        state: running
            ? CodexConversationState.running
            : CodexConversationState.complete,
      );

  test('preloads running and favorite records before a caller opens them',
      () async {
    final read = <String>[];
    final service = CodexPreloadService(
      connect: (_) async {},
      listAll: (_) async => [conversation('recent'), conversation('fav')],
      listRunning: (_) async => [conversation('running', running: true)],
      favorites: (_) => {'fav'},
      readConversation: (_, id) async {
        read.add(id);
        return [];
      },
    );
    await service.preloadConnection(connection);
    expect(read, ['running', 'fav', 'recent']);
  });

  test('deduplicates selected records, caps at six and isolates failures',
      () async {
    final read = <String>[];
    final items = List.generate(8, (i) => conversation('c$i'));
    final service = CodexPreloadService(
      connect: (_) async {},
      listAll: (_) async => items,
      listRunning: (_) async => [items.first],
      favorites: (_) => {'c0', 'c1'},
      readConversation: (_, id) async {
        read.add(id);
        if (id == 'c0') throw StateError('record failure');
        return [];
      },
    );
    await service.preloadConnection(connection);
    expect(read, ['c0', 'c1', 'c2', 'c3', 'c4', 'c5']);
  });

  test('continues preloading other hosts after a connection failure', () async {
    final connected = <String>[];
    final service = CodexPreloadService(
      connect: (host) async {
        if (host.id == 'bad') throw StateError('offline');
        connected.add(host.id);
      },
      listAll: (_) async => [],
      listRunning: (_) async => [],
      favorites: (_) => {},
      readConversation: (_, __) async => [],
    );
    final good = SshConnection(
      id: 'good',
      name: 'good',
      host: 'localhost',
      username: 'user',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    final bad = SshConnection(
      id: 'bad',
      name: 'bad',
      host: 'localhost',
      username: 'user',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await service.preloadConnections([bad, good]);
    expect(connected, ['good']);
  });

  test('does not add favorites after six running records fill the preload cap',
      () async {
    final running = List.generate(
      6,
      (i) => conversation('running-$i', running: true),
    );
    final extras = List.generate(3, (i) => conversation('extra-$i'));
    final read = <String>[];
    final service = CodexPreloadService(
      connect: (_) async {},
      listAll: (_) async => [...running, ...extras],
      listRunning: (_) async => running,
      favorites: (_) => {'extra-0', 'extra-1', 'extra-2'},
      readConversation: (_, id) async {
        read.add(id);
        return [];
      },
    );
    await service.preloadConnection(connection);
    expect(read, running.map((item) => item.id).toList());
    expect(read, hasLength(6));
  });

  test('limits host concurrency to two and merges same-host requests',
      () async {
    var active = 0, peak = 0, connects = 0;
    final gate = Completer<void>();
    final service = CodexPreloadService(
      connect: (_) async {
        connects++;
        active++;
        if (active > peak) peak = active;
        await gate.future;
        active--;
      },
      listAll: (_) async => [],
      listRunning: (_) async => [],
      favorites: (_) => {},
      readConversation: (_, __) async => [],
    );
    final same = service.preloadConnection(connection);
    final merged = service.preloadConnection(connection);
    final batch = service.preloadConnections(List.generate(
        4,
        (i) => SshConnection(
              id: 'h$i',
              name: 'h$i',
              host: 'localhost',
              username: 'user',
              createdAt: DateTime(2026),
              updatedAt: DateTime(2026),
            )));
    await Future<void>.delayed(Duration.zero);
    expect(peak, 2);
    gate.complete();
    await Future.wait([same, merged, batch]);
    expect(connects, 5);
  });

  test('transfers a freed host slot to a waiter before admitting new work',
      () async {
    final gates = <String, Completer<void>>{
      for (final id in ['a', 'b', 'c', 'd', 'e']) id: Completer<void>(),
    };
    var active = 0;
    var peak = 0;
    final service = CodexPreloadService(
      connect: (host) async {
        active++;
        if (active > peak) peak = active;
        await gates[host.id]!.future;
        active--;
      },
      listAll: (_) async => [],
      listRunning: (_) async => [],
      favorites: (_) => {},
      readConversation: (_, __) async => [],
    );
    SshConnection host(String id) => SshConnection(
          id: id,
          name: id,
          host: 'localhost',
          username: 'user',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );
    final requests = [
      service.preloadConnection(host('a')),
      service.preloadConnection(host('b')),
      service.preloadConnection(host('c')),
      service.preloadConnection(host('d')),
    ];
    await Future<void>.delayed(Duration.zero);
    gates['a']!.complete();
    final extra = service.preloadConnection(host('e'));
    await Future<void>.delayed(Duration.zero);
    expect(peak, 2);
    for (final gate in gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await Future.wait([...requests, extra]);
    expect(peak, 2);
  });
}
