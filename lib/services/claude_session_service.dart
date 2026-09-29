import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'codex_session_service.dart';
import 'ssh_service.dart';
import 'storage_service.dart';

/// Read-only access to Claude Code session history on a remote host.
class ClaudeSessionService {
  @visibleForTesting
  static Future<String> Function(
      String connectionId, String script, List<String> args)? runPythonOverride;

  static Future<List<CodexConversation>> listAll(String connectionId) async {
    final raw = await _runPython(connectionId, listScript, const []);
    return CodexConversationParser.parse(raw);
  }

  static Future<List<CodexConversationRecord>> readConversation(
      String connectionId, String id) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid Claude session id');
    }
    final raw = await _runPython(connectionId, readScript, [id]);
    return CodexConversationParser.parseRecords(raw);
  }

  static Future<String> _runPython(
      String connectionId, String script, List<String> args) async {
    final override = runPythonOverride;
    if (override != null) return override(connectionId, script, args);
    final encoded = base64Encode(utf8.encode(script));
    String quote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
    final command = [
      'printf %s ${quote(encoded)}',
      '| base64 -d | python3 -',
      ...args.map(quote),
    ].join(' ');
    final remote = '$command 2>&1; printf "\\n__SSH_TOOL_EXIT__%s\\n" "\$?"';
    var client = SshService.getClient(connectionId);
    final connection = StorageService.getConnection(connectionId);
    if (client == null && connection != null) {
      client = (await SshService.connectClient(connection)).client;
    }
    if (client == null) throw StateError('SSH connection is unavailable');
    final result = await client.run(remote);
    final output = utf8.decode(result, allowMalformed: true);
    final marker = RegExp(r'__SSH_TOOL_EXIT__(\d+)\s*$').firstMatch(output);
    if (marker == null) {
      throw StateError('Remote Python command did not return an exit status');
    }
    final body = output.substring(0, marker.start).trim();
    if (marker.group(1) != '0') {
      throw StateError('Remote Claude query failed: $body');
    }
    return body;
  }

  @visibleForTesting
  static const String listScript = r'''import glob
import json
import os
from pathlib import Path

home = Path.home()
projects = home / ".claude" / "projects"
sessions = {}

def timestamp(value):
    if not isinstance(value, str) or not value:
        return None
    try:
        from datetime import datetime, timezone
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.astimezone(timezone.utc).isoformat() if parsed.tzinfo else parsed.isoformat()
    except Exception:
        return value

def content_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content if isinstance(part, dict) and isinstance(part.get("text"), str))
    return ""

if projects.is_dir():
    for index_path in projects.glob("*/sessions-index.json"):
        try:
            index = json.loads(index_path.read_text(encoding="utf-8"))
            entries = index.get("entries", []) if isinstance(index, dict) else []
            if isinstance(entries, dict): entries = list(entries.values())
            for entry in entries:
                if not isinstance(entry, dict): continue
                session_id = entry.get("sessionId")
                if not isinstance(session_id, str) or not session_id: continue
                project_path = entry.get("projectPath")
                sessions[session_id] = {
                    "id": session_id,
                    "cwd": project_path if isinstance(project_path, str) else "",
                    "title": str(entry.get("summary") or entry.get("firstPrompt") or ""),
                    "updatedAt": timestamp(entry.get("modified")),
                    "preview": str(entry.get("firstPrompt") or entry.get("summary") or ""),
                    "directoryExists": bool(project_path and Path(project_path).is_dir()),
                    "state": "unknown",
                    "fullPath": entry.get("fullPath"),
                }
        except Exception:
            continue

log_paths = {path.stem: path for path in projects.glob("*/*.jsonl")} if projects.is_dir() else {}
for session_id, data in sessions.items():
    full_path = data.get("fullPath")
    if isinstance(full_path, str):
        indexed_path = Path(full_path)
        if indexed_path.name == session_id + ".jsonl" and indexed_path.is_file():
            log_paths[session_id] = indexed_path

for session_id, log_path in log_paths.items():
        data = sessions.get(session_id)
        if data is None:
            data = {"id": session_id, "cwd": "", "title": "", "updatedAt": None, "preview": "", "directoryExists": log_path.parent.exists(), "state": "unknown"}
        last_assistant_end = False
        try:
            with log_path.open(encoding="utf-8") as stream:
                for line in stream:
                    try: item = json.loads(line)
                    except Exception: continue
                    if not isinstance(item, dict): continue
                    kind = item.get("type")
                    message = item.get("message") if isinstance(item.get("message"), dict) else {}
                    if item.get("sessionId") == session_id or not data["cwd"]:
                        cwd = item.get("cwd")
                        if isinstance(cwd, str) and cwd: data["cwd"] = cwd
                    at = timestamp(item.get("timestamp"))
                    if at:
                        existing_at = timestamp(data.get("updatedAt"))
                        if not existing_at or at > existing_at: data["updatedAt"] = at
                    if kind == "ai-title":
                        title = item.get("aiTitle")
                        if isinstance(title, str) and title.strip(): data["title"] = title.strip()
                    elif kind in ("user", "assistant"):
                        body = content_text(message.get("content"))
                        if kind == "user":
                            last_assistant_end = False
                            if body and not data["preview"]: data["preview"] = body.strip()
                        if kind == "assistant":
                            last_assistant_end = message.get("stop_reason") == "end_turn"
            if not data["title"]: data["title"] = data["preview"]
            if data["cwd"]: data["directoryExists"] = Path(data["cwd"]).is_dir()
            if last_assistant_end: data["state"] = "complete"
        except Exception:
            continue
        sessions[session_id] = data

for data in sorted(sessions.values(), key=lambda row: row.get("updatedAt") or "", reverse=True):
    data.pop("fullPath", None)
    print(json.dumps(data, ensure_ascii=False))
''';

  @visibleForTesting
  static const String readScript = r'''import json
import re
import sys
from pathlib import Path

session_id = sys.argv[1]
if not re.fullmatch(r"[A-Za-z0-9_-]+", session_id):
    raise SystemExit("invalid session id")
projects = Path.home() / ".claude" / "projects"
candidate = f"{session_id}.jsonl"
path = next((item for item in projects.glob("*/*.jsonl") if item.name == candidate), None)
if path is None: raise SystemExit(0)
calls = {}
records = []
current_model = None
current_effort = None

def text_value(value):
    if isinstance(value, str): return value
    if isinstance(value, list): return "".join(part.get("text", "") for part in value if isinstance(part, dict) and isinstance(part.get("text"), str))
    return ""

def tool_label(name, tool_input):
    if name == "Bash":
        command = tool_input.get("command", "") if isinstance(tool_input, dict) else ""
        lines = str(command).strip().splitlines()
        label = (lines[0] if lines else "command")[:200]
        return label + (" …" if len(lines) > 1 else "")
    if name in ("Read", "Write", "Edit") and isinstance(tool_input, dict):
        path = tool_input.get("file_path")
        return name + (" " + str(path) if path else "")
    return name

with path.open(encoding="utf-8") as stream:
    for line in stream:
        try: item = json.loads(line)
        except Exception: continue
        if not isinstance(item, dict): continue
        kind = item.get("type")
        message = item.get("message") if isinstance(item.get("message"), dict) else {}
        timestamp = item.get("timestamp")
        model_value = message.get("model") or item.get("model")
        if isinstance(model_value, str) and model_value.strip(): current_model = model_value.strip()
        effort_value = item.get("effort") or item.get("reasoning_effort") or message.get("effort") or message.get("reasoning_effort")
        if isinstance(effort_value, str) and effort_value.strip(): current_effort = effort_value.strip()
        role_content = message.get("content")
        is_user_text = kind == "user" and (isinstance(role_content, str) or (isinstance(role_content, list) and any(isinstance(block, dict) and block.get("type") == "text" for block in role_content)))
        if is_user_text: current_effort = None
        if kind in ("user", "assistant"):
            role = message.get("role") or kind
            content = message.get("content")
            if isinstance(content, str):
                if content.strip(): records.append({"kind": role, "timestamp": timestamp, "text": content.strip()[:12000], "model": current_model, "reasoningEffort": current_effort})
            elif isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict): continue
                    block_type = block.get("type")
                    if block_type == "text" and isinstance(block.get("text"), str) and block["text"].strip():
                        records.append({"kind": role, "timestamp": timestamp, "text": block["text"].strip()[:12000], "model": current_model, "reasoningEffort": current_effort})
                    elif block_type == "tool_use":
                        call_id = block.get("id")
                        name = str(block.get("name") or "tool")
                        tool_input = block.get("input", {})
                        raw = json.dumps(block, ensure_ascii=False)
                        label = tool_label(name, tool_input)
                        record = {"kind": "tool_call", "timestamp": timestamp, "text": "tool: " + name + "\n" + raw[:12000], "terminalSummary": "Running " + label, "model": current_model, "reasoningEffort": current_effort}
                        records.append(record)
                        if call_id: calls[call_id] = record
                    elif block_type == "tool_result":
                        output = text_value(block.get("content"))
                        call = calls.get(block.get("tool_use_id"))
                        if call:
                            call_name = call["text"].split("\n", 1)[0].removeprefix("tool: ")
                            tool_call = json.loads(call["text"].split("\n", 1)[1])
                            tool_input = tool_call.get("input", {}) if isinstance(tool_call, dict) else {}
                            label = tool_label(call_name, tool_input)
                            call["terminalSummary"] = ("Failed " if block.get("is_error") else ("Ran " if call_name == "Bash" else "Completed ")) + label
                            call["terminalDetails"] = output[:12000]
                        records.append({"kind": "tool_output", "timestamp": timestamp, "text": json.dumps(block, ensure_ascii=False)[:12000], "model": current_model, "reasoningEffort": current_effort})

for record in records[-300:]: print(json.dumps(record, ensure_ascii=False))
''';
}
