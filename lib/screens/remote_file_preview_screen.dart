import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/remote_file_service.dart';
import '../widgets/chat_markdown.dart';
import 'remote_html_preview_screen.dart';

void openRemoteFileLink(
  BuildContext context, {
  required String connectionId,
  required String workDir,
  required String? href,
}) {
  if (href == null || href.isEmpty) return;
  try {
    final uri =
        Uri.parse(href.replaceAll(RegExp(r'%(?![0-9A-Fa-f]{2})'), '%25'));
    if ((uri.hasScheme && uri.scheme != 'file') ||
        (uri.hasAuthority && uri.authority.isNotEmpty)) {
      throw const FormatException('此处仅支持预览远程文件链接');
    }
    final path = Uri.decodeComponent(uri.path);
    final extension = p.posix.extension(path).toLowerCase();
    if (![
      '.png',
      '.jpg',
      '.jpeg',
      '.gif',
      '.webp',
      '.md',
      '.markdown',
      '.txt',
      '.html',
      '.htm'
    ].contains(extension)) {
      throw const FormatException('暂不支持预览此文件类型');
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => extension == '.html' || extension == '.htm'
          ? RemoteHtmlPreviewScreen(
              connectionId: connectionId, workDir: workDir, path: path)
          : RemoteFilePreviewScreen(
              connectionId: connectionId, workDir: workDir, path: path),
    ));
  } on FormatException catch (error) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(error.message)));
  }
}

class RemoteFilePreviewScreen extends StatefulWidget {
  const RemoteFilePreviewScreen(
      {super.key,
      required this.connectionId,
      required this.workDir,
      required this.path,
      this.readFile});

  final String connectionId;
  final String workDir;
  final String path;
  final Future<Uint8List> Function()? readFile;

  @override
  State<RemoteFilePreviewScreen> createState() =>
      _RemoteFilePreviewScreenState();
}

class _RemoteFilePreviewScreenState extends State<RemoteFilePreviewScreen> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _read();
  }

  Future<Uint8List> _read() =>
      widget.readFile?.call() ??
      RemoteFileService.read(
          connectionId: widget.connectionId,
          workDir: widget.workDir,
          path: widget.path);

  @override
  Widget build(BuildContext context) {
    final extension = p.posix.extension(widget.path).toLowerCase();
    final isText = ['.md', '.markdown', '.txt'].contains(extension);
    return Scaffold(
      appBar: AppBar(title: Text(p.posix.basename(widget.path))),
      body: FutureBuilder<Uint8List>(
          future: _bytes,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('无法打开远程文件'),
                          const SizedBox(height: 8),
                          SelectableText(widget.path),
                          Text('${snapshot.error}'),
                          TextButton(
                              onPressed: () => setState(() {
                                    _bytes = _read();
                                  }),
                              child: const Text('重试')),
                        ],
                      )));
            }
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            if (isText) {
              final text = utf8.decode(snapshot.data!, allowMalformed: true);
              return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: extension == '.txt'
                      ? SelectableText(text)
                      : ChatMarkdown(
                          text,
                          onTapLink: (_, href, __) => openRemoteFileLink(
                              context,
                              connectionId: widget.connectionId,
                              workDir: p.posix.dirname(
                                  RemoteFileService.resolvePath(
                                      workDir: widget.workDir,
                                      path: widget.path)),
                              href: href),
                        ));
            }
            return SizedBox.expand(
                child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 8,
              child: Image.memory(snapshot.data!,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) =>
                      const Center(child: Text('图片格式无法预览'))),
            ));
          }),
    );
  }
}
