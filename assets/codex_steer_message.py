"""Send input to a live Codex turn through its existing local control socket."""
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
import uuid


class RpcConnection:
    """Dependency-free WebSocket JSON-RPC over Codex's Unix control socket."""
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(5)
        self.stream = None
        self.request_id = 0
        try:
            self.socket.connect(str(path))
            self.stream = self.socket.makefile('rb')
            key = base64.b64encode(os.urandom(16)).decode()
            self.socket.sendall((
                'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
                'Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n'
                f'Sec-WebSocket-Key: {key}\r\n\r\n').encode())
            status = self.stream.readline(8192)
            headers = {}
            for _ in range(100):
                line = self.stream.readline(8192)
                if line == b'\r\n':
                    break
                if not line or b':' not in line:
                    raise RuntimeError('无效的 Codex WebSocket 握手')
                name, value = line.decode().split(':', 1)
                headers[name.lower()] = value.strip()
            accept = base64.b64encode(hashlib.sha1(
                (key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            if (status.split()[1:2] != [b'101'] or
                    headers.get('sec-websocket-accept') != accept):
                raise RuntimeError('Codex 实时接口握手失败')
        except Exception:
            self.close()
            raise

    def close(self):
        if self.stream is not None:
            self.stream.close()
        self.socket.close()

    def send_frame(self, payload, opcode=1):
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack('!H', length)
        else:
            header += bytes([0x80 | 127]) + struct.pack('!Q', length)
        mask = os.urandom(4)
        self.socket.sendall(header + mask + bytes(
            value ^ mask[i % 4] for i, value in enumerate(payload)))

    def send(self, value):
        self.send_frame(json.dumps(value, ensure_ascii=False).encode())

    def read_exact(self, size):
        data = self.stream.read(size)
        if len(data) != size:
            raise RuntimeError('Codex 实时连接已关闭')
        return data

    def receive(self, deadline):
        fragments = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Codex 实时接口响应超时')
            self.socket.settimeout(remaining)
            first, second = self.read_exact(2)
            opcode, length = first & 15, second & 127
            if second & 128 or first & 0x70:
                raise RuntimeError('不支持的 Codex WebSocket 帧')
            if length == 126:
                length = struct.unpack('!H', self.read_exact(2))[0]
            elif length == 127:
                length = struct.unpack('!Q', self.read_exact(8))[0]
            if length + len(fragments) > 16 * 1024 * 1024:
                raise RuntimeError('Codex 实时响应过大')
            payload = self.read_exact(length)
            if opcode == 8:
                raise RuntimeError('Codex 实时连接已关闭')
            if opcode == 9:
                self.send_frame(payload, opcode=10)
                continue
            if opcode == 10:
                continue
            if opcode not in (0, 1):
                raise RuntimeError('不支持的 Codex 实时消息类型')
            fragments.extend(payload)
            if first & 0x80:
                return json.loads(fragments)

    def request(self, method, params):
        self.request_id += 1
        self.send({'id': self.request_id, 'method': method, 'params': params})
        deadline = time.monotonic() + 10
        while True:
            response = self.receive(deadline)
            if response.get('id') != self.request_id:
                continue
            if 'error' in response:
                raise RuntimeError(response['error'].get('message', str(response['error'])))
            return response['result']


def control_socket_path(codex_home):
    config = Path.home() / '.ssh_tool/codex_runtime/connection.json'
    if config.is_file():
        return Path(json.loads(config.read_text(encoding='utf-8'))['socketPath'])
    return codex_home / 'app-server-control' / 'app-server-control.sock'


def steer(rpc, thread_id, message):
    thread = rpc.request('thread/read', {
        'threadId': thread_id, 'includeTurns': False})['thread']
    if thread['status']['type'] != 'active':
        raise RuntimeError('当前任务状态已变化，本次未提交；请重新发送以重新选择路线')
    if thread.get('canAcceptDirectInput') is False:
        raise RuntimeError('目标对话不接受直接输入，无法使用 Steer')
    turns = rpc.request('thread/turns/list', {
        'threadId': thread_id, 'limit': 1,
        'sortDirection': 'desc', 'itemsView': 'summary'})['data']
    if not turns or turns[0]['status'] != 'inProgress':
        raise RuntimeError('当前任务已结束或状态已变化，本次未提交；请重新发送')
    # expectedTurnId prevents delivery to a different turn if the task ends meanwhile.
    # Never interrupt, resume, start, or silently fall back to a queued submission.
    return rpc.request('turn/steer', {
        'threadId': thread_id, 'expectedTurnId': turns[0]['id'],
        'clientUserMessageId': str(uuid.uuid4()),
        'input': [{'type': 'text', 'text': message}],
    })


def main():
    thread_id, message = sys.argv[1:3]
    codex_home = Path(os.environ.get('CODEX_HOME', '~/.codex')).expanduser()
    path = control_socket_path(codex_home)
    rpc = None
    try:
        rpc = RpcConnection(path)
        rpc.request('initialize', {
            'clientInfo': {'name': 'ssh_tool_steer', 'version': '1'},
            'capabilities': {'experimentalApi': True},
        })
        rpc.send({'method': 'initialized', 'params': {}})
        result = steer(rpc, thread_id, message)
        print(json.dumps(result))
    except (FileNotFoundError, ConnectionRefusedError):
        raise SystemExit('目标任务正在运行，但所属 Codex 没有可连接的共享实时接口。'
                         '本次未发送，也未中断任务；需在旧终端任务结束后接入共享 app-server')
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        raise SystemExit('默认发送未确认成功（不会自动重发或切换 Queue）：' + str(error))
    finally:
        if rpc is not None:
            rpc.close()


if __name__ == '__main__':
    main()
