"""在远程 tmux 中执行一轮 Codex 对话，并供 SSH 客户端断线后重新读取。"""

import base64
import fcntl
import glob
import json
import os
import re
import select
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path.home() / ".ssh_tool" / "chat_jobs"
JOB_ID = re.compile(r"^[0-9a-f]{32}$")


def job_path(job_id: str) -> Path:
    if not JOB_ID.fullmatch(job_id):
        raise ValueError("无效的任务 ID")
    return ROOT / job_id


def save_state(path: Path, state: dict) -> None:
    temporary = path / "state.tmp"
    temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path / "state.json")


def append_event(path: Path, event: dict) -> None:
    with (path / "events.jsonl").open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, ensure_ascii=False) + "\n")
        stream.flush()


def load_state(path: Path) -> dict:
    return json.loads((path / "state.json").read_text(encoding="utf-8"))


def codex_binary() -> str:
    home = str(Path.home())
    candidates = [home + "/.local/bin/codex"]
    candidates += glob.glob(home + "/.config/nvm/versions/node/*/bin/codex")
    candidates += glob.glob(home + "/.nvm/versions/node/*/bin/codex")
    return next(
        (candidate for candidate in reversed(candidates) if os.access(candidate, os.X_OK)),
        shutil.which("codex") or "codex",
    )


def codex_app_server_command() -> list[str]:
    home = Path.home()
    auth = home / ".local" / "bin" / "codex-auth"
    command = ([str(auth), "run", "--"] if os.access(auth, os.X_OK)
               else [codex_binary()])
    command.append("--dangerously-bypass-approvals-and-sandbox")
    return command + ["app-server", "--stdio"]


def codex_app_server_environment() -> dict[str, str]:
    environment = os.environ.copy()
    auth = Path.home() / ".local" / "bin" / "codex-auth"
    if os.access(auth, os.X_OK):
        # 非交互 SSH 的 PATH 可能先找到旧版 /usr/bin/codex。
        environment["CODEX_AUTH_CODEX_BIN"] = codex_binary()
    return environment


def writer_locked(thread_id: str) -> bool:
    codex_home = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
    lock = codex_home / "thread-writer-locks" / f"{thread_id}.lock"
    if not lock.exists():
        return False
    with lock.open("a+") as stream:
        try:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
    return False


