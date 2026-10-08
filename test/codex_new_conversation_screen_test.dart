import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/models/remote_directory_listing.dart';
import 'package:ssh_tool_app/screens/codex_new_conversation_screen.dart';

RemoteDirectoryListing listing(String path, List<String> dirs,
        {String home = '/home/test'}) =>
    RemoteDirectoryListing(path: path, dirs: dirs, homePath: home);

Widget app(Widget child, {TextScaler textScaler = TextScaler.noScaling}) =>
    MaterialApp(
      builder: (context, widget) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: widget!,
      ),
      home: child,
    );

Future<void> _saveFavorites(Set<String> paths) async {}

void main() {
  testWidgets('favorite-only view lists saved roots and browses their children',
      (tester) async {
    var writes = 0;
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/current',
      favoritePaths: const {'/elsewhere/project', '/elsewhere/.private'},
      saveFavoritePaths: (_) async {
        writes++;
      },
      loadDirectories: (path) async => listing(
          path, path == '/current' ? ['ordinary'] : ['child', '.hidden']),
    )));
    await tester.pumpAndSettle();
    expect(find.text('ordinary'), findsOneWidget);
    expect(find.text('project'), findsNothing);

    await tester.tap(find.byTooltip('目录显示选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-only-favorite-directories')));
    await tester.pumpAndSettle();
    expect(find.text('ordinary'), findsNothing);
    expect(find.text('project'), findsOneWidget);
    expect(find.text('.private'), findsNothing);
    await tester
        .tap(find.byKey(const Key('directory-expand-/elsewhere/project')));
    await tester.pumpAndSettle();
    expect(find.text('project'), findsOneWidget);
    expect(find.text('child'), findsOneWidget);
    expect(find.text('.hidden'), findsNothing);
    await tester.tap(find.text('child'));
    await tester.pumpAndSettle();
    expect(find.text('/elsewhere/project/child'), findsOneWidget);
    expect(writes, 0);

    await tester.tap(find.byTooltip('目录显示选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-only-favorite-directories')));
    await tester.pumpAndSettle();
    expect(find.text('ordinary'), findsOneWidget);
    expect(writes, 0);
  });

  testWidgets(
      'favorite-only empty view updates when current folder is bookmarked',
      (tester) async {
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/current',
      favoritePaths: const {},
      saveFavoritePaths: _saveFavorites,
      loadDirectories: (path) async => listing(path, []),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录显示选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-only-favorite-directories')));
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏目录，可通过上方“收藏目录”添加。'), findsOneWidget);
    await tester
        .tap(find.byKey(const Key('toggle-current-directory-favorite')));
    await tester.pumpAndSettle();
    expect(find.text('current'), findsOneWidget);
    await tester
        .tap(find.byKey(const Key('toggle-current-directory-favorite')));
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏目录，可通过上方“收藏目录”添加。'), findsOneWidget);
  });

  testWidgets('valid favorite can be selected after initial directory fails',
      (tester) async {
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/missing',
      favoritePaths: const {'/valid'},
      saveFavoritePaths: _saveFavorites,
      loadDirectories: (path) async => path == '/missing'
          ? const RemoteDirectoryListing(
              path: '/missing', dirs: [], error: 'not found')
          : listing(path, []),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('目录显示选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-only-favorite-directories')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('valid'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('headerpath'))).data,
        '/valid');
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('start-new-conversation')))
            .onPressed,
        isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expands folders, selects them, then navigates up and home',
      (tester) async {
    final requested = <String>[];
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/home/test',
      favoritePaths: const {},
      saveFavoritePaths: _saveFavorites,
      loadDirectories: (path) async {
        requested.add(path);
        return listing(path, path == '/home/test' ? ['projects'] : []);
      },
    )));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const Key('directory-expand-/home/test/projects')));
    await tester.pumpAndSettle();
    expect(requested.last, '/home/test/projects');
    expect(find.text('projects'), findsOneWidget);
    await tester.tap(find.text('projects'));
    await tester.pumpAndSettle();
    expect(find.text('/home/test/projects'), findsOneWidget);

    await tester.tap(find.byTooltip('上级目录'));
    await tester.pumpAndSettle();
    expect(requested.last, '/home/test');
    await tester.tap(find.byTooltip('主目录'));
    await tester.pumpAndSettle();
    expect(requested.last, '/home/test');
  });

  testWidgets('tree expansion keeps parent and child visible and submits child',
      (tester) async {
    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await Navigator.push<Object?>(
                context,
                MaterialPageRoute<Object?>(
                  builder: (_) => CodexNewConversationScreen(
                    initialPath: '/root',
                    favoritePaths: const {},
                    saveFavoritePaths: _saveFavorites,
                    loadDirectories: (path) async => listing(
                      path,
                      path == '/root' ? ['parent'] : ['child'],
                    ),
                  ),
                ),
              );
            },
            child: const Text('open tree picker'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open tree picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('directory-expand-/root/parent')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('directory-row-/root/parent')), findsOneWidget);
    expect(find.byKey(const Key('directory-row-/root/parent/child')),
        findsOneWidget);
    await tester.tap(find.text('child'));
    await tester.pumpAndSettle();
    expect(find.text('/root/parent/child'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-new-conversation')));
    await tester.pumpAndSettle();
    expect(result, (path: '/root/parent/child', favorite: true));
  });

  testWidgets('hidden directories stay hidden at every depth until enabled',
      (tester) async {
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/root',
      favoritePaths: const {},
      saveFavoritePaths: _saveFavorites,
      loadDirectories: (path) async => listing(
          path,
          switch (path) {
            '/root' => ['visible', '.hidden'],
            '/root/visible' => ['nested', '.nested-hidden'],
            _ => ['.deep-hidden', 'leaf'],
          }),
    )));
    await tester.pumpAndSettle();
    expect(find.text('.hidden'), findsNothing);
    await tester.tap(find.byKey(const Key('directory-expand-/root/visible')));
    await tester.pumpAndSettle();
    expect(find.text('.nested-hidden'), findsNothing);
    await tester
        .tap(find.byKey(const Key('directory-expand-/root/visible/nested')));
    await tester.pumpAndSettle();
    expect(find.text('.deep-hidden'), findsNothing);

    await tester.tap(find.byTooltip('目录显示选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-hidden-directories')));
    await tester.pumpAndSettle();
    expect(find.text('.hidden'), findsOneWidget);
    expect(find.text('.nested-hidden'), findsOneWidget);
    expect(find.text('.deep-hidden'), findsOneWidget);
  });

  testWidgets('failed lazy load stays local and does not select that folder',
      (tester) async {
    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await Navigator.push<Object?>(
                context,
                MaterialPageRoute<Object?>(
                  builder: (_) => CodexNewConversationScreen(
                    initialPath: '/root',
                    favoritePaths: const {},
                    saveFavoritePaths: _saveFavorites,
                    loadDirectories: (path) async {
                      if (path == '/root/bad') {
                        throw Exception('Permission denied');
                      }
                      return listing(path, ['bad']);
                    },
                  ),
                ),
              );
            },
            child: const Text('open error picker'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open error picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('bad'));
    await tester.pumpAndSettle();
    expect(find.text('没有权限访问这个目录，请选择其他目录。'), findsOneWidget);
    await tester.tap(find.byKey(const Key('start-new-conversation')));
    await tester.pumpAndSettle();
    expect(result, (path: '/root', favorite: true));
  });

  testWidgets('stale child selection cannot override a newer root load',
      (tester) async {
    final childRequest = Completer<RemoteDirectoryListing>();
    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await Navigator.push<Object?>(
                context,
                MaterialPageRoute<Object?>(
                  builder: (_) => CodexNewConversationScreen(
                    initialPath: '/root',
                    favoritePaths: const {},
                    saveFavoritePaths: _saveFavorites,
                    loadDirectories: (path) {
                      if (path == '/root/slow') return childRequest.future;
                      return Future.value(listing(
                        path,
                        path == '/root' ? ['slow'] : ['other-child'],
                      ));
                    },
                  ),
                ),
              );
            },
            child: const Text('open stale child picker'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open stale child picker'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('slow'));
    await tester.pump();
    await tester.tap(find.text('输入路径'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.byKey(const Key('new-conversation-directory')),
      '/other',
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    childRequest.complete(listing('/root/slow', ['stale-child']));
    await tester.pumpAndSettle();
    expect(find.text('/other'), findsOneWidget);
    expect(find.text('slow'), findsNothing);
    await tester.tap(find.byKey(const Key('start-new-conversation')));
    await tester.pumpAndSettle();
    expect(result, (path: '/other', favorite: true));
  });

  testWidgets('stale favorite result cannot replace the newer directory',
      (tester) async {
    final oldRequest = Completer<RemoteDirectoryListing>();
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/initial',
      favoritePaths: const {'/favorite'},
      saveFavoritePaths: _saveFavorites,
      loadDirectories: (path) => path == '/initial'
          ? oldRequest.future
          : Future.value(listing(path, [])),
    )));
    await tester.pump();
    await tester.tap(find.byTooltip('收藏目录'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.ensureVisible(
        find.byKey(const Key('new-directory-favorite-/favorite')));
    await tester.tap(find.byKey(const Key('new-directory-favorite-/favorite')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    oldRequest.complete(listing('/initial', ['old']));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('/favorite'), findsOneWidget);
    expect(find.text('old'), findsNothing);
  });

  testWidgets(
      'failed lookup clears previous valid path and shows friendly error',
      (tester) async {
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/valid',
      favoritePaths: const {},
      saveFavoritePaths: _saveFavorites,
      loadDirectories: (path) async {
        if (path == '/valid') return listing(path, []);
        throw Exception('No such file or directory');
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入路径'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('new-conversation-directory')), '/missing');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('目录不存在，请选择其他目录。'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(
                find.byKey(const Key('start-new-conversation')))
            .onPressed,
        isNull);
  });

  testWidgets('manual path and start action return selected path and favorite',
      (tester) async {
    Object? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              result = await Navigator.push<Object?>(
                context,
                MaterialPageRoute<Object?>(
                  builder: (_) => CodexNewConversationScreen(
                    initialPath: '/start',
                    favoritePaths: const {},
                    saveFavoritePaths: _saveFavorites,
                    loadDirectories: (path) async => listing(path, []),
                  ),
                ),
              );
            },
            child: const Text('open picker'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open picker'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入路径'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('new-conversation-directory')), '/chosen');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('start-new-conversation')));
    await tester.pumpAndSettle();
    expect(result, (path: '/chosen', favorite: true));
  });

  testWidgets('favorite manager adds, edits, and removes validated paths',
      (tester) async {
    final saved = <Set<String>>[];
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/current',
      favoritePaths: const {'/old'},
      saveFavoritePaths: (paths) async => saved.add(Set.of(paths)),
      loadDirectories: (path) async => listing(
        path == '/alias' ? '/normalized' : path,
        [],
      ),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收藏目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加目录'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('new-conversation-directory')), '/alias');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(saved.last, {'/old', '/normalized'});

    await tester
        .tap(find.byKey(const Key('new-directory-favorite-actions-/old')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑路径'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const Key('new-conversation-directory')), '/replacement');
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(saved.last, {'/normalized', '/replacement'});

    await tester.tap(
        find.byKey(const Key('new-directory-favorite-actions-/normalized')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消收藏'));
    await tester.pumpAndSettle();
    expect(saved.last, {'/replacement'});
  });

  testWidgets(
      'cancelled favorite input does not save and failed save keeps old path',
      (tester) async {
    var writes = 0;
    var fail = true;
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/current',
      favoritePaths: const {'/old'},
      saveFavoritePaths: (paths) async {
        writes++;
        if (fail) throw StateError('storage unavailable');
      },
      loadDirectories: (path) async => listing(path, []),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收藏目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加目录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(writes, 0);

    await tester
        .tap(find.byKey(const Key('new-directory-favorite-actions-/old')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消收藏'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(
        find.byKey(const Key('new-directory-favorite-/old')), findsOneWidget);
    expect(find.text('收藏目录保存失败，请重试。'), findsOneWidget);
    fail = false;
  });

  testWidgets('current-directory favorite save disables overlapping actions',
      (tester) async {
    final save = Completer<void>();
    var writes = 0;
    await tester.pumpWidget(app(CodexNewConversationScreen(
      initialPath: '/current',
      favoritePaths: const {},
      saveFavoritePaths: (paths) {
        writes++;
        return save.future;
      },
      loadDirectories: (path) async => listing(path, []),
    )));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('toggle-current-directory-favorite')));
    await tester.pump();
    expect(writes, 1);
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('toggle-current-directory-favorite')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('favorite-directories-button')),
          )
          .onPressed,
      isNull,
    );
    save.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('small screen and larger text keep the main action accessible',
      (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app(
      CodexNewConversationScreen(
        initialPath: '/a/very/long/path/that/scrolls/horizontally',
        favoritePaths: const {},
        saveFavoritePaths: _saveFavorites,
        loadDirectories: (path) async => listing(
            path,
            switch (path) {
              '/a/very/long/path/that/scrolls/horizontally' => [
                  'a-very-long-folder-name-that-needs-to-truncate'
                ],
              '/a/very/long/path/that/scrolls/horizontally/a-very-long-folder-name-that-needs-to-truncate' =>
                ['middle'],
              _ => ['leaf'],
            }),
      ),
      textScaler: const TextScaler.linear(1.3),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(
        'directory-expand-/a/very/long/path/that/scrolls/horizontally/a-very-long-folder-name-that-needs-to-truncate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key(
        'directory-expand-/a/very/long/path/that/scrolls/horizontally/a-very-long-folder-name-that-needs-to-truncate/middle')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('start-new-conversation')), findsOneWidget);
  });
}
