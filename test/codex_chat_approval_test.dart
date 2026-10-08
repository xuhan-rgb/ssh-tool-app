import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/screens/codex_chat_screen.dart';
import 'package:ssh_tool_app/services/codex_chat_service.dart';

void main() {
  const approval = CodexApproval(
    jobId: 'job-1',
    requestKey: 'request-1',
    method: 'item/commandExecution/requestApproval',
    detail: '运行 rm -rf build?',
  );

  testWidgets('approval panel presents the request and sends the choice',
      (tester) async {
    bool? response;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexApprovalPanel(
          approval: approval,
          onRespond: (accept) async {
            response = accept;
          },
        ),
      ),
    ));

    expect(find.text('Codex 需要确认'), findsOneWidget);
    expect(find.text('运行 rm -rf build?'), findsOneWidget);
    await tester.tap(find.text('允许本次'));
    await tester.pumpAndSettle();
    expect(response, isTrue);
    expect(find.byKey(const ValueKey('codex-approval-panel')), findsOneWidget);
  });

  testWidgets('a failed response stays visible and can be retried',
      (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexApprovalPanel(
          approval: approval,
          onRespond: (_) async {
            attempts++;
            if (attempts == 1) throw StateError('连接中断');
          },
        ),
      ),
    ));

    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(find.text('响应失败：Bad state: 连接中断'), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-approval-panel')), findsOneWidget);

    await tester.tap(find.text('拒绝'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byKey(const ValueKey('codex-approval-error')), findsNothing);
  });

  testWidgets('long approval detail keeps the actions in view', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var accepted = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexApprovalPanel(
          approval: CodexApproval(
            jobId: 'job-long',
            requestKey: 'request-long',
            method: 'item/commandExecution/requestApproval',
            detail: List.filled(60, 'long approval detail').join('\n'),
          ),
          onRespond: (accept) async {
            accepted = accept;
          },
        ),
      ),
    ));

    final allowButton = find.text('允许本次');
    expect(tester.getRect(allowButton).bottom, lessThan(844));
    await tester.tap(allowButton);
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
  });
}
