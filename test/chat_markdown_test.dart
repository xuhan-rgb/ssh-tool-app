import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/widgets/chat_markdown.dart';

void main() {
  for (final text in ['**重点。**', '这里**重点。**后续', '这里**“重点”**后续']) {
    testWidgets('bold punctuation renders: $text', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ChatMarkdown(text)),
      ));
      final spans = tester.widgetList<SelectableText>(find.byType(SelectableText));
      final plain = spans.map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? '').join();
      expect(plain, text.replaceAll('**', ''));
      String boldText(InlineSpan span, [FontWeight? inherited]) {
        final weight = span.style?.fontWeight ?? inherited;
        if (span is! TextSpan) return '';
        return (weight == FontWeight.bold ? span.text ?? '' : '') +
            (span.children ?? []).map((child) => boldText(child, weight)).join();
      }
      expect(spans.where((widget) => widget.textSpan != null)
          .map((widget) => boldText(widget.textSpan!)).join(), contains('重点'));
    });
  }

  testWidgets('markdown emphasis preserves code, escapes, and unmatched markers',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ChatMarkdown(
          r'**粗体** `**行内代码**` 和 \*\*转义\*\*' '\n'
          '```text\n**代码块**\n```\n'
          '**未闭合',
        ),
      ),
    ));

    final spans = tester.widgetList<SelectableText>(find.byType(SelectableText));
    final plain = spans
        .map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? '')
        .join();
    expect(plain, contains('粗体'));
    expect(plain, contains('**行内代码**'));
    expect(plain, contains('**转义**'));
    expect(plain, contains('**代码块**'));
    expect(plain, contains('**未闭合'));

    String boldText(InlineSpan span, [FontWeight? inherited]) {
      final weight = span.style?.fontWeight ?? inherited;
      if (span is! TextSpan) return '';
      return (weight == FontWeight.bold ? span.text ?? '' : '') +
          (span.children ?? []).map((child) => boldText(child, weight)).join();
    }

    expect(
      spans.where((widget) => widget.textSpan != null)
          .map((widget) => boldText(widget.textSpan!)).join(),
      contains('粗体'),
    );
  });

  testWidgets('bold text supports nested inline code and links', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: ChatMarkdown('**粗 `code` [链接](https://example.com)**'),
      ),
    ));

    final spans = tester.widgetList<SelectableText>(find.byType(SelectableText));
    String boldText(InlineSpan span, [FontWeight? inherited]) {
      final weight = span.style?.fontWeight ?? inherited;
      if (span is! TextSpan) return '';
      return (weight == FontWeight.bold ? span.text ?? '' : '') +
          (span.children ?? []).map((child) => boldText(child, weight)).join();
    }

    final rendered = spans
        .where((widget) => widget.textSpan != null)
        .map((widget) => widget.textSpan!)
        .toList();
    expect(rendered.map((span) => span.toPlainText()).join(), contains('粗 code 链接'));
    expect(rendered.map((span) => boldText(span)).join(), contains('粗 '));
  });

  testWidgets('wide table scrolls horizontally and keeps real rows and cells',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
          body: SizedBox(
              width: 320,
              child: ChatMarkdown(
                '| 项目 | 数量 | 说明 | 结果 |\n'
                '| :--- | ---: | :---: | --- |\n'
                '| 表格 | 12 | 多列内容 | 成功 |\n'
                '| 列表 | 3 | 第二行 | 完成 |',
              ))),
    ));
    final table = tester.widget<Table>(find.byType(Table));
    expect(table.children, hasLength(3));
    expect(table.children.first.children, hasLength(4));
    expect(table.border, isNotNull);
    final horizontal = find.byWidgetPredicate((widget) =>
        widget is SingleChildScrollView &&
        widget.scrollDirection == Axis.horizontal);
    expect(horizontal, findsOneWidget);
    final controller =
        tester.widget<SingleChildScrollView>(horizontal).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    await tester.drag(horizontal, const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(controller.offset, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('table syntax in code stays literal and partial tables are safe',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ChatMarkdown(
      '```text\n| A | B |\n| --- | --- |\n| 1 | 2 |\n```',
    ))));
    expect(find.byType(Table), findsNothing);
    expect(find.textContaining('| A | B |'), findsOneWidget);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: ChatMarkdown(
      '| A | B |\n| --- | --- |\n| 1',
    ))));
    expect(find.byType(Table), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversation renders markdown tables instead of pipe text',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: CodexConversationViewerDialog(
        conversation: const CodexConversation(
          id: 'markdown',
          cwd: '/project',
          updatedAt: null,
          title: '格式测试',
        ),
        loadRecords: (_) async => const [
          CodexConversationRecord(
              kind: 'assistant',
              timestamp: null,
              text: '| 项目 | 状态 |\n| --- | --- |\n| **表格** | 已支持 |'),
        ],
      ),
    ));
    await tester.pump();
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('表格'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
