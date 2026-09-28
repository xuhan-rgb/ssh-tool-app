import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/app_theme.dart';

/// 对话正文共用的 Markdown 样式，宽表格在消息内横向滚动。
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown(this.data, {super.key, this.style});

  final String data;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final textStyle = DefaultTextStyle.of(context).style.merge(style);
    return MarkdownBody(
      data: data,
      inlineSyntaxes: [_ChineseStrongSyntax()],
      selectable: true,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: textStyle,
        tableHead: textStyle.copyWith(fontWeight: FontWeight.bold),
        tableBody: textStyle,
        tableBorder: TableBorder.all(color: AppTheme.borderAccent),
        tableColumnWidth: const FixedColumnWidth(160),
        tableCellsPadding: const EdgeInsets.all(10),
        tableHeadCellsDecoration: BoxDecoration(color: AppTheme.bgHover),
        tableScrollbarThumbVisibility: true,
      ),
      // 远端图片仍由聊天页的 SSH 图片预览处理，不能当成本机文件读取。
      imageBuilder: (uri, title, alt) => SelectableText(
        alt?.isNotEmpty == true ? alt! : uri.toString(),
        style: textStyle,
      ),
    );
  }
}

/// 中文紧邻标点时仍允许成对的双星号加粗；代码、转义和其他强调交给原解析器。
class _ChineseStrongSyntax extends md.InlineSyntax {
  _ChineseStrongSyntax()
      : super(r'\*\*(?=\S)([^*\n]*?\S)\*\*(?!\*)', startCharacter: 42);

  static final _chinese = RegExp(r'[\u3400-\u9fff]');
  static final _punctuation = RegExp(r'[。！？；：，、…“”‘’（）《》「」『』【】.!?:;,]');

  @override
  bool tryMatch(md.InlineParser parser, [int? startMatchPos]) {
    final position = startMatchPos ?? parser.pos;
    if (position > 0 && parser.source[position - 1] == '*') return false;
    final match = pattern.matchAsPrefix(parser.source, position);
    if (match == null) return false;
    final content = match[1]!;
    final before = position > 0 ? parser.source[position - 1] : '';
    final after = match.end < parser.source.length ? parser.source[match.end] : '';
    final touchesChinese =
        (_chinese.hasMatch(before) && _punctuation.hasMatch(content[0])) ||
        (_chinese.hasMatch(after) &&
            _punctuation.hasMatch(content[content.length - 1]));
    return touchesChinese && super.tryMatch(parser, startMatchPos);
  }

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(md.Element(
      'strong',
      md.InlineParser(match[1]!, parser.document).parse(),
    ));
    return true;
  }
}
