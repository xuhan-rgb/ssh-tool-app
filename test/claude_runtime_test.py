import json
import os
import shutil
import sys
import tempfile
import time
import uuid
import unittest
from pathlib import Path
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'assets'))
import claude_runtime as runtime


class ClaudeRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.root_patch = mock.patch.object(runtime, 'ROOT', self.root)
        self.root_patch.start()
        self.tmux = mock.patch.object(runtime, 'tmux')
        self.tmux_mock = self.tmux.start()
        self.tmux_mock.return_value = mock.Mock(stdout='', returncode=0)
        self.popen = mock.patch.object(runtime.subprocess, 'Popen')
        self.popen_mock = self.popen.start()
        self.sid = 'session_1'
        self.directory = self.root / self.sid
        self.directory.mkdir()
        self.state = dict(sessionId=self.sid, tmuxSession='ssh-claude-' + self.sid,
                          workDir=self.temp.name, resume=True, status='ready')
        runtime.save(self.directory / 'state.json', self.state)

    def tearDown(self):
        mock.patch.stopall()
        self.temp.cleanup()

    def messages(self):
        return runtime.read(self.directory / 'messages.json', [])

    def test_fifo_enqueue_is_durable_idempotent_and_rejects_conflicting_id(self):
        first = runtime.enqueue(dict(sessionId=self.sid, messageId='m1', text='one'))
        second = runtime.enqueue(dict(sessionId=self.sid, messageId='m2', text='two'))
        self.assertEqual([m['id'] for m in self.messages()], ['m1', 'm2'])
        self.assertEqual(runtime.enqueue(dict(sessionId=self.sid, messageId='m1', text='one')), first)
        with self.assertRaisesRegex(ValueError, '不同内容'):
            runtime.enqueue(dict(sessionId=self.sid, messageId='m1', text='changed'))
        self.assertEqual([m['id'] for m in self.messages()], ['m1', 'm2'])
        self.assertEqual(self.popen_mock.call_count, 2)
        self.assertTrue((self.directory / 'messages.json').exists())

    def test_rejects_terminal_control_characters(self):
        for text in ('hello\x1b[2J', 'hello\x03'):
            with self.subTest(text=repr(text)), self.assertRaisesRegex(ValueError, '控制字符'):
                runtime.enqueue(dict(sessionId=self.sid, messageId='m1', text=text))

    def test_hooks_match_session_ignore_subagent_and_prompt_ack_is_exact(self):
        runtime.save(self.directory / 'messages.json', [
            dict(id='m1', text='approved text', status='dispatching', sentAt=1)])
        runtime.hook(self.sid, 'UserPromptSubmit',
                     dict(session_id='wrong', prompt='approved text'))
        runtime.hook(self.sid, 'UserPromptSubmit',
                     dict(session_id=self.sid, agent_id='subagent', prompt='approved text'))
        self.assertEqual(self.messages()[0]['status'], 'dispatching')
        self.assertEqual(runtime.read(self.directory / 'state.json')['status'], 'ready')
        runtime.hook(self.sid, 'UserPromptSubmit',
                     dict(session_id=self.sid, prompt='approved text plus'))
        self.assertEqual(self.messages()[0]['status'], 'dispatching')
        runtime.hook(self.sid, 'UserPromptSubmit',
                     dict(session_id=self.sid, prompt='  approved text  '))
        self.assertEqual(self.messages()[0]['status'], 'dispatching')
        runtime.hook(self.sid, 'UserPromptSubmit',
                     dict(session_id=self.sid, prompt='approved text'))
        self.assertEqual(self.messages()[0]['status'], 'accepted')

    def test_permission_prompt_blocks_dispatch(self):
        runtime.hook(self.sid, 'Notification',
                     dict(session_id=self.sid, notification_type='permission_prompt'))
        self.assertEqual(runtime.read(self.directory / 'state.json')['status'], 'awaiting_input')
        runtime.enqueue(dict(sessionId=self.sid, messageId='m1', text='wait'))
        with mock.patch.object(runtime.time, 'sleep', side_effect=RuntimeError('stop loop')):
            with self.assertRaisesRegex(RuntimeError, 'stop loop'):
                runtime.dispatch(self.sid)
        self.assertEqual(self.messages()[0]['status'], 'queued')
        self.assertFalse(any(call.args[0] in ('load-buffer', 'paste-buffer', 'send-keys')
                             for call in self.tmux_mock.call_args_list))

    def test_ensure_refuses_session_owned_by_external_agent(self):
        agents = mock.Mock(returncode=0, stdout=json.dumps([{'sessionId': self.sid}]))
        self.tmux_mock.side_effect = [__import__('subprocess').CalledProcessError(1, 'tmux')]
        with mock.patch.object(runtime.subprocess, 'run', return_value=agents):
            with self.assertRaisesRegex(RuntimeError, '外部 Claude 实例'):
                runtime.ensure(dict(sessionId=self.sid, workDir=self.temp.name))
        self.assertFalse(any(call.args[0] == 'new-session'
                             for call in self.tmux_mock.call_args_list))

    def test_ensure_reuses_live_instance(self):
        with mock.patch.object(runtime.subprocess, 'run') as run:
            result = runtime.ensure(dict(sessionId=self.sid, workDir=self.temp.name))
        self.assertTrue(result['alive'])
        run.assert_not_called()
        self.tmux_mock.assert_called_once_with('has-session', '-t', '=ssh-claude-' + self.sid)

    def test_busy_queue_waits_until_stop_then_dispatches_literal_buffer(self):
        runtime.hook(self.sid, 'UserPromptSubmit', dict(session_id=self.sid, prompt='user'))
        runtime.enqueue(dict(sessionId=self.sid, messageId='m1', text='hello; $(id)\nnext'))
        sends_at_busy = []

        def wake_dispatch(_delay):
            sends_at_busy.append([c.args[0] for c in self.tmux_mock.call_args_list
                                  if c.args and c.args[0] in ('load-buffer', 'paste-buffer', 'send-keys')])
            if len(sends_at_busy) == 1:
                runtime.hook(self.sid, 'Stop', dict(session_id=self.sid))
            elif len(sends_at_busy) == 2:
                runtime.hook(self.sid, 'UserPromptSubmit',
                             dict(session_id=self.sid, prompt='hello; $(id)\nnext'))
            if len(sends_at_busy) > 8:
                raise AssertionError('dispatcher did not finish')

        with mock.patch.object(runtime.time, 'sleep', side_effect=wake_dispatch):
            runtime.dispatch(self.sid)
        self.assertEqual(sends_at_busy[0], [])
        self.assertEqual(self.messages()[0]['status'], 'accepted')
        load = next(c for c in self.tmux_mock.call_args_list if c.args[0] == 'load-buffer')
        self.assertEqual(load.kwargs['input'], 'hello; $(id)\nnext')
        self.assertIn('send-keys', [c.args[0] for c in self.tmux_mock.call_args_list])

    def test_dispatch_uses_no_interrupt_keys(self):
        runtime.enqueue(dict(sessionId=self.sid, messageId='m1', text='plain'))
        with mock.patch.object(runtime.time, 'sleep', side_effect=RuntimeError('stop')):
            with self.assertRaisesRegex(RuntimeError, 'stop'):
                runtime.dispatch(self.sid)
        args = [str(arg) for call in self.tmux_mock.call_args_list for arg in call.args]
        self.assertNotIn('C-c', args)
        self.assertNotIn('Escape', args)

    def test_stale_dispatching_message_becomes_uncertain_without_resend(self):
        runtime.save(self.directory / 'messages.json', [
            dict(id='m1', text='once', status='dispatching', sentAt=1)])
        with mock.patch.object(runtime.time, 'time', return_value=100), \
             mock.patch.object(runtime.time, 'sleep'):
            runtime.dispatch(self.sid)
        self.assertEqual(self.messages()[0]['status'], 'uncertain')
        self.tmux_mock.assert_called_once_with('has-session', '-t', '=ssh-claude-' + self.sid)

    def test_process_exit_fails_queued_and_uncertains_dispatching(self):
        runtime.save(self.directory / 'messages.json', [
            dict(id='m1', text='queued', status='queued'),
            dict(id='m2', text='sent', status='dispatching', sentAt=1)])
        self.tmux_mock.side_effect = __import__('subprocess').CalledProcessError(1, 'tmux')
        runtime.dispatch(self.sid)
        self.assertEqual([m['status'] for m in self.messages()], ['failed', 'uncertain'])

    def test_stop_hook_does_not_send_interrupt(self):
        runtime.hook(self.sid, 'Stop', dict(session_id=self.sid))
        self.assertEqual(runtime.read(self.directory / 'state.json')['status'], 'ready')
        self.assertEqual(self.popen_mock.call_count, 1)
        self.tmux_mock.assert_not_called()

    def test_cancel_allows_queued_and_uncertain_and_rejects_submitted(self):
        runtime.save(self.directory / 'messages.json', [
            dict(id='queued', text='first', status='queued'),
            dict(id='uncertain', text='second', status='uncertain'),
            dict(id='dispatching', text='third', status='dispatching'),
            dict(id='accepted', text='fourth', status='accepted'),
        ])
        self.assertEqual(runtime.cancel(dict(sessionId=self.sid, messageId='queued'))['status'],
                         'cancelled')
        self.assertEqual(runtime.cancel(dict(sessionId=self.sid, messageId='uncertain'))['status'],
                         'cancelled')
        for message_id in ('dispatching', 'accepted'):
            with self.subTest(message_id=message_id), \
                 self.assertRaisesRegex(ValueError, '不能从队列撤回'):
                runtime.cancel(dict(sessionId=self.sid, messageId=message_id))
        self.assertEqual([m['status'] for m in self.messages()],
                         ['cancelled', 'cancelled', 'dispatching', 'accepted'])
        self.assertEqual(self.popen_mock.call_count, 2)

    def test_dispatch_fails_queue_when_tmux_pane_identity_changed(self):
        state = runtime.read(self.directory / 'state.json')
        state['paneIdentity'] = '%1:123:0'
        runtime.save(self.directory / 'state.json', state)
        runtime.save(self.directory / 'messages.json', [
            dict(id='m1', text='must not reach replacement shell', status='queued')])
        self.tmux_mock.side_effect = [
            mock.Mock(stdout=''),
            mock.Mock(stdout='%2:456:0'),
        ]

        runtime.dispatch(self.sid)

        self.assertEqual(self.messages()[0]['status'], 'failed')
        self.assertFalse(any(call.args[0] in ('load-buffer', 'paste-buffer', 'send-keys')
                             for call in self.tmux_mock.call_args_list))

    def test_real_tmux_pastes_literal_text_to_fake_cli_once(self):
        real_tmux = shutil.which('tmux')
        if not real_tmux:
            self.skipTest('tmux is unavailable')
        self.popen.stop()
        server = 'claude-test-' + uuid.uuid4().hex[:10]
        sid = 'integration_' + uuid.uuid4().hex[:8]
        integration_root = self.root / 'integration'
        integration_root.mkdir()
        cli_dir = integration_root / 'bin'
        cli_dir.mkdir()
        log = integration_root / 'received.jsonl'
        runtime_root = integration_root / '.ssh_tool' / 'claude_runtime'
        fake_cli = cli_dir / 'claude'
        fake_cli.write_text('''#!/usr/bin/env python3
import json, os, shlex, subprocess, sys
args = sys.argv[1:]
settings = args[args.index('--settings') + 1]
hooks = json.load(open(settings))['hooks']
session_id = args[args.index('--session-id') + 1]
def hook(event, payload):
    command = hooks[event][0]['hooks'][0]['command']
    subprocess.run(shlex.split(command), input=json.dumps(payload), text=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
hook('SessionStart', {'session_id': session_id})
for line in sys.stdin:
    prompt = line.rstrip('\\r\\n')
    hook('UserPromptSubmit', {'session_id': session_id, 'prompt': prompt})
    with open(os.environ['FAKE_CLAUDE_LOG'], 'a') as out:
        out.write(json.dumps(prompt) + '\\n')
        out.flush()
    hook('Stop', {'session_id': session_id})
''')
        fake_cli.chmod(0o755)
        original_path = os.environ.get('PATH', '')
        profile_path = integration_root / '.bash_profile'
        profile_path.write_text('export PATH=' + str(cli_dir) + ':$PATH\n')
        with mock.patch.object(runtime, 'ROOT', runtime_root), \
             mock.patch.dict(os.environ, {'HOME': str(integration_root),
                                          'PATH': str(cli_dir) + os.pathsep + original_path,
                                          'FAKE_CLAUDE_LOG': str(log)}), \
             mock.patch.object(runtime, 'tmux',
                                side_effect=lambda *args, input=None: __import__('subprocess').run(
                                    [real_tmux, '-L', server, '-f', '/dev/null', *args],
                                    input=input, text=True, capture_output=True, check=True)):
            try:
                started = runtime.ensure(dict(sessionId=sid, workDir=str(integration_root),
                                              resume=False))
                self.assertTrue(started['alive'])
                deadline = time.monotonic() + 5
                state_path = runtime_root / sid / 'state.json'
                while runtime.read(state_path).get('status') != 'ready':
                    if time.monotonic() >= deadline:
                        pane = __import__('subprocess').run(
                            [real_tmux, '-L', server, 'capture-pane', '-p', '-t',
                             'ssh-claude-' + sid], capture_output=True, text=True).stdout
                        self.fail(f'fake CLI did not reach ready state: {runtime.read(state_path)!r}; {pane!r}')
                    time.sleep(0.02)

                text = 'literal ; $(echo injected) "quoted"'
                children = []
                real_popen = runtime.subprocess.Popen

                def track_dispatcher(*args, **kwargs):
                    child = real_popen(*args, **kwargs)
                    children.append(child)
                    return child

                with mock.patch.object(runtime.subprocess, 'Popen', side_effect=track_dispatcher):
                    receipt = runtime.enqueue(dict(sessionId=sid, messageId='one', text=text))
                self.assertEqual(receipt['status'], 'queued')
                duplicate = runtime.enqueue(dict(sessionId=sid, messageId='one', text=text))
                self.assertEqual(duplicate['id'], 'one')
                deadline = time.monotonic() + 5
                while True:
                    messages = runtime.read(runtime_root / sid / 'messages.json', [])
                    received = log.read_text().splitlines() if log.exists() else []
                    if messages and messages[0]['status'] == 'accepted' and received:
                        break
                    if time.monotonic() >= deadline:
                        self.fail(f'fake CLI did not accept queued text: {messages!r}, {received!r}')
                    time.sleep(0.02)
                self.assertEqual([json.loads(line) for line in received], [text])
                self.assertEqual(messages[0]['status'], 'accepted')
                for child in children:
                    child.wait(timeout=2)
            finally:
                __import__('subprocess').run([real_tmux, '-L', server, 'kill-server'],
                                             capture_output=True, check=False)


if __name__ == '__main__':
    unittest.main()
