"""验证手机启动命令退出后，远端 tmux 仍会完成文字问答。"""

import base64
import fcntl
import importlib.util
import json
import os
import subprocess
import tempfile
import time
from pathlib import Path


WORKER = Path(__file__).resolve().parents[1] / "assets" / "codex_chat_worker.py"
FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import os
import signal
import sys
import time
from pathlib import Path

def stop(_signal, _frame):
    time.sleep(0.5)
    (Path.home() / "codex_stopped").write_text("yes")
    sys.exit(0)

signal.signal(signal.SIGTERM, stop)
(Path.home() / "codex_args.json").write_text(json.dumps({"args": sys.argv[1:], "pid": os.getpid()}))
experimental_api = False

for line in sys.stdin:
    request = json.loads(line)
    with (Path.home() / "codex_requests.jsonl").open("a") as log:
        log.write(json.dumps(request) + "\n")
    request_id = request.get("id")
    if request_id == 1:
        experimental_api = request.get("params", {}).get("capabilities", {}).get("experimentalApi") is True
        print(json.dumps({"id": 1, "result": {}}), flush=True)
    elif request_id == 2:
        if request.get("method") == "thread/resume" and request.get("params", {}).get("excludeTurns") and not experimental_api:
            print(json.dumps({"id": 2, "error": {"message": "thread/resume.excludeTurns requires experimentalApi capability"}}), flush=True)
            continue
        thread_id = "forked-thread" if request.get("method") == "thread/fork" else "thread-test"
        print(json.dumps({"id": 2, "result": {"thread": {"id": thread_id}}}), flush=True)
    elif request_id == 3:
        print(json.dumps({"id": 3, "result": {}}), flush=True)
        prompt_text = request.get("params", {}).get("input", [{}])[0].get("text", "")
        if prompt_text == "server-dies":
            sys.exit(0)
        print(json.dumps({"method": "turn/started", "params": {"turn": {"status": "inProgress"}}}), flush=True)
        print(json.dumps({"method": "item/reasoning/summaryTextDelta", "params":
                          {"itemId": "reason", "delta": "检查代码"}}), flush=True)
        print(json.dumps({"method": "item/completed", "params":
                          {"item": {"id": "reason-fallback", "type": "reasoning",
                                    "summary": ["发现问题位置"]}}}), flush=True)
        print(json.dumps({"method": "item/started", "params":
                          {"item": {"id": "command", "type": "commandExecution", "command": "rg -n widget lib"}}}), flush=True)
        print(json.dumps({"method": "item/commandExecution/outputDelta", "params":
                          {"itemId": "command", "delta": "lib/a.dart:1"}}), flush=True)
        time.sleep(0.8)
        print(json.dumps({"method": "item/agentMessage/delta", "params":
                          {"itemId": "answer", "delta": "后台"}}), flush=True)
        time.sleep(0.2)
        print(json.dumps({"method": "item/agentMessage/delta", "params":
                          {"itemId": "answer", "delta": "完成"}}), flush=True)
        print(json.dumps({"method": "item/completed", "params":
                          {"item": {"type": "agentMessage", "text": "后台完成"}}}), flush=True)
        status = "failed" if prompt_text == "fail-turn" else "completed"
        print(json.dumps({"method": "turn/completed", "params":
                          {"turn": {"status": status}}}), flush=True)
        if prompt_text == "die-while-idle":
            sys.exit(0)
    elif request.get("method") == "turn/start":
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
        print(json.dumps({"method": "item/agentMessage/delta", "params":
                          {"itemId": "answer-2", "delta": "第二轮"}}), flush=True)
        print(json.dumps({"method": "item/completed", "params":
                          {"item": {"type": "agentMessage", "text": "第二轮完成"}}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {"turn": {"status": "completed"}}}), flush=True)
