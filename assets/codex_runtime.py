"""Prepare/reuse native Codex daemon and its desktop shortcut."""
import fcntl
import json
import os
import shlex
import shutil
import stat
from pathlib import Path
import subprocess
import sys
import threading
import time

from codex_steer_message import RpcConnection

ROOT = Path.home() / '.ssh_tool' / 'codex_runtime'
CONFIG = ROOT / 'connection.json'
LEGACY_NETWORK_CONFIG = ROOT / 'network.json'
PROXY_ENV = ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY',
             'http_proxy', 'https_proxy', 'all_proxy', 'NO_PROXY', 'no_proxy')
LAUNCHER = '#!/bin/sh\nexec python3 "$HOME/.ssh_tool/codex_runtime.py" terminal "$@"\n'
PATH_BLOCK = '''# >>> ssh-tool codex command >>>
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< ssh-tool codex command <<<
'''


def install_shortcut():
    launcher = Path.home() / '.local/bin/codex-phone'
    launcher.parent.mkdir(parents=True, exist_ok=True)
    if launcher.exists() and launcher.read_text(encoding='utf-8') != LAUNCHER:
        raise RuntimeError('已有其他 codex-phone 命令，本次没有覆盖；请先重命名该命令')
    temporary = launcher.with_suffix('.tmp')
    temporary.write_text(LAUNCHER, encoding='utf-8')
    temporary.chmod(0o700)
    temporary.replace(launcher)
    bashrc = Path.home() / '.bashrc'
    content = bashrc.read_text(encoding='utf-8') if bashrc.exists() else ''
    if PATH_BLOCK not in content:
        if '# >>> ssh-tool codex command >>>' in content:
            raise RuntimeError('.bashrc 中的 Codex 快捷命令配置已修改，请检查该配置块')
        backup = ROOT / 'bashrc.before-shortcut'
        if bashrc.exists() and not backup.exists():
            shutil.copy2(bashrc, backup)
            backup.chmod(0o600)
        with bashrc.open('a', encoding='utf-8') as stream:
            stream.write('\n' + PATH_BLOCK)
    return launcher


def read_config():
    return json.loads(CONFIG.read_text(encoding='utf-8'))


def environment(config):
    env = os.environ.copy()
    env['PATH'] = str(Path(config['codexPath']).parent) + os.pathsep + env.get('PATH', os.defpath)
    if config.get('authPath'):
        env['CODEX_AUTH_CODEX_BIN'] = config['codexPath']
    return env


def computer_shell(command):
    # Interactive shell configuration may hold the computer's existing proxy.
    # Silence startup banners so they cannot corrupt the command's JSON output.
    return ['bash', '--noprofile', '--norc', '-ic',
            'if [ -r "$HOME/.bashrc" ]; then . "$HOME/.bashrc" >/dev/null; fi; exec ' + shlex.join(command)]


def active_runtime_threads(config):
    rpc = RpcConnection(Path(config['socketPath']))
    try:
        rpc.request('initialize', {'clientInfo': {'name': 'ssh_tool_setup', 'version': '1'},
                                   'capabilities': {'experimentalApi': True}})
        rpc.send({'method': 'initialized', 'params': {}})
        loaded = rpc.request('thread/loaded/list', {})
        entries = loaded.get('data')
        if not isinstance(entries, list):
            raise RuntimeError('invalid loaded thread list')
        thread_ids = []
        for item in entries:
            thread_id = item if isinstance(item, str) else item.get('id') if isinstance(item, dict) else None
            if not thread_id:
                raise RuntimeError('invalid loaded thread entry')
            thread_ids.append(thread_id)
        for thread_id in thread_ids:
            result = rpc.request('thread/read', {'threadId': thread_id, 'includeTurns': True})
            thread = result.get('thread')
            if not isinstance(thread, dict) or not isinstance(thread.get('turns'), list):
                raise RuntimeError('invalid loaded thread status')
            status = thread.get('status')
            if isinstance(status, dict):
                status = status.get('type') or status.get('status')
            turns = thread.get('turns', [])
            if (status in ('busy', 'inProgress', 'active') or thread.get('busy') is True or
                    any(turn.get('status') in ('busy', 'inProgress', 'active') or
                        turn.get('busy') is True for turn in turns)):
                return True
        return False
    finally:
        rpc.close()