def start(encoded_request: str) -> None:
    request = json.loads(base64.b64decode(encoded_request))
    job_id = request["jobId"]
    path = job_path(job_id)
    try:
        path.mkdir(parents=True, mode=0o700, exist_ok=False)
    except FileExistsError:
        # SSH 可以在远端启动成功后、收到回执前断开；同一请求重试不能再开一轮。
        if load_state(path).get("jobId") != job_id:
            raise
        print(json.dumps({"jobId": job_id}))
        return
    work_dir = os.path.expanduser(request["workDir"])
    if not Path(work_dir).is_dir():
        path.rmdir()
        raise RuntimeError("对话目录不存在：" + work_dir)
    if request.get("threadId") and not request.get("fork") and writer_locked(request["threadId"]):
        path.rmdir()
        raise RuntimeError("该对话正在其他 Codex 窗口中占用，请先结束或接管")
    os.chmod(path, 0o700)
    request_file = path / "request.json"
    request_file.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
    os.chmod(request_file, 0o600)
    state = {
        "jobId": job_id,
        "threadId": None if request.get("fork") else request.get("threadId"),
        "title": (request.get("title") or request["prompt"]).strip()[:160],
        "tmuxName": "ssh-chat-" + job_id[:12],
        "status": "starting",
    }
    save_state(path, state)
    command = "python3 -u " + shlex.quote(str(Path(__file__))) + " run " + job_id
    subprocess.run(
        ["tmux", "new-session", "-d", "-s", state["tmuxName"], command],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    print(json.dumps({"jobId": job_id}))


def run(job_id: str) -> None:
    path = job_path(job_id)
    request = json.loads((path / "request.json").read_text(encoding="utf-8"))
    state = load_state(path)
    state["status"] = "running"
    state["startedAt"] = int(time.time() * 1000)
    save_state(path, state)
    started = time.monotonic()
    work_dir = request["workDir"]
    if work_dir == "~":
        work_dir = str(Path.home())
    process = None
    final_state = None
    try:
        if not Path(work_dir).is_dir():
            raise RuntimeError("对话目录不存在：" + work_dir)
        with (path / "codex.stderr").open("wb") as error_log:
            process = subprocess.Popen(
                codex_app_server_command(),
                cwd=work_dir,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=error_log,
                env=codex_app_server_environment(),
            )

            def send(message: dict) -> None:
                process.stdin.write((json.dumps(message) + "\n").encode())
                process.stdin.flush()

            send({
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "ssh_tool_app", "version": "1"},
                    "capabilities": {"experimentalApi": True},
                },
            })
            data = b""
            current_item = None
            reasoning_with_deltas = set()
            draft = ""
            answer = ""
            completed = False
            while True:
                ready, _, _ = select.select([process.stdout], [], [], 1)
                if not ready:
                    if process.poll() is not None:
                        raise RuntimeError("远端 Codex 提前退出")
                    continue
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("远端 Codex 输出中断")
                data += chunk
                while b"\n" in data:
                    line, data = data.split(b"\n", 1)
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if event.get("error") and event.get("id") is not None:
                        error = event["error"]
                        raise RuntimeError(error.get("message", str(error)))
                    if event.get("id") == 1:
                        send({"method": "initialized", "params": {}})
                        params = {
                            "cwd": work_dir,
                            "model": request["model"],
                            "approvalPolicy": "never",
                            "sandbox": "danger-full-access",
                        }
                        if request.get("threadId"):
                            params["threadId"] = request["threadId"]
                            if not request.get("fork"):
                                params["excludeTurns"] = True
                        method = ("thread/fork" if request.get("fork") else
                                  "thread/resume" if request.get("threadId") else
                                  "thread/start")
                        send({
                            "id": 2,
                            "method": method,
                            "params": params,
                        })
                    elif event.get("id") == 2:
                        state["threadId"] = event["result"]["thread"]["id"]
                        save_state(path, state)
                        append_event(path, {"type": "started", "threadId": state["threadId"]})
                        send({
                            "id": 3,
                            "method": "turn/start",
                            "params": {
                                "threadId": state["threadId"],
                                "input": [{"type": "text", "text": request["prompt"], "text_elements": []}],
                                "cwd": work_dir,
                                "model": request["model"],
                                "effort": request["effort"],
                            },
                        })
                    elif event.get("method") == "item/reasoning/summaryTextDelta":
                        params = event.get("params", {})
                        delta = params.get("delta", "")
                        if delta:
                            reasoning_with_deltas.add(params.get("itemId"))
                            append_event(path, {"type": "activityDelta", "delta": delta,
                                                "itemId": params.get("itemId")})
                    elif event.get("method") == "item/reasoning/summaryPartAdded":
                        params = event.get("params", {})
                        if params.get("summaryIndex", 0) > 0:
                            append_event(path, {"type": "activityDelta", "delta": "\n",
                                                "itemId": params.get("itemId")})
                    elif event.get("method") == "item/started":
                        item = event.get("params", {}).get("item", {})
                        detail = (item.get("command") if item.get("type") == "commandExecution"
                                  else item.get("tool") if item.get("type") == "mcpToolCall"
                                  else item.get("query") if item.get("type") == "webSearch"
                                  else None)
                        if isinstance(detail, str) and detail.strip():
                            append_event(path, {"type": "activity", "text": detail.strip()[:500],
                                                "itemId": item.get("id")})
                    elif event.get("method") == "item/commandExecution/outputDelta":
                        params = event.get("params", {})
                        delta = params.get("delta", "")
                        if isinstance(delta, str) and delta:
                            append_event(path, {"type": "activityDelta", "delta": delta[:1000],
                                                "itemId": params.get("itemId")})
                    elif event.get("method") == "turn/plan/updated":
                        plan = event.get("params", {}).get("plan", [])
                        current = next((step.get("step") for step in plan
                                        if step.get("status") == "inProgress"), None)
                        if isinstance(current, str) and current.strip():
                            append_event(path, {"type": "activity", "text": current.strip()[:500]})
                    elif event.get("method") == "item/agentMessage/delta":
                        params = event["params"]
                        reset = params["itemId"] != current_item
                        if reset:
                            current_item = params["itemId"]
                            draft = ""
                        draft += params["delta"]
                        append_event(path, {
                            "type": "partial", "delta": params["delta"], "reset": reset,
                        })
                    elif event.get("method") == "item/completed":
                        item = event["params"].get("item", {})
                        if item.get("type") == "agentMessage":
                            answer = item.get("text", draft)
                            append_event(path, {"type": "partial", "text": answer})
                        elif item.get("type") == "reasoning" and item.get("id") not in reasoning_with_deltas:
                            summary = item.get("summary", [])
                            if isinstance(summary, list):
                                text = "\n".join(part for part in summary if isinstance(part, str))
                                if text.strip():
                                    append_event(path, {"type": "activity", "text": text[:1000],
                                                        "itemId": item.get("id")})
                    elif event.get("method") == "turn/completed":
                        turn = event["params"]["turn"]
                        if turn.get("status") != "completed":
                            error = turn.get("error") or {}
                            raise RuntimeError(error.get("message", "Codex 回答未完成"))
                        final_state = {"status": "completed", "answer": answer}
                        completed = True
                        break
                if completed:
                    break
    except Exception as error:
        final_state = {"status": "failed", "error": str(error)}
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        (path / "request.json").unlink(missing_ok=True)
        if final_state is not None:
            final_state["durationSeconds"] = max(1, round(time.monotonic() - started))
            state.update(final_state)
            save_state(path, state)
            append_event(path, {"type": state["status"], **final_state})


