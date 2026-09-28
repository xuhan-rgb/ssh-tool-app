import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:ssh_tool_app/screens/tmux_workspace_screen.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';
import 'package:ssh_tool_app/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory settingsDirectory;

  setUpAll(() async {
    settingsDirectory = await Directory.systemTemp.createTemp('macos-codex-');
    Hive.init(settingsDirectory.path);
    await Hive.openBox('settings');
  });
  setUp(() async => Hive.box('settings').clear());
  tearDownAll(() async {
    await Hive.close();
    await settingsDirectory.delete(recursive: true);
  });

  testWidgets('macOS opens the same Codex conversation in either mode',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final conversation = CodexConversation(
      id: 'macos-thread',
      cwd: '/project',
      updatedAt: DateTime(2026, 9, 25),
      title: 'Mac 对话',
      state: CodexConversationState.complete,
    );
    CodexSessionConfig? selected;

    Widget app({required bool asChat}) => MaterialApp(
          theme: AppTheme.darkTheme,
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () async {
                  selected = await showDialog<CodexSessionConfig>(
                    context: context,
                    builder: (_) => CodexSessionDialog(
                      initialOpenAsChat: asChat,
                      defaultName: 'codex',
                      defaultWorkDir: '/project',
                      loadConversations: (_) async => [conversation],
                      loadRecords: (_) async => const [],
                      loadDirectories: (_) async => const RemoteDirectoryListing(
                        path: '/project',
                        dirs: [],
                      ),
                    ),
                  );
                },
                child: const Text('选择对话'),
              ),
            ),
          ),
        );

    for (final asChat in [true, false]) {
      selected = null;
      await tester.pumpWidget(app(asChat: asChat));
      await tester.tap(find.text('选择对话'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SegmentedButton<bool>), findsOneWidget);
      await tester.tap(find.text('Mac 对话'));
      await tester.pump();
      await tester.tap(find.text(asChat ? '打开聊天' : '恢复'));
      await tester.pump();
      expect(selected?.resumeConversation?.id, 'macos-thread');
      expect(selected?.openAsChat, asChat);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    debugDefaultTargetPlatformOverride = null;
  });
}
