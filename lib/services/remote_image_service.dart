import 'dart:typed_data';

import 'ssh_service.dart';

class RemoteImageReference {
  const RemoteImageReference(this.path, this.end, {this.embedded = false});

  final String path;
  final int end;
  final bool embedded;
}

class RemoteImageService {
  static const maxImageBytes = 8 * 1024 * 1024;
  static final _imageExtension =
      RegExp(r'\.(?:png|jpe?g|gif|webp)$', caseSensitive: false);

  static List<String> references(String text) =>
      inlineReferences(text).map((reference) => reference.path).toList();

  static List<RemoteImageReference> inlineReferences(String text) {
    final references = <RemoteImageReference>[];
    final seen = <String>{};
    final candidates = <({int start, int end, String value, bool embedded})>[];

    void add(String value, int end, bool embedded) {
      var path = value.trim();
      if (path.startsWith('<') && path.endsWith('>')) {
        path = path.substring(1, path.length - 1);
      }
      if (path.startsWith('http://') || path.startsWith('https://')) return;
      final encoded =
          path.replaceAll(RegExp(r'%(?![0-9A-Fa-f]{2})'), '%25');
      try {
        path = encoded.startsWith('file://')
            ? Uri.parse(encoded).toFilePath()
            : Uri.decodeFull(encoded);
      } on ArgumentError {
        // 远端文件名可能包含不完整的转义；保留原路径供 SFTP 读取。
      } on FormatException {
        // 非法 UTF-8 转义也不应导致整条回复无法渲染。
      }
      if (_imageExtension.hasMatch(path) && seen.add(path)) {
        references.add(RemoteImageReference(path, end, embedded: embedded));
      }
    }

    for (final match
        in RegExp(r'!?\[[^\]]*\]\((<[^>]+>|[^)]+)\)').allMatches(text)) {
      candidates.add(
          (start: match.start, end: match.end, value: match.group(1)!,
           embedded: match.group(0)!.startsWith('!')));
    }
    for (final match in RegExp(r'`([^`]+)`').allMatches(text)) {
      candidates.add(
          (start: match.start, end: match.end, value: match.group(1)!,
           embedded: false));
    }
    for (final match in RegExp(
      r'(?:^|\s)(/[^\s<>"`]+\.(?:png|jpe?g|gif|webp))(?=\s|$|[，。,.])',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(text)) {
      candidates.add(
          (start: match.start, end: match.end, value: match.group(1)!,
           embedded: false));
    }
    candidates.sort((a, b) => a.start.compareTo(b.start));
    var lastEnd = 0;
    for (final candidate in candidates) {
      if (candidate.start < lastEnd) continue;
      add(candidate.value, candidate.end, candidate.embedded);
      if (references.isNotEmpty && references.last.end == candidate.end) {
        lastEnd = candidate.end;
      }
    }
    return references;
  }

  static Future<Uint8List> read({
    required String connectionId,
    required String workDir,
    required String path,
  }) async {
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');

    var home = '';
    if (path.startsWith('~/') || workDir == '~') {
      home = String.fromCharCodes(await client.run('printf %s "\$HOME"'));
    }
    final base = workDir == '~' ? home : workDir;
    final absolutePath = path.startsWith('~/')
        ? '$home/${path.substring(2)}'
        : path.startsWith('/')
            ? path
            : '$base/$path';

    final sftp = await client.sftp();
    try {
      final attrs = await sftp.stat(absolutePath);
      if (attrs.size != null && attrs.size! > maxImageBytes) {
        throw StateError('图片超过 8 MB，无法预览');
      }
      final file = await sftp.open(absolutePath);
      try {
        final bytes = await file.readBytes(
          length: attrs.size ?? maxImageBytes + 1,
        );
        if (bytes.length > maxImageBytes) {
          throw StateError('图片超过 8 MB，无法预览');
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
