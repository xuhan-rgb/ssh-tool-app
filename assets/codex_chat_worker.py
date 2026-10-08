"""在远程 tmux 中保持 Codex 对话会话，并供 SSH 客户端断线后重新读取。"""

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
import uuid
from pathlib import Path


ROOT = Path.home() / ".ssh_tool" / "chat_jobs"
SESSIONS = ROOT / "sessions"
LOCK_FILE = ROOT / ".worker.lock"
JOB_ID = re.compile(r"^[0-9a-f]{32}$")


def job_path(job_id: str) -> Path:
    if not JOB_ID.fullmatch(job_id):
        raise ValueError("无效的任务 ID")
    return ROOT / job_id


def save_state(path: Path, state: dict) -> None:
    temporary = path / "state.tmp"
    temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path / "state.json")


def save_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


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


def prepared_runtime() -> bool:
    return (Path.home() / '.ssh_tool/codex_runtime/connection.json').is_file()


def codex_app_server_command() -> list[str]:
    if prepared_runtime():
        return ['python3', str(Path.home() / '.ssh_tool/codex_runtime.py'), 'proxy']
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


def worker_lock():
    ROOT.mkdir(parents=True, exist_ok=True)
    stream = LOCK_FILE.open("a+")
    fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
    return stream


def session_file(thread_id: str) -> Path:
    return SESSIONS / (base64.urlsafe_b64encode(thread_id.encode()).decode().rstrip("=") + ".json")


