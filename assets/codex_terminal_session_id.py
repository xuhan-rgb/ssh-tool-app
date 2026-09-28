"""Find the single Codex thread held by a tmux session's processes."""

import os
import re
import subprocess
import sys
from pathlib import Path


UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def main(session_name: str) -> None:
    panes = subprocess.run(
        ["tmux", "list-panes", "-s", "-t", session_name, "-F", "#{pane_pid}"],
        capture_output=True, text=True,
    )
    if panes.returncode != 0:
        return
    pending = [int(pid) for pid in panes.stdout.split() if pid.isdigit()]
    visited = set()
    thread_ids = set()
    while pending:
        pid = pending.pop()
        if pid in visited:
            continue
        visited.add(pid)
        try:
            children = Path(f"/proc/{pid}/task/{pid}/children").read_text()
            pending.extend(int(child) for child in children.split())
            for fd in Path(f"/proc/{pid}/fd").iterdir():
                target = os.readlink(fd)
                if "/thread-writer-locks/" not in target and "/sessions/" not in target:
                    continue
                match = UUID.search(Path(target).name)
                if match:
                    thread_ids.add(match.group())
        except (OSError, ValueError):
            continue
    if len(thread_ids) == 1:
        print(thread_ids.pop())


if __name__ == "__main__":
    main(sys.argv[1])