def restart_runtime(config):
    if config.get('transport') == 'listener':
        name = config.get('tmuxName')
        socket_path = config.get('socketPath')
        expected_socket = str(ROOT / 'app-server.sock')
        if name != 'ssh-tool-codex-runtime' or socket_path != expected_socket:
            raise RuntimeError('无法确认共享服务归本工具管理，未重启服务')
        subprocess.run(['tmux', 'kill-session', '-t', name], check=True,
                       capture_output=True, text=True, timeout=10)
        socket = Path(socket_path)
        if socket.exists() and stat.S_ISSOCK(socket.stat().st_mode):
            socket.unlink()
        config.pop('tmuxName', None)
        ensure_listener(config)
        return
    stopped = subprocess.run(prefix(config) + ['app-server', 'daemon', 'stop'],
                            env=environment(config), capture_output=True, text=True, timeout=15)
    if stopped.returncode:
        raise RuntimeError('无法重启共享 Codex 服务，旧代理设置尚未停用，请检查服务状态')
    ensure_daemon(config)


def prefix(config):
    auth = config.get('authPath')
    return [auth, 'run', '--'] if auth else [config['codexPath']]


def verify_socket(path):
    rpc = RpcConnection(Path(path))
    try:
        rpc.request('initialize', {'clientInfo': {'name': 'ssh_tool_setup', 'version': '1'},
                                   'capabilities': {'experimentalApi': True}})
        rpc.send({'method': 'initialized', 'params': {}})
        rpc.request('thread/loaded/list', {})
    finally:
        rpc.close()


def save_config(config):
    temporary = CONFIG.with_suffix('.tmp')
    temporary.write_text(json.dumps(config), encoding='utf-8')
    temporary.chmod(0o600)
    temporary.replace(CONFIG)


