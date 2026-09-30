import datetime
import contextlib
import io
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import uuid


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'lib/services/codex_session_service.dart').read_text()
SCRIPT = re.search(r"static const String _listScript = r'''(.*?)''';", SOURCE, re.S).group(1)


class CodexSessionDiscoveryTest(unittest.TestCase):
    def test_managed_daemon_default_socket_is_recognized(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'sessions').mkdir()
            control = home / 'app-server-control'
            control.mkdir()
            (control / 'app-server-control.sock').touch()
            definitions = SCRIPT.split('\nif sessions_dir.is_dir():', 1)[0]
            namespace = {}
            with patch.dict(os.environ, {'CODEX_HOME': directory}), patch('sys.argv', ['discover']):
                exec(definitions, namespace)
            class FakeRpc:
                def __init__(self, path): pass
                def request(self, method, params):
                    return {'data': [], 'nextCursor': None} if method == 'thread/loaded/list' else {}
                def send(self, value): pass
                def close(self): pass
            namespace['RpcConnection'] = FakeRpc
            original_text = Path.read_text
            original_bytes = Path.read_bytes
            def read_text(path, *args, **kwargs):
                if str(path) == '/proc/locks':
                    return '1: FLOCK ADVISORY WRITE 123 00:01:456 0 EOF\n'
                return original_text(path, *args, **kwargs)
            def read_bytes(path):
                if str(path) == '/proc/123/cmdline':
                    return b'codex\0app-server\0--listen\0unix://\0--managed-daemon\0'
                return original_bytes(path)
            with patch.object(Path, 'read_text', read_text), patch.object(Path, 'read_bytes', read_bytes):
                loaded, inodes = namespace['shared_daemon_threads']()
            self.assertEqual(loaded, set())
            self.assertEqual(inodes, {(0, 1, 456)})

    def test_shared_daemon_retained_lock_is_closed_when_thread_is_not_loaded(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'sessions').mkdir()
            (home / 'thread-writer-locks').mkdir()
            thread_id = str(uuid.UUID(int=4))
            rows = [
                {'type': 'session_meta', 'payload': {'id': thread_id, 'cwd': directory}},
                {'type': 'event_msg', 'payload': {'type': 'task_complete'}},
            ]
            (home / 'sessions' / f'rollout-{thread_id}.jsonl').write_text(
                ''.join(json.dumps(row) + '\n' for row in rows))
            lock_path = home / 'thread-writer-locks' / f'{thread_id}.lock'
            with lock_path.open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                stat = lock_path.stat()
                identity = (os.major(stat.st_dev), os.minor(stat.st_dev), stat.st_ino)
                definitions, main = SCRIPT.split('\nif sessions_dir.is_dir():', 1)
                for loaded, daemon_writer in [(True, True), (False, True), (False, False)]:
                    for mode in ['__all__', '__opened__']:
                        with self.subTest(loaded=loaded, daemon_writer=daemon_writer, mode=mode):
                            namespace = {}
                            output = io.StringIO()
                            with patch.dict(os.environ, {'CODEX_HOME': directory}), \
                                    patch('sys.argv', ['discover', mode]), contextlib.redirect_stdout(output):
                                exec(definitions, namespace)
                                namespace['shared_daemon_threads'] = lambda: (
                                    {thread_id} if loaded else set(),
                                    {identity} if daemon_writer else set())
                                exec('if sessions_dir.is_dir():' + main, namespace)
                            items = [json.loads(line) for line in output.getvalue().splitlines()]
                            expected_open = loaded or not daemon_writer
                            if mode == '__opened__' and not expected_open:
                                self.assertEqual(items, [])
                            else:
                                self.assertEqual(len(items), 1)
                                self.assertEqual(items[0]['remoteOpen'], expected_open)
                                self.assertIs(items[0]['writerLocked'], True)

    def test_open_chinese_conversation_survives_tail_cut_inside_utf8_character(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'sessions').mkdir()
            (home / 'thread-writer-locks').mkdir()
            thread_id = str(uuid.UUID(int=3))
            rows = [
                {'type': 'session_meta', 'payload': {'id': thread_id, 'cwd': directory}},
                {'type': 'response_item', 'payload': {'type': 'message', 'role': 'user',
                    'content': [{'text': '中文内容' * 20000}]}},
                {'type': 'event_msg', 'payload': {'type': 'task_started'}},
            ]
            raw = ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in rows).encode()
            while raw[len(raw) - 65536] & 0xc0 != 0x80:
                raw += b'\n'
            path = home / 'sessions' / f'rollout-{thread_id}.jsonl'
            path.write_bytes(raw)
            with (home / 'thread-writer-locks' / f'{thread_id}.lock').open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for indexed in [False, True]:
                    if indexed:
                        (home / 'session_index.jsonl').write_text(json.dumps(
                            {'id': thread_id, 'thread_name': '中文对话'}) + '\n')
                    for mode in ['__all__', '__opened__', '__running__']:
                        with self.subTest(indexed=indexed, mode=mode):
                            result = subprocess.run(['python3', '-c', SCRIPT, mode],
                                env={**os.environ, 'CODEX_HOME': directory},
                                capture_output=True, text=True, check=True)
                            items = [json.loads(line) for line in result.stdout.splitlines()]
                            self.assertEqual([item['id'] for item in items], [thread_id])
                            self.assertEqual(items[0]['state'], 'running')

    def test_open_session_with_only_settings_is_not_running(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'sessions').mkdir()
            locks = home / 'thread-writer-locks'
            locks.mkdir()
            thread_id = str(uuid.UUID(int=2))
            rows = [
                {'type': 'session_meta', 'payload': {'id': thread_id, 'cwd': directory}},
                {'type': 'event_msg', 'payload': {'type': 'thread_settings_applied'}},
            ]
            (home / 'sessions' / f'rollout-{thread_id}.jsonl').write_text(
                ''.join(json.dumps(row) + '\n' for row in rows))

            def query(mode):
                result = subprocess.run(
                    ['python3', '-c', SCRIPT, mode],
                    env={**os.environ, 'CODEX_HOME': directory},
                    capture_output=True, text=True, check=True,
                )
                return [json.loads(line) for line in result.stdout.splitlines()]

            with (locks / f'{thread_id}.lock').open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for mode in ['__all__', '__opened__']:
                    item, = query(mode)
                    self.assertEqual(item['state'], 'not_started')
                    self.assertIs(item['remoteOpen'], True)
                self.assertEqual(query('__running__'), [])
            self.assertEqual(query('__all__'), [])

    def test_completed_session_open_state_tracks_live_lock_not_lock_file(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / 'sessions').mkdir()
            locks = home / 'thread-writer-locks'
            locks.mkdir()
            thread_id = str(uuid.UUID(int=1))
            rows = [
                {'type': 'session_meta', 'payload': {'id': thread_id, 'cwd': directory}},
                {'type': 'event_msg', 'payload': {'type': 'task_complete'}},
            ]
            (home / 'sessions' / f'rollout-{thread_id}.jsonl').write_text(
                ''.join(json.dumps(row) + '\n' for row in rows))

            def inspect():
                result = subprocess.run(
                    ['python3', '-c', SCRIPT, '__all__'],
                    env={**os.environ, 'CODEX_HOME': directory},
                    capture_output=True, text=True, check=True,
                )
                item = json.loads(result.stdout)
                self.assertEqual(item['state'], 'complete')
                return item['remoteOpen']

            lock_path = locks / f'{thread_id}.lock'
            self.assertIs(inspect(), False)
            with lock_path.open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.assertIs(inspect(), True)
                fcntl.flock(lock, fcntl.LOCK_UN)
                self.assertIs(inspect(), False)
            lock_path.unlink()
            lock_path.mkdir()  # Unreadable lock state must not mean closed.
            self.assertIsNone(inspect())

    def test_new_unindexed_session_enters_first_page_without_losing_older_sessions(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            sessions = home / 'sessions'
            sessions.mkdir()
            base = datetime.datetime(2026, 9, 1, tzinfo=datetime.timezone.utc).timestamp()
            ids = [str(uuid.UUID(int=i + 1)) for i in range(201)]
            index = []
            for i, thread_id in enumerate(ids):
                stamp = datetime.datetime.fromtimestamp(base + i, datetime.timezone.utc).isoformat()
                path = sessions / f'rollout-{thread_id}.jsonl'
                rows = [
                    {'type': 'session_meta', 'payload': {'id': thread_id, 'cwd': directory}},
                    {'type': 'event_msg', 'timestamp': stamp, 'payload': {'type': 'task_complete'}},
                ]
                path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
                os.utime(path, (base + i, base + i))
                if i < 200:
                    index.append({'id': thread_id, 'thread_name': f'Old {i}', 'updated_at': stamp})
            (home / 'session_index.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in index))

            def page(offset):
                result = subprocess.run(
                    ['python3', '-c', SCRIPT, '__all__', str(offset)],
                    env={**os.environ, 'CODEX_HOME': directory},
                    capture_output=True, text=True, check=True,
                )
                return [json.loads(line)['id'] for line in result.stdout.splitlines()]

            first = page(0)
            self.assertEqual(len(first), 200)
            self.assertEqual(first[0], ids[-1])
            self.assertEqual(first + page(200), list(reversed(ids)))
            locks = home / 'thread-writer-locks'
            locks.mkdir()
            with (locks / f'{ids[0]}.lock').open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = subprocess.run(
                    ['python3', '-c', SCRIPT, '__opened__'],
                    env={**os.environ, 'CODEX_HOME': directory},
                    capture_output=True, text=True, check=True,
                )
                opened = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual([item['id'] for item in opened], [ids[0]])
                self.assertEqual(opened[0]['state'], 'complete')
                self.assertIs(opened[0]['remoteOpen'], True)


if __name__ == '__main__':
    unittest.main()
