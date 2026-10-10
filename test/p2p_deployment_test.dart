import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/p2p_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'verified agent is reused on repeated connections without opening a file',
      () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler(
            'flutter/assets', (_) async => ByteData.sublistView(bytes));
    rootBundle.evict('assets/p2p/agent-linux-amd64');
    try {
      final digest = sha256.convert(bytes).toString();
      final sftp = _CachedAgentSftp();
      final client = _CachedAgentClient(digest, sftp);
      final first = await P2pService.deployAgent(client, connectionId: 'cached-test');
      expect(P2pService.progressNotifier.value['cached-test'], '已找到辅助程序，正在复用…');
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
      final invalid = _CachedAgentClient(digest, sftp, invalidDigest: true);
      await expectLater(
          P2pService.deployAgent(invalid), throwsA(isA<StateError>()));
      expect(invalid.checkCalls, 1);
      expect(invalid.sftpCalls, 1);
      expect(sftp.openCalls, 1);
    } finally {
      P2pService.progressNotifier.value = {};
      rootBundle.evict('assets/p2p/agent-linux-amd64');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMessageHandler('flutter/assets', null);
    }
  });
}

class _CachedAgentClient extends Fake implements SSHClient {
  final String digest;
  final _CachedAgentSftp fileClient;
  int checkCalls = 0;
  int sftpCalls = 0;
  final String homeHint;
  final bool invalidDigest;
  _CachedAgentClient(this.digest, this.fileClient,
      {this.homeHint = '/home/test', this.invalidDigest = false});
  @override
  Future<Uint8List> run(String command,
      {bool runInPty = false,
      bool stdout = true,
      bool stderr = true,
      Map<String, String>? environment}) async {
    if (command.startsWith('uname'))
      return Uint8List.fromList(utf8
          .encode('Linux\nx86_64\n100.1.1.1 12345 100.2.2.2 22\n$homeHint\n'));
    if (command.startsWith('test -x')) {
      checkCalls++;
      if (invalidDigest || command.contains('/missing/'))
        return Uint8List.fromList(utf8.encode('wrong-digest  missing'));
      return Uint8List.fromList(
          utf8.encode('$digest  /home/test/.ssh_tool/p2p/agent-$digest'));
    }
    if (command.startsWith('umask')) return Uint8List(0);
    throw StateError('Unexpected deployment command');
  }

  @override
  Future<SftpClient> sftp() async {
    sftpCalls++;
    return fileClient;
  }
}

class _CachedAgentSftp extends Fake implements SftpClient {
  int openCalls = 0;
  @override
  Future<String> absolute(String path) async => '/home/test';
  @override
  Future<SftpFile> open(String path,
      {SftpFileOpenMode mode = SftpFileOpenMode.read,
      SftpFileAttrs? attrs}) async {
    openCalls++;
    throw StateError('Cached helper must not be uploaded');
  }

  @override
  Future<void> close() async {}
  @override
  Future<void> remove(String path) async {}
}
