import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'ssh_service.dart';

class RemoteHtmlPreviewService {
  static const maxFileBytes = 20 * 1024 * 1024;

  static List<String> references(String text) {
    final paths = <String>{};
    final candidates = <({int start, String value})>[];
    for (final match
        in RegExp(r'\[[^\]]*\]\((<[^>]+>|[^)]+)\)').allMatches(text)) {
      candidates.add((start: match.start, value: match.group(1)!));
    }
    for (final match in RegExp(r'`([^`]+)`').allMatches(text)) {
      candidates.add((start: match.start, value: match.group(1)!));
    }
    for (final match in RegExp(
      r'(?:^|\s)(/?[^\s<>"`]+\.html?)(?=\s|$|[，。,.])',
      caseSensitive: false,
      multiLine: true,
    ).allMatches(text)) {
      candidates.add((start: match.start, value: match.group(1)!));
    }
    candidates.sort((a, b) => a.start.compareTo(b.start));
    for (final candidate in candidates) {
      var path = candidate.value.trim();
      if (path.startsWith('<') && path.endsWith('>')) {
        path = path.substring(1, path.length - 1);
      }
      if (path.startsWith('http://') || path.startsWith('https://')) continue;
      final encoded = path.replaceAll(RegExp(r'%(?![0-9A-Fa-f]{2})'), '%25');
      try {
        path = encoded.startsWith('file://')
            ? Uri.parse(encoded).toFilePath()
            : Uri.decodeFull(encoded);
      } on ArgumentError {
        // 文件名中的非法转义不能使整条聊天回复变成错误组件。
      } on FormatException {
        // 同时保留原路径，供用户查看文件名。
      }
      path = path.split(RegExp(r'[?#]')).first;
      if (RegExp(r'\.html?$', caseSensitive: false).hasMatch(path)) {
        paths.add(path);
      }
    }
    return paths.take(3).toList();
  }

  static Future<RemoteHtmlPreviewServer> open({
    required String connectionId,
    required String workDir,
    required String path,
  }) async {
    final client = SshService.getClient(connectionId);
    if (client == null) throw StateError('SSH 连接已断开');
    final sftp = await client.sftp();
    try {
      final home = path.startsWith('~/') || workDir == '~'
          ? String.fromCharCodes(await client.run('printf %s "\$HOME"'))
          : '';
      final base = workDir == '~' ? home : workDir;
      final requested = path.startsWith('~/')
          ? '$home/${path.substring(2)}'
          : p.posix.isAbsolute(path)
              ? path
              : p.posix.join(base, path);
      final entry = await sftp.absolute(requested);
      final project = await sftp.absolute(base);
      final root = _within(entry, project) ? project : p.posix.dirname(entry);
      return await RemoteHtmlPreviewServer.start(
        root: root,
        entry: entry,
        canonicalize: sftp.absolute,
        readFile: (filePath) async {
          final attrs = await sftp.stat(filePath);
          if (attrs.size != null && attrs.size! > maxFileBytes) {
            throw const HttpException('文件超过 20 MB');
          }
          final file = await sftp.open(filePath);
          try {
            final bytes = await file.readBytes(
              length: attrs.size ?? maxFileBytes + 1,
            );
            if (bytes.length > maxFileBytes) {
              throw const HttpException('文件超过 20 MB');
            }
            return bytes;
          } finally {
            await file.close();
          }
        },
        onClose: sftp.close,
      );
    } catch (_) {
      sftp.close();
      rethrow;
    }
  }

  static bool _within(String path, String root) =>
      path == root || p.posix.isWithin(root, path);
}

class RemoteHtmlPreviewServer {
  final HttpServer _server;
  final String root;
  final String entry;
  final String _token;
  final Future<String> Function(String) _canonicalize;
  final Future<Uint8List> Function(String) _readFile;
  final void Function()? _onClose;

  RemoteHtmlPreviewServer._(
    this._server,
    this.root,
    this.entry,
    this._token,
    this._canonicalize,
    this._readFile,
    this._onClose,
  );

  static Future<RemoteHtmlPreviewServer> start({
    required String root,
    required String entry,
    required Future<String> Function(String) canonicalize,
    required Future<Uint8List> Function(String) readFile,
    void Function()? onClose,
  }) async {
    if (entry != root && !p.posix.isWithin(root, entry)) {
      throw ArgumentError('HTML 文件不在允许的目录中');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List.generate(
            24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
        .join();
    final preview = RemoteHtmlPreviewServer._(
        server, root, entry, token, canonicalize, readFile, onClose);
    unawaited(preview._serve());
    return preview;
  }

  Uri get url => Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: _server.port,
        pathSegments: [
          _token,
          ...p.posix.relative(entry, from: root).split('/')
        ],
      );

  bool allowsNavigation(Uri target) =>
      target.scheme == 'http' &&
      target.host == '127.0.0.1' &&
      target.port == _server.port;

  Future<void> _serve() async {
    await for (final request in _server) {
      unawaited(_handle(request));
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.set('Referrer-Policy', 'no-referrer');
    try {
      final segments = request.uri.pathSegments;
      final hasToken = segments.isNotEmpty && segments.first == _token;
      final hasCookie = request.cookies
          .any((cookie) => cookie.name == 'preview' && cookie.value == _token);
      if (request.method != 'GET' || (!hasToken && !hasCookie)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (hasToken) {
        response.headers.add(HttpHeaders.setCookieHeader,
            'preview=$_token; HttpOnly; SameSite=Strict; Path=/');
      }
      final requested =
          p.posix.joinAll([root, ...(hasToken ? segments.skip(1) : segments)]);
      final canonical = await _canonicalize(requested);
      if (canonical != root && !p.posix.isWithin(root, canonical)) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final bytes = await _readFile(canonical);
      response.headers.contentType = _contentType(canonical);
      response.add(bytes);
    } on HttpException {
      response.statusCode = HttpStatus.requestEntityTooLarge;
    } catch (_) {
      response.statusCode = HttpStatus.notFound;
    } finally {
      await response.close();
    }
  }

  static ContentType _contentType(String path) =>
      switch (p.posix.extension(path).toLowerCase()) {
        '.html' || '.htm' => ContentType.html,
        '.css' => ContentType('text', 'css', charset: 'utf-8'),
        '.js' || '.mjs' => ContentType('text', 'javascript', charset: 'utf-8'),
        '.json' => ContentType.json,
        '.svg' => ContentType('image', 'svg+xml'),
        '.png' => ContentType('image', 'png'),
        '.jpg' || '.jpeg' => ContentType('image', 'jpeg'),
        '.gif' => ContentType('image', 'gif'),
        '.webp' => ContentType('image', 'webp'),
        '.woff' => ContentType('font', 'woff'),
        '.woff2' => ContentType('font', 'woff2'),
        '.wasm' => ContentType('application', 'wasm'),
        _ => ContentType.binary,
      };

  Future<void> close() async {
    await _server.close(force: true);
    _onClose?.call();
  }
}
