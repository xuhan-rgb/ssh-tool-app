import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/models/codex_goal.dart';
import 'package:ssh_tool_app/theme/app_theme.dart';
import 'package:ssh_tool_app/widgets/codex_goal_card.dart';

Widget _host(Widget child) => MaterialApp(
      theme: AppTheme.darkTheme,
      home: Scaffold(body: child),
    );

CodexGoal _goal({
  String objective = '完成目标',
  String status = 'in_progress',
  int? tokenBudget,
  int tokensUsed = 0,
}) =>
    CodexGoal(
      objective: objective,
      status: status,
      tokenBudget: tokenBudget,
      tokensUsed: tokensUsed,
    );

void main() {
  testWidgets('无 goal 时不占空间', (tester) async {
    await tester.pumpWidget(_host(CodexGoalCard(
      connectionId: 'c1',
      conversationId: 't1',
      loadGoal: () async => null,
    )));
    await tester.pumpAndSettle();

    expect(find.text('Goal'), findsNothing);
    expect(find.text('目标读取失败'), findsNothing);
  });

  testWidgets('显示目标原文、中文状态和可选预算', (tester) async {
    await tester.pumpWidget(_host(CodexGoalCard(
      connectionId: 'c1',
      conversationId: 't1',
      loadGoal: () async => _goal(
        objective: '修复聊天页的目标展示',
        status: 'in_progress',
        tokenBudget: 1200,
        tokensUsed: 345,
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Goal'), findsOneWidget);
    expect(find.text('进行中'), findsOneWidget);
    expect(find.text('修复聊天页的目标展示'), findsOneWidget);
    expect(find.text('345 / 1200 tokens'), findsOneWidget);
  });

  testWidgets('15 秒后静默刷新目标状态', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var reads = 0;
    await tester.pumpWidget(_host(CodexGoalCard(
      connectionId: 'c1',
      conversationId: 't1',
      loadGoal: () async =>
          _goal(status: ++reads == 1 ? 'running' : 'completed'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('进行中'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.text('已完成'), findsOneWidget);
    expect(find.text('刷新失败'), findsNothing);
  });

  testWidgets('长目标默认截断并可展开全文', (tester) async {
    final objective =
        List.generate(40, (index) => '目标内容第 ${index + 1} 行').join('\n');
    await tester.pumpWidget(_host(CodexGoalCard(
      connectionId: 'c1',
      conversationId: 't1',
      loadGoal: () async => _goal(objective: objective),
    )));
    await tester.pumpAndSettle();

    final text = tester.widget<Text>(find.text(objective));
    expect(text.maxLines, 3);
    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text(objective)).maxLines, isNull);
    final constraint = tester.widget<ConstrainedBox>(find
        .ancestor(
          of: find.text(objective),
          matching: find.byType(ConstrainedBox),
        )
        .first);
    expect(constraint.constraints.maxHeight, 160);
    expect(find.text('收起'), findsOneWidget);
  });

  testWidgets('首次读取失败可重试，后台刷新失败保留旧目标', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var reads = 0;
    await tester.pumpWidget(_host(CodexGoalCard(
      connectionId: 'c1',
      conversationId: 't1',
      loadGoal: () async {
        reads++;
        if (reads == 1 || reads == 3) throw StateError('offline');
        return _goal(objective: '保留的目标');
      },
    )));
    await tester.pumpAndSettle();
    expect(find.text('目标读取失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('保留的目标'), findsOneWidget);

    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.text('保留的目标'), findsOneWidget);
    expect(find.text('刷新失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(reads, 4);
    expect(find.text('刷新失败'), findsNothing);
    expect(find.text('保留的目标'), findsOneWidget);
  });

  testWidgets('切换对话后旧请求结果不会覆盖新目标', (tester) async {
    final oldRequest = Completer<CodexGoal?>();
    var loadNew = false;
    Widget card(String conversationId) => CodexGoalCard(
          key: const ValueKey('goal'),
          connectionId: 'c1',
          conversationId: conversationId,
          loadGoal: () => conversationId == 't1'
              ? oldRequest.future
              : loadNew
                  ? Future.value(_goal(objective: '新对话目标'))
                  : Future.value(null),
        );

    await tester.pumpWidget(_host(card('t1')));
    loadNew = true;
    await tester.pumpWidget(_host(card('t2')));
    await tester.pumpAndSettle();
    oldRequest.complete(_goal(objective: '旧对话目标'));
    await tester.pumpAndSettle();

    expect(find.text('新对话目标'), findsOneWidget);
    expect(find.text('旧对话目标'), findsNothing);
  });

  testWidgets('卸载后定时器不会再读取', (tester) async {
    var reads = 0;
    await tester.pumpWidget(_host(CodexGoalCard(
      connectionId: 'c1',
      conversationId: 't1',
      loadGoal: () async {
        reads++;
        return _goal();
      },
    )));
    await tester.pumpAndSettle();
    expect(reads, 1);

    await tester.pumpWidget(_host(const SizedBox.shrink()));
    await tester.pump(const Duration(seconds: 30));
    expect(reads, 1);
  });
}
