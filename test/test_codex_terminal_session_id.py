import os
import subprocess
import tempfile
import time
from pathlib import Path


RESOLVER = Path(__file__).resolve().parents[1] / "assets" / "codex_terminal_session_id.py"
THREAD_ID = "11111111-2222-3333-4444-555555555555"


def test_finds_thread_held_by_tmux_process():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        lock = root / "thread-writer-locks" / f"{THREAD_ID}.lock"
        lock.parent.mkdir()
        tmux = root / "tmux"
        tmux.write_text("#!/bin/sh\necho \"$TEST_PANE_PID\"\n")
        tmux.chmod(0o755)
        holder = subprocess.Popen(
            ["python3", "-c", "import sys,time; f=open(sys.argv[1], 'w'); time.sleep(10)", str(lock)],
        )
        try:
            deadline = time.monotonic() + 2
            while not lock.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            result = subprocess.run(
                ["python3", str(RESOLVER), "codex-1"],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                     "TEST_PANE_PID": str(holder.pid)},
                capture_output=True, text=True, check=True,
            )
            assert result.stdout.strip() == THREAD_ID
        finally:
            holder.terminate()
            holder.wait()


def test_does_not_guess_when_tmux_has_two_codex_threads():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        tmux = root / "tmux"
        tmux.write_text("#!/bin/sh\nprintf '%s\\n' $TEST_PANE_PID\n")
        tmux.chmod(0o755)
        holders = []
        try:
            for thread_id in (THREAD_ID, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"):
                lock = root / "thread-writer-locks" / f"{thread_id}.lock"
                lock.parent.mkdir(exist_ok=True)
                holders.append(subprocess.Popen(
                    ["python3", "-c", "import sys,time; f=open(sys.argv[1], 'w'); time.sleep(10)", str(lock)],
                ))
            deadline = time.monotonic() + 2
            while len(list((root / "thread-writer-locks").iterdir())) < 2 and time.monotonic() < deadline:
                time.sleep(0.01)
            result = subprocess.run(
                ["python3", str(RESOLVER), "codex-1"],
                env={**os.environ, "PATH": f"{root}:{os.environ['PATH']}",
                     "TEST_PANE_PID": " ".join(str(holder.pid) for holder in holders)},
                capture_output=True, text=True, check=True,
            )
            assert result.stdout.strip() == ""
        finally:
            for holder in holders:
                holder.terminate()
                holder.wait()
