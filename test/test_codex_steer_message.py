import importlib.util
import pathlib
import unittest
import json
import socket
import struct
import threading

spec = importlib.util.spec_from_file_location(
    'steer_message', pathlib.Path(__file__).parents[1] / 'assets/codex_steer_message.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeRpc:
    def __init__(self, active=True, paginated=False, fail=False):
        self.calls = []
        self.active, self.paginated, self.fail = active, paginated, fail

    def request(self, method, params):
        self.calls.append((method, params))
        if method == 'thread/read':
            return {'thread': {'id': 'thread', 'status': {
                'type': 'active' if self.active else 'idle'},
                'historyMode': 'paginated' if self.paginated else 'legacy',
                'turns': [{'id': 'turn', 'status': 'inProgress'}]}}
        if method == 'thread/turns/list':
            return {'data': [{'id': 'turn', 'status': 'inProgress'}]}
        if method == 'turn/steer':
            if self.fail:
                raise RuntimeError('expected active turn id mismatch')
            return {'turnId': 'turn'}
        raise AssertionError(method)


class SteerTests(unittest.TestCase):
    def test_steers_exact_message_to_active_turn_without_interrupt_or_queue(self):
        for paginated in [False, True]:
            with self.subTest(paginated=paginated):
                rpc = FakeRpc(paginated=paginated)
                message = '中文 "引号"\n保留格式 '
                module.steer(rpc, 'thread', message)
                method, params = rpc.calls[-1]
                self.assertEqual(method, 'turn/steer')
                self.assertEqual(params['threadId'], 'thread')
                self.assertEqual(params['expectedTurnId'], 'turn')
                self.assertEqual(params['input'], [{'type': 'text', 'text': message}])
                self.assertTrue(params['clientUserMessageId'])
                self.assertTrue(all(m in ['thread/read', 'thread/turns/list', 'turn/steer']
                                    for m, _ in rpc.calls))

    def test_changed_to_idle_before_steer_does_not_submit_any_message(self):
        rpc = FakeRpc(active=False)
        with self.assertRaisesRegex(RuntimeError, '状态已变化'):
            module.steer(rpc, 'thread', 'hello')
        self.assertEqual([m for m, _ in rpc.calls], ['thread/read'])

    def test_rejected_steer_is_never_retried_or_changed_to_queue(self):
        rpc = FakeRpc(fail=True)
        with self.assertRaisesRegex(RuntimeError, 'mismatch'):
            module.steer(rpc, 'thread', 'hello')
        self.assertEqual(sum(m == 'turn/steer' for m, _ in rpc.calls), 1)
        self.assertFalse(any('queue' in m or 'interrupt' in m for m, _ in rpc.calls))


class TransportTests(unittest.TestCase):
    def test_masked_multiline_request_and_fragmented_response_with_ping(self):
        client, server = socket.socketpair()
        rpc = module.RpcConnection.__new__(module.RpcConnection)
        rpc.socket, rpc.stream, rpc.request_id = client, client.makefile('rb'), 0
        errors = []
        message = '中文\n"引号" ' * 100

        def serve():
            try:
                server.settimeout(3)
                with server.makefile('rb') as stream:
                    first, second = stream.read(2)
                    self.assertEqual(first, 0x81)
                    self.assertTrue(second & 128)
                    length = second & 127
                    if length == 126:
                        length = struct.unpack('!H', stream.read(2))[0]
                    mask = stream.read(4)
                    payload = stream.read(length)
                    request = json.loads(bytes(v ^ mask[i % 4]
                                               for i, v in enumerate(payload)))
                    self.assertEqual(request['params']['text'], message)
                    # An unrelated notification, fragmented JSON, then an interleaved ping.
                    notification = b'{"method":"thread/status/changed"}'
                    server.sendall(bytes([0x81, len(notification)]) + notification)
                    part = b'{"id":1,"result":'
                    server.sendall(bytes([0x01, len(part)]) + part)
                    server.sendall(b'\x89\x02ok')
                    pong_first, pong_second = stream.read(2)
                    self.assertEqual(pong_first, 0x8a)
                    self.assertEqual(pong_second, 0x82)
                    pong_mask, pong = stream.read(4), stream.read(2)
                    self.assertEqual(bytes(v ^ pong_mask[i % 4]
                                           for i, v in enumerate(pong)), b'ok')
                    part = b'{"turnId":"turn"}}'
                    server.sendall(bytes([0x80, len(part)]) + part)
            except Exception as error:
                errors.append(error)
            finally:
                server.close()

        worker = threading.Thread(target=serve)
        worker.start()
        try:
            self.assertEqual(rpc.request('turn/steer', {'text': message}),
                             {'turnId': 'turn'})
        finally:
            rpc.close()
            worker.join(timeout=5)
        self.assertFalse(worker.is_alive())
        if errors:
            raise errors[0]


if __name__ == '__main__':
    unittest.main()
