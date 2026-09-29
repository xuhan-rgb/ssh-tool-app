/// Shared remote snapshot/delta protocol. Readers remain independently runnable.
const conversationSyncScript = r'''
import contextlib
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile


def sync(reader, provider):
    session_id = sys.argv[1]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
        raise ValueError("invalid session id")
    requested = sys.argv[2] if len(sys.argv) > 2 else ""
    if provider == "codex":
        root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex"))).expanduser() / "sessions"
        path = next(root.rglob(f"*-{session_id}.jsonl"), None)
    else:
        root = Path.home() / ".claude" / "projects"
        path = next(root.glob(f"*/{session_id}.jsonl"), None)
    if path is None:
        raise FileNotFoundError("conversation log is unavailable")
    parser_version = hashlib.sha256(reader.encode()).hexdigest()
    key = hashlib.sha256(json.dumps([provider, str(root.resolve()), session_id, parser_version]).encode()).hexdigest()
    cache_dir = Path.home() / ".cache" / "ssh_tool" / "conversation_sync"
    cache_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    cache_path = cache_dir / (key + ".json")

    def signature():
        stat = path.stat()
        return [str(path.resolve()), stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]

    def digest(value):
        return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    # One stable lock per cache slot; never unlink an active lock inode.
    with (cache_dir / (key + ".lock")).open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            state = json.loads(cache_path.read_text())
            if state.get("protocol") != 1 or not isinstance(state.get("snapshots"), list):
                state = {}
        except (OSError, ValueError, AttributeError):
            state = {}
        before = signature()
        snapshots = state.get("snapshots", [])
        if not snapshots or state.get("signature") != before:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                exec(compile(reader, "conversation_reader", "exec"), {"__name__": "__main__"})
            rows = [json.loads(line) for line in output.getvalue().splitlines() if line.strip()]
            after = signature()
            if before[:3] != after[:3] or after[3] < before[3]:
                raise RuntimeError("conversation log changed identity during read; retry")
            # Source positions are stable for append-only logs. A replacement or
            # truncation starts a new generation, even when positions repeat.
            previous = state.get("signature", [])
            generation = state.get("generation")
            if not generation or previous[:3] != before[:3] or (len(previous) > 3 and before[3] < previous[3]):
                generation = digest(before)
                snapshots = []
            snapshot = {"version": digest([generation, rows]), "records": rows}
            if not snapshots or snapshots[-1]["version"] != snapshot["version"]:
                snapshots = (snapshots + [snapshot])[-3:]
            state = {"protocol": 1, "signature": before, "generation": generation, "snapshots": snapshots}
            fd, temporary = tempfile.mkstemp(dir=cache_dir, suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as stream:
                    json.dump(state, stream, ensure_ascii=False, separators=(",", ":"))
                os.replace(temporary, cache_path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
        else:
            cache_path.touch()
        current = snapshots[-1]
        response = {"protocol": 1, "version": current["version"]}
        baseline = next((item for item in snapshots if item["version"] == requested), None)
        if requested == current["version"]:
            response["type"] = "unchanged"
        elif baseline is None:
            response.update(type="snapshot", records=current["records"])
        else:
            old = {row["_syncId"]: row for row in baseline["records"]}
            new = {row["_syncId"]: row for row in current["records"]}
            response.update(type="delta", base=requested,
                upserts=[row for row in current["records"] if old.get(row["_syncId"]) != row],
                removed=[key for key in old if key not in new],
                order=list(new))
        print(json.dumps(response, ensure_ascii=False, separators=(",", ":")))

    # Eviction only discards an optimization: stale clients receive snapshots.
    entries = []
    for item in cache_dir.glob("*.json"):
        try:
            stat = item.stat()
            entries.append((stat.st_mtime_ns, stat.st_size, item))
        except FileNotFoundError:
            pass
    total = 0
    for index, (_, size, item) in enumerate(sorted(entries, reverse=True)):
        total += size
        if index >= 48 or total > 64 * 1024 * 1024:
            try:
                item.unlink()
            except FileNotFoundError:
                pass
''';
