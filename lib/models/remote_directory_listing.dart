class RemoteDirectoryListing {
  final String path;
  final List<String> dirs;
  final String homePath;
  final List<String> diskPaths;
  final String? error;

  const RemoteDirectoryListing({
    required this.path,
    required this.dirs,
    this.homePath = '~',
    this.diskPaths = const [],
    this.error,
  });
}
