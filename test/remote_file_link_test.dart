import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/screens/remote_file_preview_screen.dart';
import 'package:ssh_tool_app/services/remote_file_service.dart';
import 'package:ssh_tool_app/widgets/chat_markdown.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

void main() {
  test('relative paths resolve against conversation or document directory', () {
    expect(
        RemoteFileService.resolvePath(
            workDir: '/project', path: 'build/frame/rgb.png'),
        '/project/build/frame/rgb.png');
    expect(
        RemoteFileService.resolvePath(
            workDir: '/project/docs', path: '../build/rgb.png'),
        '/project/build/rgb.png');
    expect(
        RemoteFileService.resolvePath(
            workDir: '/project', path: '/tmp/rgb.png'),
        '/tmp/rgb.png');
    expect(
        RemoteFileService.resolvePath(
            workDir: '~/project', path: 'rgb.png', home: '/home/user'),
        '/home/user/project/rgb.png');
  });

  test('home-relative document directory is preserved until SSH resolves it',
      () {
    expect(RemoteFileService.resolvePath(workDir: '~', path: 'docs/report.md'),
        '~/docs/report.md');
  });

  testWidgets('Markdown file renders and nested links use its directory',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: RemoteFilePreviewScreen(
      connectionId: '',
      workDir: '/project',
      path: 'docs/report.md',
      readFile: () async =>
          Uint8List.fromList(utf8.encode('# 验证记录\n[最终成像](../build/rgb.png)')),
    )));
    await tester.pumpAndSettle();
    expect(find.text('验证记录'), findsOneWidget);
    final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    body.onTapLink!('最终成像', '../build/rgb.png', '');
    await tester.pumpAndSettle();
    final previews = tester.widgetList<RemoteFilePreviewScreen>(
        find.byType(RemoteFilePreviewScreen));
    expect(previews.last.workDir, '/project/docs');
    expect(previews.last.path, '../build/rgb.png');
    expect(find.textContaining('SSH 连接已断开'), findsOneWidget);
  });

  testWidgets('image bytes render in a zoomable preview', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: RemoteFilePreviewScreen(
      connectionId: '',
      workDir: '/project',
      path: 'rgb.png',
      readFile: () async => base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='),
    )));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('file read failure is visible and retry reloads', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
        home: RemoteFilePreviewScreen(
      connectionId: '',
      workDir: '/project',
      path: 'docs/report.md',
      readFile: () async {
        if (++attempts == 1) throw StateError('文件不存在');
        return Uint8List.fromList(utf8.encode('读取成功'));
      },
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('文件不存在'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('读取成功'), findsOneWidget);
    expect(attempts, 2);
  });

  for (final href in [
    'file:///tmp/rgb.png',
    '/tmp/%E6%9C%80%E7%BB%88%20rgb.png',
    'build/rgb.png#preview'
  ]) {
    testWidgets('local file URI is decoded: $href', (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                    body: ChatMarkdown('[打开]($href)',
                        onTapLink: (_, target, __) => openRemoteFileLink(
                            context,
                            connectionId: '',
                            workDir: '/project',
                            href: target)),
                  ))));
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      final screen = tester.widget<RemoteFilePreviewScreen>(
          find.byType(RemoteFilePreviewScreen));
      expect(
          screen.path,
          href.startsWith('file:')
              ? '/tmp/rgb.png'
              : href.startsWith('/tmp')
                  ? '/tmp/最终 rgb.png'
                  : 'build/rgb.png');
    });
  }

  testWidgets('conversation file links have an open handler', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: CodexConversationViewerDialog(
      connectionId: '',
      conversation: const CodexConversation(
          id: 'files', cwd: '/project', updatedAt: null, title: '结果'),
      loadRecords: (_) async => const [
        CodexConversationRecord(
            kind: 'assistant',
            timestamp: null,
            text:
                '[查看最终成像](build/verification/source-rgb-scenes/underground/source_rgb_final/frame_000000/rgb.png) · [查看完整验证记录](docs/underground-imaging-investigation-20260929.md)')
      ],
    )));
    await tester.pump();
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.onTapLink, isNotNull);
    markdown.onTapLink!(
        '查看最终成像',
        'build/verification/source-rgb-scenes/underground/source_rgb_final/frame_000000/rgb.png',
        '');
    await tester.pumpAndSettle();
    expect(find.textContaining('SSH 连接已断开'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    markdown.onTapLink!(
        '查看完整验证记录', 'docs/underground-imaging-investigation-20260929.md', '');
    await tester.pumpAndSettle();
    final document = tester
        .widget<RemoteFilePreviewScreen>(find.byType(RemoteFilePreviewScreen));
    expect(document.workDir, '/project');
    expect(document.path, 'docs/underground-imaging-investigation-20260929.md');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
