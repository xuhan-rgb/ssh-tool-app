import 'package:flutter/material.dart';

import '../services/codex_user_input_service.dart';
import 'codex_user_input_panel.dart';

class CodexQuestionListener extends StatefulWidget {
  final String connectionId, threadId;
  const CodexQuestionListener(
      {super.key, required this.connectionId, required this.threadId});

  @override
  State<CodexQuestionListener> createState() => _CodexQuestionListenerState();
}

class _CodexQuestionListenerState extends State<CodexQuestionListener> {
  late CodexUserInputService _service;

  void _start() {
    _service = CodexUserInputService(widget.connectionId, widget.threadId);
    _service.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(CodexQuestionListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connectionId != widget.connectionId ||
        oldWidget.threadId != widget.threadId) {
      _service.removeListener(_refresh);
      _service.dispose();
      _start();
    }
  }

  @override
  void dispose() {
    _service.removeListener(_refresh);
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = _service.pending;
    if (pending.isEmpty) return const SizedBox.shrink();
    // One request contains all questions; remaining requests follow after submission.
    final request = pending.first;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (_service.error != null)
        const Text('问题同步正在重连，已选择的答案会保留', style: TextStyle(fontSize: 12)),
      CodexUserInputPanel(
        key: ValueKey(
            '${widget.threadId}-${CodexUserInputService.requestKey(request['id'])}'),
        request: request,
        onSubmit: (answers) => _service.submit(request, answers),
      ),
    ]);
  }
}
