import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/remote_status_service.dart';
import 'package:ssh_tool_app/widgets/remote_status_widgets.dart';

void main() {
  test('preserves missing hardware metrics and multiple GPUs', () {
    final status = ComputerStatus.fromJson({
      'gpus': [
        {'name': 'A', 'usedPercent': 0},
        {'name': 'B', 'usedPercent': null},
      ]
    });
    expect(status.cpuPercent, isNull);
    expect(status.gpus[0].usedPercent, 0);
    expect(status.gpus[1].usedPercent, isNull);
  });

  test('quota uses real windows, multiple buckets and reset seconds', () {
    final quota = CodexQuota.fromJson({
      'rateLimitsByLimitId': {
        'codex': {
          'limitId': 'codex',
          'primary': {
            'usedPercent': 25,
            'windowDurationMins': 300,
            'resetsAt': 1730947200,
          },
          'secondary': {'usedPercent': 105, 'windowDurationMins': 10080}
        },
        'review': {
          'limitName': '代码审查',
          'primary': {'usedPercent': null}
        },
      }
    });
    expect(quota.buckets.length, 2);
    expect(quota.buckets[0].windows[0].remainingPercent, 75);
    expect(quota.buckets[0].windows[0].label, '5 小时额度');
    expect(quota.buckets[0].windows[0].resetsAt!.millisecondsSinceEpoch,
        1730947200000);
    expect(quota.buckets[0].windows[1].remainingPercent, 0);
    expect(quota.buckets[0].windows[1].label, '7 天额度');
    expect(quota.buckets[1].windows, isEmpty);
    expect(CodexQuota.fromJson({}).buckets, isEmpty);
    expect(
        CodexQuota.fromJson({
          'rateLimits': {
            'primary': {'usedPercent': 0}
          }
        }).buckets.single.windows.single.remainingPercent,
        100);
  });

  testWidgets('small screen summary opens scrollable details for multiple GPUs',
      (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteComputerStatus(
      connectionId: 'demo',
      load: () async => ComputerStatus.fromJson({
        'cpuPercent': 18,
        'cpuCores': 8,
        'gpus': [
          {
            'name': 'GPU A',
            'usedPercent': 35,
            'memoryUsedMiB': 100,
            'memoryTotalMiB': 1000
          },
          {'name': 'GPU B'},
        ],
      }),
    ))));
    await tester.pump();
    expect(find.text('CPU 18% · GPU 2 张'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('computer-status-summary')));
    await tester.pumpAndSettle();
    expect(find.text('GPU 1 · GPU A'), findsOneWidget);
    expect(find.textContaining('100 / 1000 MiB'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('single GPU summary shows utilization and used memory',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: RemoteComputerStatus(
      connectionId: 'demo',
      load: () async => ComputerStatus.fromJson({
        'cpuPercent': 18,
        'gpus': [
          {
            'name': 'GPU A',
            'usedPercent': 35,
            'memoryUsedMiB': 100,
            'memoryTotalMiB': 1000
          }
        ],
      }),
    ))));
    await tester.pump();
    expect(find.text('CPU 18% · GPU 35% · 显存 0.1/1G'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'quota displays remaining value and shares pending details request',
      (tester) async {
    var calls = 0;
    final pending = Completer<CodexQuota>();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: CodexQuotaButton(
      connectionId: 'demo',
      load: () {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(CodexQuota.fromJson({
                'rateLimits': {
                  'primary': {'usedPercent': 25, 'windowDurationMins': 300}
                },
              }));
      },
    ))));
    expect(calls, 1);
    await tester.tap(find.byKey(const ValueKey('codex-quota-button')));
    await tester.pump();
    expect(calls, 1);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新状态'))
            .onPressed,
        isNull);
    pending.completeError(StateError('当前账号不可用'));
    await tester.pumpAndSettle();
    expect(find.text('暂无法获取，请稍后刷新'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新状态'))
            .onPressed,
        isNotNull);
    await tester.tap(find.byTooltip('刷新状态'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('5 小时额度 · 剩余 75%'), findsOneWidget);
    expect(find.text('额度 75%'), findsOneWidget);
    expect(find.text('暂无法获取，请稍后刷新'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
