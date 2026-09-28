String _normalizeTmuxVersion(String tmuxVersion) =>
    tmuxVersion.trim().toLowerCase();

bool supportsTerminalFeatures(String tmuxVersion) {
  final normalized = _normalizeTmuxVersion(tmuxVersion);
  final match = RegExp(r'tmux\s+(\d+)(?:\.(\d+))?').firstMatch(normalized);
  if (match == null) {
    return false;
  }

  final major = int.tryParse(match.group(1) ?? '') ?? 0;
  final minor = int.tryParse(match.group(2) ?? '0') ?? 0;
  if (major > 3) {
    return true;
  }
  if (major < 3) {
    return false;
  }
  return minor >= 2;
}

bool tmuxConfigMatchesClipboardTransport(String content, String tmuxVersion) {
  if (supportsTerminalFeatures(tmuxVersion)) {
    return content.contains('terminal-features') &&
        content.contains('xterm-256color:clipboard');
  }

  return content.contains('terminal-overrides') &&
      content.contains('xterm-256color:Ms=');
}

String buildTmuxConfig(String tmuxVersion) {
  final clipboardTransport = supportsTerminalFeatures(tmuxVersion)
      ? 'set -as terminal-features ",xterm-256color:clipboard"'
      : r'set -ga terminal-overrides ",xterm-256color:Ms=\E]52;%p1%s;%p2%s\007"';

  return '''
# ssh_tool_app 专用 tmux 配置（不修改用户 ~/.tmux.conf）
set -g mouse on
set -g history-limit 10000
set -g default-terminal "xterm-256color"
$clipboardTransport
set -g escape-time 10
set -g status-style "bg=#252545,fg=#cccccc"
# tmux 原生复制：鼠标拖选结束时复制到 tmux buffer，并通过 OSC 52 同步
setw -g mode-keys vi
set -g status-keys vi
set -g set-clipboard on
set -s set-clipboard on
bind -Tcopy-mode MouseDragEnd1Pane send -X copy-selection-and-cancel
bind -Tcopy-mode Enter send -X copy-selection-and-cancel
bind -Tcopy-mode-vi MouseDragEnd1Pane send -X copy-selection-and-cancel
bind -Tcopy-mode-vi Enter send -X copy-selection-and-cancel
''';
}
