import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'ssh_service.dart';

/// 远程服务器 Claude 状态同步服务
///
/// 职责：
/// 1. 检测远程是否已配置 ~/.ssh_tool
/// 2. 未配置则自动部署脚本 + 注册 Claude hooks
/// 3. 读取 state.json 返回会话列表和活动状态
class RemoteStateService {
  /// 同步远程状态：检测 → 部署(如需) → 读取
  /// [connectionId] 用于从 SshService 获取已连接的 SSHClient
  static Future<SyncResult> sync(String connectionId) async {
    final client = SshService.getClient(connectionId);
    if (client == null) {
      return SyncResult(wasConfigured: false, sessions: {}, aliveTmuxSessions: {});
    }

    final configured = await isConfigured(client);

    if (!configured) {
      await deploy(client);
    }

    // 读取 state.json
    final sessions = await readState(client);

    // 获取 tmux 存活会话
    final alive = await queryAliveTmux(client);

    return SyncResult(
      wasConfigured: configured,
      sessions: sessions,
      aliveTmuxSessions: alive,
    );
  }

  /// 仅读取远程状态（用于轮询）
  static Future<Map<String, dynamic>> poll(String connectionId) async {
    final client = SshService.getClient(connectionId);
    if (client == null) return {};
    return readState(client);
  }

  /// 检查远程是否已配置
  static Future<bool> isConfigured(SSHClient client) async {
    final result = await _run(client,
        'test -f ~/.ssh_tool/state.json && test -f ~/.ssh_tool/update_state.py && echo OK || echo NO');
    return result.trim() == 'OK';
  }

  /// 部署所有脚本到远程服务器
  static Future<void> deploy(SSHClient client) async {
    // 1. 创建目录
    await _run(client, 'mkdir -p ~/.ssh_tool/hooks ~/.claude');

    // 2. 部署 Python 更新脚本（base64 编码避免引号问题）
    await _writeRemoteFile(client, '~/.ssh_tool/update_state.py', _updateStatePy);

    // 3. 部署三个 hook 脚本
    await _writeRemoteFile(client, '~/.ssh_tool/hooks/on_stop.sh', _onStopSh);
    await _writeRemoteFile(client, '~/.ssh_tool/hooks/on_notification.sh', _onNotificationSh);
    await _writeRemoteFile(client, '~/.ssh_tool/hooks/on_user_prompt.sh', _onUserPromptSh);

    // 4. 设置执行权限
    await _run(client,
        'chmod +x ~/.ssh_tool/update_state.py ~/.ssh_tool/hooks/*.sh');

    // 5. 初始化空的 state.json（不覆盖已有的）
    await _run(client,
        'test -f ~/.ssh_tool/state.json || echo \'{"version":1,"sessions":{}}\' > ~/.ssh_tool/state.json');

    // 6. 部署 hook 注册脚本并执行
    await _writeRemoteFile(client, '~/.ssh_tool/register_hooks.py', _registerHooksPy);
    await _run(client, 'python3 ~/.ssh_tool/register_hooks.py');
  }

  /// 读取远程 state.json 中的 sessions
  static Future<Map<String, dynamic>> readState(SSHClient client) async {
    final raw = await _run(client, 'cat ~/.ssh_tool/state.json 2>/dev/null');
    if (raw.trim().isEmpty) return {};
    try {
      final state = jsonDecode(raw) as Map<String, dynamic>;
      return (state['sessions'] as Map<String, dynamic>?) ?? {};
    } catch (_) {
      return {};
    }
  }

