class CodexCompletionNotice {
  final String id;
  final String connectionId;
  final String threadId;
  final String? title;
  final DateTime completedAt;
  final bool read;

  const CodexCompletionNotice({
    required this.id,
    required this.connectionId,
    required this.threadId,
    this.title,
    required this.completedAt,
    this.read = false,
  });

  factory CodexCompletionNotice.fromJson(Map<String, dynamic> json) =>
      CodexCompletionNotice(
        id: json['id'] as String,
        connectionId: json['connectionId'] as String,
        threadId: json['threadId'] as String,
        title: json['title'] as String?,
        completedAt: DateTime.parse(json['completedAt'] as String),
        read: json['read'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'connectionId': connectionId,
        'threadId': threadId,
        'title': title,
        'completedAt': completedAt.toIso8601String(),
        'read': read,
      };

  CodexCompletionNotice markRead() => CodexCompletionNotice(
        id: id,
        connectionId: connectionId,
        threadId: threadId,
        title: title,
        completedAt: completedAt,
        read: true,
      );

  static String formatTitle(String threadId, String? title) {
    final name = title?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    final shortId = threadId.length > 8 ? threadId.substring(0, 8) : threadId;
    return name.isEmpty ? '对话 $shortId' : name;
  }

  String get displayTitle => formatTitle(threadId, title);
  String get notificationTitle => '$displayTitle · 已完成';
}
