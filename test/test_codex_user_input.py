import json
import importlib.util
import sys
from pathlib import Path

import pytest

ASSETS = Path(__file__).resolve().parents[1] / 'assets'
sys.path.insert(0, str(ASSETS))


def load():
    spec = importlib.util.spec_from_file_location('codex_user_input', ASSETS / 'codex_user_input.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_replayed_question_and_resolution():
    events, sent = [], []
    bridge = load().InteractionBridge('thread', sent.append, events.append)
    request = {'id': 12, 'method': 'item/tool/requestUserInput', 'params': {
        'threadId': 'thread', 'questions': [{'id': 'q', 'question': 'Choose',
        'options': [{'label': 'NumPy', 'description': 'CPU'}]}]}}
    bridge.receive(request)
    bridge.receive(request)
    assert len(events) == 1
    bridge.submit({'id': 12, 'answers': {'q': ['NumPy']}})
    assert sent == [{'id': 12, 'result': {'answers': {'q': {'answers': ['NumPy']}}}}]
    assert events[-1]['type'] == 'pending'
    bridge.receive({'method': 'serverRequest/resolved', 'params': {'threadId': 'thread', 'requestId': 12}})
    assert events[-1] == {'type': 'resolved', 'id': 12}
    with pytest.raises(ValueError):
        bridge.submit({'id': 12, 'answers': {'q': ['NumPy']}})


def test_unrelated_threads_and_invalid_answers():
    events, sent = [], []
    bridge = load().InteractionBridge('thread', sent.append, events.append)
    bridge.receive({'id': 1, 'method': 'item/tool/requestUserInput', 'params': {'threadId': 'other'}})
    assert events == []
    bridge.receive({'id': 'server-1', 'method': 'item/tool/requestUserInput', 'params': {
        'threadId': 'thread', 'questions': [{'id': 'q', 'isOther': False,
        'options': [{'label': 'A'}, {'label': 'B'}]}]}})
    for answers in ({}, {'q': ['C']}, {'q': []}, {'q': ['A', 'B']}):
        with pytest.raises(ValueError):
            bridge.submit({'id': 'server-1', 'answers': answers})
    assert sent == []


def test_other_free_text_and_computer_first_resolution():
    events, sent = [], []
    bridge = load().InteractionBridge('t', sent.append, events.append)
    bridge.receive({'id': 8, 'method': 'item/tool/requestUserInput', 'params': {
        'threadId': 't', 'questions': [{'id': 'q', 'isOther': True, 'options': [{'label': 'A'}]},
        {'id': 'text'}]}})
    bridge.submit({'id': 8, 'answers': {'q': ['Custom'], 'text': ['Details']}})
    assert sent[0]['result']['answers']['text']['answers'] == ['Details']
    bridge.receive({'method': 'serverRequest/resolved', 'params': {'threadId': 't', 'requestId': 8}})
    assert not bridge.pending


def test_prepared_worker_does_not_reject_question_owned_by_shared_subscriber(tmp_path):
    import base64
    import os
    import subprocess
    import time

    home = tmp_path / 'home'
    owned = home / '.ssh_tool'
    owned.mkdir(parents=True)
    config = owned / 'codex_runtime/connection.json'
    config.parent.mkdir()
    config.write_text('{}')
    (owned / 'codex_runtime.py').write_text('''import json, sys, time
from pathlib import Path
for line in sys.stdin:
    request=json.loads(line)
    with (Path.home()/'requests.jsonl').open('a') as stream:
        stream.write(json.dumps(request)+'\\n')
    method=request.get('method')
    if method=='initialize': result={}
    elif method=='thread/start': result={'thread':{'id':'question-thread'}}
    elif method=='turn/start':
        print(json.dumps({'id':request['id'],'result':{'turn':{'id':'turn'}}}),flush=True)
        print(json.dumps({'id':90,'method':'item/tool/requestUserInput','params':{
            'threadId':'question-thread','turnId':'turn','questions':[{'id':'q','question':'Choose'}]}}),flush=True)
        time.sleep(.3)
        print(json.dumps({'method':'turn/completed','params':{'turn':{'id':'turn','status':'completed'}}}),flush=True)
        continue
    elif method=='thread/unsubscribe': result={}
    else: continue
    print(json.dumps({'id':request['id'],'result':result}),flush=True)
''')
    tmux_dir = tmp_path / 'tmux'
    tmux_dir.mkdir()
    env = {**os.environ, 'HOME': str(home), 'TMUX_TMPDIR': str(tmux_dir)}
    env.pop('TMUX', None)
    worker = ASSETS / 'codex_chat_worker.py'
    job = 'd' * 32
    request = {'jobId': job, 'workDir': str(tmp_path), 'prompt': 'test', 'model': 'test', 'effort': 'low'}
    encoded = base64.b64encode(json.dumps(request).encode()).decode()
    def call(*args):
        result = subprocess.run([sys.executable, str(worker), *args], env=env,
            capture_output=True, text=True, timeout=10, check=True)
        return json.loads(result.stdout)
    try:
        assert call('start', encoded)['jobId'] == job
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            snapshot = call('poll', job, '0')
            assert snapshot['state']['status'] != 'failed', snapshot
            if snapshot['state']['status'] == 'completed': break
            time.sleep(.05)
        else: pytest.fail('worker did not complete')
        messages = [json.loads(line) for line in (home / 'requests.jsonl').read_text().splitlines()]
        assert not any(message.get('id') == 90 and 'error' in message for message in messages)
        call('close', 'question-thread')
    finally:
        subprocess.run(['tmux', 'kill-server'], env=env, capture_output=True)


def test_async_question_survives_turn_end_and_computer_answer_wins():
    events, sent = [], []
    bridge = load().InteractionBridge('t', sent.append, events.append)
    bridge.receive({'id': 3, 'method': 'item/tool/requestUserInput', 'params': {
        'threadId': 't', 'isBlocking': False, 'questions': [{'id': 'q'}]}})
    bridge.receive({'method': 'turn/completed', 'params': {'threadId': 't'}})
    assert 3 in bridge.pending
    bridge.receive({'method': 'serverRequest/resolved', 'params': {'threadId': 't', 'requestId': 3}})
    with pytest.raises(ValueError, match='其他端'):
        bridge.submit({'id': 3, 'answers': {'q': ['mobile']}})
    assert not sent