  /// 查询 tmux 存活会话名
  static Future<Set<String>> queryAliveTmux(SSHClient client) async {
    final raw = await _run(client,
        "tmux list-sessions -F '#{session_name}' 2>/dev/null || true");
    if (raw.trim().isEmpty) return {};
    return raw
        .trim()
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty && !s.startsWith('ssh-chat-'))
        .toSet();
  }

  /// 通过 base64 写入远程文件（避免引号/转义问题）
  static Future<void> _writeRemoteFile(
      SSHClient client, String path, String content) async {
    final b64 = base64Encode(utf8.encode(content));
    await _run(client, 'echo "$b64" | base64 -d > $path');
  }

  /// 执行远程命令并返回 stdout
  static Future<String> _run(SSHClient client, String command) async {
    try {
      final result = await client.run(command);
      return utf8.decode(result, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  // ===== 远程脚本内容 =====

  /// ~/.ssh_tool/update_state.py — 核心状态更新脚本
  static const String _updateStatePy = '''#!/usr/bin/env python3
"""update_state.py - Called by Claude hooks to update state.json"""
import json, os, sys, subprocess
from datetime import datetime, timezone

STATE_FILE = os.path.expanduser("~/.ssh_tool/state.json")

def get_tmux_info():
    """Get current tmux session name and working directory."""
    try:
        name = subprocess.check_output(
            ["tmux", "display-message", "-p", "#{session_name}"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        if not name:
            return None, None
        path = subprocess.check_output(
            ["tmux", "display-message", "-p", "#{pane_current_path}"],
            stderr=subprocess.DEVNULL
        ).decode().strip() or "~"
        return name, path
    except Exception:
        return None, None

def main():
    activity = sys.argv[1] if len(sys.argv) > 1 else "idle"
    message = sys.argv[2] if len(sys.argv) > 2 else ""

    tmux_name, work_dir = get_tmux_info()
    if not tmux_name:
        sys.exit(0)

    state = {"version": 1, "sessions": {}}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE) as f:
                state = json.load(f)
        except Exception:
            pass

    state.setdefault("version", 1)
    state.setdefault("sessions", {})

    existing = state["sessions"].get(tmux_name, {})
    state["sessions"][tmux_name] = {
        "type": existing.get("type", "claude"),
        "activity": activity,
        "message": message,
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "workDir": work_dir,
    }

    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_FILE)

if __name__ == "__main__":
    main()
''';

  /// ~/.ssh_tool/hooks/on_stop.sh — Claude 完成时
  static const String _onStopSh = '''#!/bin/bash
python3 ~/.ssh_tool/update_state.py "finished" ""
''';

  /// ~/.ssh_tool/hooks/on_notification.sh — Claude 提问时
  static const String _onNotificationSh = r'''#!/bin/bash
# Read hook JSON from stdin, extract message
INPUT=$(cat)
MSG=$(echo "$INPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('message', ''))
except:
    print('')
" 2>/dev/null)
python3 ~/.ssh_tool/update_state.py "asking" "$MSG"
''';

  /// ~/.ssh_tool/hooks/on_user_prompt.sh — 用户提交时
  static const String _onUserPromptSh = '''#!/bin/bash
python3 ~/.ssh_tool/update_state.py "generating" ""
''';

  /// ~/.ssh_tool/register_hooks.py — 注册 hooks 到 Claude settings
  static const String _registerHooksPy = '''#!/usr/bin/env python3
"""register_hooks.py - Append ssh_tool hooks to ~/.claude/settings.json"""
import json, os

SETTINGS_FILE = os.path.expanduser("~/.claude/settings.json")
MARKER = "ssh_tool"

HOOK_DEFS = {
    "Stop": {
        "matcher": "",
        "hooks": [{"type": "command", "command": "~/.ssh_tool/hooks/on_stop.sh"}]
    },
    "Notification": {
        "matcher": "",
        "hooks": [{"type": "command", "command": "~/.ssh_tool/hooks/on_notification.sh"}]
    },
    "UserPromptSubmit": {
        "matcher": "",
        "hooks": [{"type": "command", "command": "~/.ssh_tool/hooks/on_user_prompt.sh"}]
    },
}

settings = {}
if os.path.exists(SETTINGS_FILE):
    try:
        with open(SETTINGS_FILE) as f:
            settings = json.load(f)
    except Exception:
        pass

hooks = settings.setdefault("hooks", {})

for event, hook_def in HOOK_DEFS.items():
    event_hooks = hooks.setdefault(event, [])

    already = False
    for existing in event_hooks:
        for h in existing.get("hooks", []):
            if MARKER in h.get("command", ""):
                already = True
                break
        if already:
            break

    if not already:
        event_hooks.append(hook_def)

settings["hooks"] = hooks

os.makedirs(os.path.dirname(SETTINGS_FILE), exist_ok=True)
with open(SETTINGS_FILE, "w") as f:
    json.dump(settings, f, indent=2)
''';
}

/// 同步结果
class SyncResult {
  /// 同步前是否已配置（false 表示本次首次部署）
  final bool wasConfigured;

  /// 远程会话状态 {tmuxName: {type, activity, message, updatedAt, workDir}}
  final Map<String, dynamic> sessions;

  /// tmux 存活的会话名集合
  final Set<String> aliveTmuxSessions;

  SyncResult({
    required this.wasConfigured,
    required this.sessions,
    required this.aliveTmuxSessions,
  });
}
