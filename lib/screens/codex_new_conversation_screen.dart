import 'dart:async';

import 'package:flutter/material.dart';

import '../models/remote_directory_listing.dart';

class CodexNewConversationScreen extends StatefulWidget {
  final String initialPath;
  final Set<String> favoritePaths;
  final Future<RemoteDirectoryListing> Function(String) loadDirectories;
  final Future<void> Function(Set<String>) saveFavoritePaths;

  const CodexNewConversationScreen({
    super.key,
    required this.initialPath,
    required this.favoritePaths,
    required this.loadDirectories,
    required this.saveFavoritePaths,
  });

  @override
  State<CodexNewConversationScreen> createState() =>
      _CodexNewConversationScreenState();
}

class _CodexNewConversationScreenState
    extends State<CodexNewConversationScreen> {
  RemoteDirectoryListing? _listing;
  String? _error;
  bool _loading = false;
  bool _favorite = true;
  bool _showHidden = false;
  bool _showOnlyFavorites = false;
  bool _savingFavorite = false;
  bool _selectingDirectory = false;
  int _generation = 0;
  String _homePath = '~';
  late String _requestedPath;
  String? _selectedPath;
  final Map<String, _DirectoryNode> _nodes = {};
  late Set<String> _favoritePaths;
  final TextEditingController _pathController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _favoritePaths = Set.of(widget.favoritePaths);
    _requestedPath = widget.initialPath;
    unawaited(_load(widget.initialPath));
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<void> _load(String path) async {
    if (!mounted) return;
    final generation = ++_generation;
    setState(() {
      _requestedPath = path;
      _loading = true;
      _error = null;
      _listing = null;
      _selectedPath = null;
      _selectingDirectory = false;
      _nodes.clear();
    });
    try {
      final listing = await widget.loadDirectories(path);
      if (!mounted || generation != _generation) return;
      if (listing.error != null) {
        setState(() {
          _loading = false;
          _error = _friendlyError(listing.error!);
          _selectedPath = null;
        });
        return;
      }
      setState(() {
        _listing = listing;
        _selectedPath = listing.path;
        _nodes.clear();
        _homePath = listing.homePath.isNotEmpty ? listing.homePath : '~';
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _error = _friendlyError(error.toString());
        _selectedPath = null;
      });
    }
  }

  String _friendlyError(String error) {
    final value = error.toLowerCase();
    if (value.contains('no such file') ||
        value.contains('not found') ||
        value.contains('目录不存在')) {
      return '目录不存在，请选择其他目录。';
    }
    if (value.contains('permission') ||
        value.contains('denied') ||
        value.contains('权限')) {
      return '没有权限访问这个目录，请选择其他目录。';
    }
    return '无法读取目录，请检查连接后重试。';
  }

  String _parentPath(String path) {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    if (normalized == '/' || normalized == '~' || normalized.isEmpty) {
      return normalized == '~' ? '~' : '/';
    }
    final index = normalized.lastIndexOf('/');
    if (index < 0) return '~';
    if (index == 0) return '/';
    return normalized.substring(0, index);
  }

  String _childPath(String parent, String name) =>
      parent == '/' ? '/$name' : '$parent/$name';

  _DirectoryNode _nodeFor(String parent, String name) {
    final path = _childPath(parent, name);
    return _nodes.putIfAbsent(path, () => _DirectoryNode(path, name));
  }

  Future<RemoteDirectoryListing?> _loadNode(_DirectoryNode node) async {
    if (node.childrenLoaded) return node.listing;
    if (node.loading) return null;
    final generation = _generation;
    setState(() {
      node.loading = true;
      node.error = null;
    });
    try {
      final listing = await widget.loadDirectories(node.path);
      if (!mounted || generation != _generation) return null;
      setState(() {
        node.loading = false;
        if (listing.error == null) {
          node.path = listing.path;
          node.listing = listing;
          node.childrenLoaded = true;
        } else {
          node.error = _friendlyError(listing.error!);
        }
      });
      return listing.error == null ? listing : null;
    } catch (error) {
      if (!mounted || generation != _generation) return null;
      setState(() {
        node.loading = false;
        node.error = _friendlyError(error.toString());
      });
      return null;
    }
  }

  Future<void> _toggleExpanded(_DirectoryNode node) async {
    if (node.expanded) {
      setState(() => node.expanded = false);
      return;
    }
    final generation = _generation;
    if (!node.childrenLoaded && await _loadNode(node) == null) return;
    if (generation != _generation) return;
    if (mounted) setState(() => node.expanded = true);
  }

  Future<void> _selectNode(_DirectoryNode node) async {
    if (_selectingDirectory) return;
    if (node.childrenLoaded) {
      setState(() {
        _selectedPath = node.path;
        _error = null;
        node.error = null;
      });
      return;
    }
    setState(() {
      _selectingDirectory = true;
      node.error = null;
    });
    final generation = _generation;
    final loaded = await _loadNode(node);
    if (!mounted || generation != _generation) return;
    setState(() {
      _selectingDirectory = false;
      if (loaded != null) {
        _selectedPath = loaded.path;
        _error = null;
      }
    });
  }

  List<Widget> _directoryRows(String parent, List<String> names, int depth,
      {bool favoriteRoots = false}) {
    final theme = Theme.of(context);
    final rows = <Widget>[];
    for (final entry in names) {
      final name = favoriteRoots
          ? (entry == '/'
              ? '/'
              : entry.split('/').lastWhere((part) => part.isNotEmpty))
          : entry;
      if (!_showHidden && name.startsWith('.')) continue;
      final node = favoriteRoots
          ? _nodes.putIfAbsent(entry, () => _DirectoryNode(entry, name))
          : _nodeFor(parent, name);
      rows.add(Padding(
        padding: EdgeInsets.only(left: depth.clamp(0, 4).toDouble() * 16),
        child: ListTile(
          key: Key('directory-row-${node.path}'),
          minTileHeight: 50,
          horizontalTitleGap: 8,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          selected: node.path == _selectedPath,
          leading: IconButton(
            key: Key('directory-expand-${node.path}'),
            tooltip: node.expanded ? '收起 ${node.name}' : '展开 ${node.name}',
            onPressed:
                _loading || node.loading ? null : () => _toggleExpanded(node),
            icon: Icon(
              node.expanded ? Icons.expand_more : Icons.chevron_right,
              size: 20,
            ),
          ),
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(fontSize: 14),
          ),
          subtitle: favoriteRoots
              ? Text(node.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ))
              : null,
          trailing: node.loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : null,
          onTap: _loading || _selectingDirectory || node.loading
              ? null
              : () => _selectNode(node),
        ),
      ));
      if (node.error != null) {
        rows.add(Padding(
          padding: EdgeInsets.only(
            left: (depth.clamp(0, 4) + 2).toDouble() * 16,
            right: 16,
          ),
          child: Text(
            node.error!,
            key: Key('directory-error-${node.path}'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ));
      }
      if (node.expanded && node.listing != null) {
        rows.addAll(_directoryRows(node.path, node.listing!.dirs, depth + 1));
      }
    }
    return rows;
  }

  Future<void> _inputPath() async {
    _pathController.text = _selectedPath ?? _requestedPath;
    final path = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入目录路径', style: TextStyle(fontSize: 17)),
        content: TextField(
          key: const Key('new-conversation-directory'),
          controller: _pathController,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: '/path/to/directory',
            hintStyle: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(fontSize: 14)),
          ),
          TextButton(
            onPressed: () {
              if (_pathController.text.trim().isNotEmpty) {
                Navigator.pop(context, _pathController.text.trim());
              }
            },
            child: const Text('打开', style: TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
    if (path != null && path.trim().isNotEmpty) _load(path.trim());
  }

  Future<void> _showFavorites() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => _FavoriteDirectoryManager(
        paths: _favoritePaths,
        loadDirectories: widget.loadDirectories,
        onPathsChanged: (paths) async {
          await widget.saveFavoritePaths(paths);
          if (mounted) setState(() => _favoritePaths = Set.of(paths));
        },
        onNavigate: (path) {
          Navigator.pop(sheetContext);
          _load(path);
        },
      ),
    );
  }

  Future<void> _toggleCurrentFavorite() async {
    final path = _selectedPath;
    if (path == null || _loading || _savingFavorite) return;
    setState(() => _savingFavorite = true);
    final next = Set<String>.of(_favoritePaths);
    if (!next.add(path)) next.remove(path);
    try {
      await widget.saveFavoritePaths(next);
      if (mounted) {
        setState(() {
          _favoritePaths = next;
          _savingFavorite = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _savingFavorite = false);
        _showSaveError();
      }
    }
  }

  void _showSaveError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('收藏目录保存失败，请重试。')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final listing = _listing;
    final favoriteRows = _showOnlyFavorites
        ? _directoryRows('', _favoritePaths.toList()..sort(), 0,
            favoriteRoots: true)
        : const <Widget>[];
    return Scaffold(
      appBar: AppBar(
        title: const Text('新建对话', style: TextStyle(fontSize: 17)),
        actions: [
          PopupMenuButton<String>(
            tooltip: '目录显示选项',
            onSelected: (value) => setState(() {
              if (value == 'hidden') _showHidden = !_showHidden;
              if (value == 'favorites') {
                _showOnlyFavorites = !_showOnlyFavorites;
              }
            }),
            itemBuilder: (context) => [
              CheckedPopupMenuItem<String>(
                key: const Key('show-hidden-directories'),
                value: 'hidden',
                checked: _showHidden,
                child: const Text('显示隐藏目录', style: TextStyle(fontSize: 14)),
              ),
              CheckedPopupMenuItem<String>(
                key: const Key('show-only-favorite-directories'),
                value: 'favorites',
                checked: _showOnlyFavorites,
                child: const Text('只显示收藏目录', style: TextStyle(fontSize: 14)),
              ),
            ],
          ),
          TextButton(
            onPressed: _inputPath,
            child: const Text('输入路径', style: TextStyle(fontSize: 14)),
          ),
        ],
      ),
      body: Column(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '主目录',
                      onPressed: _loading ? null : () => _load(_homePath),
                      icon: const Icon(Icons.home_outlined),
                    ),
                    IconButton(
                      tooltip: '上级目录',
                      onPressed: _loading || _selectedPath == null
                          ? null
                          : () => _load(_parentPath(_selectedPath!)),
                      icon: const Icon(Icons.arrow_upward),
                    ),
                    IconButton(
                      key: const Key('toggle-current-directory-favorite'),
                      tooltip: _selectedPath != null &&
                              _favoritePaths.contains(_selectedPath)
                          ? '取消收藏当前目录'
                          : '收藏当前目录',
                      onPressed:
                          _selectedPath == null || _loading || _savingFavorite
                              ? null
                              : _toggleCurrentFavorite,
                      icon: Icon(_selectedPath != null &&
                              _favoritePaths.contains(_selectedPath)
                          ? Icons.star
                          : Icons.star_border),
                    ),
                    IconButton(
                      key: const Key('favorite-directories-button'),
                      tooltip: '收藏目录',
                      onPressed: _savingFavorite ? null : _showFavorites,
                      icon: const Icon(Icons.bookmarks_outlined),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Text(
                      _selectedPath ?? _requestedPath,
                      key: const Key('headerpath'),
                      maxLines: 1,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontSize: 12,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Expanded(
            child: _showOnlyFavorites
                ? favoriteRows.isEmpty
                    ? Center(
                        child: Text(
                          _favoritePaths.isEmpty
                              ? '暂无收藏目录，可通过上方“收藏目录”添加。'
                              : '收藏目录已隐藏，可开启“显示隐藏目录”查看。',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontSize: 12,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                        ),
                      )
                    : ListView(
                        key: const Key('favorite-directory-tree'),
                        children: favoriteRows,
                      )
                : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                        ? Center(
                            child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_error!, textAlign: TextAlign.center),
                          ))
                        : listing == null
                            ? const SizedBox.shrink()
                            : _directoryRows(
                                listing.path,
                                listing.dirs,
                                0,
                              ).isEmpty
                                ? Center(
                                    child: Text(
                                      '此目录没有子文件夹，可直接开始聊天。',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            fontSize: 12,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  )
                                : ListView(
                                    key: const Key('directory-tree'),
                                    children: _directoryRows(
                                      listing.path,
                                      listing.dirs,
                                      0,
                                    ),
                                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    key: const Key('favorite-new-conversation'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: _favorite,
                    title: const Text(
                      '收藏新对话',
                      style: TextStyle(fontSize: 14),
                    ),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (value) =>
                        setState(() => _favorite = value ?? false),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('start-new-conversation'),
                      onPressed: _selectedPath == null ||
                              _loading ||
                              _selectingDirectory ||
                              _error != null
                          ? null
                          : () => Navigator.pop(context,
                              (path: _selectedPath!, favorite: _favorite)),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text(
                        '在此目录开始聊天',
                        style: TextStyle(fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DirectoryNode {
  String path;
  final String name;
  RemoteDirectoryListing? listing;
  String? error;
  bool childrenLoaded = false;
  bool expanded = false;
  bool loading = false;

  _DirectoryNode(this.path, this.name);
}

class _FavoriteDirectoryManager extends StatefulWidget {
  final Set<String> paths;
  final Future<RemoteDirectoryListing> Function(String) loadDirectories;
  final Future<void> Function(Set<String>) onPathsChanged;
  final ValueChanged<String> onNavigate;

  const _FavoriteDirectoryManager({
    required this.paths,
    required this.loadDirectories,
    required this.onPathsChanged,
    required this.onNavigate,
  });

  @override
  State<_FavoriteDirectoryManager> createState() =>
      _FavoriteDirectoryManagerState();
}

class _FavoriteDirectoryManagerState extends State<_FavoriteDirectoryManager> {
  late Set<String> _paths = Set.of(widget.paths);
  bool _saving = false;
  String? _error;
  final TextEditingController _pathController = TextEditingController();

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<String?> _askPath({String initial = ''}) async {
    _pathController.text = initial;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          initial.isEmpty ? '添加收藏目录' : '编辑目录路径',
          style: const TextStyle(fontSize: 17),
        ),
        content: TextField(
          key: const Key('new-conversation-directory'),
          controller: _pathController,
          autofocus: true,
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: '/path/to/directory',
            hintStyle: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消', style: TextStyle(fontSize: 14)),
          ),
          TextButton(
            onPressed: () {
              if (_pathController.text.trim().isNotEmpty) {
                Navigator.pop(context, _pathController.text.trim());
              }
            },
            child: const Text('打开', style: TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
    return value;
  }

  Future<String?> _validatedPath(String value) async {
    try {
      final listing = await widget.loadDirectories(value);
      if (listing.error != null) {
        _setError(listing.error!);
        return null;
      }
      return listing.path;
    } catch (error) {
      _setError(error.toString());
      return null;
    }
  }

  void _setError(String error) {
    if (!mounted) return;
    final lower = error.toLowerCase();
    setState(() {
      if (lower.contains('no such file') || lower.contains('not found')) {
        _error = '目录不存在，请选择其他目录。';
      } else if (lower.contains('permission') || lower.contains('denied')) {
        _error = '没有权限访问这个目录，请选择其他目录。';
      } else {
        _error = '无法读取目录，请检查连接后重试。';
      }
    });
  }

  Future<void> _persist(Set<String> paths) async {
    setState(() => _error = null);
    try {
      await widget.onPathsChanged(paths);
      if (!mounted) return;
      setState(() {
        _paths = Set.of(paths);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '收藏目录保存失败，请重试。');
    }
  }

  Future<void> _add() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final entered = await _askPath();
      if (!mounted || entered == null) return;
      final path = await _validatedPath(entered);
      if (!mounted || path == null) return;
      await _persist({..._paths, path});
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit(String oldPath) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final entered = await _askPath(initial: oldPath);
      if (!mounted || entered == null) return;
      final path = await _validatedPath(entered);
      if (!mounted || path == null) return;
      final next = Set<String>.of(_paths)
        ..remove(oldPath)
        ..add(path);
      await _persist(next);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove(String path) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final next = Set<String>.of(_paths)..remove(path);
      await _persist(next);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _basename(String path) {
    final trimmed = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = trimmed.lastIndexOf('/');
    final name = index < 0 ? trimmed : trimmed.substring(index + 1);
    return name.isEmpty ? '~' : name;
  }

  @override
  Widget build(BuildContext context) {
    final paths = _paths.toList()..sort();
    final theme = Theme.of(context);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(
          children: [
            ListTile(
              title: const Text('收藏目录', style: TextStyle(fontSize: 17)),
              trailing: TextButton.icon(
                onPressed: _saving ? null : _add,
                icon: const Icon(Icons.add),
                label: const Text('添加目录', style: TextStyle(fontSize: 14)),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(fontSize: 14),
                ),
              ),
            Expanded(
              child: paths.isEmpty
                  ? Center(
                      child: Text(
                        '暂无收藏目录',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView(
                      children: [
                        for (final path in paths)
                          ListTile(
                            key: Key('new-directory-favorite-$path'),
                            minTileHeight: 50,
                            title: Text(
                              _basename(path),
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(fontSize: 14),
                            ),
                            subtitle: Text(
                              path,
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 12,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            onTap:
                                _saving ? null : () => widget.onNavigate(path),
                            trailing: PopupMenuButton<String>(
                              key: Key('new-directory-favorite-actions-$path'),
                              enabled: !_saving,
                              onSelected: (value) =>
                                  value == 'edit' ? _edit(path) : _remove(path),
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'edit',
                                  child: Text(
                                    '编辑路径',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'remove',
                                  child: Text(
                                    '取消收藏',
                                    style: TextStyle(fontSize: 14),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
