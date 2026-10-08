"""Subscribe to questions in a shared Codex thread and submit their answers."""
import queue
import json
import os
from pathlib import Path
import socket
import sys
import time
import threading

from codex_steer_message import RpcConnection, control_socket_path


class InteractionBridge:
    def __init__(self, thread_id, send, emit):
        self.thread_id, self.send, self.emit = thread_id, send, emit
        self.pending = {}
        self.submitted = set()

    def receive(self, message):
        params = message.get('params', {})
        if params.get('threadId') != self.thread_id:
            return
        if message.get('method') == 'item/tool/requestUserInput' and 'id' in message:
            request_id = message['id']
            if request_id not in self.pending:
                self.pending[request_id] = message
                self.emit({'type': 'pending', 'request': message})
        elif message.get('method') == 'serverRequest/resolved':
            request_id = params.get('requestId')
            if request_id in self.pending:
                del self.pending[request_id]
                self.submitted.discard(request_id)
                self.emit({'type': 'resolved', 'id': request_id})

    def submit(self, value):
        request_id = value.get('id')
        if request_id not in self.pending:
            raise ValueError('问题已在其他端回答或取消，请等待同步')
        if request_id in self.submitted:
            raise ValueError('答案已发送，正在等待远程确认')
        questions = self.pending[request_id]['params']['questions']
        answers = value.get('answers', {})
        if not isinstance(answers, dict) or set(answers) != {q['id'] for q in questions}:
            raise ValueError('请回答全部问题')
        for question in questions:
            answer = answers[question['id']]
            if (not isinstance(answer, list) or len(answer) != 1 or
                    not isinstance(answer[0], str) or not answer[0].strip()):
                raise ValueError('每个问题需要一个答案')
            options = question.get('options') or []
            if options and not question.get('isOther') and answer[0] not in {o['label'] for o in options}:
                raise ValueError('选项已变化，请重新选择')
        self.send({'id': request_id, 'result': {
            'answers': {key: {'answers': answer} for key, answer in answers.items()}}})
        self.submitted.add(request_id)


def run(thread_id):
    rpc = RpcConnection(control_socket_path(Path(os.environ.get('CODEX_HOME', '~/.codex')).expanduser()))
    messages = queue.Queue()
    send_lock = threading.Lock()
    original_send_frame = rpc.send_frame

    def send_frame(payload, opcode=1):
        with send_lock:
            original_send_frame(payload, opcode)
    rpc.send_frame = send_frame

    def emit(value):
        print(json.dumps(value, ensure_ascii=False), flush=True)

    bridge = InteractionBridge(thread_id, rpc.send, emit)

    def reader():
        try:
            while True:
                messages.put(('rpc', rpc.receive(time.monotonic() + 86400)))
        except Exception as error:
            messages.put(('error', str(error)))

    def inputs():
        try:
            for line in sys.stdin:
                messages.put(('input', json.loads(line)))
        except Exception as error:
            messages.put(('error', str(error)))
        finally:
            messages.put(('closed', None))

    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=inputs, daemon=True).start()
    rpc.send({'id': 'phone-init', 'method': 'initialize', 'params': {
        'clientInfo': {'name': 'ssh_tool_questions', 'version': '1'},
        'capabilities': {'experimentalApi': True}}})
    try:
        while True:
            kind, value = messages.get()
            if kind == 'closed':
                return
            if kind == 'error':
                raise RuntimeError(value)
            if kind == 'input':
                try:
                    bridge.submit(value)
                except (ValueError, KeyError) as error:
                    emit({'type': 'error', 'id': value.get('id'), 'error': str(error)})
                continue
            # Server requests may arrive before the resume response. Never discard them.
            if 'method' in value:
                bridge.receive(value)
            elif value.get('id') in ('phone-init', 'phone-resume'):
                if 'error' in value:
                    raise RuntimeError(value['error'].get('message', str(value['error'])))
                if value['id'] == 'phone-init':
                    rpc.send({'method': 'initialized', 'params': {}})
                    rpc.send({'id': 'phone-resume', 'method': 'thread/resume', 'params': {
                        'threadId': thread_id, 'excludeTurns': True}})
                else:
                    emit({'type': 'ready', 'pendingIds': list(bridge.pending)})
    finally:
        # Exit without unsubscribing other clients or changing the running turn.
        rpc.socket.shutdown(socket.SHUT_RDWR)
        rpc.close()


if __name__ == '__main__':
    try:
        run(sys.argv[1])
    except Exception as error:
        print(json.dumps({'type': 'connectionError', 'error': str(error)}, ensure_ascii=False), flush=True)
        sys.exit(1)
