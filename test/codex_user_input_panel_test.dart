import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/widgets/codex_user_input_panel.dart';

Map<String, dynamic> _request(List<Map<String, dynamic>> questions) => {
      'id': 'request-1',
      'params': {'questions': questions},
    };

void main() {
  testWidgets('selects answers for multiple questions and submits them',
      (tester) async {
    Map<String, List<String>>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexUserInputPanel(
          request: _request([
            {
              'id': 'color',
              'question': 'Choose a color',
              'options': [
                {'label': 'Blue', 'description': 'Cool tone'},
                {'label': 'Red'},
              ],
            },
            {
              'id': 'mode',
              'question': 'Choose a mode',
              'options': [
                {'label': 'Fast'},
                {'label': 'Safe'},
              ],
            },
          ]),
          onSubmit: (answers) async => submitted = answers,
        ),
      ),
    ));

    await tester.tap(find.text('Blue'));
    await tester.tap(find.text('Safe'));
    await tester.pump();
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('codex-user-input-submit')))
            .onPressed,
        isNotNull);
    await tester.tap(find.byKey(const ValueKey('codex-user-input-submit')));
    await tester.pumpAndSettle();

    expect(submitted, {
      'color': ['Blue'],
      'mode': ['Safe']
    });
  });

  testWidgets('submits text and Other answers, obscuring secret text',
      (tester) async {
    Map<String, List<String>>? submitted;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexUserInputPanel(
          request: _request([
            {
              'id': 'tool',
              'question': 'Choose a tool',
              'isOther': true,
              'options': [
                {'label': 'Built in'},
              ],
            },
            {'id': 'token', 'question': 'Token', 'isSecret': true},
          ]),
          onSubmit: (answers) async => submitted = answers,
        ),
      ),
    ));

    await tester.tap(find.text('其他'));
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-user-input-tool-other')),
        findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('codex-user-input-tool-other')), 'custom');
    await tester.enterText(
        find.byKey(const ValueKey('codex-user-input-token')), 'secret');
    await tester.pump();
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('codex-user-input-token')))
            .obscureText,
        isTrue);
    await tester.tap(find.byKey(const ValueKey('codex-user-input-submit')));
    await tester.pumpAndSettle();

    expect(submitted, {
      'tool': ['custom'],
      'token': ['secret']
    });
  });

  testWidgets('keeps the draft after failure and allows retry', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexUserInputPanel(
          request: _request([
            {
              'id': 'answer',
              'question': 'Choose',
              'options': [
                {'label': 'Yes'},
              ],
            },
          ]),
          onSubmit: (_) async {
            attempts++;
            if (attempts == 1) throw StateError('connection lost');
          },
        ),
      ),
    ));

    await tester.tap(find.text('Yes'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-user-input-submit')));
    await tester.pumpAndSettle();
    expect(find.text('提交失败：Bad state: connection lost'), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-user-input-submit')));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.byKey(const ValueKey('codex-user-input-error')), findsNothing);
  });

  testWidgets('busy submit blocks duplicate submissions', (tester) async {
    final completer = Completer<void>();
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexUserInputPanel(
          request: _request([
            {
              'id': 'answer',
              'question': 'Choose',
              'options': [
                {'label': 'Yes'},
              ],
            },
          ]),
          onSubmit: (_) {
            attempts++;
            return completer.future;
          },
        ),
      ),
    ));

    await tester.tap(find.text('Yes'));
    await tester.tap(find.byKey(const ValueKey('codex-user-input-submit')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-user-input-submit')));
    expect(attempts, 1);
    completer.complete();
    await tester.pumpAndSettle();
  });

  testWidgets(
      'submit starts disabled and long questions scroll in short viewports',
      (tester) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexUserInputPanel(
          request: _request([
            {
              'id': 'answer',
              'question': 'Choose',
              'options':
                  List.generate(20, (index) => {'label': 'Option $index'}),
            },
          ]),
          onSubmit: (_) async {},
        ),
      ),
    ));

    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const ValueKey('codex-user-input-submit')))
            .onPressed,
        isNull);
    expect(
        tester
            .getRect(find.byKey(const ValueKey('codex-user-input-submit')))
            .bottom,
        lessThan(390));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });

  testWidgets('question area adapts when the keyboard covers the viewport',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CodexUserInputPanel(
          request: _request([
            {
              'id': 'answer',
              'question': 'Choose',
              'options':
                  List.generate(20, (index) => {'label': 'Option $index'}),
            },
          ]),
          onSubmit: (_) async {},
        ),
      ),
    ));

    expect(
      tester
          .getRect(find.byKey(const ValueKey('codex-user-input-submit')))
          .bottom,
      lessThan(844 - 300),
    );
    expect(tester.takeException(), isNull);
  });
}
