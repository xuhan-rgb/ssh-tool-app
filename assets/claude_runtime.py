#!/usr/bin/env python3
"""One interactive Claude process per managed conversation, with durable receipts."""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
import uuid

ROOT = Path.home() / '.ssh_tool' / 'claude_runtime'
SCRIPT = Path(__file__).resolve()


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-zA-Z0-9_-]{1,100}', value):
        raise ValueError('Invalid Claude session ID')
    return value


def folder(sid):
    path = ROOT / identifier(sid)
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


@contextlib.contextmanager
def locked(path, nonblocking=False):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with path.open('a') as stream:
        os.chmod(path, 0o600)
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(stream, fcntl.LOCK_UN)


def read(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {} if default is None else default


def save(path, value):
    temp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    with temp.open('x') as out:
        os.chmod(temp, 0o600)
        json.dump(value, out, ensure_ascii=False)
    temp.replace(path)


def tmux(*args, input=None):
    return subprocess.run(['tmux', *args], input=input, text=True,
                          capture_output=True, check=True)


def alive(state):
    if not state.get('tmuxSession'):
        return False
    try:
        tmux('has-session', '-t', '=' + state['tmuxSession'])
        if state.get('paneIdentity'):
            identity = tmux('display-message', '-p', '-t', state['tmuxSession'] + ':0.0',
                            '#{pane_id}:#{pane_pid}:#{pane_dead}').stdout.strip()
            return identity == state['paneIdentity'] and identity.endswith(':0')
        return True
    except subprocess.CalledProcessError:
        return False


def snapshot(sid):
    state = read(folder(sid) / 'state.json')
    if not state:
        return None
    state['alive'] = alive(state)
    if not state['alive']:
        state['status'] = 'stopped'
    return state


def launch_dispatcher(sid):
    subprocess.Popen([sys.executable, str(SCRIPT), 'dispatch', sid],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)


def ensure(payload):
    sid = identifier(payload['sessionId'])
    directory = folder(sid)
    with locked(ROOT / 'launch.lock'):
        current = snapshot(sid)
        if current and current['alive']:
            return current
        resume = payload.get('resume', True)
        if resume:
            # Fail closed: do not quietly fork a conversation owned elsewhere.
            result = subprocess.run(['bash', '-lc', 'claude agents --json'],
                                    capture_output=True, text=True, timeout=15)
            if result.returncode:
                raise RuntimeError('无法确认 Claude 运行实例，请先在终端检查 claude agents --json')
            roster = json.loads(result.stdout)
            if isinstance(roster, dict):
                roster = roster.get('agents', [])
            if not isinstance(roster, list):
                raise RuntimeError('Claude 运行实例信息格式无法识别')
            if any(item.get('sessionId') == sid for item in roster if isinstance(item, dict)):
                raise RuntimeError('此对话已由外部 Claude 实例打开；请连接原终端，避免启动不同步的副本')
        cwd = str(Path(payload.get('workDir') or '~').expanduser().resolve())
        if not Path(cwd).is_dir():
            raise ValueError('对话目录不存在：' + cwd)
        effort = payload.get('effort')
        if effort not in (None, '', 'low', 'medium', 'high', 'xhigh', 'max'):
            raise ValueError('不支持的思考强度')
        state = dict(sessionId=sid, tmuxSession='ssh-claude-' + sid,
                     workDir=cwd, model=payload.get('model') or None,
                     effort=effort or None, resume=resume, status='starting',
                     updatedAt=time.time())
        hooks = {}
        for event in ('SessionStart', 'UserPromptSubmit', 'Stop', 'Notification', 'SessionEnd', 'StopFailure'):
            command = shlex.join([sys.executable, str(SCRIPT), 'hook', sid, event])
            hooks[event] = [{'hooks': [{'type': 'command', 'command': command}]}]
        save(directory / 'settings.json', {'hooks': hooks})
        save(directory / 'state.json', state)
        command = shlex.join(['bash', '-lc', 'exec ' + shlex.join(
            [sys.executable, str(SCRIPT), 'run', sid])])
        try:
            tmux('new-session', '-d', '-s', state['tmuxSession'], '-c', cwd, command)
            identity = tmux('display-message', '-p', '-t', state['tmuxSession'] + ':0.0',
                            '#{pane_id}:#{pane_pid}:#{pane_dead}').stdout.strip()
            with locked(directory / 'state.lock'):
                # SessionStart may already have updated readiness.
                state = read(directory / 'state.json')
                state['paneIdentity'] = identity
                save(directory / 'state.json', state)
        except Exception:
            state['status'] = 'error'
            save(directory / 'state.json', state)
            raise
        return snapshot(sid)


def run_session(sid):
    directory = folder(sid)
    state = read(directory / 'state.json')
    command = ['claude', '--resume' if state['resume'] else '--session-id', sid,
               '--settings', str(directory / 'settings.json')]
    if state.get('model'):
        command += ['--model', state['model']]
    if state.get('effort'):
        command += ['--effort', state['effort']]
    # No shell remains to execute pasted user text if Claude exits.
    os.chdir(state['workDir'])
    os.execvp(command[0], command)


def enqueue(payload):
    sid = identifier(payload['sessionId'])
    message_id = identifier(payload['messageId'])
    message = payload.get('text', '')
    if not isinstance(message, str) or not message.strip():
        raise ValueError('消息不能为空')
    if any((ord(char) < 32 and char not in '\n\t') or 127 <= ord(char) < 160 for char in message):
        raise ValueError('消息包含终端控制字符')
    directory = folder(sid)
    with locked(directory / 'state.lock'):
        state = snapshot(sid)
        if not state or not state['alive']:
            raise RuntimeError('Claude 实例未运行，请先继续对话')
        messages = read(directory / 'messages.json', [])
        existing = next((m for m in messages if m['id'] == message_id), None)
        if existing:
            if existing['text'] != message:
                raise ValueError('消息 ID 已用于不同内容')
            return existing
        receipt = dict(id=message_id, text=message, status='queued', createdAt=time.time())
        messages.append(receipt)
        save(directory / 'messages.json', messages)
    launch_dispatcher(sid)
    return receipt


def cancel(payload):
    sid = identifier(payload['sessionId'])
    directory = folder(sid)
    with locked(directory / 'state.lock'):
        messages = read(directory / 'messages.json', [])
        message = next((item for item in messages if item['id'] == payload['messageId']), None)
        if not message or message['status'] not in ('queued', 'uncertain'):
            raise ValueError('消息已提交，不能从队列撤回')
        message['status'] = 'cancelled'
        save(directory / 'messages.json', messages)
    launch_dispatcher(sid)
    return message


def hook(sid, event, payload):
    if payload.get('session_id') != sid or payload.get('agent_id'):
        return
    directory = folder(sid)
    with locked(directory / 'state.lock'):
        state = read(directory / 'state.json')
        if not state:
            return
        if event == 'UserPromptSubmit':
            state['status'] = 'busy'
            messages = read(directory / 'messages.json', [])
            pending = next((m for m in messages if m['status'] == 'dispatching'), None)
            if pending and payload.get('prompt') == pending['text']:
                pending['status'] = 'accepted'
                pending['acceptedAt'] = time.time()
                save(directory / 'messages.json', messages)
        elif event in ('SessionStart', 'Stop'):
            state['status'] = 'ready'
        elif event == 'StopFailure':
            state['status'] = 'awaiting_input'
        elif event == 'SessionEnd':
            state['status'] = 'stopped'
        elif event == 'Notification':
            kind = payload.get('notification_type')
            if kind == 'permission_prompt':
                state['status'] = 'awaiting_input'
            elif kind == 'idle_prompt':
                state['status'] = 'ready'
        state['updatedAt'] = time.time()
        save(directory / 'state.json', state)
    if event in ('SessionStart', 'Stop'):
        launch_dispatcher(sid)


def dispatch(sid):
    directory = folder(sid)
    # A waiting dispatcher also closes the enqueue/worker-exit lost-wakeup race.
    with locked(directory / 'dispatch.lock') as acquired:
        if not acquired:
            return
        while True:
            with locked(directory / 'state.lock'):
                state = snapshot(sid)
                messages = read(directory / 'messages.json', [])
                if not state or not state['alive']:
                    for item in messages:
                        if item['status'] == 'queued':
                            item.update(status='failed', error='Claude 实例已退出，消息未发送')
                        elif item['status'] == 'dispatching':
                            item.update(status='uncertain', error='Claude 已退出，接收状态未确认；未自动重发')
                    save(directory / 'messages.json', messages)
                    return
                if any(item['status'] == 'uncertain' for item in messages):
                    return
                pending = next((item for item in messages if item['status'] in ('queued', 'dispatching')), None)
                if not pending:
                    return
                if pending['status'] == 'dispatching':
                    if time.time() - pending['sentAt'] > 30:
                        pending.update(status='uncertain', error='未收到 Claude 接收确认，请检查终端；未自动重发')
                        save(directory / 'messages.json', messages)
                        return
                elif state['status'] == 'ready':
                    pending.update(status='dispatching', sentAt=time.time())
                    save(directory / 'messages.json', messages)
                    buffer_name = 'ssh-claude-' + pending['id']
                    try:
                        tmux('load-buffer', '-b', buffer_name, '-', input=pending['text'])
                        tmux('paste-buffer', '-d', '-p', '-b', buffer_name,
                             '-t', state['tmuxSession'] + ':0.0')
                        tmux('send-keys', '-t', state['tmuxSession'] + ':0.0', 'Enter')
                    except Exception:
                        pending.update(status='uncertain', error='终端提交中断，接收状态不确定；未自动重发')
                        save(directory / 'messages.json', messages)
                        return
            time.sleep(0.25)


def request(action, payload):
    if action == 'ensure':
        return ensure(payload)
    if action == 'list':
        return [state for path in ROOT.glob('*/state.json')
                if (state := snapshot(path.parent.name))]
    if action == 'send':
        return enqueue(payload)
    if action == 'cancel':
        return cancel(payload)
    if action == 'status':
        sid = identifier(payload['sessionId'])
        state = snapshot(sid)
        return {'session': state, 'messages': read(folder(sid) / 'messages.json', [])}
    raise ValueError('Unknown action')


if __name__ == '__main__':
    try:
        action = sys.argv[1]
        if action == 'run':
            run_session(identifier(sys.argv[2]))
        elif action == 'dispatch':
            dispatch(identifier(sys.argv[2]))
        elif action == 'hook':
            hook(identifier(sys.argv[2]), sys.argv[3], json.load(sys.stdin))
        else:
            print(json.dumps(request(action, json.load(sys.stdin)), ensure_ascii=False))
    except Exception as error:
        if len(sys.argv) > 1 and sys.argv[1] == 'hook':
            # Hook diagnostics must not become instructions or stop Claude.
            print(str(error), file=sys.stderr)
        else:
            print(str(error), file=sys.stderr)
            sys.exit(1)
