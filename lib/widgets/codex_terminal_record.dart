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
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('• ',
              style: TextStyle(color: failed ? AppTheme.red : AppTheme.green)),
          Expanded(
              child: Text(summary,
                  maxLines: _expanded ? null : 1,
                  overflow:
                      _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                      color: failed ? AppTheme.red : AppTheme.textPrimary,
                      fontSize: 12))),
        ]),
        if (details.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (final line in visible)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(left: 14, right: 4),
              color: line.startsWith('+')
                  ? AppTheme.green.withValues(alpha: 0.14)
                  : line.startsWith('-')
                      ? AppTheme.red.withValues(alpha: 0.14)
                      : null,
              child: _expanded
                  ? SelectableText(_lineText(line), style: _lineStyle(line))
                  : Text(_lineText(line),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: _lineStyle(line)),
            ),
          TextButton(
            onPressed: () => setState(() => _expanded = !_expanded),
            child: Text(_expanded ? '− 收起详情' : '+ 显示详情'),
          ),
        ],
      ]),
    );
  }
}