def session_info(thread_id: str) -> dict:
    file = session_file(thread_id)
    if not file.exists():
        return {"open": False, "busy": False}
    try:
        session = json.loads(file.read_text(encoding="utf-8"))
        alive = subprocess.run(["tmux", "has-session", "-t", session["tmuxName"]],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if not alive:
            return {"open": False, "busy": False}
        return {"open": True, "busy": bool(session.get("busy"))}
    except (OSError, ValueError, KeyError):
        return {"open": False, "busy": False}


def session(thread_id: str) -> None:
    print(json.dumps(session_info(thread_id)))


def sessions() -> None:
    thread_ids = []
    if SESSIONS.exists():
        for file in SESSIONS.glob("*.json"):
            try:
                data = json.loads(file.read_text(encoding="utf-8"))
                if data.get("threadId") and session_info(data["threadId"])["open"]:
                    thread_ids.append(data["threadId"])
            except (OSError, ValueError):
                continue
    print(json.dumps({"threadIds": thread_ids}, ensure_ascii=False))


def close(thread_id: str, emit: bool = True) -> None:
    lock = worker_lock()
    try:
        file = session_file(thread_id)
        if not file.exists():
            if emit:
                print(json.dumps({"closed": True, "open": False}))
            return
        data = json.loads(file.read_text(encoding="utf-8"))
        if not data.get("busy"):
            data["closeRequested"] = True
            save_json(file, data)
        elif data.get("busy"):
            raise RuntimeError("该对话仍有任务运行，请完成后再关闭")
    finally:
        lock.close()
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if not session_info(thread_id)["open"]:
            if emit:
                print(json.dumps({"closed": True, "open": False}))
            return
        time.sleep(0.1)
    raise RuntimeError("关闭远程会话超时，请刷新状态")


def start(encoded_request: str) -> None:
    request = json.loads(base64.b64decode(encoded_request))
    job_id = request["jobId"]
    existing_thread = request.get("threadId") if not request.get("fork") else None
    if existing_thread and session_info(existing_thread)["open"]:
        existing = json.loads(session_file(existing_thread).read_text(encoding="utf-8"))
        if existing.get("interactionVersion", 0) < 1 and not existing.get("busy"):
            # Only retire idle app-owned workers; never interrupt a running turn.
            close(existing_thread, emit=False)
    path = job_path(job_id)
    lock = worker_lock()
    try:
        if path.exists():
            if load_state(path).get("jobId") != job_id:
                raise RuntimeError("任务 ID 已被占用")
            print(json.dumps({"jobId": job_id}))
            return
        thread_id = request.get("threadId") if not request.get("fork") else None
        if thread_id and session_info(thread_id)["open"]:
            file = session_file(thread_id)
            data = json.loads(file.read_text(encoding="utf-8"))
            if data.get("closeRequested"):
                raise RuntimeError("该对话正在关闭，请稍后重试")
            path.mkdir(parents=True, mode=0o700)
            request_file = path / "request.json"
            request_file.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
            request_file.chmod(0o600)
            owner_state = load_state(job_path(data["ownerJobId"]))
            save_state(path, {"jobId": job_id, "threadId": thread_id,
                              "title": (request.get("title") or request["prompt"]).strip()[:160],
                              "tmuxName": owner_state["tmuxName"], "status": "starting"})
            data["busy"] = True
            save_json(file, data)
            with (SESSIONS / (data["queueId"] + ".jsonl")).open("a", encoding="utf-8") as stream:
                stream.write(json.dumps({"jobId": job_id, "request": request}) + "\n")
            print(json.dumps({"jobId": job_id}))
            return
        path.mkdir(parents=True, mode=0o700)
        work_dir = os.path.expanduser(request["workDir"])
        if not Path(work_dir).is_dir():
            path.rmdir()
            raise RuntimeError("对话目录不存在：" + work_dir)
        if thread_id and writer_locked(thread_id):
            if not prepared_runtime():
                path.rmdir()
                raise RuntimeError("该对话正在其他 Codex 窗口中占用，请先结束或接管")
            from codex_runtime import read_config, RpcConnection
            config = read_config()
            rpc = RpcConnection(Path(config['socketPath']))
            try:
                rpc.request('initialize', {'clientInfo': {'name': 'ssh_tool_guard', 'version': '1'}})
                rpc.send({'method': 'initialized', 'params': {}})
                loaded = rpc.request('thread/loaded/list', {})['data']
                thread = rpc.request('thread/read', {'threadId': thread_id, 'includeTurns': False})['thread']
                if thread_id not in loaded or thread['status']['type'] != 'idle':
                    raise RuntimeError('该对话仍由其他运行实例占用，本次未发送')
            except Exception:
                path.rmdir()
                raise
            finally:
                rpc.close()
        os.chmod(path, 0o700)
        request_file = path / "request.json"
        request_file.write_text(json.dumps(request, ensure_ascii=False), encoding="utf-8")
        os.chmod(request_file, 0o600)
        state = {"jobId": job_id, "threadId": None if request.get("fork") else thread_id,
                 "title": (request.get("title") or request["prompt"]).strip()[:160],
                 "tmuxName": "ssh-chat-" + job_id[:12], "status": "starting"}
        save_state(path, state)
        command = "python3 -u " + shlex.quote(str(Path(__file__))) + " run " + job_id
        subprocess.run(["tmux", "new-session", "-d", "-s", state["tmuxName"], command],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        print(json.dumps({"jobId": job_id}))
    finally:
        lock.close()


def finish_job(path: Path, state: dict, result: dict, started: float) -> None:
    result["durationSeconds"] = max(1, round(time.monotonic() - started))
    state.update(result)
    save_state(path, state)
    append_event(path, {"type": state["status"], **result})
    (path / "request.json").unlink(missing_ok=True)


def respond_approval(job_id: str, request_key: str, decision: str) -> None:
    path = job_path(job_id)
    with worker_lock():
        if decision not in ('accept', 'decline'):
            raise RuntimeError('无效的审批决定')
        pending = path / 'approval.json'
        response = path / 'approval-response.json'
        receipt = path / 'approval-receipt.json'
        for previous in (response, receipt):
            if previous.is_file():
                value = json.loads(previous.read_text(encoding='utf-8'))
                if value['requestKey'] == request_key:
                    if value['decision'] != decision:
                        raise RuntimeError('审批结果已经提交，不能更改')
                    print(json.dumps({'ok': True}))
                    return
        approval = json.loads(pending.read_text(encoding='utf-8'))
        if approval['requestKey'] != request_key:
            raise RuntimeError('审批请求已变化，请刷新后重试')
        save_json(response, {'requestKey': request_key, 'decision': decision})
    print(json.dumps({'ok': True}))


def run(job_id: str) -> None:
    owner_path = job_path(job_id)
    initial_request = json.loads((owner_path / "request.json").read_text(encoding="utf-8"))
    owner_state = load_state(owner_path)
    work_dir = os.path.expanduser(initial_request["workDir"])
    process = None
    current = None
    session_path = None
    queue_file = None
    queue_index = 0
    rpc_id = 0
    try:
        if not Path(work_dir).is_dir():
            raise RuntimeError("对话目录不存在：" + work_dir)
        with (owner_path / "codex.stderr").open("wb") as error_log:
            process = subprocess.Popen(codex_app_server_command(), cwd=work_dir,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=error_log, env=codex_app_server_environment())
            buffer = b""
            pending_items = {}
            current_turn_id = None

            def send(message: dict) -> None:
                process.stdin.write((json.dumps(message) + "\n").encode())
                process.stdin.flush()

            def handle_message(message):
                if not isinstance(message, dict):
                    return {}
                if message.get('method') == 'item/started':
                    item = message.get('params', {}).get('item', {})
                    pending_items[item.get('id')] = item
                if 'method' not in message or 'id' not in message:
                    return message
                method = message['method']
                if method == 'item/tool/requestUserInput' and prepared_runtime():
                    # The foreground question subscriber answers on the shared connection.
                    return {}
                if current is None or method not in (
                        'item/commandExecution/requestApproval', 'item/fileChange/requestApproval'):
                    send({'id': message['id'], 'error': {'code': -32601,
                          'message': '手机当前不支持该交互，本次未批准；请通过 Codex 终端继续'}})
                    if current is not None:
                        append_event(current[0], {'type': 'activity',
                            'text': '手机不支持该交互，本次未批准；请通过 Codex 终端继续：' + method})
                    return {}
                path = current[0]
                params = message.get('params', {})
                if ((params.get('threadId') and params['threadId'] != thread_id) or
                        (current_turn_id and params.get('turnId') and params['turnId'] != current_turn_id)):
                    send({'id': message['id'], 'error': {'code': -32602,
                          'message': '审批不属于当前对话任务'}})
                    return {}
                decisions = params.get('availableDecisions')
                if decisions is not None and not all(choice in decisions for choice in ('accept', 'decline')):
                    send({'id': message['id'], 'error': {'code': -32601,
                          'message': '当前审批选项需通过 Codex 终端处理'}})
                    append_event(current[0], {'type': 'activity', 'text': '当前审批选项不受手机支持，本次未批准'})
                    return {}
                item = pending_items.get(params.get('itemId'), {})
                detail = params.get('command') or item.get('command') or params.get('reason') or 'Codex 请求修改文件'
                if item.get('changes'):
                    detail += '\n' + '\n'.join(str(change.get('path', '')) for change in item['changes'])
                if params.get('grantRoot'):
                    detail += '\n目录：' + str(params['grantRoot'])
                approval = {'requestKey': uuid.uuid4().hex, 'method': method, 'detail': str(detail)}
                with worker_lock():
                    (path / 'approval-response.json').unlink(missing_ok=True)
                    save_json(path / 'approval.json', approval)
                append_event(path, {'type': 'activity', 'text': '等待审批：' + str(detail)})
                response = path / 'approval-response.json'
                while not response.exists():
                    if process.poll() is not None:
                        raise RuntimeError('等待审批时 Codex 连接已断开')
                    time.sleep(0.15)
                value = json.loads(response.read_text(encoding='utf-8'))
                if value['requestKey'] != approval['requestKey']:
                    raise RuntimeError('审批响应与当前请求不一致')
                send({'id': message['id'], 'result': {'decision': value['decision']}})
                with worker_lock():
                    save_json(path / 'approval-receipt.json', value)
                    (path / 'approval.json').unlink(missing_ok=True)
                    response.unlink(missing_ok=True)
                return {}

            def receive(timeout=1):
                nonlocal buffer
                if b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    try:
                        return handle_message(json.loads(line))
                    except ValueError:
                        return {}
                ready, _, _ = select.select([process.stdout], [], [], timeout)
                if not ready:
                    if process.poll() is not None:
                        raise RuntimeError("远端 Codex 提前退出")
                    return None
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("远端 Codex 输出中断")
                buffer += chunk
                if b"\n" not in buffer:
                    return None
                line, buffer = buffer.split(b"\n", 1)
                try:
                    return handle_message(json.loads(line))
                except ValueError:
                    return {}

            def rpc(method: str, params: dict):
                nonlocal rpc_id
                rpc_id += 1
                request_id = rpc_id
                send({"id": request_id, "method": method, "params": params})
                while True:
                    message = receive()
                    if message is None:
                        continue
                    if message.get("id") == request_id:
                        if message.get("error"):
                            raise RuntimeError(message["error"].get("message", "Codex 请求失败"))
                        return message.get("result", {})

            rpc("initialize", {"clientInfo": {"name": "ssh_tool_app", "version": "1"},
                                "capabilities": {"experimentalApi": True}})
            send({"method": "initialized", "params": {}})
            params = {"cwd": work_dir, "model": initial_request["model"]}
            if not prepared_runtime():
                # Preserve existing installations; prepared official runtimes inherit remote policy.
                params.update({"approvalPolicy": "never", "sandbox": "danger-full-access"})
            if initial_request.get("threadId"):
                params["threadId"] = initial_request["threadId"]
                if not initial_request.get("fork"):
                    params["excludeTurns"] = True
            method = ("thread/fork" if initial_request.get("fork") else
                      "thread/resume" if initial_request.get("threadId") else "thread/start")
            thread_id = rpc(method, params)["thread"]["id"]
            owner_state.update({"threadId": thread_id, "status": "running",
                                "startedAt": int(time.time() * 1000)})
            save_state(owner_path, owner_state)
            SESSIONS.mkdir(parents=True, mode=0o700, exist_ok=True)
            session_path = session_file(thread_id)
            queue_id = job_id
            queue_file = SESSIONS / (queue_id + ".jsonl")
            lock = worker_lock()
            try:
                save_json(session_path, {"threadId": thread_id, "ownerJobId": job_id,
                    "tmuxName": owner_state["tmuxName"], "queueId": queue_id,
                    "busy": True, "activeJobId": job_id, "closeRequested": False, "interactionVersion": 1})
                queue_file.write_text("", encoding="utf-8")
                queue_file.chmod(0o600)
            finally:
                lock.close()

            current_request = initial_request
            current_path = owner_path
            while True:
                current = (current_path, current_request, load_state(current_path), time.monotonic())
                state = current[2]
                state["status"] = "running"
                state["startedAt"] = int(time.time() * 1000)
                save_state(current_path, state)
                append_event(current_path, {"type": "started", "threadId": thread_id})
                current_turn_id = None
                pending_items.clear()
                result = rpc("turn/start", {"threadId": thread_id,
                    "input": [{"type": "text", "text": current_request["prompt"], "text_elements": []}],
                    "cwd": os.path.expanduser(current_request["workDir"]),
                    "model": current_request["model"], "effort": current_request["effort"]})
                current_turn_id = result.get('turn', {}).get('id')
                current_item = None
                reasoning_with_deltas = set()
                draft = ""
                answer = ""
                turn_result = None
                while turn_result is None:
                    event = receive()
                    if event is None:
                        continue
                    if event.get("error") and event.get("id") is not None:
                        raise RuntimeError(event["error"].get("message", "Codex 请求失败"))
                    method = event.get("method")
                    params = event.get("params", {})
                    event_turn_id = params.get('turnId') or params.get('turn', {}).get('id')
                    if current_turn_id and event_turn_id and event_turn_id != current_turn_id:
                        continue
                    if method == "item/reasoning/summaryTextDelta":
                        delta = params.get("delta", "")
                        if delta:
                            reasoning_with_deltas.add(params.get("itemId"))
                            append_event(current_path, {"type": "activityDelta", "delta": delta, "itemId": params.get("itemId")})
                    elif method == "item/reasoning/summaryPartAdded" and params.get("summaryIndex", 0) > 0:
                        append_event(current_path, {"type": "activityDelta", "delta": "\n", "itemId": params.get("itemId")})
                    elif method == "item/started":
                        item = params.get("item", {})
                        detail = (item.get("command") if item.get("type") == "commandExecution" else
                                  item.get("tool") if item.get("type") == "mcpToolCall" else
                                  item.get("query") if item.get("type") == "webSearch" else None)
                        if isinstance(detail, str) and detail.strip():
                            append_event(current_path, {"type": "activity", "text": detail.strip()[:500], "itemId": item.get("id")})
                    elif method == "item/commandExecution/outputDelta":
                        delta = params.get("delta", "")
                        if isinstance(delta, str) and delta:
                            append_event(current_path, {"type": "activityDelta", "delta": delta[:1000], "itemId": params.get("itemId")})
                    elif method == "turn/plan/updated":
                        plan = params.get("plan", [])
                        active_step = next((step.get("step") for step in plan if step.get("status") == "inProgress"), None)
                        if isinstance(active_step, str) and active_step.strip():
                            append_event(current_path, {"type": "activity", "text": active_step.strip()[:500]})
                    elif method == "item/agentMessage/delta":
                        item_id = params["itemId"]
                        reset = item_id != current_item
                        if reset:
                            current_item, draft = item_id, ""
                        draft += params["delta"]
                        append_event(current_path, {"type": "partial", "delta": params["delta"], "reset": reset})
                    elif method == "item/completed":
                        item = params.get("item", {})
                        if item.get("type") == "agentMessage":
                            answer = item.get("text", draft)
                            append_event(current_path, {"type": "partial", "text": answer})
                        elif item.get("type") == "reasoning" and item.get("id") not in reasoning_with_deltas:
                            summary = item.get("summary", [])
                            if isinstance(summary, list):
                                text = "\n".join(part for part in summary if isinstance(part, str))
                                if text.strip():
                                    append_event(current_path, {"type": "activity", "text": text[:1000], "itemId": item.get("id")})
                    elif method == "turn/completed":
                        turn = params["turn"]
                        if turn.get("status") != "completed":
                            error = turn.get("error") or {}
                            raise RuntimeError(error.get("message", "Codex 回答未完成"))
                        turn_result = {"status": "completed", "answer": answer}
                finish_job(current_path, state, turn_result, current[3])
                current = None
                lock = worker_lock()
                try:
                    meta = json.loads(session_path.read_text(encoding="utf-8"))
                    lines = queue_file.read_text(encoding="utf-8").splitlines()
                    if queue_index < len(lines):
                        queued = json.loads(lines[queue_index])
                        queue_index += 1
                        meta.update({"busy": True, "activeJobId": queued["jobId"]})
                    else:
                        queued = None
                        meta.update({"busy": False, "activeJobId": None})
                    save_json(session_path, meta)
                finally:
                    lock.close()
                while queued is None:
                    if process.poll() is not None:
                        raise RuntimeError("远端 Codex 提前退出")
                    lock = worker_lock()
                    try:
                        meta = json.loads(session_path.read_text(encoding="utf-8"))
                        if meta.get("closeRequested"):
                            break
                        lines = queue_file.read_text(encoding="utf-8").splitlines()
                        if queue_index < len(lines):
                            queued = json.loads(lines[queue_index])
                            queue_index += 1
                            meta.update({"busy": True, "activeJobId": queued["jobId"]})
                            save_json(session_path, meta)
                    finally:
                        lock.close()
                    if queued is None:
                        time.sleep(0.15)
                if meta.get("closeRequested"):
                    if prepared_runtime():
                        rpc('thread/unsubscribe', {'threadId': thread_id})
                    break
                if queued is None:
                    time.sleep(0.15)
                    continue
                current_path = job_path(queued["jobId"])
                current_request = queued["request"]
                # The perturn request is persisted at acceptance; remove it once loaded.
                (current_path / "request.json").unlink(missing_ok=True)
    except Exception as error:
        if current is not None:
            current_path, _, state, started = current
            finish_job(current_path, state, {"status": "failed", "error": str(error)}, started)
        else:
            latest_owner = load_state(owner_path)
            if latest_owner.get("status") in ("starting", "running"):
                finish_job(owner_path, latest_owner,
                           {"status": "failed", "error": str(error)}, time.monotonic())
        if queue_file is not None and queue_file.exists():
            try:
                for line in queue_file.read_text(encoding="utf-8").splitlines()[queue_index:]:
                    queued = json.loads(line)
                    queued_path = job_path(queued["jobId"])
                    queued_state = load_state(queued_path)
                    if queued_state.get("status") in ("starting", "running"):
                        finish_job(queued_path, queued_state,
                                   {"status": "failed", "error": "远端 Codex 会话已结束"},
                                   time.monotonic())
            except (OSError, ValueError, KeyError):
                pass
    finally:
        if process is not None:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if session_path is not None:
            try:
                session_path.unlink(missing_ok=True)
            except OSError:
                pass
        (owner_path / "request.json").unlink(missing_ok=True)

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
    approval_file = path / 'approval.json'
    try:
        approval = json.loads(approval_file.read_text(encoding='utf-8'))
    except FileNotFoundError:
        approval = None
    return {"offset": next_offset, "events": events, "state": state, "approval": approval}


def poll(job_id: str, offset: int) -> None:
    print(json.dumps(snapshot(job_id, offset), ensure_ascii=False))


def follow(job_id: str, offset: int) -> None:
    offset = int(offset)
    while True:
        update = snapshot(job_id, offset)
        offset = update["offset"]
        if update["events"] or update.get('approval') or update["state"]["status"] not in ("starting", "running"):
            print(json.dumps(update, ensure_ascii=False), flush=True)
        if update["state"]["status"] not in ("starting", "running"):
            return
        time.sleep(0.25)


def find(thread_id: str) -> None:
    file = session_file(thread_id)
    if file.exists():
        try:
            active_job_id = json.loads(file.read_text(encoding="utf-8")).get("activeJobId")
            if active_job_id:
                state = load_state(job_path(active_job_id))
                if state.get("status") in ("starting", "running"):
                    print(json.dumps(state, ensure_ascii=False))
                    return
        except (OSError, ValueError, KeyError):
            pass
    if ROOT.exists():
        paths = sorted(ROOT.iterdir(), key=lambda path: path.stat().st_mtime, reverse=True)
        matches = []
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
                priority = 0 if state.get("status") == "running" else 1 if active else 2
                matches.append((priority, path.stat().st_mtime, state))
        if matches:
            _, _, state = min(matches, key=lambda match: (match[0], -match[1]))
            print(json.dumps(state, ensure_ascii=False))
            return
    print("{}")


if __name__ == "__main__":
    try:
        {"start": start, "run": run, "poll": poll, "follow": follow, "find": find,
         "session": session, "sessions": sessions, "close": close, "approve": respond_approval}[sys.argv[1]](*sys.argv[2:])
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False))
        sys.exit(1)
