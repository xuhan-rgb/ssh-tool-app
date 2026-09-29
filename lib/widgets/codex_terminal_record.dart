import 'package:flutter/material.dart';

import '../services/codex_session_service.dart';
import '../theme/app_theme.dart';

/// A compact terminal entry; raw records remain available in the full log.
class CodexTerminalRecord extends StatefulWidget {
  const CodexTerminalRecord({super.key, required this.record});
  final CodexConversationRecord record;

  @override
  State<CodexTerminalRecord> createState() => _CodexTerminalRecordState();
}

class _CodexTerminalRecordState extends State<CodexTerminalRecord> {
  bool _expanded = false;

  String _lineText(String line) =>
      line.replaceFirst(RegExp(r'^\*\*\* (?:Update|Add|Delete) File: '), '└ ');

  TextStyle _lineStyle(String line) => TextStyle(
      fontFamily: 'monospace',
      fontSize: 11,
      color: line.startsWith('+')
          ? AppTheme.green
          : line.startsWith('-')
              ? AppTheme.red
              : AppTheme.textSecondary);

  @override
  Widget build(BuildContext context) {
    final summary = widget.record.terminalSummary ?? widget.record.text;
    final failed =
        summary.startsWith('Failed') || widget.record.kind == 'turn_aborted';
    final details = widget.record.terminalDetails ?? '';
    final lines = details
        .split('\n')
        .where((line) =>
            !line.startsWith('*** Begin Patch') &&
            !line.startsWith('*** End Patch'))
        .toList();
    final fileStarts = <int>[
      for (var i = 0; i < lines.length; i++)
        if (RegExp(r'^\*\*\* (?:Update|Add|Delete) File: ').hasMatch(lines[i]))
          i,
    ];
    final preview = fileStarts.isEmpty ? lines.take(5).toList() : <String>[];
    for (var file = 0; file < fileStarts.length; file++) {
      final end =
          file + 1 < fileStarts.length ? fileStarts[file + 1] : lines.length;
      preview.add(lines[fileStarts[file]]);
      final changes = lines
          .sublist(fileStarts[file] + 1, end)
          .where((line) =>
              (line.startsWith('+') && !line.startsWith('+++')) ||
              (line.startsWith('-') && !line.startsWith('---')))
          .toList();
      preview.addAll(changes.take(4));
      if (changes.length > 4) preview.add('  ⋮');
    }
    final visible = _expanded ? lines : preview;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minWidth: constraints.maxWidth),
                    child: IntrinsicWidth(
                        child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('• ',
                                  style: TextStyle(
                                      color: failed
                                          ? AppTheme.red
                                          : AppTheme.green)),
                              Expanded(
                                  child: Text(summary,
                                      softWrap: false,
                                      style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w600,
                                          color: failed
                                              ? AppTheme.red
                                              : AppTheme.textPrimary,
                                          fontSize: 12))),
                            ]),
                        if (details.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          for (var index = 0; index < visible.length; index++)
                            Container(
                              width: double.infinity,
                              padding:
                                  const EdgeInsets.only(left: 14, right: 4),
                              color: visible[index].startsWith('+')
                                  ? AppTheme.green.withValues(alpha: 0.14)
                                  : visible[index].startsWith('-')
                                      ? AppTheme.red.withValues(alpha: 0.14)
                                      : null,
                              child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (fileStarts.isEmpty)
                                      SizedBox(
                                        width: 16,
                                        child: index == 0
                                            ? Text('└ ',
                                                softWrap: false,
                                                style: _lineStyle(''))
                                            : null,
                                      ),
                                    Expanded(
                                        child: _expanded
                                            ? SelectableText(
                                                _lineText(visible[index]),
                                                style:
                                                    _lineStyle(visible[index]))
                                            : Text(_lineText(visible[index]),
                                                softWrap: false,
                                                style: _lineStyle(
                                                    visible[index]))),
                                  ]),
                            ),
                        ],
                      ],
                    )),
                  ),
                )),
        if (details.isNotEmpty)
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '− 收起详情' : '+ 显示详情'),
          ),
      ]),
    );
  }
}
