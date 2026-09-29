import 'dart:typed_data';
import 'package:path/path.dart' as p;
import 'ssh_service.dart';

class RemoteFileService {
  static String resolvePath(
      {required String workDir, required String path, String home = '~'}) {
    final base = workDir == '~'
        ? home
        : workDir.startsWith('~/')
            ? '$home/${workDir.substring(2)}'
            : workDir;
    return p.posix.normalize(path.startsWith('~/')
        ? '$home/${path.substring(2)}'
        : p.posix.isAbsolute(path)
            ? path
            : p.posix.join(base, path));
  }

  static Future<Uint8List> read({
    required String connectionId,
    required String workDir,
    required String path,
    int maxBytes = 8 * 1024 * 1024,
    String tooLargeMessage = '文件超过 8 MB，无法预览',
  }) async {
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');

    var home = '';
    if (path.startsWith('~/') || workDir == '~' || workDir.startsWith('~/')) {
      home = String.fromCharCodes(await client.run('printf %s "\$HOME"'));
    }
    final absolutePath = resolvePath(workDir: workDir, path: path, home: home);

    final sftp = await client.sftp();
    try {
      final attrs = await sftp.stat(absolutePath);
      if (attrs.size != null && attrs.size! > maxBytes) {
        throw StateError(tooLargeMessage);
      }
      final file = await sftp.open(absolutePath);
      try {
        final bytes = await file.readBytes(
          length: attrs.size ?? maxBytes + 1,
        );
        if (bytes.length > maxBytes) {
          throw StateError(tooLargeMessage);
        }
        return bytes;
      } finally {
        await file.close();
      }
    } finally {
      sftp.close();
    }
  }
}