'''


def test_worker_pins_codex_binary_when_ssh_path_is_stale(monkeypatch):
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        auth = home / ".local" / "bin" / "codex-auth"
        modern = home / ".config" / "nvm" / "versions" / "node" / "v20" / "bin" / "codex"
        for binary in (auth, modern):
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
        monkeypatch.setenv("HOME", temporary)
        spec = importlib.util.spec_from_file_location("codex_chat_worker_test", WORKER)
        worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(worker)
        assert worker.codex_app_server_environment()["CODEX_AUTH_CODEX_BIN"] == str(modern)
        assert worker.codex_app_server_command()[:3] == [str(auth), "run", "--"]


def test_tmux_job_survives_launcher_and_can_be_reconnected():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        home = root / "home"
        home.mkdir()
        tmux_dir = root / "tmux"
        tmux_dir.mkdir()
        binary = home / ".local" / "bin" / "codex"
        binary.parent.mkdir(parents=True)
        binary.write_text(FAKE_CODEX, encoding="utf-8")
        binary.chmod(0o755)
        environment = os.environ.copy()
        environment.update(HOME=str(home), TMUX_TMPDIR=str(tmux_dir))
        environment.pop("TMUX", None)
        job_id = "fedcba9876543210fedcba9876543210"
        request = {
            "jobId": job_id,
            "workDir": str(root),
            "prompt": "测试后台执行",
            "title": "修复工作台环境安装提示",
            "model": "gpt-6-sol",
            "effort": "medium",
            "threadId": None,
        }
        encoded = base64.b64encode(json.dumps(request).encode()).decode()
        follower = None
        try:
            started = subprocess.run(
                ["python3", str(WORKER), "start", encoded],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            assert json.loads(started.stdout)["jobId"] == job_id
            state = json.loads(
                (home / ".ssh_tool" / "chat_jobs" / job_id / "state.json").read_text()
            )
            assert state["title"] == "修复工作台环境安装提示"
            retried = subprocess.run(
                ["python3", str(WORKER), "start", encoded],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            assert json.loads(retried.stdout)["jobId"] == job_id
            follower = subprocess.Popen(
                ["python3", str(WORKER), "follow", job_id, "0"],
                env=environment,
                stdout=subprocess.PIPE,
                text=True,
            )
            # 启动命令已结束；工作进程必须仍留在 tmux 中。
            assert subprocess.run(
                ["tmux", "has-session", "-t", "ssh-chat-" + job_id[:12]],
                env=environment,
                capture_output=True,
            ).returncode == 0
            offset = 0
            events = []
            reconnected_while_running = False
            second_id = "abcdef0123456789abcdef0123456789"
            second_request = {**request, "jobId": second_id, "threadId": "thread-test",
                              "prompt": "继续对话", "model": "gpt-6-astra", "effort": "high"}
            second_encoded = base64.b64encode(json.dumps(second_request).encode()).decode()
            queued_second = False
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                polled = subprocess.run(
                    ["python3", str(WORKER), "poll", job_id, str(offset)],
                    env=environment,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                snapshot = json.loads(polled.stdout)
                offset = snapshot["offset"]
                events.extend(snapshot["events"])
                if snapshot["state"]["status"] == "running" and snapshot["state"]["threadId"]:
                    recovered = subprocess.run(
                        ["python3", str(WORKER), "find", "thread-test"],
                        env=environment,
                        check=True,
                        capture_output=True,
                        text=True,
                    )
                    reconnected_while_running = (
                        json.loads(recovered.stdout).get("jobId") in (job_id, second_id)
                    )
                    if not queued_second:
                        assert json.loads(recovered.stdout).get("jobId") == job_id
                    if snapshot["state"]["status"] == "running" and not queued_second:
                        session_status = subprocess.run(["python3", str(WORKER), "session", "thread-test"],
                                                        env=environment, check=True, capture_output=True, text=True)
                        if json.loads(session_status.stdout) == {"open": True, "busy": True}:
                            subprocess.run(["python3", str(WORKER), "start", second_encoded], env=environment,
                                           check=True, capture_output=True, text=True)
                            busy_close = subprocess.run(["python3", str(WORKER), "close", "thread-test"],
                                                        env=environment, capture_output=True, text=True)
                            assert busy_close.returncode != 0
                            assert "仍有任务运行" in json.loads(busy_close.stdout)["error"]
                            queued_second = True
                if snapshot["state"]["status"] == "completed":
                    break
                time.sleep(0.1)
            assert snapshot["state"]["status"] == "completed", (snapshot["state"], (home / ".ssh_tool" / "chat_jobs" / job_id / "codex.stderr").read_text())
            assert snapshot["state"]["threadId"] == "thread-test"
            assert snapshot["state"]["answer"] == "后台完成"
            app_server = json.loads((home / "codex_args.json").read_text())
            assert app_server["args"] == [
                "--dangerously-bypass-approvals-and-sandbox",
                "app-server", "--stdio",
            ]
            requests = [json.loads(line) for line in
                        (home / "codex_requests.jsonl").read_text().splitlines()]
            assert next(request for request in requests if request.get("id") == 2)["params"]["sandbox"] == "danger-full-access"
            assert not (home / "codex_stopped").exists()
            assert any(event.get("type") == "partial" for event in events)
            assert any(event.get("delta") == "后台" for event in events)
            assert any(event.get("type") == "activityDelta" and "检查代码" in event.get("delta", "") for event in events)
            assert any(event.get("type") == "activity" and event.get("text") == "发现问题位置" for event in events)
            assert any(event.get("type") == "activity" and event.get("text") == "rg -n widget lib" for event in events)
            assert any(event.get("type") == "activityDelta" and event.get("itemId") == "command" for event in events)
            assert snapshot["state"]["durationSeconds"] >= 1
            assert reconnected_while_running
            followed, _ = follower.communicate(timeout=5)
            updates = [json.loads(line) for line in followed.splitlines()]
            assert len(updates) >= 2
            assert any(update["state"]["status"] == "running" for update in updates)
            assert updates[-1]["state"]["status"] == "completed"
            recovered = subprocess.run(
                ["python3", str(WORKER), "find", "thread-test"],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            assert json.loads(recovered.stdout)["jobId"] in (job_id, second_id)
            session_result = subprocess.run(["python3", str(WORKER), "session", "thread-test"],
                                             env=environment, check=True, capture_output=True, text=True)
            assert json.loads(session_result.stdout) == {"open": True, "busy": False}
            assert queued_second
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                second_state = json.loads((home / ".ssh_tool" / "chat_jobs" / second_id / "state.json").read_text())
                if second_state["status"] == "completed":
                    break
                time.sleep(0.05)
            assert second_state["status"] == "completed", second_state
            assert second_state["answer"] == "第二轮完成"
            assert json.loads((home / "codex_args.json").read_text())["pid"] == app_server["pid"]
            idle_status = subprocess.run(["python3", str(WORKER), "session", "thread-test"],
                                         env=environment, check=True, capture_output=True, text=True)
            assert json.loads(idle_status.stdout) == {"open": True, "busy": False}
            time.sleep(0.35)
            third_id = "fedcba9876543210abcdef0123456789"
            third_request = {**request, "jobId": third_id, "threadId": "thread-test",
                             "prompt": "空闲后继续", "model": "gpt-6-luna", "effort": "low"}
            third_encoded = base64.b64encode(json.dumps(third_request).encode()).decode()
            for _ in range(2):
                subprocess.run(["python3", str(WORKER), "start", third_encoded], env=environment,
                               check=True, capture_output=True, text=True)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                third_state = json.loads((home / ".ssh_tool" / "chat_jobs" / third_id / "state.json").read_text())
                if third_state["status"] == "completed":
                    break
                time.sleep(0.05)
            assert third_state["status"] == "completed", third_state
            assert third_state["answer"] == "第二轮完成"
            assert json.loads((home / "codex_args.json").read_text())["pid"] == app_server["pid"]
            all_requests = [json.loads(line) for line in (home / "codex_requests.jsonl").read_text().splitlines()]
            turn_requests = [item for item in all_requests if item.get("method") == "turn/start"]
            assert len(turn_requests) == 3
            assert turn_requests[1]["params"]["model"] == "gpt-6-astra"
            assert turn_requests[2]["params"]["model"] == "gpt-6-luna"
            closed = subprocess.run(["python3", str(WORKER), "close", "thread-test"], env=environment,
                                    check=True, capture_output=True, text=True)
            assert json.loads(closed.stdout) == {"closed": True, "open": False}
            assert (home / "codex_stopped").exists()
        finally:
            if follower is not None and follower.poll() is None:
                follower.terminate()
                follower.wait(timeout=2)
            subprocess.run(["tmux", "kill-server"], env=environment, capture_output=True)


def run_direct_job_and_close(home, job_id, thread_id):
    environment = {**os.environ, "HOME": str(home), "TMUX_TMPDIR": str(home / "tmux")}
    environment.pop("TMUX", None)
    (home / "tmux").mkdir(exist_ok=True)
    name = "worker-test-" + job_id[:12]
    subprocess.run(["tmux", "new-session", "-d", "-s", name,
                    f"python3 {WORKER} run {job_id}"], env=environment, check=True)
    path = home / ".ssh_tool" / "chat_jobs" / job_id
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        state = json.loads((path / "state.json").read_text())
        if state["status"] in ("completed", "failed"):
            break
        time.sleep(0.05)
    assert state["status"] == "completed", state
    closed = subprocess.run(["python3", str(WORKER), "close", thread_id], env=environment,
                            check=True, capture_output=True, text=True)
    assert json.loads(closed.stdout) == {"closed": True, "open": False}


def test_fork_job_creates_a_new_thread_before_sending():
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        binary = home / ".local" / "bin" / "codex"
        binary.parent.mkdir(parents=True)
        binary.write_text(FAKE_CODEX, encoding="utf-8")
        binary.chmod(0o755)
        job_id = "0123456789abcdef0123456789abcdef"
        path = home / ".ssh_tool" / "chat_jobs" / job_id
        path.mkdir(parents=True)
        request = {
            "jobId": job_id,
            "workDir": temporary,
            "prompt": "新分支消息",
            "model": "gpt-6-sol",
            "effort": "medium",
            "threadId": "source-thread",
            "fork": True,
        }
        (path / "request.json").write_text(json.dumps(request))
        (path / "state.json").write_text(json.dumps({
            "jobId": job_id, "threadId": "source-thread", "status": "starting",
            "tmuxName": "worker-test-" + job_id[:12]}))
        run_direct_job_and_close(home, job_id, "forked-thread")
        methods = [json.loads(line)["method"] for line in
                   (home / "codex_requests.jsonl").read_text().splitlines()]
        assert methods == ["initialize", "initialized", "thread/fork", "turn/start"]
        state = json.loads((path / "state.json").read_text())
        assert state["status"] == "completed"
        assert state["threadId"] == "forked-thread"


def test_resume_job_declares_capability_for_excluding_turns():
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        binary = home / ".local" / "bin" / "codex"
        binary.parent.mkdir(parents=True)
        binary.write_text(FAKE_CODEX, encoding="utf-8")
        binary.chmod(0o755)
        job_id = "1123456789abcdef0123456789abcdef"
        path = home / ".ssh_tool" / "chat_jobs" / job_id
        path.mkdir(parents=True)
        (path / "request.json").write_text(json.dumps({
            "jobId": job_id, "workDir": temporary, "prompt": "继续测试",
            "model": "gpt-6-sol", "effort": "medium", "threadId": "source-thread",
        }))
        (path / "state.json").write_text(json.dumps({
            "jobId": job_id, "threadId": "source-thread", "status": "starting",
            "tmuxName": "worker-test-" + job_id[:12]}))
        run_direct_job_and_close(home, job_id, "source-thread")
        state = json.loads((path / "state.json").read_text())
        assert state["status"] == "completed", state.get("error")
        requests = [json.loads(line) for line in
                    (home / "codex_requests.jsonl").read_text().splitlines()]
        assert requests[0]["params"]["capabilities"]["experimentalApi"] is True
        assert requests[2]["method"] == "thread/resume"
        assert requests[2]["params"]["excludeTurns"] is True


def test_server_failure_and_idle_death_preserve_terminal_job_state():
    for index, prompt, expected in ((1, "server-dies", "failed"),
                                    (2, "fail-turn", "failed"),
                                    (3, "die-while-idle", "completed")):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            binary = home / ".local" / "bin" / "codex"
            binary.parent.mkdir(parents=True)
            binary.write_text(FAKE_CODEX, encoding="utf-8")
            binary.chmod(0o755)
            env = {**os.environ, "HOME": str(home), "TMUX_TMPDIR": str(home / "tmux")}
            env.pop("TMUX", None)
            (home / "tmux").mkdir()
            job_id = f"{index:032x}"
            request = {"jobId": job_id, "workDir": temporary, "prompt": prompt,
                       "model": "gpt-6-sol", "effort": "medium", "threadId": None}
            encoded = base64.b64encode(json.dumps(request).encode()).decode()
            subprocess.run(["python3", str(WORKER), "start", encoded], env=env,
                           check=True, capture_output=True, text=True)
            path = home / ".ssh_tool" / "chat_jobs" / job_id
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                state = json.loads((path / "state.json").read_text())
                if state["status"] in ("completed", "failed"):
                    time.sleep(0.2)
                    if not subprocess.run(["tmux", "has-session", "-t", state["tmuxName"]],
                                          env=env, capture_output=True).returncode == 0:
                        break
                time.sleep(0.05)
            assert state["status"] == expected, state
            session_status = subprocess.run(["python3", str(WORKER), "session", "thread-test"],
                                            env=env, check=True, capture_output=True, text=True)
            assert json.loads(session_status.stdout) == {"open": False, "busy": False}


def test_start_rejects_a_thread_held_by_another_codex_process():
    with tempfile.TemporaryDirectory() as temporary:
        home = Path(temporary)
        lock = home / ".codex" / "thread-writer-locks" / "thread-test.lock"
        lock.parent.mkdir(parents=True)
        request = {
            "jobId": "0123456789abcdef0123456789abcdef",
            "workDir": temporary,
            "prompt": "测试",
            "model": "gpt-6-sol",
            "effort": "medium",
            "threadId": "thread-test",
        }
        encoded = base64.b64encode(json.dumps(request).encode()).decode()
        with lock.open("a+") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            failed = subprocess.run(
                ["python3", str(WORKER), "start", encoded],
                env={**os.environ, "HOME": temporary, "CODEX_HOME": str(home / ".codex")},
                capture_output=True,
                text=True,
            )
        assert failed.returncode != 0
        assert "正在其他 Codex 窗口中占用" in json.loads(failed.stdout)["error"]
        assert not (home / ".ssh_tool" / "chat_jobs" / request["jobId"]).exists()