def ensure_listener(config):
    socket_path = ROOT / 'app-server.sock'
    try:
        verify_socket(str(socket_path))
        config['socketPath'] = str(socket_path)
        save_config(config)
        return config
    except (OSError, RuntimeError):
        pass
    name = 'ssh-tool-codex-runtime'
    alive = subprocess.run(['tmux', 'has-session', '-t', name], capture_output=True).returncode == 0
    if alive:
        raise RuntimeError('已有共享服务进程但无法连接，本次没有重复启动；请检查远端服务')
    if socket_path.exists():
        if not stat.S_ISSOCK(socket_path.stat().st_mode):
            raise RuntimeError('共享 socket 路径被其他文件占用')
        socket_path.unlink()
    env = environment(config)
    # Replace stale tmux proxy variables with the current process environment;
    # then read the computer's shell configuration inside the new service.
    assignments = [item for name in PROXY_ENV for item in ('-u', name)]
    assignments.extend(['PATH=' + env['PATH'],
                        'CODEX_HOME=' + env.get('CODEX_HOME', str(Path.home() / '.codex'))])
    if config.get('authPath'):
        assignments.append('CODEX_AUTH_CODEX_BIN=' + config['codexPath'])
    assignments.extend(name + '=' + env[name] for name in PROXY_ENV if name in env)
    command = ['env', *assignments, *computer_shell(prefix(config) +
               ['app-server', '--listen', 'unix://' + str(socket_path)])]
    shell_command = 'umask 077; exec ' + shlex.join(command) + ' >> ' + shlex.quote(str(ROOT / 'server.log')) + ' 2>&1'
    result = subprocess.run(['tmux', 'new-session', '-d', '-s', name, shell_command],
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError('无法启动共享 Codex 服务：' + result.stderr.strip())
    deadline = time.monotonic() + 15
    last_error = ''
    while time.monotonic() < deadline:
        try:
            verify_socket(str(socket_path))
            config.update({'socketPath': str(socket_path), 'tmuxName': name})
            save_config(config)
            return config
        except (OSError, RuntimeError) as error:
            last_error = str(error)
            time.sleep(.15)
    raise RuntimeError('共享服务未就绪：' + last_error)


def ensure_daemon(config):
    if config.get('transport') == 'listener':
        return ensure_listener(config)
    result = subprocess.run(computer_shell(prefix(config) + ['app-server', 'daemon', 'start']),
                            env=environment(config), capture_output=True, text=True, timeout=30)
    if result.returncode:
        # Some CLI packages expose daemon help but require a separate managed
        # installation at runtime. Reuse the installed CLI's socket server.
        if 'managed standalone Codex install not found' in result.stderr:
            help_result = subprocess.run(prefix(config) + ['app-server', '--help'],
                                         env=environment(config), capture_output=True,
                                         text=True, timeout=10)
            if help_result.returncode == 0 and '--listen' in help_result.stdout:
                config['transport'] = 'listener'
                return ensure_listener(config)
        raise RuntimeError('共享 Codex 服务启动失败：' + result.stderr.strip()[-1000:])
    try:
        value = json.loads(result.stdout)
        socket_path = value['socketPath']
        if not isinstance(socket_path, str) or not Path(socket_path).is_absolute():
            raise ValueError('invalid socketPath')
    except (ValueError, KeyError, TypeError) as error:
        raise RuntimeError('Codex daemon 未返回有效的 socketPath') from error
    verify_socket(socket_path)
    config['socketPath'] = socket_path
    save_config(config)
    return config


def prepare(codex_path):
    if not Path(codex_path).is_file() or not os.access(codex_path, os.X_OK):
        raise RuntimeError('Codex 路径不可执行')
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    ROOT.chmod(0o700)
    auth = Path.home() / '.local/bin/codex-auth'
    config = {'codexPath': codex_path, 'authPath': str(auth) if os.access(auth, os.X_OK) else None}
    help_result = subprocess.run([codex_path, 'app-server', 'daemon', 'start', '--help'],
                                 env=environment(config), capture_output=True, text=True, timeout=10)
    config['transport'] = ('native' if help_result.returncode == 0 and
                           'daemon start' in help_result.stdout else 'listener')
    with (ROOT / '.setup.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if LEGACY_NETWORK_CONFIG.exists():
            if CONFIG.exists():
                previous = read_config()
                try:
                    active = active_runtime_threads(previous)
                except Exception as error:
                    raise RuntimeError('无法确认对话状态，旧代理设置尚未停用；请稍后重新准备') from error
                if active:
                    raise RuntimeError('有对话正在运行，请任务结束后重新准备以使用电脑网络配置')
                restart_runtime(previous)
            ensure_daemon(config)
            LEGACY_NETWORK_CONFIG.replace(ROOT / 'network.json.disabled')
        else:
            ensure_daemon(config)
    return config


def prepared_config():
    config = read_config()
    with (ROOT / '.setup.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            verify_socket(config['socketPath'])
            return config
        except (OSError, RuntimeError):
            return ensure_daemon(config)


def proxy():
    # Bridge JSONL worker traffic to the daemon's WebSocket Unix socket.
    # Native "app-server proxy" is not assumed to expose this wire format.
    config = prepared_config()
    rpc = RpcConnection(Path(config['socketPath']))
    send_frame = rpc.send_frame
    send_lock = threading.Lock()

    def serialized_send(payload, opcode=1):
        with send_lock:
            send_frame(payload, opcode)
    rpc.send_frame = serialized_send

    def receive():
        try:
            while True:
                message = rpc.receive(time.monotonic() + 365 * 24 * 3600)
                print(json.dumps(message, ensure_ascii=False), flush=True)
        except Exception as error:
            print('共享 Codex 连接已断开：' + str(error), file=sys.stderr, flush=True)
            os._exit(1)

    receiver = threading.Thread(target=receive, daemon=True)
    receiver.start()
    try:
        for line in sys.stdin:
            if line.strip():
                rpc.send(json.loads(line))
    finally:
        rpc.close()


def terminal(arguments):
    config = read_config()
    with (ROOT / '.setup.lock').open('a+') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        config = ensure_daemon(config)
    # A remote server's default cwd can differ from the desktop shell's directory.
    has_directory = any(value in ('-C', '--cd') or value.startswith('--cd=')
                        or value.startswith('-C') for value in arguments)
    directory = ([] if has_directory or any(value in ('resume', 'fork', 'agents')
                                            for value in arguments)
                 else ['--cd', os.getcwd()])
    command = prefix(config) + ['--remote', 'unix://' + config['socketPath']] + directory + arguments
    os.execvpe(command[0], command, environment(config))


def main():
    action = sys.argv[1]
    if action == 'prepare':
        prepare(sys.argv[2])
        print(json.dumps({'ok': True}))
    elif action == 'check':
        config = read_config()
        verify_socket(config['socketPath'])
        print(json.dumps({'ok': True, 'setupVersion': 4}))
    elif action == 'terminal':
        terminal(sys.argv[2:])
    elif action == 'shortcut':
        read_config()
        with (ROOT / '.setup.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            install_shortcut()
        print(json.dumps({'ok': True}))
    elif action == 'proxy':
        proxy()
    else:
        raise ValueError('未知的 Codex 环境操作')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(json.dumps({'error': str(error)}, ensure_ascii=False))
        sys.exit(1)
