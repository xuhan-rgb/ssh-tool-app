import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_tool_app/services/codex_session_service.dart';

CodexConversationRecord userMessage(String text) =>
    CodexConversationRecord(kind: 'user', timestamp: null, text: text);

void main() {
  setUp(() => CodexSessionService.clearCache());

  test('pending messages are isolated by connection and conversation', () {
    final pending = CodexSessionService.pendingMessages('a', 'thread');
    pending.add('hello', pending.nextOccurrence([], 'hello'));
    expect(CodexSessionService.pendingMessages('a', 'thread'), same(pending));
    expect(
        CodexSessionService.pendingMessages('b', 'thread').isNotEmpty, false);
    expect(CodexSessionService.pendingMessages('a', 'other').isNotEmpty, false);
    CodexSessionService.clearCache('b');
    expect(CodexSessionService.pendingMessages('a', 'thread'), same(pending));
    CodexSessionService.clearCache('a');
    expect(
        CodexSessionService.pendingMessages('a', 'thread').isNotEmpty, false);
  });

  test('each repeated send requires another occurrence in the remote log', () {
    final pending = CodexPendingMessages();
    final records = [userMessage('继续')];
    pending.add('继续', pending.nextOccurrence(records, '继续'));
    pending.add('继续', pending.nextOccurrence(records, '继续'));
    pending.reconcile(records);
    expect(pending.isNotEmpty, true);
    records.add(userMessage('继续'));
    pending.reconcile(records);
    expect(pending.isNotEmpty, true);
    records.add(userMessage('继续'));
    pending.reconcile(records);
    expect(pending.isNotEmpty, false);
  });

  test('receiving one message leaves other queued messages pending', () {
    final pending = CodexPendingMessages();
    pending.add('first', pending.nextOccurrence([], 'first'));
    pending.add('second', pending.nextOccurrence([], 'second'));
    pending.reconcile([userMessage('second')]);
    expect(pending.isNotEmpty, true);
    pending.reconcile([userMessage('first'), userMessage('second')]);
    expect(pending.isNotEmpty, false);
  });

  test('confirmation matches the whitespace normalization of remote records',
      () {
    final pending = CodexPendingMessages();
    const text = '  保留内部\n换行  \n';
    pending.add(text, pending.nextOccurrence([], text));
    pending.reconcile([userMessage(text.trim())]);
    expect(pending.isNotEmpty, false);
  });
}
