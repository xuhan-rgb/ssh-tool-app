import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:ssh_tool_app/services/remote_html_preview_service.dart';

void main() {
  test('malformed percent escapes in a reply do not break HTML detection', () {
    expect(
      RemoteHtmlPreviewService.references(
          '图片完成度 100%：`/project/100%完成图.png`，另有 `site/50%完成.html`'),
      ['site/50%完成.html'],
    );
  });

  test('recognizes local HTML paths without treating web links as local files',
      () {
    expect(
      RemoteHtmlPreviewService.references('''
已完成：`/project/site/index.html`
[查看交互页面](site/chart.htm)
https://example.com/demo.html
'''),
      ['/project/site/index.html', 'site/chart.htm'],
    );
  });

  test('serves relative assets and blocks paths outside the project', () async {
    final files = {
      '/project/site/index.html': '<link rel="stylesheet" href="style.css">',
      '/project/site/style.css': 'body { color: red; }',
      '/project/assets/logo.svg': '<svg></svg>',
    };
    final preview = await RemoteHtmlPreviewServer.start(
      root: '/project',
      entry: '/project/site/index.html',
      canonicalize: (path) async => p.posix.normalize(path),
      readFile: (path) async {
        final content = files[path];
        if (content == null) throw const FileSystemException('missing');
        return Uint8List.fromList(content.codeUnits);
      },
    );
    addTearDown(preview.close);
    final client = HttpClient();
    addTearDown(client.close);

    Future<HttpClientResponse> get(Uri url) async =>
        (await client.getUrl(url)).close();
    final html = await get(preview.url);
    expect(html.statusCode, HttpStatus.ok);
    expect(html.headers.contentType!.mimeType, 'text/html');
    expect(await html.transform(utf8.decoder).join(), contains('style.css'));

    final css = await get(preview.url.resolve('style.css'));
    expect(css.statusCode, HttpStatus.ok);
    expect(css.headers.contentType!.mimeType, 'text/css');
    expect(await css.transform(utf8.decoder).join(), contains('color: red'));

    final rootAsset = preview.url.replace(path: '/assets/logo.svg');
    expect((await get(rootAsset)).statusCode, HttpStatus.forbidden);
    final authorized = await client.getUrl(rootAsset);
    authorized.cookies.addAll(html.cookies);
    final svg = await authorized.close();
    expect(svg.statusCode, HttpStatus.ok);
    expect(svg.headers.contentType!.mimeType, 'image/svg+xml');
    await svg.drain<void>();

    final outside = await get(preview.url.resolve('../../../secret.txt'));
    expect(outside.statusCode, HttpStatus.forbidden);
    expect(
        preview.allowsNavigation(Uri.parse('https://example.com/')), isFalse);
  });
}
