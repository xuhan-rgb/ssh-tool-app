import pathlib
import re
import sys
import tempfile
import os
import base64
import uuid
import json
import unittest
from unittest.mock import patch

SOURCE = (pathlib.Path(__file__).parents[1] / 'lib/services/codex_session_service.dart').read_text()
SCRIPT = re.search(r"static const _sendWithModelScript = r'''(.*?)''';", SOURCE, re.S).group(1)


class Rpc:
    def __init__(self, state='idle', fail=False):
        self.state, self.fail = state, fail
        self.calls = []
        self.closed = False

    def request(self, method, params):
        self.calls.append((method, params))
        if method == 'thread/read':
            return {'thread': {'status': {'type': self.state}}}
        if method == 'turn/start' and self.fail:
            raise RuntimeError('model unavailable')
        return {}

    def send(self, value):
        pass

    def close(self):
        self.closed = True


def send(rpc):
    import os
    from pathlib import Path
    with patch.object(sys, 'argv', ['script', 'thread', '中文\n"exact"', 'gpt-6.1-sol', 'low', '/project']):
        with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {'HOME': home}):
            exec(SCRIPT, {'sys': sys, 'os': os, 'Path': Path, 'RpcConnection': lambda _: rpc,
                          'uuid': uuid, 'base64': base64, 'json': json})


class ModelMessageTests(unittest.TestCase):
    def test_idle_sends_exact_message_and_configuration_once(self):
        rpc = Rpc()
        send(rpc)
        self.assertEqual([p for m, p in rpc.calls if m == 'turn/start'], [{
            'threadId': 'thread', 'input': [{'type': 'text', 'text': '中文\n"exact"'}],
            'model': 'gpt-6.1-sol', 'effort': 'low'}])
        self.assertNotIn('thread/resume', [m for m, _ in rpc.calls])
        self.assertTrue(rpc.closed)

    def test_running_and_unknown_do_not_send_or_interrupt(self):
        for state in ['active', 'systemError']:
            rpc = Rpc(state)
            with self.assertRaises(RuntimeError):
                send(rpc)
            self.assertEqual([m for m, _ in rpc.calls], ['initialize', 'thread/read'])
            self.assertTrue(rpc.closed)

    def test_closed_thread_resumes_before_sending(self):
        rpc = Rpc('notLoaded')
        send(rpc)
        self.assertEqual([m for m, _ in rpc.calls], ['initialize', 'thread/read', 'thread/resume', 'turn/start'])

    def test_phone_worker_uses_its_owner_and_preserves_model_and_directory(self):
        from pathlib import Path
        for busy in (False, True):
            with tempfile.TemporaryDirectory() as home, patch.dict(os.environ, {'HOME': home}):
                folder = Path(home) / '.ssh_tool'
                folder.mkdir()
                output = folder / 'submitted.json'
                (folder / 'codex_chat_worker.py').write_text(
                    "import base64, json\nfrom pathlib import Path\n"
                    f"def session_info(t): return {{'open': True, 'busy': {busy!r}}}\n"
                    f"def start(data): Path({str(output)!r}).write_text(base64.b64decode(data).decode())\n")
                rpc = Rpc()
                with patch.object(sys, 'argv', ['script', 'thread', 'hello', 'gpt-6.1-sol', 'low', '/project']):
                    with self.assertRaises(RuntimeError if busy else SystemExit):
                        exec(SCRIPT, {'sys': sys, 'os': os, 'Path': Path,
                                      'RpcConnection': lambda _: rpc, 'uuid': uuid,
                                      'base64': base64, 'json': json})
                self.assertEqual(rpc.calls, [])
                self.assertEqual(output.exists(), not busy)
                if not busy:
                    request = json.loads(output.read_text())
                    self.assertEqual(request['threadId'], 'thread')
                    self.assertEqual(request['model'], 'gpt-6.1-sol')
                    self.assertEqual(request['effort'], 'low')
                    self.assertEqual(request['workDir'], '/project')

    def test_failed_send_is_not_retried(self):
        rpc = Rpc(fail=True)
        with self.assertRaisesRegex(RuntimeError, 'model unavailable'):
            send(rpc)
        self.assertEqual(len([m for m, _ in rpc.calls if m == 'turn/start']), 1)
        self.assertTrue(rpc.closed)


if __name__ == '__main__':
    unittest.main()
