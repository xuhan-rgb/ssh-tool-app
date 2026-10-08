import 'dart:math' as math;

import 'package:flutter/material.dart';

class CodexUserInputPanel extends StatefulWidget {
  final Map<String, dynamic> request;
  final Future<void> Function(Map<String, List<String>> answers) onSubmit;

  const CodexUserInputPanel({
    super.key,
    required this.request,
    required this.onSubmit,
  });

  @override
  State<CodexUserInputPanel> createState() => _CodexUserInputPanelState();
}

class _CodexUserInputPanelState extends State<CodexUserInputPanel> {
  final Map<String, String> _selected = {};
  final Map<String, TextEditingController> _text = {};
  bool _busy = false;
  String? _error;

  List<Map<String, dynamic>> get _questions =>
      ((widget.request['params'] as Map?)?['questions'] as List? ?? const [])
          .whereType<Map>()
          .map((question) => Map<String, dynamic>.from(question))
          .toList();

  TextEditingController _controller(String id) =>
      _text.putIfAbsent(id, TextEditingController.new);

  bool _hasAnswer(Map<String, dynamic> question) {
    final id = question['id']?.toString() ?? '';
    final selected = _selected[id];
    if (selected == null) return _controller(id).text.trim().isNotEmpty;
    if (selected == '__other__') {
      return _controller('$id-other').text.trim().isNotEmpty;
    }
    return true;
  }

  bool get _allAnswered => _questions.every(_hasAnswer);

  Future<void> _submit() async {
    if (_busy) return;
    final questions = _questions;
    if (!questions.every(_hasAnswer)) {
      setState(() => _error = '请回答所有问题');
      return;
    }
    final answers = <String, List<String>>{};
    for (final question in questions) {
      final id = question['id']?.toString() ?? '';
      final selected = _selected[id];
      answers[id] = [
        selected == null || selected == '__other__'
            ? _controller(selected == '__other__' ? '$id-other' : id)
                .text
                .trim()
            : selected,
      ];
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(answers);
    } catch (error) {
      if (mounted) setState(() => _error = '提交失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final questions = _questions;
    final availableHeight = MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;
    final questionMaxHeight =
        math.min(320.0, math.max(0.0, availableHeight * 0.4));
    return Card(
      key: const ValueKey('codex-user-input-panel'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: questionMaxHeight),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final question in questions) _buildQuestion(question),
                  ],
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    key: const ValueKey('codex-user-input-error'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                key: const ValueKey('codex-user-input-submit'),
                onPressed: _busy || !_allAnswered ? null : _submit,
                child: Text(_busy ? '提交中…' : '提交'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuestion(Map<String, dynamic> question) {
    final id = question['id']?.toString() ?? '';
    final options = (question['options'] as List? ?? const [])
        .whereType<Map>()
        .map((option) => Map<String, dynamic>.from(option))
        .toList();
    final obscure = question['isSecret'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(question['question']?.toString() ?? '',
              style:
                  const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          if (options.isEmpty)
            TextField(
              key: ValueKey('codex-user-input-$id'),
              controller: _controller(id),
              obscureText: obscure,
              enabled: !_busy,
              decoration: const InputDecoration(isDense: true),
              onChanged: (_) => setState(() {}),
            )
          else ...[
            for (final option in options)
              Material(
                  color: _selected[id] == option['label'].toString()
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: _busy
                        ? null
                        : () => setState(
                            () => _selected[id] = option['label'].toString()),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            _selected[id] == option['label'].toString()
                                ? Icons.radio_button_checked
                                : Icons.radio_button_unchecked,
                            size: 20,
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(option['label']?.toString() ?? '',
                                      style: const TextStyle(fontSize: 14)),
                                  if ((option['description']?.toString() ?? '')
                                      .isNotEmpty)
                                    Text(option['description'].toString(),
                                        style: const TextStyle(fontSize: 12)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )),
            if (question['isOther'] == true) ...[
              InkWell(
                onTap: _busy
                    ? null
                    : () => setState(() => _selected[id] = '__other__'),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      Icon(
                        _selected[id] == '__other__'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      const Text('其他', style: TextStyle(fontSize: 14)),
                    ]),
                  ),
                ),
              ),
              if (_selected[id] == '__other__')
                TextField(
                  key: ValueKey('codex-user-input-$id-other'),
                  controller: _controller('$id-other'),
                  obscureText: obscure,
                  enabled: !_busy,
                  decoration: const InputDecoration(isDense: true),
                  onChanged: (_) => setState(() {}),
                ),
            ],
          ],
        ],
      ),
    );
  }
}
