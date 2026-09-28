import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/remote_html_preview_service.dart';

class RemoteHtmlPreviewScreen extends StatefulWidget {
  final String connectionId;
  final String workDir;
  final String path;

  const RemoteHtmlPreviewScreen({
    super.key,
    required this.connectionId,
    required this.workDir,
    required this.path,
  });

  @override
  State<RemoteHtmlPreviewScreen> createState() =>
      _RemoteHtmlPreviewScreenState();
}

class _RemoteHtmlPreviewScreenState extends State<RemoteHtmlPreviewScreen> {
  RemoteHtmlPreviewServer? _preview;
  WebViewController? _controller;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      final preview = await RemoteHtmlPreviewService.open(
        connectionId: widget.connectionId,
        workDir: widget.workDir,
        path: widget.path,
      );
      if (!mounted) {
        await preview.close();
        return;
      }
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..setNavigationDelegate(NavigationDelegate(
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (mounted && error.isForMainFrame == true) {
              setState(() => _error = error.description);
            }
          },
          onNavigationRequest: (request) =>
              preview.allowsNavigation(Uri.parse(request.url))
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent,
        ));
      setState(() {
        _preview = preview;
        _controller = controller;
      });
      await controller.loadRequest(preview.url);
    } catch (error) {
      if (mounted) setState(() => _error = '无法预览远端 HTML：$error');
    }
  }

  @override
  void dispose() {
    final preview = _preview;
    if (preview != null) unawaited(preview.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(widget.path.split('/').last),
          actions: [
            IconButton(
              tooltip: '刷新预览',
              onPressed: _controller == null
                  ? null
                  : () {
                      setState(() {
                        _error = null;
                        _loading = true;
                      });
                      unawaited(_controller!.reload());
                    },
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: _error != null
            ? Center(child: Text(_error!, textAlign: TextAlign.center))
            : _controller == null
                ? const Center(child: CircularProgressIndicator())
                : Stack(children: [
                    WebViewWidget(controller: _controller!),
                    if (_loading)
                      const Center(child: CircularProgressIndicator()),
                  ]),
      );
}