def snapshot(job_id: str, offset: int) -> dict:
    offset = int(offset)
    path = job_path(job_id)
    state = load_state(path)
    events_file = path / "events.jsonl"
    events = []
    next_offset = offset
    if events_file.exists():
        with events_file.open("rb") as stream:
            stream.seek(offset)
            data = stream.read()
        last_line = data.rfind(b"\n")
        if last_line >= 0:
            complete = data[: last_line + 1]
            next_offset += len(complete)
            events = [json.loads(line) for line in complete.splitlines()]
    if state["status"] in ("starting", "running"):
        alive = subprocess.run(
            ["tmux", "has-session", "-t", state["tmuxName"]],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode == 0
        if not alive:
            state = load_state(path)
            if state["status"] in ("starting", "running"):
                state.update({"status": "failed", "error": "远端 tmux 任务已结束"})
                save_state(path, state)
    return {"offset": next_offset, "events": events, "state": state}


def poll(job_id: str, offset: int) -> None:
    print(json.dumps(snapshot(job_id, offset), ensure_ascii=False))


def follow(job_id: str, offset: int) -> None:
    offset = int(offset)
    while True:
        update = snapshot(job_id, offset)
        offset = update["offset"]
        if update["events"] or update["state"]["status"] not in ("starting", "running"):
            print(json.dumps(update, ensure_ascii=False), flush=True)
        if update["state"]["status"] not in ("starting", "running"):
            return
        time.sleep(0.25)


def find(thread_id: str) -> None:
    if ROOT.exists():
        paths = sorted(ROOT.iterdir(), key=lambda path: path.stat().st_mtime, reverse=True)
        for path in paths:
            if not path.is_dir():
                continue
            try:
                state = load_state(path)
            except (OSError, ValueError):
                continue
            active = state.get("status") in ("starting", "running")
            just_finished = (
                state.get("status") in ("completed", "failed")
                and time.time() - (path / "state.json").stat().st_mtime < 30
            )
            if state.get("threadId") == thread_id and (active or just_finished):
                print(json.dumps(state))
                return
    print("{}")


if __name__ == "__main__":
    try:
        {"start": start, "run": run, "poll": poll, "follow": follow, "find": find}[sys.argv[1]](*sys.argv[2:])
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        sys.exit(1)
