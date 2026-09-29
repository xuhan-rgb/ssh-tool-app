import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor


ROOT = Path(__file__).resolve().parents[1]


def raw_constant(path, name):
    source = (ROOT / path).read_text(encoding="utf-8")
    match = re.search(r"\b" + re.escape(name) + r"\s*=\s*r'''(.*?)'''", source, re.S)
    if not match:
        raise AssertionError(f"raw script constant {name} not found in {path}")
    return match.group(1)


SYNC = raw_constant("lib/services/conversation_sync_script.dart", "conversationSyncScript")
READERS = {
    "codex": raw_constant("lib/services/codex_session_service.dart", "_readScript"),
    "claude": raw_constant("lib/services/claude_session_service.dart", "readScript"),
}


def jsonl(rows):
    return "".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows)


class ConversationSyncTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.session = "session_abc123"
        self.source_paths = {}
        for provider in READERS:
            if provider == "codex":
                root = self.home / "codex" / "sessions"
                root.mkdir(parents=True)
                path = root / f"2026-01-01-{self.session}.jsonl"
            else:
                root = self.home / ".claude" / "projects" / "project"
                root.mkdir(parents=True)
                path = root / f"{self.session}.jsonl"
            path.write_text("", encoding="utf-8")
            self.source_paths[provider] = path

    def tearDown(self):
        self.temp.cleanup()

    def run_sync(self, provider, cursor="", reader=None):
        helper = SYNC + "\nsync(" + repr(reader or READERS[provider]) + ", " + repr(provider) + ")\n"
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        env["CODEX_HOME"] = str(self.home / "codex")
        result = subprocess.run(
            ["python3", "-c", helper, self.session, cursor],
            text=True, capture_output=True, env=env, check=True,
        )
        return json.loads(result.stdout)

    def append(self, provider, rows):
        with self.source_paths[provider].open("a", encoding="utf-8") as stream:
            stream.write(jsonl(rows))

    def reader_rows(self, provider):
        env = os.environ.copy()
        env["HOME"] = str(self.home)
        env["CODEX_HOME"] = str(self.home / "codex")
        result = subprocess.run(
            ["python3", "-c", READERS[provider], self.session],
            text=True, capture_output=True, env=env, check=True,
        )
        return [json.loads(line) for line in result.stdout.splitlines()]

    def first_records(self, provider):
        if provider == "codex":
            return [
                {"type": "turn_context", "payload": {"model": "gpt-test", "effort": "high"}},
                {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hello"}]}},
                {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "shell", "call_id": "call-1", "input": {"cmd": "echo hi"}}},
                {"type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call-1", "output": {"exit_code": 0, "output": "hi"}}},
            ]
        return [
            {"type": "user", "message": {"role": "user", "content": "hello"}},
            {"type": "assistant", "message": {"role": "assistant", "model": "claude-test", "content": [
                {"type": "text", "text": "same text"},
                {"type": "tool_use", "id": "call-1", "name": "Bash", "input": {"command": "echo hi"}},
            ]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "call-1", "content": "hi"}]}},
        ]

    def test_both_readers_snapshot_unchanged_delta_and_exact_merge(self):
        for provider in READERS:
            with self.subTest(provider=provider):
                self.append(provider, self.first_records(provider))
                snapshot = self.run_sync(provider)
                self.assertEqual(snapshot["protocol"], 1)
                self.assertEqual(snapshot["type"], "snapshot")
                self.assertTrue(snapshot["version"])
                self.assertEqual(snapshot["records"], self.reader_rows(provider))
                self.assertTrue(all(row.get("_syncId") for row in snapshot["records"]))
                self.assertEqual(self.run_sync(provider, snapshot["version"])["type"], "unchanged")

                self.append(provider, [
                    {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hello"}]}}
                ] if provider == "codex" else [
                    {"type": "user", "message": {"role": "user", "content": "same text"}}
                ])
                delta = self.run_sync(provider, snapshot["version"])
                self.assertEqual(delta["type"], "delta")
                self.assertEqual(delta["base"], snapshot["version"])
                merged = {row["_syncId"]: row for row in snapshot["records"]}
                for key in delta["removed"]:
                    merged.pop(key)
                merged.update({row["_syncId"]: row for row in delta["upserts"]})
                self.assertEqual([merged[key] for key in delta["order"]], self.reader_rows(provider))
                texts = [row["text"] for row in self.reader_rows(provider)]
                repeated = "hello" if provider == "codex" else "same text"
                self.assertGreaterEqual(texts.count(repeated), 2)

    def test_claude_tool_result_updates_existing_call_and_duplicate_text_has_distinct_ids(self):
        provider = "claude"
        self.append(provider, self.first_records(provider)[:2])
        old = self.run_sync(provider)
        call = next(row for row in old["records"] if row["kind"] == "tool_call")
        self.append(provider, [{"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "call-1", "content": "done"}]}}])
        delta = self.run_sync(provider, old["version"])
        updated = next(row for row in delta["upserts"] if row["_syncId"] == call["_syncId"])
        self.assertEqual(updated["terminalSummary"], "Ran echo hi")
        self.assertIn("done", updated["terminalDetails"])
        self.append(provider, [{"type": "user", "message": {"role": "user", "content": "hello"}}])
        rows = self.run_sync(provider)["records"]
        same = [row for row in rows if row["text"] == "hello"]
        self.assertEqual(len(same), 2)
        self.assertNotEqual(same[0]["_syncId"], same[1]["_syncId"])

    def test_codex_tool_result_and_task_completion_mutate_prior_records(self):
        provider = "codex"
        self.append(provider, [
            {"type": "event_msg", "payload": {"type": "task_started"}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "answer"}]}},
            {"type": "response_item", "payload": {"type": "custom_tool_call", "name": "shell", "call_id": "call-1", "input": {"cmd": "echo done"}}},
        ])
        old = self.run_sync(provider)
        answer = next(row for row in old["records"] if row["kind"] == "assistant")
        call = next(row for row in old["records"] if row["kind"] == "tool_call")
        self.append(provider, [
            {"type": "response_item", "payload": {"type": "custom_tool_call_output", "call_id": "call-1", "output": {"exit_code": 0, "output": "done"}}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {"last_token_usage": {"input_tokens": 12, "output_tokens": 3}}}},
            {"type": "event_msg", "payload": {"type": "task_complete"}},
        ])
        delta = self.run_sync(provider, old["version"])
        upserts = {row["_syncId"]: row for row in delta["upserts"]}
        self.assertEqual(upserts[call["_syncId"]]["terminalSummary"], "Ran echo done")
        self.assertIn("done", upserts[call["_syncId"]]["terminalDetails"])
        self.assertEqual(upserts[answer["_syncId"]]["tokenUsage"], {"input_tokens": 12, "output_tokens": 3})

    def test_unchanged_does_not_execute_reader_and_concurrent_clients_share_correct_delta(self):
        provider = "claude"
        self.append(provider, self.first_records(provider))
        marker = self.home / "reader-runs"
        instrumented = READERS[provider] + "\nwith open(" + repr(str(marker)) + ", 'a') as marker_file: marker_file.write('run\\n')\n"
        first = self.run_sync(provider, reader=instrumented)
        self.assertEqual(marker.read_text(encoding="utf-8"), "run\n")
        unchanged = self.run_sync(provider, first["version"], reader=instrumented)
        self.assertEqual(unchanged["type"], "unchanged")
        self.assertEqual(marker.read_text(encoding="utf-8"), "run\n")

        self.append(provider, [{"type": "user", "message": {"role": "user", "content": "concurrent append"}}])
        with ThreadPoolExecutor(max_workers=2) as pool:
            responses = list(pool.map(lambda _: self.run_sync(provider, first["version"], reader=instrumented), range(2)))
        self.assertEqual(responses[0], responses[1])
        self.assertEqual(responses[0]["type"], "delta")
        self.assertEqual(marker.read_text(encoding="utf-8"), "run\nrun\n")

    def test_malformed_cache_falls_back_to_snapshot(self):
        provider = "claude"
        self.append(provider, self.first_records(provider))
        first = self.run_sync(provider)
        self.append(provider, [{"type": "user", "message": {"role": "user", "content": "cache generation changed"}}])
        current = self.run_sync(provider)
        cache_file = next((self.home / ".cache" / "ssh_tool" / "conversation_sync").glob("*.json"))
        cache_file.write_text("{ malformed", encoding="utf-8")
        fallback = self.run_sync(provider, first["version"])
        self.assertEqual(fallback["type"], "snapshot")
        self.assertEqual(fallback["records"], self.reader_rows(provider))
        self.assertNotEqual(fallback["version"], current["version"])

    def test_window_overflow_and_partial_line_completion(self):
        provider = "claude"
        records = [{"type": "user", "message": {"role": "user", "content": f"row {i}"}} for i in range(300)]
        self.append(provider, records)
        snapshot = self.run_sync(provider)
        self.assertEqual(len(snapshot["records"]), 300)
        self.assertEqual(snapshot["records"], self.reader_rows(provider))
        self.append(provider, [{"type": "user", "message": {"role": "user", "content": f"row {i}"}} for i in range(300, 305)])
        delta = self.run_sync(provider, snapshot["version"])
        self.assertEqual(delta["type"], "delta")
        self.assertEqual(len(delta["removed"]), 5)
        merged = {row["_syncId"]: row for row in snapshot["records"]}
        for key in delta["removed"]:
            merged.pop(key)
        merged.update({row["_syncId"]: row for row in delta["upserts"]})
        self.assertEqual([merged[key] for key in delta["order"]], self.reader_rows(provider))
        path = self.source_paths[provider]
        with path.open("a", encoding="utf-8") as stream:
            stream.write('{"type":"user","message":{"role":"user","content":"partial"}')
        before = self.run_sync(provider)
        with path.open("a", encoding="utf-8") as stream:
            stream.write("}\n")
        after = self.run_sync(provider, before["version"])
        self.assertEqual(after["type"], "delta")
        self.assertIn("partial", [row["text"] for row in after["upserts"]])

    def test_replay_after_cache_loss_truncation_replacement_and_missing_source(self):
        provider = "claude"
        self.append(provider, self.first_records(provider))
        first = self.run_sync(provider)
        self.append(provider, [{"type": "user", "message": {"role": "user", "content": "later"}}])
        latest = self.run_sync(provider)
        cache = self.home / ".cache" / "ssh_tool" / "conversation_sync"
        for item in cache.glob("*.json"):
            item.unlink()
        replay = self.run_sync(provider, first["version"])
        self.assertEqual(replay["type"], "snapshot")
        self.assertEqual(replay["records"], self.reader_rows(provider))
        self.assertNotEqual(latest["version"], replay["version"])

        path = self.source_paths[provider]
        path.write_text(jsonl([{"type": "user", "message": {"role": "user", "content": "replacement"}}]), encoding="utf-8")
        replaced = self.run_sync(provider, replay["version"])
        self.assertEqual(replaced["type"], "snapshot")
        self.assertEqual(replaced["records"], self.reader_rows(provider))
        path.write_text("", encoding="utf-8")
        truncated = self.run_sync(provider, replaced["version"])
        self.assertEqual(truncated["type"], "snapshot")
        path.unlink()
        result = subprocess.run(["python3", "-c", SYNC + "\nsync(" + repr(READERS[provider]) + ", 'claude')", self.session], text=True, capture_output=True, env={**os.environ, "HOME": str(self.home)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conversation log is unavailable", result.stderr)

    def test_clients_versions_parser_cache_isolation_and_retention_fallback(self):
        provider = "codex"
        self.append(provider, self.first_records(provider))
        one = self.run_sync(provider)
        two = self.run_sync(provider)
        self.assertEqual(two["version"], one["version"])
        self.append(provider, [{"type": "response_item", "payload": {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "next"}]}}])
        next_snapshot = self.run_sync(provider)
        client_a = self.run_sync(provider, one["version"])
        client_b = self.run_sync(provider, next_snapshot["version"])
        self.assertEqual(client_a["type"], "delta")
        self.assertEqual(client_b["type"], "unchanged")
        changed_reader = READERS[provider] + "\n# parser change\n"
        helper = SYNC + "\nsync(" + repr(changed_reader) + ", 'codex')\n"
        env = {**os.environ, "HOME": str(self.home), "CODEX_HOME": str(self.home / "codex")}
        changed = json.loads(subprocess.run(["python3", "-c", helper, self.session, one["version"]], text=True, capture_output=True, env=env, check=True).stdout)
        self.assertEqual(changed["type"], "snapshot")

        cache = self.home / ".cache" / "ssh_tool" / "conversation_sync"
        # Simulate an evicted prior version: only the current version is retained.
        for state_file in cache.glob("*.json"):
            state = json.loads(state_file.read_text(encoding="utf-8"))
            state["snapshots"] = state["snapshots"][-1:]
            state_file.write_text(json.dumps(state), encoding="utf-8")
        fallback = self.run_sync(provider, one["version"])
        self.assertEqual(fallback["type"], "snapshot")
        self.assertEqual(fallback["records"], self.reader_rows(provider))

    def test_synthetic_response_bytes_vs_full_reader_jsonl(self):
        provider = "claude"
        all_rows = [{"type": "user", "message": {"role": "user", "content": f"synthetic message {i} " + "x" * 1000}} for i in range(300)]
        self.append(provider, all_rows)
        first = self.run_sync(provider)
        first_bytes = len(json.dumps(first, ensure_ascii=False, separators=(",", ":")).encode())
        baseline_first = len(jsonl([{key: value for key, value in row.items() if key != "_syncId"} for row in first["records"]]).encode())
        self.append(provider, [{"type": "user", "message": {"role": "user", "content": "synthetic appended " + "y" * 1000}}])
        next_response = self.run_sync(provider, first["version"])
        subsequent_bytes = len(json.dumps(next_response, ensure_ascii=False, separators=(",", ":")).encode())
        baseline_subsequent = len(jsonl([{key: value for key, value in row.items() if key != "_syncId"} for row in self.reader_rows(provider)]).encode())
        for _ in range(10):
            response = self.run_sync(provider, next_response["version"])
            self.assertEqual(response["type"], "unchanged")
            subsequent_bytes += len(json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode())
            baseline_subsequent += len(jsonl([{key: value for key, value in row.items() if key != "_syncId"} for row in self.reader_rows(provider)]).encode())
        protocol_total = first_bytes + subsequent_bytes
        baseline_total = baseline_first + baseline_subsequent
        print(f"synthetic 300x1KB + append + 10 idle polls bytes: first protocol={first_bytes} baseline={baseline_first}; subsequent protocol={subsequent_bytes} baseline={baseline_subsequent}; all protocol={protocol_total} baseline={baseline_total} ratio={protocol_total / baseline_total:.4f}")
        self.assertLess(protocol_total, baseline_total)


if __name__ == "__main__":
    unittest.main()
