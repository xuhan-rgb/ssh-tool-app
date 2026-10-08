"""Official-only setup checks, without network, accounts, or host configuration changes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

import pytest

ASSETS = Path(__file__).resolve().parents[1] / 'assets'


def module(name):
    sys.path.insert(0, str(ASSETS))
    try:
        spec = importlib.util.spec_from_file_location(name, ASSETS / (name + '.py'))
        value = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(value)
        return value
    finally:
        sys.path.pop(0)


def fields(output):
    import base64
    return {key: base64.b64decode(value).decode() for key, value in
            (line.split('\t', 1) for line in output.splitlines())}


def fake_codex(home, *, logged_in=True, compatible=True):
    path = home / '.local/bin/codex'
    return fake_codex_at(path, logged_in=logged_in, compatible=compatible)


def fake_codex_at(path, *, logged_in=True, compatible=True):
    path = Path(path)
    path.parent.mkdir(parents=True)
    path.write_text('''#!/bin/sh
case "$*" in
  '--version') echo 'codex-test';;
  'login status') exit LOGIN_STATUS;;
  'app-server daemon start --help') echo 'DAEMON_HELP';;
  'app-server proxy --help') echo 'PROXY_HELP';;
  '--help') echo 'REMOTE_HELP';;
  *) exit 2;;
esac
'''.replace('LOGIN_STATUS', '0' if logged_in else '1')
        .replace('DAEMON_HELP', 'daemon start' if compatible else 'old CLI')
        .replace('PROXY_HELP', '--sock' if compatible else 'old CLI')
        .replace('REMOTE_HELP', '--remote' if compatible else 'old CLI'))
    path.chmod(0o755)
    return path


def test_discovery_prefers_user_install_after_upgrade_even_with_old_system_codex(tmp_path):
    system_codex = fake_codex_at(tmp_path / 'system/bin/codex')
    upgraded = fake_codex(tmp_path)
    result = subprocess.run(
        ['sh', str(ASSETS / 'codex_environment.sh')],
        env={**os.environ, 'HOME': str(tmp_path),
             'PATH': str(system_codex.parent) + ':/usr/bin:/bin'},
        capture_output=True, text=True, check=True)
    assert fields(result.stdout)['codexPath'] == str(upgraded)


def test_discovery_prefers_logged_in_compatible_codex_candidate(tmp_path):
    system_codex = fake_codex_at(tmp_path / 'system/bin/codex', logged_in=False)
    nvm_codex = fake_codex_at(
        tmp_path / '.nvm/versions/node/v22.0.0/bin/codex', logged_in=True)
    auth = tmp_path / '.local/bin/codex-auth'
    auth.parent.mkdir(parents=True)
    auth.write_text(f'''#!/bin/sh
[ "$1 $2 $3 $4" = "run -- login status" ] || exit 2
[ "$CODEX_AUTH_CODEX_BIN" = "{nvm_codex}" ]
''')
    auth.chmod(0o755)

    result = subprocess.run(
        ['sh', str(ASSETS / 'codex_environment.sh')],
        env={**os.environ, 'HOME': str(tmp_path),
             'PATH': str(system_codex.parent) + ':/usr/bin:/bin'},
        capture_output=True, text=True, check=True)

    status = fields(result.stdout)
    assert status['codexPath'] == str(nvm_codex)
    assert status['compatible'] == 'true'
    assert status['loggedIn'] == 'true'


@pytest.mark.parametrize('logged_in,compatible', [(True, True), (False, True), (True, False)])
def test_inspect_official_codex_never_starts_daemon(tmp_path, logged_in, compatible):
    binary = fake_codex(tmp_path, logged_in=logged_in, compatible=compatible)
    result = subprocess.run(['sh', str(ASSETS / 'codex_environment.sh')],
        env={**os.environ, 'HOME': str(tmp_path), 'PATH': str(binary.parent) + ':/usr/bin:/bin'},
        capture_output=True, text=True, check=True)
    status = fields(result.stdout)
    assert status['codexPath'] == str(binary)
    assert status['loggedIn'] == str(logged_in).lower()
    assert status['compatible'] == str(compatible).lower()
    assert status['prepared'] == 'false'
    assert not (tmp_path / '.ssh_tool').exists()
    assert not (tmp_path / '.local/bin/codex-auth').exists()


def test_prepare_records_verified_actual_socket_without_yolo(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    binary = fake_codex(tmp_path)
    calls = []
    def run(command, **kwargs):
        if command[-1] == '--help':
            return SimpleNamespace(returncode=0, stdout='daemon start', stderr='')
        calls.append((command, kwargs))
        return SimpleNamespace(returncode=0, stdout=json.dumps({'socketPath': str(tmp_path / 'actual.sock')}), stderr='')
    monkeypatch.setattr(runtime.subprocess, 'run', run)
    verified = []
    monkeypatch.setattr(runtime, 'verify_socket', verified.append)
    first = runtime.prepare(str(binary))
    second = runtime.prepare(str(binary))
    assert first == second
    assert verified == [str(tmp_path / 'actual.sock')] * 2
    assert runtime.read_config() == first
    assert runtime.CONFIG.stat().st_mode & 0o777 == 0o600
    assert all(command == runtime.computer_shell([str(binary), 'app-server', 'daemon', 'start']) for command, _ in calls)
    config = runtime.prepared_config()
    assert config['socketPath'] == str(tmp_path / 'actual.sock')
    assert str(binary.parent) == runtime.environment(config)['PATH'].split(':')[0]
    assert not (tmp_path / '.local/bin/codex-phone').exists()
    assert not (tmp_path / '.bashrc').exists()


def test_shortcut_preserves_bashrc_and_existing_yolo(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    runtime.ROOT.mkdir(parents=True)
    original = 'export EXISTING_SETTING=yes\ncodex-yolo() { echo existing; }\n'
    (tmp_path / '.bashrc').write_text(original)
    launcher = runtime.install_shortcut()
    runtime.install_shortcut()
    content = (tmp_path / '.bashrc').read_text()
    assert content.startswith(original)
    assert content.count(runtime.PATH_BLOCK) == 1
    assert (runtime.ROOT / 'bashrc.before-shortcut').read_text() == original
    assert launcher.stat().st_mode & 0o777 == 0o700
    result = subprocess.run(['bash', '--noprofile', '--norc', '-c',
                             'source "$HOME/.bashrc"; command -v codex-phone; codex-yolo'],
        env={**os.environ, 'HOME': str(tmp_path), 'PATH': '/usr/bin:/bin'},
        capture_output=True, text=True, check=True)
    assert result.stdout.splitlines() == [str(launcher), 'existing']


def test_shortcut_does_not_overwrite_another_command(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    launcher = tmp_path / '.local/bin/codex-phone'
    launcher.parent.mkdir(parents=True)
    launcher.write_text('existing command')
    with pytest.raises(RuntimeError, match='没有覆盖'):
        runtime.install_shortcut()
    assert launcher.read_text() == 'existing command'
    assert not (tmp_path / '.bashrc').exists()


def test_shortcut_forwards_resume_arguments_without_splitting(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    runtime.ROOT.mkdir(parents=True)
    launcher = runtime.install_shortcut()
    fake_bin = tmp_path / 'bin'
    fake_bin.mkdir()
    python = fake_bin / 'python3'
    python.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
    python.chmod(0o700)
    result = subprocess.run([str(launcher), 'resume', 'thread with spaces'],
        env={**os.environ, 'HOME': str(tmp_path), 'PATH': str(fake_bin) + ':/usr/bin:/bin'},
        capture_output=True, text=True, check=True)
    assert result.stdout.splitlines() == [str(tmp_path / '.ssh_tool/codex_runtime.py'),
                                          'terminal', 'resume', 'thread with spaces']


@pytest.mark.parametrize('arguments,expected', [
    ([], ['--cd', '/desktop/project']),
    (['--cd', '/explicit/project'], ['--cd', '/explicit/project']),
    (['resume', 'thread-id'], ['resume', 'thread-id']),
])
def test_desktop_new_chat_uses_local_directory(monkeypatch, tmp_path, arguments, expected):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    runtime.ROOT.mkdir(parents=True)
    config = {'codexPath': '/native/codex', 'socketPath': '/shared.sock'}
    monkeypatch.setattr(runtime, 'read_config', lambda: config)
    monkeypatch.setattr(runtime, 'ensure_daemon', lambda value: value)
    monkeypatch.setattr(runtime.os, 'getcwd', lambda: '/desktop/project')
    calls = []
    monkeypatch.setattr(runtime.os, 'execvpe', lambda *values: calls.append(values))
    runtime.terminal(arguments)
    assert calls[0][1] == ['/native/codex', '--remote', 'unix:///shared.sock', *expected]


@pytest.mark.parametrize('version,prepared', [(3, False), (4, True)])
def test_service_readiness_does_not_require_desktop_shortcut(tmp_path, version, prepared):
    binary = fake_codex(tmp_path)
    owned = tmp_path / '.ssh_tool'
    owned.mkdir()
    (owned / 'codex_runtime.py').write_text(
        'import json\nprint(json.dumps({"ok": True, "setupVersion": ' + str(version) + '}))\n')
    result = subprocess.run(['sh', str(ASSETS / 'codex_environment.sh')],
        env={**os.environ, 'HOME': str(tmp_path), 'PATH': str(binary.parent) + ':/usr/bin:/bin'},
        capture_output=True, text=True, check=True)
    status = fields(result.stdout)
    assert status['prepared'] == str(prepared).lower()
    assert status['shortcut'] == 'false'
    assert not (tmp_path / '.bashrc').exists()


def test_missing_managed_install_falls_back_to_verified_listener(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    binary = fake_codex(tmp_path)
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        if command[-3:] == ['daemon', 'start', '--help']:
            return SimpleNamespace(returncode=0, stdout='daemon start', stderr='')
        if command == runtime.computer_shell([str(binary), 'app-server', 'daemon', 'start']):
            return SimpleNamespace(returncode=1, stdout='',
                stderr='Error: managed standalone Codex install not found at /missing/codex')
        return SimpleNamespace(returncode=0, stdout='--listen unix://', stderr='')
    monkeypatch.setattr(runtime.subprocess, 'run', run)
    def listener(config):
        assert config['transport'] == 'listener'
        config['socketPath'] = str(tmp_path / 'verified.sock')
        runtime.save_config(config)
        return config
    monkeypatch.setattr(runtime, 'ensure_listener', listener)
    config = runtime.prepare(str(binary))
    assert config['transport'] == 'listener'
    assert runtime.read_config() == config
    assert [str(binary), 'app-server', '--help'] in calls


def test_unrelated_daemon_failure_does_not_start_another_service(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *args, **kwargs:
        SimpleNamespace(returncode=1, stdout='', stderr='permission denied'))
    monkeypatch.setattr(runtime, 'ensure_listener', lambda _: pytest.fail('unexpected fallback'))
    with pytest.raises(RuntimeError, match='permission denied'):
        runtime.ensure_daemon({'codexPath': '/usr/bin/codex'})
    assert not runtime.CONFIG.exists()


def test_failed_daemon_does_not_mark_setup_ready(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    binary = fake_codex(tmp_path)
    monkeypatch.setattr(runtime.subprocess, 'run', lambda command, **kwargs:
        SimpleNamespace(returncode=0, stdout='daemon start' if command[-1] == '--help' else '{}', stderr=''))
    with pytest.raises(RuntimeError, match='socketPath'):
        runtime.prepare(str(binary))
    assert not runtime.CONFIG.exists()


def test_shared_runtime_retains_existing_auth_wrapper(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    binary = fake_codex(tmp_path)
    auth = binary.parent / 'codex-auth'
    auth.write_text('#!/bin/sh\nexit 0\n')
    auth.chmod(0o755)
    config = {'codexPath': str(binary), 'authPath': str(auth)}
    assert runtime.prefix(config) == [str(auth), 'run', '--']
    assert runtime.environment(config)['CODEX_AUTH_CODEX_BIN'] == str(binary)


def test_pending_approval_can_be_answered_only_once(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    worker = module('codex_chat_worker')
    job_id = 'a' * 32
    job = worker.job_path(job_id)
    job.mkdir(parents=True)
    (job / 'approval.json').write_text(json.dumps({'requestKey': 'request-key'}))
    with pytest.raises(RuntimeError, match='已变化'):
        worker.respond_approval(job_id, 'wrong', 'accept')
    assert not (job / 'approval-response.json').exists()
    worker.respond_approval(job_id, 'request-key', 'decline')
    assert json.loads((job / 'approval-response.json').read_text())['decision'] == 'decline'
    worker.respond_approval(job_id, 'request-key', 'decline')
    with pytest.raises(RuntimeError, match='已经提交'):
        worker.respond_approval(job_id, 'request-key', 'accept')


def test_socket_resolution_uses_prepared_address(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    steer = module('codex_steer_message')
    assert steer.control_socket_path(tmp_path / '.codex') == tmp_path / '.codex/app-server-control/app-server-control.sock'
    config = tmp_path / '.ssh_tool/codex_runtime/connection.json'
    config.parent.mkdir(parents=True)
    config.write_text(json.dumps({'socketPath': str(tmp_path / 'custom.sock')}))
    assert steer.control_socket_path(tmp_path / '.codex') == tmp_path / 'custom.sock'


@pytest.mark.parametrize('decision', ['accept', 'decline'])
def test_prepared_chat_uses_shared_bridge_and_waits_for_phone_approval(tmp_path, decision):
    import base64
    import time
    home = tmp_path / 'home'
    owned = home / '.ssh_tool'
    owned.mkdir(parents=True)
    tmux_directory = tmp_path / 'tmux'
    tmux_directory.mkdir()
    binary = fake_codex(home)
    binary.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
turn=0
for line in sys.stdin:
    request=json.loads(line)
    with (Path.home()/'requests.jsonl').open('a') as stream:
        stream.write(json.dumps(request)+'\\n')
    method=request.get('method')
    if method=='initialize':
        print(json.dumps({'id':request['id'],'result':{}}),flush=True)
    elif method in ('thread/start','thread/resume'):
        print(json.dumps({'id':request['id'],'result':{'thread':{'id':'shared-thread'}}}),flush=True)
    elif method=='turn/start':
        turn+=1
        print(json.dumps({'id':request['id'],'result':{'turn':{'id':'turn-'+str(turn)}}}),flush=True)
        print(json.dumps({'id':100+turn,'method':'item/commandExecution/requestApproval',
            'params':{'command':'echo approval-test'}}),flush=True)
    elif 'result' in request and request.get('id',0)>100:
        print(json.dumps({'method':'item/completed','params':{'item':{
            'type':'agentMessage','text':request['result']['decision']}}}),flush=True)
        print(json.dumps({'method':'turn/completed','params':{
            'turn':{'id':'turn-'+str(turn),'status':'completed'}}}),flush=True)
    elif method=='thread/unsubscribe':
        print(json.dumps({'id':request['id'],'result':{}}),flush=True)
''')
    # Isolate the worker lifecycle; native bridge wire protocol is checked separately.
    (owned / 'codex_runtime.py').write_text('''import os
from pathlib import Path
binary=str(Path.home()/'.local/bin/codex')
os.execv(binary,[binary])
''')
    config = owned / 'codex_runtime/connection.json'
    config.parent.mkdir()
    config.write_text('{}')
    # Mobile chats must not execute a user's desktop shortcut or source their shell rc.
    (home / '.bashrc').write_text('touch "$HOME/desktop-command-used"; exit 42\n')
    for shortcut in ('codex-phone', 'codex-yolo'):
        path = binary.parent / shortcut
        path.write_text('#!/bin/sh\ntouch "$HOME/desktop-command-used"; exit 42\n')
        path.chmod(0o700)
    env = {**os.environ, 'HOME': str(home), 'TMUX_TMPDIR': str(tmux_directory)}
    env.pop('TMUX', None)
    worker = ASSETS / 'codex_chat_worker.py'
    job_id = 'c' * 32
    request = {'jobId': job_id, 'workDir': str(tmp_path), 'prompt': 'test',
               'title': 'test', 'model': 'test-model', 'effort': 'medium'}
    encoded = base64.b64encode(json.dumps(request).encode()).decode()
    def call(*args):
        result = subprocess.run(['python3', str(worker), *args], env=env,
                                capture_output=True, text=True, timeout=10, check=True)
        return json.loads(result.stdout)
    try:
        assert call('start', encoded)['jobId'] == job_id
        # Retrying an accepted launch cannot create another process or turn.
        assert call('start', encoded)['jobId'] == job_id
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            snapshot = call('poll', job_id, '0')
            if snapshot.get('approval') and snapshot['state']['status'] == 'running': break
            assert snapshot['state']['status'] != 'failed', snapshot
            time.sleep(.05)
        else: pytest.fail('pending approval was not exposed')
        assert snapshot['state']['status'] == 'running'
        assert snapshot['approval']['detail'] == 'echo approval-test'
        assert call('approve', job_id, snapshot['approval']['requestKey'], decision)['ok']
        while time.monotonic() < deadline:
            snapshot = call('poll', job_id, '0')
            if snapshot['state']['status'] == 'completed': break
            assert snapshot['state']['status'] != 'failed', snapshot
            time.sleep(.05)
        else: pytest.fail('approved turn did not finish')
        assert snapshot['state']['answer'] == decision
        receipt = json.loads((owned / 'chat_jobs' / job_id / 'approval-receipt.json').read_text())
        assert call('approve', job_id, receipt['requestKey'], decision)['ok']
        assert snapshot['approval'] is None
        requests = [json.loads(line) for line in (home / 'requests.jsonl').read_text().splitlines()]
        params = next(value['params'] for value in requests if value.get('method') == 'thread/start')
        assert 'approvalPolicy' not in params and 'sandbox' not in params
        assert params['cwd'] == str(tmp_path)
        assert not (home / 'desktop-command-used').exists()
        assert sum(value.get('method') == 'turn/start' for value in requests) == 1
        assert call('close', 'shared-thread')['closed']
        requests = [json.loads(line) for line in (home / 'requests.jsonl').read_text().splitlines()]
        assert any(value.get('method') == 'thread/unsubscribe' for value in requests)
    finally:
        subprocess.run(['tmux', 'kill-server'], env=env, capture_output=True)


def test_listener_backend_is_selected_without_native_daemon(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    binary = fake_codex(tmp_path)
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *args, **kwargs:
        SimpleNamespace(returncode=0, stdout='app-server --listen unix://', stderr=''))
    captured = []
    def ensure(config):
        captured.append(config.copy())
        return config
    monkeypatch.setattr(runtime, 'ensure_daemon', ensure)
    runtime.prepare(str(binary))
    assert captured[0]['transport'] == 'listener'
    assert captured[0]['authPath'] is None


def test_environment_accepts_official_unix_listener_without_daemon(tmp_path):
    binary = fake_codex(tmp_path, compatible=False)
    script = binary.read_text().replace("'--help') echo 'old CLI'", "'--help') echo '--remote'")
    script = script.replace("  *) exit 2;;", "  'app-server --help') echo '--listen unix://';;\n  *) exit 2;;")
    binary.write_text(script)
    result = subprocess.run(['sh', str(ASSETS / 'codex_environment.sh')],
        env={**os.environ, 'HOME': str(tmp_path), 'PATH': str(binary.parent) + ':/usr/bin:/bin'},
        capture_output=True, text=True, check=True)
    assert fields(result.stdout)['compatible'] == 'true'


@pytest.mark.parametrize('turn_status,active', [('completed', False), ('inProgress', True)])
def test_loaded_string_thread_ids_are_checked_using_read_turns(
        monkeypatch, tmp_path, turn_status, active):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    calls = []
    class Rpc:
        def __init__(self, path): pass
        def request(self, method, params):
            calls.append((method, params))
            if method == 'initialize':
                return {}
            if method == 'thread/loaded/list':
                return {'data': ['thread-id']}
            if method == 'thread/read':
                return {'thread': {'id': 'thread-id', 'turns': [{'status': turn_status}]}}
            raise AssertionError('unexpected RPC method: ' + method)
        def send(self, value): pass
        def close(self): pass
    monkeypatch.setattr(runtime, 'RpcConnection', Rpc)
    assert runtime.active_runtime_threads({'socketPath': '/socket'}) is active
    assert [method for method, _ in calls] == ['initialize', 'thread/loaded/list', 'thread/read']
    assert calls[-1][1] == {'threadId': 'thread-id', 'includeTurns': True}


def test_environment_preserves_inherited_proxy_without_saved_network_config(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    monkeypatch.setenv('HTTPS_PROXY', 'http://inherited.proxy:3128')
    runtime = module('codex_runtime')
    env = runtime.environment({'codexPath': '/usr/bin/codex'})
    assert env['HTTPS_PROXY'] == 'http://inherited.proxy:3128'


def test_listener_keeps_inherited_proxy_without_saved_network_config(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    monkeypatch.setenv('HTTPS_PROXY', 'http://inherited.proxy:3128')
    runtime = module('codex_runtime')
    runtime.ROOT.mkdir(parents=True)
    commands = []
    def run(command, **kwargs):
        commands.append(command)
        if command[:2] == ['tmux', 'has-session']:
            return SimpleNamespace(returncode=1)
        return SimpleNamespace(returncode=0, stderr='')
    monkeypatch.setattr(runtime.subprocess, 'run', run)
    verify_calls = []
    def verify(_):
        verify_calls.append(True)
        if len(verify_calls) == 1:
            raise RuntimeError('not ready')
    monkeypatch.setattr(runtime, 'verify_socket', verify)
    runtime.ensure_listener({'codexPath': '/usr/bin/codex', 'transport': 'listener'})
    command = ' '.join(commands[-1])
    assert '-u HTTPS_PROXY' in command
    assert 'bash --noprofile --norc -ic' in command
    assert 'HTTPS_PROXY=http://inherited.proxy:3128' in command


def test_environment_ignores_legacy_phone_proxy(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    monkeypatch.setenv('HTTPS_PROXY', 'http://computer.proxy:3128')
    runtime = module('codex_runtime')
    runtime.ROOT.mkdir(parents=True)
    (runtime.ROOT / 'network.json').write_text(json.dumps({'proxyUrl': 'http://phone.proxy:7890'}))
    assert runtime.environment({'codexPath': '/usr/bin/codex'})['HTTPS_PROXY'] == 'http://computer.proxy:3128'


def test_daemon_reads_computer_bashrc_without_rewriting_it(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    monkeypatch.delenv('HTTPS_PROXY', raising=False)
    runtime = module('codex_runtime')
    runtime.ROOT.mkdir(parents=True)
    bashrc = 'case $- in *i*) ;; *) return;; esac\necho shell-banner\nexport HTTPS_PROXY=http://computer.proxy:3128\n'
    (tmp_path / '.bashrc').write_text(bashrc)
    binary = tmp_path / 'codex'
    binary.write_text('#!/bin/sh\nprintf %s "$HTTPS_PROXY" > "$HOME/observed-proxy"\nprintf \'{"socketPath":"/test.sock"}\\n\'\n')
    binary.chmod(0o700)
    monkeypatch.setattr(runtime, 'verify_socket', lambda _: None)
    runtime.ensure_daemon({'codexPath': str(binary), 'transport': 'native'})
    assert (tmp_path / 'observed-proxy').read_text() == 'http://computer.proxy:3128'
    assert (tmp_path / '.bashrc').read_text() == bashrc


def test_prepare_disables_legacy_proxy_only_after_idle_restart(monkeypatch, tmp_path):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    binary = fake_codex(tmp_path)
    runtime.ROOT.mkdir(parents=True)
    old = runtime.ROOT / 'network.json'
    old.write_text('{"proxyUrl":"http://phone.proxy:7890"}')
    runtime.CONFIG.write_text(json.dumps({'codexPath': str(binary), 'socketPath': '/sock', 'transport': 'native'}))
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *a, **k: SimpleNamespace(returncode=0,stdout='daemon start',stderr=''))
    monkeypatch.setattr(runtime, 'active_runtime_threads', lambda _: False)
    restarts = []
    monkeypatch.setattr(runtime, 'restart_runtime', lambda config: restarts.append(config))
    monkeypatch.setattr(runtime, 'ensure_daemon', lambda config: config)
    runtime.prepare(str(binary))
    assert len(restarts) == 1
    assert not old.exists()
    assert (runtime.ROOT / 'network.json.disabled').read_text() == '{"proxyUrl":"http://phone.proxy:7890"}'


@pytest.mark.parametrize('failure', ['active', 'unknown', 'restart'])
def test_legacy_proxy_migration_preserves_config_when_restart_is_unsafe(monkeypatch, tmp_path, failure):
    monkeypatch.setenv('HOME', str(tmp_path))
    runtime = module('codex_runtime')
    binary = fake_codex(tmp_path)
    runtime.ROOT.mkdir(parents=True)
    original = '{"proxyUrl":"http://phone.proxy:7890"}'
    runtime.LEGACY_NETWORK_CONFIG.write_text(original)
    runtime.CONFIG.write_text(json.dumps({'codexPath': str(binary), 'socketPath': '/sock', 'transport': 'native'}))
    monkeypatch.setattr(runtime.subprocess, 'run', lambda *a, **k: SimpleNamespace(returncode=0, stdout='daemon start', stderr=''))
    def active(_):
        if failure == 'unknown':
            raise RuntimeError('status unavailable')
        return failure == 'active'
    monkeypatch.setattr(runtime, 'active_runtime_threads', active)
    restarts = []
    def restart(_):
        restarts.append(True)
        raise RuntimeError('restart failed')
    monkeypatch.setattr(runtime, 'restart_runtime', restart)
    monkeypatch.setattr(runtime, 'ensure_daemon', lambda _: pytest.fail('must not continue preparation'))
    with pytest.raises(RuntimeError):
        runtime.prepare(str(binary))
    assert runtime.LEGACY_NETWORK_CONFIG.read_text() == original
    assert not (runtime.ROOT / 'network.json.disabled').exists()
    assert len(restarts) == (1 if failure == 'restart' else 0)
