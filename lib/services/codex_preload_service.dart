import 'dart:async';
import 'dart:collection';

import '../models/ssh_connection.dart';
import 'codex_session_service.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

/// Loads Codex data into the shared session cache before a connection is opened.
class CodexPreloadService {
  CodexPreloadService({
    Future<void> Function(SshConnection)? connect,
    Future<List<CodexConversation>> Function(String)? listAll,
    Future<List<CodexConversation>> Function(String)? listRunning,
    Set<String> Function(String)? favorites,
    Future<List<CodexConversationRecord>> Function(String, String)?
        readConversation,
  })  : _connect = connect ?? _connectDefault,
        _listAll = listAll ?? CodexSessionService.listAll,
        _listRunning = listRunning ?? CodexSessionService.listRunning,
        _favorites = favorites ?? StorageService.getFavoriteCodexConversations,
        _readConversation =
            readConversation ?? CodexSessionService.readConversation;

  final Future<void> Function(SshConnection) _connect;
  final Future<List<CodexConversation>> Function(String) _listAll;
  final Future<List<CodexConversation>> Function(String) _listRunning;
  final Set<String> Function(String) _favorites;
  final Future<List<CodexConversationRecord>> Function(String, String)
      _readConversation;
  final Map<String, Future<void>> _inFlight = {};
  int _activeHosts = 0;
  final Queue<Completer<void>> _hostWaiters = Queue<Completer<void>>();

  static Future<void> _connectDefault(SshConnection connection) async {
    await SshService.connectClient(connection);
  }

  Future<void> preloadConnections(Iterable<SshConnection> connections) async {
    final pending = List<SshConnection>.of(connections);
    var next = 0;
    Future<void> worker() async {
      while (next < pending.length) {
        final connection = pending[next++];
        try {
          await preloadConnection(connection);
        } catch (_) {
          // One unavailable host must not stop the remaining hosts.
        }
      }
    }

    await Future.wait(List.generate(
      pending.length.clamp(0, 2),
      (_) => worker(),
    ));
  }

  Future<void> preloadConnection(SshConnection connection) {
    final existing = _inFlight[connection.id];
    if (existing != null) return existing;
    late final Future<void> request;
    request = _withHostSlot(() => _preload(connection)).whenComplete(() {
      if (identical(_inFlight[connection.id], request)) {
        _inFlight.remove(connection.id);
      }
    });
    _inFlight[connection.id] = request;
    return request;
  }

  Future<void> _withHostSlot(Future<void> Function() action) async {
    if (_activeHosts >= 2) {
      final waiter = Completer<void>();
      _hostWaiters.add(waiter);
      await waiter.future;
    } else {
      _activeHosts++;
    }
    try {
      await action();
    } finally {
      if (_hostWaiters.isNotEmpty) {
        _hostWaiters.removeFirst().complete();
      } else {
        _activeHosts--;
      }
    }
  }

  Future<void> _preload(SshConnection connection) async {
    await _connect(connection);
    final results = await Future.wait([
      _listAll(connection.id).then<Object>((value) => value,
          onError: (_) => <CodexConversation>[]),
      _listRunning(connection.id).then<Object>((value) => value,
          onError: (_) => <CodexConversation>[]),
    ]);
    final all = results[0] as List<CodexConversation>;
    final running = results[1] as List<CodexConversation>;
    final byId = <String, CodexConversation>{};
    for (final item in [...running, ...all]) {
      byId.putIfAbsent(item.id, () => item);
    }
    final selected = <String>[];
    void add(Iterable<CodexConversation> candidates) {
      if (selected.length >= 6) return;
      for (final item in candidates) {
        if (!selected.contains(item.id) && byId.containsKey(item.id)) {
          selected.add(item.id);
          if (selected.length >= 6) return;
        }
      }
    }

    add(running);
    final favoriteIds = _favorites(connection.id);
    add(all.where((item) => favoriteIds.contains(item.id)));
    add(all);

    var next = 0;
    Future<void> readWorker() async {
      while (next < selected.length) {
        final id = selected[next++];
        try {
          await _readConversation(connection.id, id);
        } catch (_) {
          // A corrupt or removed record must not block the other records.
        }
      }
    }

    await Future.wait(
        List.generate(selected.length.clamp(0, 2), (_) => readWorker()));
  }
}
