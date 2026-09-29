# Conversation history synchronization

Codex and Claude history readers use the existing SSH connection. The viewer still
receives the latest 300 parsed records from `readConversation()`; synchronization
and merging happen in the service layer. Poll intervals are unchanged.

## Protocol

- `snapshot`: initial load or unavailable baseline; replaces all local records.
- `delta`: includes the client's `base` version, new `version`, changed/new
  `upserts`, `removed` IDs, and the final `order` of IDs in the 300-record window.
- `unchanged`: version only; no conversation records.

Record IDs derive from source line and content-block positions. A source replacement
or observed truncation resets the snapshot generation. Repeated message text is
not used as an identity. Tool results and token-usage events may update old records.

The client commits records and version together after validating the response. It
coalesces simultaneous requests for one connection/conversation, keeps at most 24
snapshots per provider, and rejects stale cache writes after cache clearing. Network
failures retain the previous cursor; a retry can receive the same delta safely.
Connection edits/deletion clear both providers' synchronization state.

## Remote cache

`~/.cache/ssh_tool/reader_scripts/` stores content-addressed Python scripts. A small
command checks and executes the script; missing versions are uploaded atomically.
Scripts are never uploaded on a normal cached poll. Cached script versions remain
until removed; deleting this directory is safe and triggers automatic deployment.

`~/.cache/ssh_tool/conversation_sync/` stores up to three snapshot versions per
reader/session. File identity, size, mtime and ctime detect changes. Unchanged files
skip parsing. Changed files still use the full existing parser, then compute record
differences. This is incremental transfer, not incremental log parsing.

Snapshot files use atomic replacement and per-key locks. A best-effort sweep limits
JSON caches to 48 files / 64 MiB; tiny lock files are retained to keep lock identities
stable. Missing, malformed or evicted caches rebuild automatically. Missing source
logs and reader errors fail the request rather than clear the visible conversation.

## Verification

- `flutter --no-version-check test test/conversation_sync_test.dart test/conversation_sync_integration_test.dart test/remote_python_script_test.dart`
- `python3 -m unittest discover -s test -p test_conversation_sync.py`

The Python suite compares every merged snapshot against the full reader, including
updates to old records, window rollover, partial JSON, replacement/truncation,
concurrent clients, lost responses, and cache recovery. Its deterministic byte
benchmark includes the first snapshot, one append, and ten idle polls over 300
roughly 1 KB records. It measures response payloads, not SSH wire traffic. The Dart
integration test executes the deployed Python script locally through a shell; it
does not establish an SSH connection or launch the UI.
